#!/bin/bash
# 三级缓存容量 + 健康面板：L0(GPU APC) / L1(server 内存池) / L2(redis|mooncake)。
# 用法: bash scripts/caches.sh [端口...]      # 默认 8000
# 与 status.sh 的分工：本脚本只看「容量与健康」，动态命中率看 hitrate.py。
set -uo pipefail
source "$(dirname "$0")/../env.sh"
PORTS=("${@:-8000}")

OK="✓"; BAD="✗"
declare -i ISSUES=0

# ---------- L0: 各实例 GPU APC ----------
echo "======== L0 · GPU APC（每实例私有）========"
for p in "${PORTS[@]}"; do
  if ! curl -sf -m 3 "localhost:$p/metrics" >/dev/null 2>&1; then
    echo ":$p  $BAD 实例不可达"; ISSUES+=1; continue
  fi
  M=$(curl -s "localhost:$p/metrics")
  q=$(awk '/^vllm:prefix_cache_queries_total/{print $2}' <<<"$M" | head -1)
  h=$(awk '/^vllm:prefix_cache_hits_total/{print $2}'   <<<"$M" | head -1)
  rate=$(awk -v q="${q:-0}" -v h="${h:-0}" 'BEGIN{if(q>0) printf "%.1f%%", h/q*100; else print "n/a"}')
  # L0 容量/水位/APC 开关都藏在 cache_config_info 标签里；指标带 {labels}，正则要允许
  usage=$(grep -oE '^vllm:kv_cache_usage_perc(\{[^}]*\})? [0-9.]+' <<<"$M" | awk '{print $NF}' | head -1)
  apc=$(grep  -oE 'enable_prefix_caching="[A-Za-z]+"'      <<<"$M" | head -1 | cut -d'"' -f2)
  pool=$(grep -oE 'num_gpu_blocks="[0-9]+"'                <<<"$M" | head -1 | grep -oE '[0-9]+')
  blk=$(grep  -oE '\bblock_size="[0-9]+"'                  <<<"$M" | head -1 | grep -oE '[0-9]+')
  cap=$(( ${pool:-0} * ${blk:-0} ))
  caps=$([ "$cap" -gt 0 ] && echo "${cap} tok" || echo "?")
  [ "$apc" = "True" ] || [ "$apc" = "true" ] || { echo ":$p  $BAD APC 未开启(enable_prefix_caching=$apc)"; ISSUES+=1; }
  echo ":$p  $OK APC=$apc | KV池 $caps | 用量 ${usage:-n/a} | 累计命中(自启动) $rate"
done

# ---------- L1: server 共享内存池 ----------
echo
echo "======== L1 · server 内存池 ========"
if ! curl -sf -m 3 "localhost:${LMS_HTTP}/healthcheck" >/dev/null 2>&1; then
  echo "  $BAD lmcache server 不可达 (:${LMS_HTTP})"; ISSUES+=1
else
  L1=$(curl -s -m 3 "localhost:${LMS_HTTP}/status" | "$PY" -c "
import json,sys
d=json.load(sys.stdin)['storage_manager']['l1_manager']
print(d['is_healthy'], d['total_object_count'],
      round(d['memory_used_bytes']/2**30,1), round(d['memory_total_bytes']/2**30,0),
      round(d['memory_usage_ratio']*100,1))" 2>/dev/null) || L1=""
  if [ -z "$L1" ]; then
    echo "  $BAD /status 解析失败"; ISSUES+=1
  else
    set -- $L1   # healthy objects usedGiB totalGiB ratio%
    if [ "$1" = "True" ] || [ "$1" = "true" ]; then
      echo "  $OK 健康 | $3 GiB / $4 GiB ($5%) | objects=$2"
    else
      echo "  $BAD l1_manager 状态异常 (is_healthy=$1)"; ISSUES+=1
    fi
  fi
fi

# ---------- L2: 后端池 ----------
echo
echo "======== L2 · 后端 ($L2_BACKEND) ========"
case "$L2_BACKEND" in
  mooncake)
    if ! ss -ltn "sport = :${MOONCAKE_MASTER_PORT}" 2>/dev/null | grep -q LISTEN; then
      echo "  $BAD mooncake_master 未监听 :${MOONCAKE_MASTER_PORT}"; ISSUES+=1
    else
      M=$(curl -s -m 3 "localhost:9003/metrics/summary")
      state=$(grep -oE 'state=[a-z]+'         <<<"$M" | head -1)
      ready=$(grep -oE 'service_ready=[a-z]+' <<<"$M" | head -1)
      keys=$(grep -oE 'Keys: [0-9]+'          <<<"$M" | grep -oE '[0-9]+')
      mem=$(grep -oE 'Mem Storage: [^|]*'     <<<"$M" | head -1 | cut -d: -f2- | xargs)
      clients=$(grep -oE 'Clients: [0-9]+'    <<<"$M" | grep -oE '[0-9]+')
      allocfail=$(grep -oE 'AllocFail=[0-9]+' <<<"$M" | grep -oE '[0-9]+' | head -1)
      if [[ "$state" == "state=serving" && "$ready" == "service_ready=true" ]]; then
        echo "  $OK master $state/$ready | $mem | Keys=$keys | Clients=$clients"
      else
        echo "  $BAD master 异常: $state $ready"; ISSUES+=1
      fi
      if [ "${clients:-0}" -ge 1 ]; then
        echo "  $OK lmcache server 已挂段 (Clients=$clients)"
      else
        echo "  $BAD 无 client 挂段（server 未连上 master，L2 实为哑的）"; ISSUES+=1
      fi
      [ "${allocfail:-0}" -eq 0 ] || { echo "  $BAD AllocFail=$allocfail（段满，分配失败）"; ISSUES+=1; }
    fi
    curl -s -m 3 "localhost:${LMS_HTTP}/status" | "$PY" -c "
import json,sys
sm=json.load(sys.stdin)['storage_manager']
a=sm['l2_adapters']; sc=sm['store_controller']
verdict='✓' if a and all(x['is_healthy'] for x in a) else '✗'
print('  %s 适配器 %s | active=%s draining=%s pending=%s' %
      (verdict, [x['type'] for x in a], sc['num_active_adapters'],
       sc['num_draining_adapters'], sc['pending_keys_count']))" 2>/dev/null
    ;;
  redis)
    if "$REDIS_CLI" -p "$REDIS_PORT" ping >/dev/null 2>&1; then
      echo "  $OK redis | keys $("$REDIS_CLI" -p "$REDIS_PORT" dbsize) | $("$REDIS_CLI" -p "$REDIS_PORT" info memory | grep used_memory_human: | cut -d: -f2 | xargs) | evicted $("$REDIS_CLI" -p "$REDIS_PORT" info stats | grep evicted_keys: | cut -d: -f2 | xargs)"
    else
      echo "  $BAD redis 不可达 :${REDIS_PORT}"; ISSUES+=1
    fi
    ;;
  none) echo "  （L2_BACKEND=none，无 L2 层）" ;;
  *)    echo "  $BAD 未知后端 $L2_BACKEND"; ISSUES+=1 ;;
esac

echo
[ "$ISSUES" -eq 0 ] && echo "[OK] 三级缓存全部健康" || echo "[WARN] $ISSUES 项异常（见上行 $BAD 标记）"
