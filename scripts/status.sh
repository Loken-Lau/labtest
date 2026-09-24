#!/bin/bash
# 观测面板：LMCache server 状态 + 各 vLLM 实例缓存指标 + L2 池水位。
# 用法: bash scripts/status.sh [端口...]     # 默认 8000 8001
set -uo pipefail
source "$(dirname "$0")/../env.sh"
PORTS=("${@:-8000 8001}")

echo "======== LMCache MP server (:${LMS_HTTP}) ========"
if curl -sf "http://localhost:${LMS_HTTP}/healthcheck" >/dev/null 2>&1; then
  curl -s "http://localhost:${LMS_HTTP}/status" | "$PY" -c '
import json,sys
d=json.load(sys.stdin)
def pick(d,*ks):
    for k in ks:
        if isinstance(d,dict) and k in d: d=d[k]
        else: return d
    return d
print(json.dumps(d,ensure_ascii=False,indent=1)[:2000])' 2>/dev/null \
    || curl -s "http://localhost:${LMS_HTTP}/status" | head -c 1500
  echo
else
  echo "  [DOWN] server 未运行"
fi

echo
echo "======== vLLM 实例 ========"
for p in "${PORTS[@]}"; do
  if ! curl -sf "http://localhost:${p}/metrics" >/dev/null 2>&1; then
    echo ":${p}  [DOWN]"; continue
  fi
  echo ":${p}"
  curl -s "http://localhost:${p}/metrics" | grep -E \
    '^(vllm:(external_)?prefix_cache_(queries|hits)(_total)?|vllm:num_requests_(waiting|running))' \
    | awk '{printf "  %-55s %s\n",$1,$2}'
done

echo
echo "======== L2 ($L2_BACKEND) ========"
case "$L2_BACKEND" in
  redis)
    if "$REDIS_CLI" -p "$REDIS_PORT" ping >/dev/null 2>&1; then
      echo "  keys   : $("$REDIS_CLI" -p "$REDIS_PORT" dbsize)"
      echo "  memory : $("$REDIS_CLI" -p "$REDIS_PORT" info memory | grep used_memory_human:)"
      echo "  evicted: $("$REDIS_CLI" -p "$REDIS_PORT" info stats | grep evicted_keys:)"
    else
      echo "  [DOWN] redis 未运行"
    fi ;;
  *) echo "  （观测方式见 REPORT.md）" ;;
esac
