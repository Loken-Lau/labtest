#!/bin/bash
# 模型货架：sleep/wake 秒级换入换出（实例睡进主机内存，GPU 完全释放，唤醒 ~0.5s）。
#
# MP 模式下的关键性质: 热状态(KV)住在 lmcache server 的 L1/L2 里，不随实例睡眠丢失——
# 实例 GPU KV 会被丢弃，但唤醒后从 server 直接取回（旧 lab 需要靠 Redis 池绕一圈，
# MP 下这是架构自带的）。所以 sleep 纯粹是"GPU 占用的换入换出"，与缓存无关。
#
# 用法:
#   bash scripts/rack.sh status          # 货架全景(端口/模型/睡醒/GPU)
#   bash scripts/rack.sh sleep 8000      # 睡下(~9s, GPU 释放; level1=权重进主机内存)
#   bash scripts/rack.sh wake 8000       # 唤醒(~0.5s)
#   bash scripts/rack.sh gpu             # 只看 GPU
#
# 铁律: 同时醒着的实例 util 之和 <= 0.90（GPU KV + 权重都要地方）。
# 前置: 实例须以 SLEEP=1 启动（start_engine.sh），否则 dev 端点 404。
set -uo pipefail
source "$(dirname "$0")/../env.sh"

CMD=${1:-status}

is_sleeping() {  # 端口 -> true/false/unknown
  local r
  r=$(curl -s -m 3 'http://localhost:'"$1"'/is_sleeping' 2>/dev/null || true)
  case "$r" in
    *true*)  echo true ;;
    *false*) echo false ;;
    *)       echo unknown ;;
  esac
}

model_of() {  # 从进程命令行抓 served-model-name
  pgrep -f "vllm serve.*--port $1(\$| )" >/dev/null 2>&1 || return 1
  pgrep -af "vllm serve" | grep -- "--port $1\$\|--port $1 " \
    | grep -oE "served-model-name [^ ]+" | head -1 | cut -d' ' -f2
}

ports_running() {  # 列出所有在跑端口
  pgrep -af "vllm serve" 2>/dev/null | grep -oE -- "--port [0-9]+" | awk '{print $2}' | sort -un
}

case "$CMD" in
  status)
    printf "%-7s %-14s %-9s %s\n" "PORT" "MODEL" "STATE" "GPU(唤醒实例)"
    for p in $(ports_running); do
      m=$(model_of "$p"); s=$(is_sleeping "$p")
      [ "$s" = true ] && st="💤 sleeping" || st="😀 awake"
      printf "%-7s %-14s %-9s\n" "$p" "${m:-?}" "$st"
    done
    [ -z "$(ports_running)" ] && echo "（无实例在跑）"
    nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader | sed 's/^/GPU /'
    ;;
  sleep)
    P=${2:?用法: rack.sh sleep <端口>}
    echo "[INFO] 睡下 :$P (level 1, 权重->主机内存, ~9s)..."
    time curl -s -m 180 -X POST "localhost:$P/sleep?level=1" && echo "[OK] :$P 已睡"
    ;;
  wake)
    P=${2:?用法: rack.sh wake <端口>}
    echo "[INFO] 唤醒 :$P (~0.5s)..."
    time curl -s -m 60 -X POST "localhost:$P/wake_up" && echo "[OK] :$P 已醒"
    ;;
  gpu)
    nvidia-smi
    ;;
  *)
    echo "用法: rack.sh {status|sleep <端口>|wake <端口>|gpu}"; exit 1 ;;
esac
