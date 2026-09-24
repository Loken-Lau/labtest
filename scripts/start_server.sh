#!/bin/bash
# 启动 LMCache MP server（缓存层独立进程：L1 共享内存池 + 可插拔 L2）。
# 用法:
#   bash scripts/start_server.sh                       # 按当前 L2_BACKEND
#   L2_BACKEND=redis    bash scripts/start_server.sh
#   L2_BACKEND=mooncake bash scripts/start_server.sh   # 需先装 lmcache_mooncake + mooncake master
#   L1_SIZE_GB=120      bash scripts/start_server.sh   # 覆盖 L1
# 已在跑则直接退出（幂等）。
set -euo pipefail
source "$(dirname "$0")/../env.sh"

health() { curl -sf "http://localhost:${LMS_HTTP}/healthcheck" >/dev/null 2>&1; }

if health; then
  echo "[OK] LMCache server 已在跑 (:${LMS_PORT} zmq / :${LMS_HTTP} http)"
  exit 0
fi
pgrep -f "lmcache server" >/dev/null 2>&1 && {
  echo "[INFO] 残留 lmcache server 进程未就绪，清理后重启..."
  pkill -f "lmcache server" || true; sleep 3
}

# ---- 传输模式 ----
# auto = 同时开 lmcache_driven(CUDA IPC 零拷贝) + engine_driven(SHM 拷贝)，
# 每个实例在 kv_transfer_config 里自选。SLEEP=1 的实例必须选 engine_driven
# （VMM 分配器与 CUDA IPC 不兼容，见 start_engine.sh 注释）。
TRANSFER_ARGS=(--supported-transfer-mode "${TRANSFER_MODE:-auto}")

# ---- L2 依赖的前置服务 ----
L2_ARGS=()
case "$L2_BACKEND" in
  redis)
    if ! "$REDIS_CLI" -p "$REDIS_PORT" ping >/dev/null 2>&1; then
      echo "[INFO] 起本机 Redis 池 (:${REDIS_PORT}, ${REDIS_MAXMEM}, allkeys-lru)..."
      # maxmemory 用 env 覆盖 conf，免得改两处
      nohup "$REDIS_SERVER" "$REPO_ROOT/config/redis.conf" \
            --maxmemory "$REDIS_MAXMEM" \
            > "$LOG_DIR/redis.log" 2>&1 &
      for i in $(seq 1 20); do
        "$REDIS_CLI" -p "$REDIS_PORT" ping >/dev/null 2>&1 && break
        sleep 0.5
      done
    fi
    L2_ARGS+=(--l2-adapter "$(cat "$REPO_ROOT/config/l2-redis.json")")
    ;;
  mooncake)
    L2_ARGS+=(--l2-adapter "$(cat "$REPO_ROOT/config/l2-mooncake.json")")
    ;;
  none) : ;;
  *) echo "[FAIL] 未知 L2_BACKEND=$L2_BACKEND"; exit 1 ;;
esac

echo "[INFO] 启动 lmcache server: L1=${L1_SIZE_GB}GB L2=${L2_BACKEND} chunk=${CHUNK_SIZE} hash=${HASH_ALG}"
# --eviction-policy 在本 lmcache(0.5.5) 构建里是必填项（LRU/IsolatedLRU/noop）
nohup "$LMC_BIN" server \
  --host "$LMS_BIND" --port "$LMS_PORT" \
  --http-host "$LMS_BIND" --http-port "$LMS_HTTP" \
  --l1-size-gb "$L1_SIZE_GB" \
  --eviction-policy "${EVICT_POLICY:-LRU}" \
  --chunk-size "$CHUNK_SIZE" \
  --hash-algorithm "$HASH_ALG" \
  "${TRANSFER_ARGS[@]}" \
  "${L2_ARGS[@]}" \
  > "$LOG_DIR/lmcache-server.log" 2>&1 &

for i in $(seq 1 60); do
  health && { echo "[OK] server 就绪: zmq :${LMS_PORT} | http :${LMS_HTTP} (日志 $LOG_DIR/lmcache-server.log)"; exit 0; }
  sleep 1
done
echo "[FAIL] 60s 未就绪，查日志: tail -50 $LOG_DIR/lmcache-server.log"
exit 1
