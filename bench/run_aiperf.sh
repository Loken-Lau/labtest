#!/bin/bash
# AIPerf 回放一条 trace 窗口（mooncake_trace 格式 + fixed-schedule 按 timestamp 精确回放），
# 自动包裹指标快照（前/后/差值），产出标准 results/<run_id>/ 目录。
#
# 用法:
#   bash bench/run_aiperf.sh <窗口.jsonl> <端口> <模型名> [额外 aiperf 参数...]
# 示例:
#   bash bench/run_aiperf.sh data/traces/conv_600s_x10.jsonl 8000 qwen3-8b
#
# 产物 results/<时间戳>_aiperf/:
#   before.json after.json delta.json   —— 缓存指标口径（collect.py）
#   aiperf_console.log                   —— aiperf 控制台输出
#   artifacts/                           —— aiperf 原生产出（TTFT/吞吐 profile_export*）
#
# 注意:
#   - tokenizer 用 HF 名（env.sh MODEL_TOKENIZERS），本地路径会炸 aiperf 的 worker
#   - ignore_eos:true 严格按 trace 的 output_length 生成（与官方 trace 语义一致）
#   - aiperf 不感知 LMCache 命中率，缓存口径由本脚本的 collect.py 补采
set -euo pipefail
source "$(dirname "$0")/../env.sh"

WINDOW=${1:?用法: run_aiperf.sh <窗口.jsonl> <端口> <模型名> [aiperf 额外参数...]}
PORT=${2:?缺端口}
MODEL=${3:?缺模型名}
shift 3 || true
TOK="${MODEL_TOKENIZERS[$MODEL]:-}"
[ -n "$TOK" ] || { echo "[FAIL] 模型 $MODEL 未登记 tokenizer（env.sh）"; exit 1; }

RUN_ID="$(date +%Y%m%d_%H%M%S)_aiperf"
OUT="$RESULTS_DIR/$RUN_ID"
mkdir -p "$OUT/artifacts"

echo "[1/4] 跑前快照..."
"$PY" "$REPO_ROOT/bench/collect.py" snapshot --ports "$PORT" > "$OUT/before.json"

echo "[2/4] aiperf 回放: $WINDOW -> :$PORT/$MODEL"
# --export 产物固定放 artifacts/；fixed_schedule 由 aiperf 按 timestamp 自动应用
HF_ENDPOINT="$HF_ENDPOINT" "$AIPERF_BIN" profile \
  --model "$MODEL" \
  --tokenizer "$TOK" \
  --endpoint-type completions \
  --streaming \
  --url "localhost:$PORT" \
  --input-file "$WINDOW" \
  --custom-dataset-type mooncake_trace \
  --extra-inputs ignore_eos:true \
  --output-artifact-dir "$OUT/artifacts" \
  "$@" 2>&1 | tee "$OUT/aiperf_console.log"

echo "[3/4] 跑后快照 + 差值..."
"$PY" "$REPO_ROOT/bench/collect.py" snapshot --ports "$PORT" > "$OUT/after.json"
"$PY" "$REPO_ROOT/bench/collect.py" delta "$OUT/before.json" "$OUT/after.json" \
  --window "$WINDOW" | tee "$OUT/delta.json"

echo "[4/4] 完成: $OUT"
echo "  性能指标(TTFT/吞吐): $OUT/artifacts/ 下 profile_export_aiperf.json"
echo "  缓存指标(命中率):    $OUT/delta.json"
