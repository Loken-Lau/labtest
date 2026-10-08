# lmcache-mp 改写说明报告

> 从 lmcache-lab（embedded 模式）改写为 LMCache **MP 模式**实验台的全记录。
> 含：MP vs embedded 调研结论、旧仓库 review、改写清单、L1/L2 选型论证、
> 端到端验证数据、mooncake 上分布式路线。
> 所有标注「实测」的数字都是 2026-09-23 在本机（H200 / vLLM 0.29.0 / LMCache 0.5.5）跑出来的。

---

## 1. TL;DR

| 项 | 结论 |
|---|---|
| 架构 | 一个 `lmcache server` 独立进程（ZMQ :5555 数据面 + HTTP :8080 控制面）+ N 个 vLLM 实例经 `LMCacheMPConnector` 接入 |
| L1 | server 进程内**全实例共享**内存池，`--l1-size-gb`（默认 60GB，LRU）；**多模型 KV 按键共存天然隔离**（§5.5） |
| L2 | 可插拔 `--l2-adapter`：默认 `resp`→Redis；**`mooncake_store` 已编译跑通**（2026-10-07 tcp 语义验证，rdma/多节点见 §6） |
| trace | 回放全量切到 AIPerf（mooncake_trace + fixed-schedule），自研回放器删除 |
| sleep 秒级拉起 | `SLEEP=1` 启动 + `rack.sh sleep/wake`，唤醒实测 0.512s，热状态住 server 不丢（§5.6） |
| 验证 | 实例重启后热状态不丢（L1 保活）；冷实例+热 L1 单请求 external 命中 91.3%、TTFT 162→70ms |
| 删掉 | router 全套（按需求）、自研回放器 replay.py、双 Redis 分池 |

---

## 2. 调研：MP 模式 vs embedded 模式

### 2.1 两模式是什么

**embedded（in-process，旧 lab 用的，官方已标 deprecated）**：
LMCache 作为库嵌在每个 vLLM 进程里。vLLM 启动带 `LMCacheConnectorV1` +
`LMCACHE_CONFIG_FILE=<yaml>`，每个实例**各自**持有一份 L1（local_cpu）和 L2 客户端
（remote_url），跨实例共享只能靠两边写同一个 Redis 达成——lab 的 `sha256_cbor` +
`PYTHONHASHSEED=0` 就是为了让两边的键对得上。

**MP（multiprocess，本仓库）**：
LMCache 是独立进程 `lmcache server`，自己持有全部缓存层级。vLLM 侧换成
`LMCacheMPConnector`，通过 ZMQ 连 server：

```
vLLM: --kv-transfer-config '{"kv_connector":"LMCacheMPConnector",
       "kv_role":"kv_both",
       "kv_connector_extra_config":{
         "lmcache.mp.host":"tcp://<server-ip>",
         "lmcache.mp.port":5555}}'
```

注意：**不再需要 per-instance YAML、不需要 LMCACHE_CONFIG_FILE、不需要 PYTHONHASHSEED**。
chunk 大小、哈希算法、L1/L2 全部收敛为 server 启动参数，一份配置管所有实例。

### 2.2 差异对照

| 维度 | embedded | MP |
|---|---|---|
| LMCache 进程 | 无（在 vLLM 里） | 独立 `lmcache server` |
| L1 | 每实例私有（lab: 20GB×N 份） | **全实例共享一份**（省内存+命中率高） |
| L2 客户端 | 每实例一份 | server 一份 |
| 实例崩溃/重启 | 该实例 CPU 层全丢 | **缓存不丢**（server 活着就在） |
| 缓存键一致性 | 要自己保证（hash 种子/算法） | server 端统一计算，天然一致 |
| 配置面 | N 份 yaml | server 1 份 CLI 参数 |
| CPU/内存开销位置 | 吃在推理进程里 | 吃在 server 进程里 |
| 观测 | vLLM /metrics 里的 external_* 计数器 | 同左 + server 自己的 HTTP `/status` |
| 官方状态 | deprecated | 推荐，且是分布式路线的基础 |

### 2.3 关键接线细节（从本机源码确认）

- 数据面：ZMQ（`--transport zmq`，也支持 grpc），默认端口 5555。
- 控制面：HTTP `--http-port`（默认 8080），FastAPI，端点有
  `/healthcheck` `/status` `/config` `/config/adapters` `/cache/objects`
  `/cache/clear` `/cache/prefetches` `/quota` `/reconfigure/*`。
- 本 lmcache 0.5.5 构建**必填** `--eviction-policy`（LRU/IsolatedLRU/noop）——
  官方文档没写，实测踩到，`start_server.sh` 已内置。
- server 还有 coordinator（`--coordinator-url`，分布式多 server 注册发现用）、
  p2p、blend 等 进阶面，本仓库先不用。

---

## 3. 旧仓库（lmcache-lab）review

整体评价：实验设计思路是好的（确定性块、理论天花板、LRU 模拟、aiperf 交叉验证），
但工程质量有系统性问题，改写时逐条处理：

### 3.1 正确性 bug

| # | 位置 | 问题 | 本仓库处理 |
|---|---|---|---|
| 1 | `replay.py fetch_metrics` | `async for raw in resp.content` 按网络 chunk 解码再逐块 match 正则。**chunk 边界≠行边界**，metrics 页一大就会漏行（丢指标） | collect.py 一次性读全 + `splitlines()`，并写进文件头注释防止回退 |
| 2 | `blocks.py` | `_block_text_cache` 无上限缓存（每模型每 hash_id 一条文本），长 trace 内存失控 | 删掉整个文本模式——aiperf 内置 hash_ids 合成（带并行解码），不需要自己维护 |
| 3 | `replay.py` summary 循环 | `pair = next(...)` 变量 shadow + 每端口线性查 pairs | 删除（回放器整体退役） |
| 4 | `theoretical_ceiling` | 注释自述「漏了 seen.update 导致 ceiling 恒 0」——修过但没测试兜底 | ceiling 函数独立在 window.py，被 aiperf 流水线和 analyze.py 共用 |
| 5 | 启动脚本 | `PYTHONHASHSEED=0`、每端口一份几乎相同的 yaml、路径硬编码散落各处 | env.sh 单一事实来源；MP 模式下这两项直接消失 |

### 3.2 结构问题

- **双份指标口径**：`replay.py` 和 `exp/aiperf_metrics.py` 各自维护一份
  METRIC_RE + 命中率计算，靠人肉对齐（报告里写「交叉一致 7.41% vs 7.52%」）。
  → 收敛为 `bench/collect.py` 唯一实现，snapshot/delta 两个子命令。
- **trace 工具链三分叉**：download.sh（下载）/ gen_corpus.py（模拟）/ replay.py（回放）
  与 aiperf 并存，同一实验要在两套体系里换算。→ aiperf 成为唯一回放器，
  download/window/analyze 只做数据准备与离线分析。
- **router 与主体耦合**：start_all.sh 把 router 拉进主流程。→ 按需求整体删除。
- **双 Redis 分池（A@6379/B@6381）**：embedded 时代每模型一池是迫不得已
  （实例各自配置）。MP 模式缓存键自带模型维度，一个池天然分模型 → 单池。
- **sleep 实验**（sleep_warm.py）论证的命题「热状态住在池子里，跨实例继承」
  在 MP 下**自动成立**（server 就是独立进程，实例随便死），实验失去判决性 → 删。

### 3.3 值得保留并继承的资产

- 确定性 hash_id→token 块思想（aiperf 原生支持，继续受益）
- LRU 容量-命中率模拟（`analyze.py` 继承）
- Mooncake trace 下载转换（`download.py` 继承，加 schema 校验）
- 「取回 vs 重算的分界线由 KV 字节密度决定」等实验结论（报告仍引用）

---

## 4. 新仓库写了什么（逐文件）

```
lmcache-mp/
├── env.sh                    # ★ 单一事实来源：路径/端口/模型表/L1/L2 参数，全部可用环境变量覆盖
├── config/
│   ├── l2-redis.json         # L2=resp 适配器（指向本机 Redis）
│   ├── l2-mooncake.json      # L2=mooncake_store 适配器（分布式目标，§6）
│   └── redis.conf            # 单池：300GB allkeys-lru 纯内存
├── scripts/
│   ├── env_check.sh          # 依赖自检（二进制/权重/L2 前置/端口/GPU）
│   ├── start_server.sh       # 起 lmcache server（自动带 L2 前置，幂等，传输模式 auto）
│   ├── stop_server.sh        # [--keep-redis]
│   ├── start_engine.sh       # 起一个 vLLM 实例接 MP server（MP 接线见 §2.3；SLEEP=1 见 §5.6）
│   ├── stop_engine.sh        # 按端口精确停实例
│   ├── rack.sh               # 模型货架：sleep/wake 秒级换入换出 + 状态面板（§5.6）
│   └── status.sh             # 三面板：server /status + 实例 /metrics + L2 水位
├── trace/
│   ├── download.py           # Mooncake parquet→jsonl（schema 校验、幂等、镜像）
│   ├── window.py             # ★ 切实验窗口：时间/条数/长度过滤 + 时间轴压缩 + 打印理论上限
│   └── analyze.py            # 统计 + LRU 容量模拟（选 L1/L2 容量的依据）
├── bench/
│   ├── run_aiperf.sh         # ★ 一条命令回放：前后快照 + aiperf + 差值，落 results/
│   └── collect.py            # ★ 唯一指标口径：snapshot/delta（修了按 chunk 解码 bug）
└── checks/
    └── smoke.py              # 链路冒烟：external 命中/L1 对象数判定
```

标 ★ 的是每天都会碰的文件。与旧仓库的对应关系：

| 旧 lab | 新仓库 | 变化 |
|---|---|---|
| `scripts/start_qwen.sh` + 4 份 lmcache-*.yaml | `scripts/start_server.sh` + `start_engine.sh` | 配置从 N 份 yaml 收敛为 server 一份 CLI；实例脚本只剩端口/模型 |
| `trace/replay.py`（自研回放） | `bench/run_aiperf.sh` | 退役，aiperf 顶替（timestamp 精确回放 + 自带 TTFT/吞吐统计） |
| `trace/blocks.py` | （删除） | aiperf 内置 hash_ids 确定性合成 + 并行 decode |
| `trace/gen_corpus.py` | `trace/analyze.py` | 保留模拟，修结构 |
| `trace/download.sh` | `trace/download.py` | parquet→jsonl 加校验 |
| `exp/aiperf_metrics.py` + 手工命令 | `bench/collect.py` + `run_aiperf.sh` | 两套口径合一 |
| `router/*`、`exp/sleep_warm.py`、`model_rack.sh` 等 | （删除） | 按需求/失去判决性 |
| 手工切 `conversation_600s_aiperf.jsonl` | `trace/window.py` | 参数化切窗 + 倍速 + 上限计算 |

### 典型工作流（已实测跑通）

```bash
bash scripts/env_check.sh
bash scripts/start_server.sh                      # L2=redis（默认）
bash scripts/start_engine.sh 8000 0.45
"$PY" checks/smoke.py --port 8000 --model qwen3-8b
"$PY" trace/download.py
"$PY" trace/analyze.py --trace data/traces/conversation_trace.jsonl --model qwen3-8b
"$PY" trace/window.py --trace data/traces/conversation_trace.jsonl \
    --seconds 600 --max-input 7000 --speed 10 -o data/traces/conv_600s_x10.jsonl
bash bench/run_aiperf.sh data/traces/conv_600s_x10.jsonl 8000 qwen3-8b
```

---

## 5. L1 / L2 选型（重点）

### 5.1 层级总览

```
GPU APC（vLLM 自带，每实例私有，最快的命中）      ← 不归我们管，天然存在
  └─ L1：lmcache server 进程内共享内存池          ← 我们配的
       └─ L2：可插拔适配器（redis / mooncake / fs / s3 / ...） ← 我们配的
```

### 5.2 L1：用了什么

**用：`lmcache server --l1-size-gb`（默认 60GB）的进程内 pinned 内存池 + LRU。**

- 形态：server 启动即向 OS 预留（默认 lazy 分配，`--l1-use-lazy`），对象带 TTL
  （实测默认 write_ttl=600s / read_ttl=300s，读会续期），水位超限按 LRU 逐出。
- 容量依据：analyze.py 的 LRU 模拟曲线（本机 conversation trace 600s 窗口：
  512 块(38.7GB)→22.1%，1024 块(77GB)→27.1%，逼近上限 28.95% 的拐点在 ~512-1024 块，
  60GB 落在拐点左侧的性价比区间；主机 755GB 内存、可用 ~430GB，留足余量给 L2 写穿与系统）。

**为什么用这个（而不是别的）：**

1. MP 模式下 L1 是 server 进程内实现，**没有第二个选项要选**——选的是参数而不是实现。
   真正的收益在「全实例共享一份」：旧 lab 是 20GB×N 份各自为政，同一前缀被 N 个实例
   各存一份；现在一份 60GB 全体共用，等效容量和命中率都上去。
2. L1 的职责定位是「热工作集的 RAM 缓冲」，LRU + TTL 足够，不需要更花哨的策略。

**还可以用什么（同一 L1 位的变体，都在 server CLI 上）：**

| 变体 | 参数 | 什么时候用 |
|---|---|---|
| 惰性分配 | `--l1-use-lazy --l1-init-size-gb` | 不想让 server 启动就吃满 60GB |
| **devdax 持久内存** | `--l1-devdax-path` | 有 CXL/PMem 时 L1 掉电不丢、且能与 dax L2 适配器组成混合层（hybrid L1，代码里专门有 single-region 融合逻辑） |
| **GDS（GPUDirect Storage）** | `--gds-l1-path --gds-l1-backend {auto,cufile,hipfile,ugds,phx}` | L1 直接放 NVMe 且 GPU 绕过 CPU 拷贝（cuFile），旧 lab「取回运费」问题的另一条解法 |
| 逐出策略 | `--eviction-policy {LRU,IsolatedLRU,noop}` + watermark/ratio | IsolatedLRU 按命名空间隔离（多租户），noop 只用于调试 |
| TTL | `--l1-write/read-ttl-seconds` | 控制热度和新鲜度 |

### 5.3 L2：用了什么、为什么、还可以用什么

**现状（本仓库默认）：`resp` 适配器 → 本机 Redis 单池（300GB, allkeys-lru）。**

为什么先用它：
- **今天就能跑**：`resp` 是原生 C++ RESP 连接器（非 python redis 客户端），
  走 server 自带依赖，零编译；`config/redis.conf` 一份单池替代旧 lab 的双池。
- **兼容旧实验**：旧 lab 大量结论（容量-命中率曲线、300GB→14.9% 全量命中率等）
  都在 Redis 池上得出，保持 L2=Redis 让新旧数据可比。
- **职责清晰**：L2 在单机阶段只是「L1 装不下的溢出 + 持久化兜底」，Redis 足任。

**目标（你上分布式的优先项）：`mooncake_store` 适配器。**

为什么 mooncake 是分布式正解（`config/l2-mooncake.json` 已备好）：
1. **RDMA 原生**：mooncake 的 TransferEngine 就是为 KV 传输设计的（旧 lab 实验
   已论证「socket 档取回运费超过重算，qwen3 147KB/tok 走 socket 划不来」——
   RDMA 正是解这个的）。本机 5×mlx5 HCA 就绪。
2. **master 元数据 + 跨节点拓扑**：mooncake-store 架构（master 管元数据 +
   各节点 transfer engine 数据面）天然支持多节点共享一个 L2，比 Redis 集群
   分片更适合大块 KV 的局部性调度。
3. **LMCache 官方深度集成**：`mooncake_store` 适配器把 setup 键**原样转发**给
   mooncake 的 `setup_internal`，且 `protocol=rdma` 时自动把 L1 内存区预注册给
   RDMA（`l1_registration`），L1↔L2 零拷贝路径是专门优化过的。
4. **H200 + 多节点演进路线一致**：RFC #3262 的分布式 MP 设计讨论也是围绕
   node-local MP server + 跨节点 store 的形态。

**启用步骤（2026-10-07 实测跑通，tcp 零 RDMA 语义验证）**：
```bash
# 构建产物都在 ~/build/mooncake-l2（源码 mooncake-src/ + 安装前缀 mooncake-install/，一键复刻见下）
L2_BACKEND=mooncake bash scripts/start_server.sh   # 自动连带起 mooncake_master(:50051)
```
Mooncake Store 2.0 架构要点（与旧认知的差异）：**没有独立 store node 进程**——
`mooncake_master` 只做控制面（:50051 RPC + :9003 admin 指标），数据面 P2P，
**各 client（即 lmcache server 进程）贡献 DRAM 段**组成池子
（`global_segment_size`，config/l2-mooncake.json 现为 180GB——**必须 > L1 容量**，
否则 L1 滚一轮时 L2 同轮淘汰对象，取回实验假阴性）。TE 对等发现用
`metadata_server:"P2PHANDSHAKE"` 字面量，**不需要 etcd/redis 元数据服务**。
键名注意：master 地址键是 `master_server_addr`（不是 master_server），
协议键 `protocol`（tcp|rdma），`rdma_devices`（不是 device_name）。

构建配方（无 sudo，全部用户态；只记录关键坑，完整命令见 ~/build/mooncake-l2/）：
```bash
# 1) mooncake v0.3.13.post1 源码（依赖机器上都有：zstd/xxhash/glog/gflags/jsoncpp/yaml-cpp/numa/liburing/ibverbs；yalantinglibs 走 FetchContent）
git clone --depth 1 -b v0.3.13.post1 https://github.com/kvcache-ai/Mooncake && git submodule update --init extern/pybind11
cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON -DWITH_STORE_RUST=OFF \
      -DWITH_P2P_STORE=OFF -DWITH_EP=OFF -DBUILD_UNIT_TESTS=OFF -DBUILD_EXAMPLES=OFF -DUSE_CUDA=OFF \
      -DCMAKE_INSTALL_PREFIX=<prefix>       # 系统 cmake 3.16 太老，用 pip 装的 cmake 4.x
cmake --build build --target mooncake_store mooncake_master -- -j64 && cmake --install build  # install 末尾对未编的测试目标报错可忽略
patchelf --set-rpath '$ORIGIN' <prefix>/lib/libmooncake_store.so   # 关键：默认无 rpath，且要放一份真系统 libffi.so.7 进 <prefix>/lib
#   （conda python 的 RPATH $ORIGIN/../lib 里有个"假"libffi.so.7=ffi8，p11-kit 要真 ffi7 的 LIBFFI_BASE_7.0 符号，不放会 ImportError）
# 2) lmcache 0.5.5 源码重装（原 wheel 无 mooncake 扩展）
SETUPTOOLS_SCM_PRETEND_VERSION=0.5.5 BUILD_MOONCAKE=1 \
  MOONCAKE_INCLUDE_DIR="mooncake-src/mooncake-store/include;.../cachelib_memory_allocator{,/include,/fake_include};build/mooncake-store/include;mooncake-transfer-engine/include;mooncake-common/include;build/_deps/yalantinglibs-src/include" \
  MOONCAKE_LIB_DIR=<prefix>/lib \
  pip install --no-build-isolation --no-deps --force-reinstall .   # 需先装 grpcio-tools==1.78.0（protobuf 代码生成）
```
验证记录（2026-10-07）：server /status 适配器 active=1；master :9003 `Clients:1, Mem Storage 64GB`；
smoke 写入后 **master 立即可见 `Keys:10 / 360MB`——mooncake 路径的 L2 写穿是即时的**
（对比 §5.4 redis 的滞后批量写穿，做对照实验时口径不同要留意）。
**L2 取回路径也端到端验证**（`checks/l2_retrieve.py`，可复跑）：L1 水位滚一轮逐出 probe →
冷实例重放 → `external hits 2048/2106 (97%)`，server 日志铁证
`Prefetch request completed: 8/8 retained keys (0 L1, 8 L2) in 122.1ms`。
排障教训（三个假阴性，都记下来防再踩）：
1. mooncake 池容量 ≥ L1 才能保住被逐出的对象——首测 64GB 池被灌满时 master 自己
   淘汰了 probe（`Eviction: keys=1058`），"查无此键"是真 miss 不是链路坏；
2. master :9003 的 `Get/Exist` 是**每秒速率**非累计值，空闲时采样恒 0，要在 burst 中采；
3. lookup 日志行 `(N L1, M L2)` 是最可靠的分层证据（DEBUG 级更全）。
单机注意：mooncake 数据住在 lmcache server 自己贡献的段里，**server 重启 L2 也丢**
（redis 时代 L2 在外部进程可幸存）；多 client 贡献段才是它分布式价值的形态。
分布式时：多台机各跑一个 lmcache server，同一份 l2-mooncake.json 指向同一 master，
vLLM 连本机 server（LMS_HOST 改远端 IP 即可跨机）。

**完整 L2 选项表（本机 lmcache 0.5.5 注册的 17 个适配器）**：

| 适配器 | 本机可用 | 定位 / 什么时候选 |
|---|---|---|
| **resp** | ✅（默认） | Redis/Valkey 单机或集群，运维熟、兼容旧实验 |
| **mooncake_store** | ✅ 已编译跑通(tcp) | **分布式/RDMA 优先项**（见上） |
| fs / fs_native | ✅ | 本地 NVMe 文件层——大容量、断电不丢；fs_native 是原生实现更快。无 RDMA 时的单机扩容选项 |
| valkey | ✅ | 同 resp，面向 Valkey 部署 |
| s3 | ✅ | 对象存储——跨机房容灾、冷数据；延迟高不适合热路径 |
| nixl_store / nixl_store_dynamic | ✅ | NVIDIA NIXL 传输层（需要单一大 L1 内存区，混合层模式）——另一条 RDMA 路线，mooncake 之外的候选 |
| p2p | ✅ | server 间点对点直传（`--p2p-*` 参数），无中心 store 的对等共享 |
| dax | ✅ | DAX 设备直存（和 devdax L1 组成持久内存混合层） |
| bigtable / aerospike / sagemaker-hyperpod / hfbucket | ✅ | 云厂/托管存储集成 |
| raw_block / plugin / native_plugin / fault_inject / mock | ✅ | 调试/研究用（fault_inject 做混沌测试不错） |

多适配器可叠（`--l2-adapter` 可重复，有序 = 分层），例如 `fs + s3`（本地 NVMe 热、
S3 冷）。这是后面容量-成本曲线实验的现成素材。

### 5.4 L2 写穿时机（短实验看不见，长实验大量写）

20 条的小窗口回放后 redis dbsize=0、store_controller 无待写任务——**短实验下 L2
看似不写穿**。但全量 59 分钟回放（6060 条）后：redis 存活 7676 键、用量打满
300GB、**累计逐出 40831 键**——L2 实际在大量写穿，只是写入是滞后/批量的
（推测由 periodic notifier / 逐出触发，`--periodic-notifier-interval-ms` 可调）。
结论：**做 L2 相关实验必须跑足够长的窗口**（或对比 dbsize 增长曲线确认写入已
开始），别用几分钟的小实验下"L2 没写"的结论。`--l2-store-policy
{default,skip_l1}` 和 `--l2-prefetch-policy {default,retain}`（L2→L1 预取）是
配套旋钮。

### 5.5 L1 的多模型共存与淘汰机制（源码级确认）

**多模型 KV 可以共存，且天然隔离。** 缓存键 `ObjectKey` 是五元组：

```
(chunk_hash, model_name, kv_rank, object_group_id, cache_salt)
```

`model_name` 是键的一等公民：qwen3-8b 和 qwen2.5-7b 的块即使内容哈希相同也是
不同对象。两个模型的实例同时往一个 server 存 KV，L1 里混着放、查找按完整键精确
匹配，互不污染、互不误命中。这也是 MP 模式替代旧 lab「按模型分 Redis 池」的底气
——一个池（无论 L1 还是 L2）自动按模型分键。

**淘汰机制有三层，按时间顺序作用：**

| 层 | 机制 | 参数（默认） | 说明 |
|---|---|---|---|
| 1 | TTL 到期 | write 600s / read 300s，读续期 | 对象写入 10 分钟没人读就过期；每次命中续 5 分钟 |
| 2 | 水位逐出 | watermark 0.8 / ratio 0.2 | 内存用到 80% 触发，一次逐掉 20%（LRU 尾部） |
| 3 | 逐出策略 | `--eviction-policy` | 决定"谁是尾部"，见下 |

逐出策略的可选项（`CreateEvictionPolicy` 工厂，源码确认）：

- **`LRU`（本仓库默认）**：**全局单链表**——所有模型、所有 salt 的对象在一条
  LRU 上竞争。简单高效，但没有模型间公平性：大流量的 qwen3 可以把 qwen2.5 的
  KV 全部挤出去（只要 qwen3 访问更频繁）。
- **`IsolatedLRU`**：**按 `cache_salt` 分桶**，每桶一条独立 LRU，配合 QuotaManager
  （HTTP `PUT /quota/{cache_salt}` 设配额）只逐超配额桶的尾部，别的桶不动。
  注意隔离维度是 `cache_salt` **不是** `model_name`——想按模型隔离，给各模型的实例
  配不同的 `LMCACHE_CACHE_SALT`（如模型名），再设各桶配额。多模型混跑担心互相
  挤占时用这个。
- **`noop`**：不逐出（满了写不进，仅调试）。

选型建议：单模型或模型间流量悬殊可接受 → LRU；多模型要保底配额 → IsolatedLRU +
per-model salt + quota（HTTP API 免重启可调）。

### 5.6 「冷/热」术语澄清 与 sleep 秒级拉起（本仓库已支持）

**旧报告里"冷/热"指的是缓存状态，不是模型热度：**

| 旧 lab 术语 | 含义 | 和模型调度无关 |
|---|---|---|
| 冷实例 | 加载后从未处理过流量的实例：GPU KV 空，共享存储里也没有它这个模型的 KV | |
| 热实例 | 处理过流量的实例：其请求的 prefill KV 已写穿到共享存储（"热"住在存储里，不在实例里） | |
| 加热 warm | 发一组确定性 prompt，把 KV 写进共享存储 | |

它是「**这块 KV 在不在缓存里**」的判定词，服务于 sleep 实验的验证逻辑（睡前
加热、醒后探测，用 TTFT 变化证明缓存活着）。**不涉及**「识别哪个模型是热门模型、
决定谁常驻 GPU」那类冷热模型调度——那个确实需要识别算法，本仓库不做，也不需要。
下文统一改用「缓存命中/未命中」表述，避免歧义。

**sleep 秒级拉起（你要的能力，已加回并实测）**：

```bash
SLEEP=1 bash scripts/start_engine.sh 8000 0.29        # 带 sleep 能力启动
bash scripts/rack.sh sleep 8000                       # 睡下: GPU 全释放(~8s)
bash scripts/rack.sh wake 8000                        # 唤醒: ~0.5s
bash scripts/rack.sh status                           # 货架面板
```

与旧 lab 的关键区别：热状态从「Redis 池绕一圈」变成「server L1/L2 架构自带」——
sleep 会丢实例的 GPU KV，但 server 里的 KV 不动，唤醒后直接取回。

**实测记录（2026-09-23，qwen3-8b @ util 0.30，SLEEP=1）**：

| 步骤 | 实测 |
|---|---|
| 加热请求（冷缓存） | TTFT 323ms，KV 落入 server L1（12 对象/453MB） |
| `rack.sh sleep` | 7.8s，GPU 43GB→2.2GB；**server L1 不受影响** |
| `rack.sh wake` | **0.512s** |
| 唤醒后首请求 | 命中 server L1（external hits 3072 tok）；TTFT 2556ms 含一次性重建开销 |
| 唤醒后稳态 | TTFT 56ms / 40ms |

结论：秒级拉起成立（0.5s 唤醒 vs ~120s 冷启动 ≈ 240 倍），唤醒后首个请求有一次
~2.5s 的传输通道重建税，之后恢复稳态。若对首请求延迟敏感，可在唤醒后立刻发一条
小请求预热。

**实现上的坑（踩了三个，都在脚本里处理好了）**：

1. sleep 模式下 vLLM 用 CuMemAllocator（CUDA VMM）分配 KV，与默认
   `lmcache_driven`（CUDA IPC 零拷贝）**不兼容**，启动即 `CUDA error: invalid
   argument`（lmcache 源码注释明说两者互斥）。
2. `use_vmm_api`（VMM IPC 通道）理论可解，但其 POSIX fd 带外传输在本地
   lmcache 0.5.5 **只接了测试注入、无生产通道**（server 报 "No VMM fd resolver
   installed"）。
3. **正解是 `engine_driven` 传输模式**：worker 侧经 SHM 池 gather/scatter 拷贝，
   与分配器无关。`start_engine.sh` 在 SLEEP=1 时自动带上
   `"lmcache.mp.mp_transfer_mode":"engine_driven"`，`start_server.sh` 默认
   `--supported-transfer-mode auto` 两边都开。代价是比零拷贝多一次搬运
   （加热请求 323ms vs IPC 模式 162ms，量大时此差距会放大——sleep 实例与极致
   传输性能暂不可兼得，等上游接好 VMM fd 传输后可回零拷贝）。

---

## 6. 分布式演进路线（建议顺序）

```
已完成      单机: 1×lmcache server(L1 60G + L2 redis) + 2×vLLM        ← 已验证
已完成(a)   L2 换 mooncake_store(protocol=tcp, 单 master)             ← 2026-10-07 语义跑通（§5.3）
下一步(b)   protocol=rdma + 多 HCA                                     ← 解决"取回运费"问题（本机 5×mlx5 就绪）
之后(c)     多节点: 每节点 1×MP server, 共享同一 mooncake master       ← L2 全局共享, L1 节点本地
可选(d)     打开 coordinator(--coordinator-url)                        ← 多 server 注册/发现/事件
可选(e)     p2p 或 nixl_store 适配器对照实验                            ← 无中心 vs 中心化 store
```

每一步都只动 `env.sh`/`config/`，主体代码零改动——这是把配置收敛到 server 端的最大红利。

---

## 7. 指标口径（实测确认，读数前必看）

vLLM `/metrics` 上的两个口径**分工**（MP connector 下语义与 embedded 相同，但计数时机不同）：

| 计数器 | 含义 | 什么时候增长 |
|---|---|---|
| `vllm:prefix_cache_{queries,hits}_total` | GPU APC 口径（含从 server 取回后落 GPU 的块） | 请求调度时同步 |
| `vllm:external_prefix_cache_{queries,hits}_total` | **从 MP server 取回的 token** | 异步上报，实测要 ~10s 才可见（snapshot 要留余量） |

三条实测推论：
1. **同实例重复请求不增 external**（命中 GPU APC，不查外部）——验证 external 命中
   必须「冷实例 + 热缓存」（smoke.py 里已写明）。
2. combined = (prefix_hits + external_hits) / queries，可略超理论上限
   （APC 16-token 粒度 vs trace 512-token 块粒度，实测 31.75% vs 27.94% 上限，正常）。
3. 指标名带 `{engine="0",model_name=...}` 标签，正则必须跳过标签段再取数值
   （旧 lab 的 smoke 判定就是这么静默失效的，本仓库已修）。

server 侧另有 `/status`：L1 的对象数/内存/TTL、store_controller 的待写/在飞数、
适配器健康——`status.sh` 和 `collect.py` 已接入。

---

## 8. 端到端验证记录（2026-09-23 本机实测）

| # | 实验 | 结果 |
|---|---|---|
| 1 | `lmcache server` 启动（L2=none / redis） | 均健康；/status 可见 L1 精确 60GiB、resp 适配器 active=1 |
| 2 | vLLM 0.29 + LMCacheMPConnector 接入 | 连接成功，external 计数器存在且工作 |
| 3 | 冒烟（同实例连发 2 条相同 prompt） | TTFT 162→38ms；external 增量 0（GPU APC 拦截，符合口径） |
| 4 | **实例重启实验**（停实例→L1 不动→重启→单请求） | L1 保活（10 对象/377MB）；TTFT 70ms（冷启 162ms 的 43%）；**external hits +2560/2804 = 91.3% 从 server L1 取回** ← MP 模式招牌特性的直接证据 |
| 5 | aiperf 端到端（20 条窗口 ×2 轮） | 流水线跑通；第一轮 gpu_apc 31.75% vs 上限 27.94%（捡边角正常）；第二轮 99.49%（GPU APC 容量大，全拦）；L2 写穿未观测（§5.4） |
| 6 | window.py 与旧 lab 交叉验证 | 同参数切窗 802 条 = 旧 lab 手工产物 801 条 ✓ |
| 7 | SLEEP=1 实例 + rack.sh（§5.6） | 睡 7.8s/GPU 43G→2.2G；**唤醒 0.512s**；唤醒后 external hits 3072（server L1 取回）；稳态 TTFT 40-56ms |
| 8 | **全量 conversation 回放**（6060 条/59min，冷缓存，qwen3-8b@0.30） | **合计命中率 36.61% vs 理论上限 36.35%（100.7%，捡边角）**；gpu_apc 19.6% + external 21.17%；TTFT p50 369/p99 2971ms；吞吐 1.7 req/s；L1 终态 1243 对象/46.9GB；redis 打满 300GB 逐出 40831 键（L2 写穿实证，§5.4） |
| 9 | **mooncake L2 上线**（2026-10-07，§5.3） | 扩展编译安装；`mooncake_master` 自动拉起；写穿即时（smoke 级即 Keys 可见）；L1 水位淘汰写穿 L2（滚 60GB 全部落 mooncake）；**L2 取回 97%**（`0 L1, 8 L2`，§5.3 验证记录） |

附带修掉的实施 bug（都是跑出来的）：`--eviction-policy` 必填、env.sh 覆盖
外部环境变量、aiperf 参数名 `--output-artifact-dir`、smoke 正则漏标签、
subprocess `~` 不展开。

## 9. 已知局限 / 下一步

- ~~mooncake 扩展未编译（§5.3 卡点）~~ → **已解决并实测跑通**（2026-10-07，tcp 语义；
  下一步 protocol=rdma + 多 HCA，再往后多节点）。
- L2 写穿时机待长窗口实验确认（§5.4；注意 mooncake 路径写穿是即时的，与 redis 口径不同）。
- `--max-workers`/`--max-gpu-workers`/`--max-cpu-workers`、prefetch 旋钮未调优，
  上 RDMA 前建议先扫一遍。
- trace 只有 Mooncake 三条；aiperf 还支持 baseten/bailian 等 loader，加格式即用。
