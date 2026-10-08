#!/bin/bash
# =============================================================================
# lmcache-mp 全局环境 —— 单一事实来源
# 所有脚本必须 source 本文件；改路径/端口/容量只改这里。
# =============================================================================
# shellcheck disable=SC2034

# 仓库根目录（按本文件位置推断，不受调用 cwd 影响）
export REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- 外部依赖路径（不在本仓库，见 env_check.sh 自检） ----
export VLLM_ENV="$HOME/ant/miniconda3/envs/vllm"       # vLLM 0.29.0 + LMCache 0.5.5
export VLLM_BIN="$VLLM_ENV/bin/vllm"
export PY="$VLLM_ENV/bin/python"
export LMC_BIN="$VLLM_ENV/bin/lmcache"
export AIPERF_BIN="$HOME/aiperf-venv/bin/aiperf"        # AIPerf 0.12.0（独立 venv）
export REDIS_SERVER="$HOME/ant/miniconda3/envs/redis/bin/redis-server"
export REDIS_CLI="$HOME/ant/miniconda3/envs/redis/bin/redis-cli"

# ---- 模型注册表：名字 -> (本地权重路径, HF tokenizer 名) ----
# aiperf 的 tokenizer 必须用 HF 名（本地路径会炸其多进程 worker），故两列。
declare -A MODEL_PATHS=(
  [qwen3-8b]="/home/liujinhao/ant/models/Qwen3-8B"
  [qwen2.5-7b]="/home/liujinhao/ant/models/Qwen2.5-7B-Instruct"
)
declare -A MODEL_TOKENIZERS=(
  [qwen3-8b]="Qwen/Qwen3-8B"
  [qwen2.5-7b]="Qwen/Qwen2.5-7B-Instruct"
)

# ---- LMCache MP server（缓存层独立进程，所有 vLLM 实例共享） ----
export LMS_HOST="${LMS_HOST:-localhost}"    # vLLM 侧连接地址（分布式时改远端 IP）
export LMS_BIND="${LMS_BIND:-0.0.0.0}"      # server 监听地址
export LMS_PORT="${LMS_PORT:-5555}"         # ZMQ 数据面
export LMS_HTTP="${LMS_HTTP:-8080}"         # HTTP 控制面: /healthcheck /status /cache/...
export L1_SIZE_GB="${L1_SIZE_GB:-60}"       # server 进程内共享 L1（主机内存 755G，可用 ~430G）
export CHUNK_SIZE="${CHUNK_SIZE:-256}"      # KV chunk tokens（与旧实验可比）
export HASH_ALG="${HASH_ALG:-blake3}"       # 键哈希：MP 下统一在 server 端计算
export EVICT_POLICY="${EVICT_POLICY:-LRU}"  # 本 lmcache 构建必填（LRU/IsolatedLRU/noop）

# ---- L2 后端选择: none | redis | mooncake ----
# redis    = resp 适配器 -> 本机 Redis（立即可跑，兼容旧实验数据）
# mooncake = mooncake_store 适配器（分布式目标；需编译 lmcache_mooncake 扩展，
#           见 REPORT.md "L2 选型"）
export L2_BACKEND="${L2_BACKEND:-mooncake}"
export REDIS_PORT="${REDIS_PORT:-6379}"
export REDIS_MAXMEM="${REDIS_MAXMEM:-300gb}"   # 仅 redis 后端使用

# ---- mooncake（L2_BACKEND=mooncake 时使用）----
# 构建产物在 ~/build/mooncake-l2（源码 mooncake-src/ + 安装 mooncake-install/），
# lmcache_mooncake 扩展已编进 vllm env 的 lmcache（源码 LMCache-0.5.5/ 重装）。
# master 是纯控制面进程（:50051），数据面 P2P（metadata_server=P2PHANDSHAKE，
# 数据住各 client 贡献的 DRAM 段，无独立 store node 进程）。
export MOONCAKE_MASTER_BIN="${MOONCAKE_MASTER_BIN:-$HOME/build/mooncake-l2/mooncake-install/bin/mooncake_master}"
export MOONCAKE_MASTER_PORT="${MOONCAKE_MASTER_PORT:-50051}"   # 仅探活用，地址改 config/l2-mooncake.json

# ---- vLLM 实例 ----
export MAXLEN="${MAXLEN:-8192}"

# ---- 数据目录 ----
export DATA_DIR="$REPO_ROOT/data"
export TRACE_DIR="$DATA_DIR/traces"
export LOG_DIR="$REPO_ROOT/logs"
export RESULTS_DIR="$REPO_ROOT/results"
mkdir -p "$TRACE_DIR" "$LOG_DIR" "$RESULTS_DIR" 2>/dev/null || true

# HF 镜像（本机网络环境必需，download.sh 教训）
export HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
export HF_HUB_DISABLE_XET=1   # 绕过 xet 后端绕过镜像的 401 问题
