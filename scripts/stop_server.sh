#!/bin/bash
# 停 LMCache MP server（连带 redis，若本仓库拉起的）。
# 用法: bash scripts/stop_server.sh [--keep-redis]
set -uo pipefail
source "$(dirname "$0")/../env.sh"

if pgrep -f "lmcache server" >/dev/null 2>&1; then
  pkill -f "lmcache server" && echo "[OK] lmcache server 已停"
else
  echo "[INFO] lmcache server 未在跑"
fi

if [ "${1:-}" != "--keep-redis" ] && "$REDIS_CLI" -p "$REDIS_PORT" ping >/dev/null 2>&1; then
  "$REDIS_CLI" -p "$REDIS_PORT" shutdown nosave 2>/dev/null && echo "[OK] redis(:${REDIS_PORT}) 已停（缓存丢弃，可再生）"
fi

# mooncake master 是独立控制面进程，连带停（对象元数据随之丢弃，可再生）
if pgrep -x mooncake_master >/dev/null 2>&1; then
  pkill -x mooncake_master && echo "[OK] mooncake_master(:${MOONCAKE_MASTER_PORT:-50051}) 已停"
fi
