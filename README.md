# lmcache-mp

多模型 KV cache 共置实验台（**MP 模式**）：一个 LMCache server 独立进程 +
多个 vLLM 实例共享它。从 lmcache-lab（embedded 模式 + 双 Redis 分池）改写而来，
trace 回放全量切换到 [AIPerf](https://github.com/ai-dynamo/aiperf)。
设计细节、L1/L2 选型依据见 **[REPORT.md](REPORT.md)**。

## 架构

```
                    AIPerf (mooncake_trace, fixed-schedule 回放)
                        │ HTTP
                        ▼
   ┌─────────── vLLM :8000 (qwen3-8b) ───────────┐
   │        LMCacheMPConnector (ZMQ, kv_both)     │   ← 每实例仍自带 GPU APC
   └───────────────────────┬──────────────────────┘
   ┌─────────── vLLM :8001 (qwen2.5-7b) ─────────┐
   │        LMCacheMPConnector (ZMQ, kv_both)     │
   └───────────────────────┬──────────────────────┘
                           ▼
        lmcache server（独立进程, :5555 ZMQ / :8080 HTTP）
        ├── L1: 进程内共享内存池 --l1-size-gb（所有实例共享一个 L1）
        └── L2: --l2-adapter 可插拔
            ├── resp      → Redis（默认，立即可跑）
            └── mooncake_store → Mooncake（分布式目标，RDMA 就绪）
```

与旧 lab 的本质区别：缓存层从「每实例私有配置 + 靠 Redis 间接共享」变成
「独立进程统一持有，实例挂了缓存不丢，配置只此一份」。

## 快速开始

```bash
bash scripts/env_check.sh                     # 依赖自检

bash scripts/start_server.sh                  # lmcache server（默认 L2=mooncake，连带起 master）
bash scripts/start_engine.sh 8000 0.45        # qwen3-8b 实例
bash scripts/start_engine.sh 8001 0.42 qwen2.5-7b

"$PY" checks/smoke.py --port 8000 --model qwen3-8b   # 链路冒烟（验证命中）
```

多模型实例的 KV 在同一个 server 里按键（含 model_name）共存，天然隔离、
淘汰与配额机制见 [REPORT.md §5.5](REPORT.md)。

## Trace 实验流水线

```bash
# 1. 下载 Mooncake trace（一次性）
"$PY" trace/download.py

# 2. 离线分析 + 容量-命中率模拟（不占 GPU，选 L1/L2 容量依据）
"$PY" trace/analyze.py --trace data/traces/conversation_trace.jsonl --model qwen3-8b

# 3. 切实验窗口（前600s × 10倍速，输出 aiperf 输入）
"$PY" trace/window.py --trace data/traces/conversation_trace.jsonl \
    --seconds 600 --max-input 7000 --speed 10 -o data/traces/conv_600s_x10.jsonl

# 4. 回放（自动前后快照 + 差值）
bash bench/run_aiperf.sh data/traces/conv_600s_x10.jsonl 8000 qwen3-8b
#    性能(TTFT/吞吐): results/<id>_aiperf/artifacts/
#    缓存(命中率):     results/<id>_aiperf/delta.json
```

## 日常观测与运维

```bash
bash scripts/status.sh 8000 8001              # server/实例/L2 三面板
bash scripts/caches.sh 8000                   # 三级缓存容量+健康速查（L0/L1/L2 一屏）
"$PY" scripts/hitrate.py --watch              # 动态命中率（窗口增量口径，非自启动累计）
bash scripts/stop_engine.sh 8000              # 停单实例（缓存不丢！server 还在）
bash scripts/start_engine.sh 8000 0.45        # 重启实例，热状态直接继承
bash scripts/stop_server.sh                   # 全停（redis 缓存随之丢弃，可再生）
```

## Sleep 秒级拉起（模型货架）

实例可睡进主机内存（GPU 全释放），唤醒 ~0.5s（对比冷启动 ~120s）。热状态住
server，睡眠不丢。须以 `SLEEP=1` 启动（自动带 engine_driven 传输，绕开
sleep 分配器与 CUDA IPC 的不兼容，详见 REPORT.md §5.6）：

```bash
SLEEP=1 bash scripts/start_engine.sh 8000 0.29 qwen3-8b
bash scripts/rack.sh sleep 8000               # 睡下(~8s, GPU 释放)
bash scripts/rack.sh wake 8000                # 唤醒(~0.5s)
bash scripts/rack.sh status                   # 货架面板
```

铁律：同时醒着的实例 util 之和 ≤ 0.90。

## 换 L2 后端

```bash
L2_BACKEND=none     bash scripts/start_server.sh   # 纯 L1（隔离 L1 贡献）
L2_BACKEND=redis    bash scripts/start_server.sh   # resp 适配器（回退 redis 池）
L2_BACKEND=mooncake bash scripts/start_server.sh   # 分布式后端（默认，已编译跑通，自动连带起 mooncake_master）
L1_SIZE_GB=120      bash scripts/start_server.sh   # 调 L1 容量
```

mooncake 后端：`mooncake_master`(:50051) 纯控制面由脚本自动拉起，数据面 P2P
（对象住 lmcache server 贡献的 180GB DRAM 段，`config/l2-mooncake.json` 可调）；
master 指标 `curl localhost:9003/metrics/summary`（Keys/用量/clients）。
构建与踩坑记录见 [REPORT.md §5.3](REPORT.md)。

## 依赖位置（不在本仓库）

- 模型权重 `~/ant/models/`，Python `~/ant/miniconda3/envs/vllm`（vLLM 0.29.0 + LMCache 0.5.5）
- AIPerf 0.12.0 `~/aiperf-venv`，Redis 8.10.1 `~/ant/miniconda3/envs/redis`

路径/端口/模型表集中在 `env.sh`，是唯一需要改的文件。
