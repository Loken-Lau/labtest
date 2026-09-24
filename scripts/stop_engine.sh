#!/bin/bash
# 停一个 vLLM 实例（按端口精确匹配，避免误杀其他实例）。
# 用法: bash scripts/stop_engine.sh 8000
set -uo pipefail
PORT=${1:?用法: stop_engine.sh <端口>}
if pkill -f "vllm serve.*--port ${PORT}(\$| )"; then
  echo "[OK] :${PORT} 实例已停"
else
  echo "[INFO] :${PORT} 无运行实例"
fi
