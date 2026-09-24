#!/usr/bin/env python3
"""统一指标采集：实验前后快照 + 差值面板（唯一口径，别处不许再算命中率）。

用法:
  python3 collect.py snapshot --ports 8000,8001 > before.json   # 跑前
  <跑 aiperf / 任意负载>
  python3 collect.py snapshot --ports 8000,8001 > after.json    # 跑后
  python3 collect.py delta before.json after.json [--window W.jsonl]

采集面:
  - vLLM 实例 /metrics（前缀缓存计数器、队列）
  - LMCache MP server http /status（缓存对象/命中率，若有）
  - L2 redis 水位（若 L2_BACKEND=redis）
delta 输出:
  - gpu_apc / external / combined 命中率 + 理论上限对照（--window 给出 trace 窗口时）

实现注意（旧 lab 的坑，别再犯）:
  旧代码 `async for raw in resp.content` 按网络 chunk 解码再逐块 match 正则，
  chunk 边界≠行边界，长 metrics 页会整行漏匹配。这里一次性读全、按行 split。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

METRIC_RE = re.compile(
    r"^(vllm:(?:external_)?prefix_cache_(?:queries|hits)(_total)?|"
    r"vllm:num_requests_(?:waiting|running))(?:\{[^}]*\})?\s+([0-9.e+-]+)"
)


def http_json(url: str, timeout: float = 5.0):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:
            return json.loads(r.read().decode())
    except Exception as e:  # noqa: BLE001 — 探活失败要继续采其他面
        return {"error": str(e)}


def engine_metrics(port: int) -> dict:
    """抓 vLLM /metrics 的关键计数器。按行解码（见文件头注释）。"""
    try:
        with urllib.request.urlopen(
            f"http://localhost:{port}/metrics", timeout=5
        ) as r:
            out = {}
            for line in r.read().decode().splitlines():
                m = METRIC_RE.match(line)
                if m:
                    out[m.group(1)] = float(m.group(3))
            return out
    except Exception as e:  # noqa: BLE001
        return {"error": str(e)}


def server_status(http_port: int) -> dict:
    return http_json(f"http://localhost:{http_port}/status")


def redis_snapshot(port: int) -> dict:
    cli = os.path.expanduser(
        os.environ.get("REDIS_CLI", "~/ant/miniconda3/envs/redis/bin/redis-cli")
    )

    def rcli(*args: str) -> str:
        return subprocess.run(
            [cli, "-p", str(port), *args],
            capture_output=True, text=True, timeout=5,
        ).stdout

    try:
        info_mem = rcli("info", "memory")
        info_st = rcli("info", "stats")
        used = re.search(r"used_memory_human:(\S+)", info_mem)
        evicted = re.search(r"evicted_keys:(\d+)", info_st)
        return {
            "dbsize": int(rcli("dbsize").strip() or -1),
            "used": used.group(1) if used else "?",
            "evicted": int(evicted.group(1)) if evicted else -1,
        }
    except Exception as e:  # noqa: BLE001
        return {"error": str(e)}


def snapshot(ports: list[int]) -> dict:
    snap = {"ts": time.time(), "engines": {}, "server": {}, "l2": {}}
    for p in ports:
        snap["engines"][str(p)] = engine_metrics(p)
    http_port = int(os.environ.get("LMS_HTTP", "8080"))
    snap["server"] = server_status(http_port)
    if os.environ.get("L2_BACKEND", "redis") == "redis":
        snap["l2"]["redis"] = redis_snapshot(int(os.environ.get("REDIS_PORT", "6379")))
    return snap


def window_ceiling(path: str) -> float | None:
    """实验窗口的理论前缀命中率上限（有 trace 窗口文件才算）。"""
    try:
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "trace"))
        from window import ceiling  # noqa: E402

        reqs = [json.loads(l) for l in open(path)]
        reqs.sort(key=lambda r: r["timestamp"])
        return round(ceiling(reqs), 2)
    except Exception:  # noqa: BLE001 — 上限是锦上添花
        return None


def delta(before: dict, after: dict, window: str | None) -> dict:
    out: dict = {"cache": {}, "l2": {}}
    for port, m_after in after.get("engines", {}).items():
        m_before = before.get("engines", {}).get(port, {})
        d = {
            k: round(m_after[k] - m_before.get(k, 0))
            for k in m_after
            if k in m_before and "num_requests" not in k and m_after[k] - m_before.get(k, 0)
        }
        q = d.get("vllm:prefix_cache_queries_total", 0)
        h = d.get("vllm:prefix_cache_hits_total", 0)
        eq = d.get("vllm:external_prefix_cache_queries_total", 0)
        eh = d.get("vllm:external_prefix_cache_hits_total", 0)
        panel = {
            "deltas": d,
            "gpu_apc_hit_pct": round(h / q * 100, 2) if q else None,
            "external_hit_pct": round(eh / eq * 100, 2) if eq else None,
            "combined_pct": round((h + eh) / q * 100, 2) if q else None,
        }
        out["cache"][f"port{port}"] = panel
    if window:
        out["theoretical_max_pct"] = window_ceiling(window)
    rb = before.get("l2", {}).get("redis", {})
    ra = after.get("l2", {}).get("redis", {})
    if rb or ra:
        out["l2"]["redis"] = {
            "before": rb, "after": ra,
            "evicted_delta": ra.get("evicted", 0) - rb.get("evicted", 0)
            if "evicted" in ra and "evicted" in rb else None,
        }
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sp = sub.add_parser("snapshot")
    sp.add_argument("--ports", default="8000", help="逗号分隔的 vLLM 端口")
    dp = sub.add_parser("delta")
    dp.add_argument("before")
    dp.add_argument("after")
    dp.add_argument("--window", default=None, help="回放窗口 jsonl（算理论上限）")
    args = ap.parse_args()

    if args.cmd == "snapshot":
        print(json.dumps(snapshot([int(p) for p in args.ports.split(",")]), indent=1))
    else:
        d = delta(json.load(open(args.before)), json.load(open(args.after)), args.window)
        print(json.dumps(d, indent=1, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
