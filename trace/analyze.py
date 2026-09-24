#!/usr/bin/env python3
"""离线 trace 分析 + LRU 命中率模拟（不占 GPU，选缓存容量的第一手依据）。

用法:
  python3 analyze.py --trace data/traces/conversation_trace.jsonl
  python3 analyze.py --trace ... --kv-bytes-per-token 147456   # 算容量(GB)

模拟语义（前缀缓存的真实行为）:
  命中 = 请求 hash_ids 的最长前导连续块已在缓存（KV 复用要求前缀对齐，
  中间块在缓存里没用）；请求完成后全部块入缓存（write-through）。
产出:
  - 基本统计（QPS / 长度分布 / 块重用）
  - 无限缓存理论命中率上限
  - 各容量（块数）下的 LRU 命中率曲线
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter, OrderedDict

BLOCK_TOKENS = 512  # Mooncake trace 块粒度；LMCache chunk 256 恰好整除

# 每字节/每 token 的 KV 体积: 2(K+V) × 层数 × kv_heads × head_dim × 2(bf16)
KV_BYTES_PER_TOKEN = {
    "qwen3-8b": 2 * 36 * 8 * 128 * 2,
    "qwen2.5-7b": 2 * 28 * 4 * 128 * 2,
}
CAPACITIES_BLOCKS = [32, 64, 128, 256, 512, 1024, 2048, 4096, 8192]


def load(path: str) -> list[dict]:
    reqs = []
    with open(path) as f:
        for line in f:
            r = json.loads(line)
            reqs.append(r)
    reqs.sort(key=lambda r: r["timestamp"])
    return reqs


def stats(reqs: list[dict]) -> None:
    ins = sorted(r["input_length"] for r in reqs)
    outs = [r["output_length"] for r in reqs]
    blocks = [len(r["hash_ids"]) for r in reqs]
    ref = Counter(h for r in reqs for h in r["hash_ids"])
    reuse = Counter(ref.values())
    dur = (reqs[-1]["timestamp"] - reqs[0]["timestamp"]) / 1000 if reqs else 1
    print(f"请求 {len(reqs)} | 时长 {dur/60:.1f}min | QPS {len(reqs)/max(dur,1):.2f}")
    print(f"input:  avg {sum(ins)/max(len(ins),1):.0f}  p50 {ins[len(ins)//2]}  max {ins[-1] if ins else 0}")
    print(f"output: avg {sum(outs)/max(len(outs),1):.0f}  max {max(outs, default=0)}")
    print(f"块引用 {sum(blocks)} | 唯一块 {len(ref)} | "
          f"块重用分布(次:块数) {dict(sorted(reuse.items())[:6])}")


def lru_sim(reqs: list[dict], cap_blocks: int) -> float:
    """返回块命中率（前导连续块命中才计数），write-through 语义。"""
    cache: OrderedDict[int, None] = OrderedDict()
    hit = tot = 0
    for r in reqs:
        k = 0
        for h in r["hash_ids"]:
            if h in cache:
                k += 1
                cache.move_to_end(h)
            else:
                break
        hit += k
        tot += len(r["hash_ids"])
        for h in r["hash_ids"]:
            if h in cache:
                cache.move_to_end(h)
            else:
                cache[h] = None
                if len(cache) > cap_blocks:
                    cache.popitem(last=False)
    return hit / tot if tot else 0.0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--trace", required=True)
    ap.add_argument("--model", choices=sorted(KV_BYTES_PER_TOKEN),
                    help="按该模型算各容量对应 GB")
    args = ap.parse_args()

    reqs = load(args.trace)
    print(f"== {args.trace} ==")
    stats(reqs)

    from window import ceiling  # 同目录模块

    print(f"无限缓存理论命中率上限: {ceiling(reqs):.2f}%  (输入 token 口径)")

    gb = KV_BYTES_PER_TOKEN.get(args.model) if args.model else None
    header = f"{'容量(块)':>8}"
    if gb:
        header += f"{'容量(GB)':>10}"
    header += f"{'LRU命中率':>10}"
    print(header)
    for cap in CAPACITIES_BLOCKS:
        hr = lru_sim(reqs, cap)
        row = f"{cap:>8}"
        if gb:
            row += f"{cap * BLOCK_TOKENS * gb / 1e9:>10.1f}"
        row += f"{hr*100:>9.1f}%"
        print(row)
    return 0


if __name__ == "__main__":
    sys.exit(main())
