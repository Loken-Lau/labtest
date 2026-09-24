#!/usr/bin/env python3
"""下载 Mooncake FAST'25 trace（parquet）并转为 jsonl。

产出: <TRACE_DIR>/<name>_trace.jsonl，每行
  {"timestamp": ms, "input_length": int, "output_length": int, "hash_ids": [..]}
hash_ids 前缀相同 = 前缀 KV 可复用（数据集的灵魂字段）。

用法:
  python3 download.py                        # conversation/toolagent/synthetic 全下
  python3 download.py --only conversation
设计（相对旧 lab download.sh 的改进）:
  - schema 校验 + 行数/字段完整性报告，坏了立刻知道而不是回放时炸
  - 幂等：已存在的 jsonl 跳过（--force 重转）
"""
from __future__ import annotations

import argparse
import json
import os
import sys

TRACES = ("conversation", "toolagent", "synthetic")
REQUIRED = ("timestamp", "input_length", "output_length", "hash_ids")


def convert(parquet_path: str, out_path: str) -> tuple[int, int]:
    """parquet -> jsonl。返回 (行数, 坏行数)。"""
    import pyarrow.parquet as pq

    n = bad = 0
    with open(out_path, "w") as f:
        for row in pq.read_table(parquet_path).to_pylist():
            if all(k in row and row[k] is not None for k in REQUIRED):
                f.write(json.dumps({k: row[k] for k in REQUIRED}) + "\n")
                n += 1
            else:
                bad += 1
    return n, bad


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", choices=TRACES, help="只下某一条")
    ap.add_argument("--force", action="store_true", help="已存在也重转")
    args = ap.parse_args()

    trace_dir = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data", "traces"
    )
    os.makedirs(trace_dir, exist_ok=True)
    names = [args.only] if args.only else list(TRACES)

    from huggingface_hub import hf_hub_download  # env.sh 已设 HF_ENDPOINT 镜像

    repo = os.environ.get("TRACE_REPO", "valeriol29/mooncake-traces")
    for name in names:
        out = os.path.join(trace_dir, f"{name}_trace.jsonl")
        if os.path.exists(out) and not args.force:
            print(f"[SKIP] {out} 已存在（--force 重转）")
            continue
        pq_path = hf_hub_download(
            repo_id=repo,
            filename=f"{name}/train-00000-of-00001.parquet",
            repo_type="dataset",
        )
        n, bad = convert(pq_path, out)
        print(f"[OK] {out}: {n} 条" + (f"（丢弃坏行 {bad}）" if bad else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
