#!/usr/bin/env python3
"""从全量 trace 切一个实验窗口，产出 aiperf mooncake_trace 输入文件。

用法（典型）:
  python3 window.py --trace data/traces/conversation_trace.jsonl \
      --seconds 600 --max-input 7000 --speed 10 -o data/traces/conv_600s_x10.jsonl

做了什么:
  - 按时间窗口/条数/长度过滤
  - timestamp 归零到窗口起点（aiperf fixed-schedule 立即开跑）
  - --speed>1 时整体压缩时间轴（等效旧 replay.py 的 --speed，但只改文件，回放器零逻辑）
  - 打印本窗口的理论前缀命中率上限（结构性天花板，回放后对照用）

注意: 命中率不随 --speed 变（缓存语义相同），TTFT 只在同倍速间可比。
"""
from __future__ import annotations

import argparse
import json
import os
import sys


def load(path: str) -> list[dict]:
    reqs = []
    with open(path) as f:
        for line in f:
            r = json.loads(line)
            reqs.append(r)
    reqs.sort(key=lambda r: r["timestamp"])
    return reqs


def ceiling(reqs: list[dict], block_tokens: int = 512) -> float:
    """无限缓存下前缀命中率上限：最长前导已见块（官方 trace 语义）。"""
    seen: set[int] = set()
    hit = tot = 0
    for r in reqs:
        k = 0
        for h in r["hash_ids"]:
            if h in seen:
                k += 1
            else:
                break
        hit += k * block_tokens
        tot += len(r["hash_ids"]) * block_tokens
        seen.update(r["hash_ids"])
    return hit / tot * 100 if tot else 0.0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--trace", required=True, help="全量 trace jsonl")
    ap.add_argument("--seconds", type=float, default=0,
                    help="只取前 N 秒（0=全量）")
    ap.add_argument("--max-requests", type=int, default=0, help="最多条数（0=不限）")
    ap.add_argument("--max-input", type=int, default=7000,
                    help="过滤 input_length 超长请求（适配 max_model_len）")
    ap.add_argument("--speed", type=float, default=1.0,
                    help="时间轴压缩倍数（10=快放10倍）")
    ap.add_argument("-o", "--output", required=True, help="输出 jsonl（aiperf 输入）")
    args = ap.parse_args()

    reqs = load(args.trace)
    n_all = len(reqs)
    reqs = [r for r in reqs if r["input_length"] <= args.max_input]
    n_len = len(reqs)

    t0 = reqs[0]["timestamp"] if reqs else 0
    if args.seconds > 0:
        reqs = [r for r in reqs if (r["timestamp"] - t0) / 1000 <= args.seconds]
    if args.max_requests:
        reqs = reqs[: args.max_requests]

    with open(args.output, "w") as f:
        for r in reqs:
            r2 = dict(r)
            r2["timestamp"] = int((r["timestamp"] - t0) / args.speed)
            f.write(json.dumps(r2) + "\n")

    dur = (reqs[-1]["timestamp"] - t0) / 1000 / args.speed if reqs else 0
    print(f"[OK] {args.output}")
    print(f"     条数 {len(reqs)}/{n_all}（长度过滤丢弃 {n_all - n_len}），"
          f"窗口时长 {dur:.0f}s @ {args.speed}x")
    print(f"     理论前缀命中率上限: {ceiling(reqs):.2f}%（回放实测对照此值）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
