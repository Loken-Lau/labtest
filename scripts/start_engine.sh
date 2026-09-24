#!/bin/bash
# 启动一个 vLLM 实例并接入 LMCache MP server（MP 模式，无 per-instance 配置文件）。
# 用法: bash scripts/start_engine.sh [端口] [显存占比] [模型名]
# 示例:
#   bash scripts/start_engine.sh 8000 0.45            # qwen3-8b @ 8000
#   bash scripts/start_engine.sh 8001 0.42 qwen2.5-7b
#   SLEEP=1 bash scripts/start_engine.sh 8000 0.29    # 带 sleep/wake 秒级换入换出
# 前置: lmcache server 必须先就绪（start_server.sh）
# 睡眠/唤醒: bash scripts/rack.sh sleep 8000 | wake 8000 | status
# 停止: bash scripts/stop_engine.sh 8000
set -euo pipefail
source "$(dirname "$0")/../env.sh"

PORT=${1:-8000}
UTIL=${2:-0.45}
MODEL=${3:-qwen3-8b}

MODEL_DIR="${MODEL_PATHS[$MODEL]:-}"
[ -n "$MODEL_DIR" ] || { echo "[FAIL] 未知模型 $MODEL（在 env.sh MODEL_PATHS 里登记）"; exit 1; }

curl -sf "http://localhost:${LMS_HTTP}/healthcheck" >/dev/null 2>&1 \
  || { echo "[FAIL] lmcache server 未就绪，先跑: bash scripts/start_server.sh"; exit 1; }

# 幂等：健康则退出
if curl -sf "http://localhost:${PORT}/v1/models" >/dev/null 2>&1; then
  echo "[OK] ${MODEL} 已在 :${PORT} 运行"; exit 0
fi
# 清理同端口残留
pkill -f "vllm serve.*--port ${PORT}(\$| )" 2>/dev/null || true
sleep 5

# MP 模式接线：vLLM 的 LMCacheMPConnector 经 ZMQ 连 server。
# 注意：不再需要 LMCACHE_CONFIG_FILE / PYTHONHASHSEED（embedded 时代的产物）——
# L1/L2/chunk/hash 全部收敛到 server 端统一配置。
KVT_CONFIG=$(cat <<EOF
{"kv_connector":"LMCacheMPConnector",
 "kv_role":"kv_both",
 "kv_connector_extra_config":{
   "lmcache.mp.host":"tcp://${LMS_HOST}",
   "lmcache.mp.port":${LMS_PORT}}}
EOF
)

EXTRA_ARGS=()
if [ "${SLEEP:-0}" = "1" ]; then
    EXTRA_ARGS+=(--enable-sleep-mode)   # 秒级 sleep/wake_up，配合 rack.sh
    export VLLM_SERVER_DEV_MODE=1       # sleep/wake_up/is_sleeping 是 dev 端点，必须开门禁
    # sleep 模式下 vLLM 用 CuMemAllocator(VMM) 分配 KV：
    #  - lmcache_driven(默认, CUDA IPC 零拷贝) 对 VMM 内存直接 CUDA error: invalid argument
    #  - VMM IPC(use_vmm_api) 的 POSIX fd 带外传输在本 lmcache 0.5.5 未接生产通道
    #  → engine_driven: worker 侧经 SHM 池 gather/scatter 拷贝，与分配器无关，sleep 可用
    #    （代价：多一次拷贝，非零拷贝）
    KVT_CONFIG=$(cat <<EOF
{"kv_connector":"LMCacheMPConnector",
 "kv_role":"kv_both",
 "kv_connector_extra_config":{
   "lmcache.mp.host":"tcp://${LMS_HOST}",
   "lmcache.mp.port":${LMS_PORT},
   "lmcache.mp.mp_transfer_mode":"engine_driven"}}
EOF
)
fi

LOG="$LOG_DIR/vllm-${PORT}.log"
echo "[INFO] 启动 ${MODEL} @ :${PORT} (util ${UTIL}, sleep=${SLEEP:-0}) -> lmcache server :${LMS_PORT}，日志 ${LOG}"
nohup "$VLLM_BIN" serve "$MODEL_DIR" \
  --served-model-name "$MODEL" \
  --max-model-len "${MAXLEN}" \
  --gpu-memory-utilization "$UTIL" \
  --port "$PORT" \
  --kv-transfer-config "$KVT_CONFIG" \
  "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}" \
  > "$LOG" 2>&1 &

for i in $(seq 1 120); do
  if curl -sf "http://localhost:${PORT}/v1/models" >/dev/null 2>&1; then
    echo "[OK] 就绪: http://localhost:${PORT}/v1  (model: ${MODEL})"
    exit 0
  fi
  sleep 5
done
echo "[FAIL] 10 分钟未就绪，查日志: tail -50 ${LOG}"
exit 1
