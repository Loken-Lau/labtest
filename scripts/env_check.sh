#!/bin/bash
# 依赖自检：一条命令验证全部外部依赖就位，给出去别处排查省时间。
# 用法: bash scripts/env_check.sh
set -uo pipefail
source "$(dirname "$0")/../env.sh"

fail=0
warn=0
ok()   { echo "  [OK]   $1"; }
bad()  { echo "  [FAIL] $1"; fail=$((fail+1)); }
warnf(){ echo "  [WARN] $1"; warn=$((warn+1)); }

echo "== 1. 二进制依赖 =="
for b in "$VLLM_BIN" "$LMC_BIN" "$PY" "$AIPERF_BIN"; do
  [ -x "$b" ] && ok "$b" || bad "$b 不存在或不可执行"
done
"$LMC_BIN" server --help >/dev/null 2>&1 \
  && ok "lmcache MP server 子命令可用" \
  || bad "lmcache server 子命令不可用（需完整版 lmcache，非 lightweight）"

echo "== 2. 模型权重 =="
for m in "${!MODEL_PATHS[@]}"; do
  [ -d "${MODEL_PATHS[$m]}" ] && ok "$m -> ${MODEL_PATHS[$m]}" \
                                || bad "$m 缺少权重目录 ${MODEL_PATHS[$m]}"
done

echo "== 3. L2 后端 ($L2_BACKEND) =="
case "$L2_BACKEND" in
  redis)
    [ -x "$REDIS_SERVER" ] && ok "redis-server: $REDIS_SERVER" \
                               || bad "redis-server 不存在: $REDIS_SERVER"
    [ -x "$REDIS_CLI" ] || warnf "redis-cli 缺失（仅影响 status.sh 观测）"
    ;;
  mooncake)
    "$PY" -c "import lmcache.lmcache_mooncake" >/dev/null 2>&1 \
      && ok "lmcache_mooncake 原生扩展已装" \
      || bad "lmcache_mooncake 扩展未编译。需 MOONCAKE_INCLUDE_DIR=<mooncake-store 源码> 重装 lmcache（见 REPORT.md L2 选型）"
    ;;
  none)
    warnf "L2_BACKEND=none：仅 server L1，无持久层"
    ;;
  *)
    bad "未知 L2_BACKEND=$L2_BACKEND（合法: none|redis|mooncake）"
    ;;
esac

echo "== 4. 端口占用 =="
for p in "$LMS_PORT" "$LMS_HTTP" "$REDIS_PORT"; do
  if ss -ltn "sport = :$p" 2>/dev/null | grep -q LISTEN; then
    warnf "端口 $p 已被占用（若服务已在跑可忽略）"
  else
    ok "端口 $p 空闲"
  fi
done

echo "== 5. 硬件 =="
mem_g=$(free -g | awk '/^Mem:/{print $2}')
echo "  主机内存 ${mem_g}G（L1=${L1_SIZE_GB}GB 将由 server 进程持有）"
command -v nvidia-smi >/dev/null && nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv,noheader | sed 's/^/  GPU /'

echo
if [ $fail -gt 0 ]; then
  echo "[FAIL] $fail 项不通过"; exit 1
fi
echo "[OK] 自检通过${warn:+（$warn 项警告）}"
