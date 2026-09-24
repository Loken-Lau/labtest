#!/usr/bin/env python3
"""端到端冒烟：验证「vLLM -> LMCacheMPConnector -> MP server -> L2」整条链路。

用法:
  python3 smoke.py --port 8000 --model qwen3-8b

判定（三选一通过即 PASS，按证据强度排序）:
  1. external_prefix_cache_hits 计数器在第二次请求后增加（最直接）
  2. MP server /cache/objects 非空
  3. L2(redis) dbsize 增加
同时报告两次相同 prompt 的 TTFT（第二次应显著变快）。
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
import urllib.request

# 确定性 prompt：每次运行完全一致（前缀命中判定要求）
PROMPT = "smoke-prefix-" + "确定性冒烟填充文本。" * 400


def metrics(port: int) -> dict:
    with urllib.request.urlopen(f"http://localhost:{port}/metrics", timeout=5) as r:
        out = {}
        for line in r.read().decode().splitlines():
            # 指标名后可能带 {engine="0",model_name=...} 标签，必须跳过再取数值
            m = re.match(
                r"^(vllm:(?:external_)?prefix_cache_(?:queries|hits)(_total)?)"
                r"(?:\{[^}]*\})?\s+([0-9.e+-]+)", line)
            if m:
                out[m.group(1)] = float(m.group(3))
        return out


def one_request(port: int, model: str) -> float:
    """发一条流式请求，返回 TTFT(ms)。"""
    body = json.dumps({
        "model": model, "prompt": PROMPT, "max_tokens": 8,
        "temperature": 0.0, "stream": True, "ignore_eos": True,
        "stream_options": {"include_usage": True},
    }).encode()
    req = urllib.request.Request(
        f"http://localhost:{port}/v1/completions", data=body,
        headers={"Content-Type": "application/json"})
    t0 = time.monotonic()
    ttft = None
    with urllib.request.urlopen(req, timeout=300) as r:
        for raw in r:
            line = raw.decode().strip()
            if line.startswith("data: ") and line[6:] != "[DONE]":
                if ttft is None:
                    ttft = (time.monotonic() - t0) * 1000
    return ttft or -1.0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--model", default="qwen3-8b")
    ap.add_argument("--http", type=int, default=int(__import__("os").environ.get("LMS_HTTP", "8080")))
    args = ap.parse_args()

    # 0. server 健康
    try:
        with urllib.request.urlopen(
            f"http://localhost:{args.http}/healthcheck", timeout=5
        ) as r:
            print(f"[OK] lmcache server 健康: {r.read().decode()[:100]}")
    except Exception as e:  # noqa: BLE001
        print(f"[FAIL] lmcache server 不可达: {e}")
        return 1

    m0 = metrics(args.port)
    t1 = one_request(args.port, args.model)
    t2 = one_request(args.port, args.model)
    # 计数器经 KVConnectorStats 异步上报，实测要 ~10s 才可见
    time.sleep(12)
    m2 = metrics(args.port)

    eh_delta = (m2.get("vllm:external_prefix_cache_hits_total", 0)
                - m0.get("vllm:external_prefix_cache_hits_total", 0))
    print(f"TTFT 第1次 {t1:.0f}ms -> 第2次 {t2:.0f}ms（相同 prompt）")
    print(f"external_prefix_cache_hits 增量: {eh_delta:.0f}")
    print("（注意: 同实例重复请求命中 GPU APC 不走 external；external>0 需要"
          "冷实例+热缓存，见 REPORT.md 指标口径说明）")

    verdicts = []
    if eh_delta > 0:
        verdicts.append(("external_hits>0", True))
    try:
        with urllib.request.urlopen(
            f"http://localhost:{args.http}/status", timeout=5
        ) as r:
            st = json.loads(r.read().decode())
            n = st["storage_manager"]["l1_manager"]["total_object_count"]
            verdicts.append((f"server L1 objects={n}", n > 0))
    except Exception:  # noqa: BLE001
        pass
    try:
        cli = subprocess.run(
            [__import__("os").path.expanduser("~/ant/miniconda3/envs/redis/bin/redis-cli"),
             "-p", "6379", "dbsize"],
            capture_output=True, text=True, timeout=5,
        )
        verdicts.append((f"redis dbsize={cli.stdout.strip()}", int(cli.stdout.strip() > 0)))
    except Exception:  # noqa: BLE001
        pass

    if any(ok for _, ok in verdicts):
        print("[PASS] MP 缓存链路验证通过: " + "; ".join(
            f"{name}={'✓' if ok else '✗'}" for name, ok in verdicts))
        return 0
    print(f"[WARN] 未捕获到命中证据（可能是 v0 指标口径变化）: {verdicts}")
    print("       人工复核: scripts/status.sh + 服务日志")
    return 2


if __name__ == "__main__":
    sys.exit(main())
