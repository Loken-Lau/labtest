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
