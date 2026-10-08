#!/usr/bin/env python3
"""L2 取回路径决定性实验（任何 L2 后端通用，mooncake 上最有判决力）。

问题：external 命中通常来自 L1，L2 是否真的能取回？本脚本构造唯一场景：
  1. 写入独占 probe prompt（重算 → L1 + 写穿 L2）
  2. 灌新数据把 L1 滚过一轮（probe 被 LRU 逐出；L2 池要够大才保得住——
     mooncake 注意 global_segment_size 需 > L1 容量，否则 L2 同轮被淘汰假阴性）
  3. 重启 vLLM 实例（冷 GPU APC）
  4. 重放 probe → external hits 增量即 L2 取回证据
判定:
  - external_prefix_cache_hits 增量 > 0（token 口径）
  - server 日志 "Prefetch request completed ... (0 L1, N L2)"（对象口径）

用法: python3 checks/l2_retrieve.py [--port 8000] [--model qwen3-8b] [--util 0.30]
前置: lmcache server + 一个实例已在跑；GPU 需容纳两次实例启动（共享机注意别人占用）。
"""
from __future__ import annotations

import argparse
import json
import random
import re
import subprocess
import threading
import time
import urllib.request

WORDS = ("alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu "
         "nu xi omicron pi rho sigma tau upsilon phi chi psi omega tensor "
         "kernel latency throughput bandwidth cache prefetch evict segment").split()


def post(port: int, model: str, prompt: str, max_tokens: int = 8) -> None:
    body = json.dumps({"model": model, "prompt": prompt, "max_tokens": max_tokens,
                       "temperature": 0.0, "stream": False, "ignore_eos": True}).encode()
    req = urllib.request.Request(f"http://localhost:{port}/v1/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        r.read()


def l1_count() -> int:
    with urllib.request.urlopen("http://localhost:8080/status", timeout=5) as r:
        return json.load(r)["storage_manager"]["l1_manager"]["total_object_count"]


def metrics(port: int) -> dict:
    with urllib.request.urlopen(f"http://localhost:{port}/metrics", timeout=5) as r:
        out = {}
        for line in r.read().decode().splitlines():
            m = re.match(r"^(vllm:external_prefix_cache_(?:queries|hits)_total)"
                         r"(?:\{[^}]*\})?\s+([0-9.e+-]+)", line)
            if m:
                out[m.group(1)] = float(m.group(2))
        return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--model", default="qwen3-8b")
    ap.add_argument("--util", default="0.30", help="重启实例的 gpu-memory-utilization")
    ap.add_argument("--fills", type=int, default=95, help="灌 L1 的新 prompt 条数")
    ap.add_argument("--repo", default="/home/liujinhao/lmcache-mp")
    args = ap.parse_args()

    probe = f"l2-retrieve-probe-{time.time_ns()}-" + "独有探针文本。" * 300

    # 1. 写 probe
    post(args.port, args.model, probe)
    time.sleep(2)
    print(f"[1] probe written: L1={l1_count()}")

    # 2. 滚一轮 L1（每条 ~6.5k token ≈ 29 chunk ≈ 1GB）
    last, drops = None, 0
    for i in range(9000, 9000 + args.fills):
        rng = random.Random(i)
        post(args.port, args.model, " ".join(rng.choice(WORDS) for _ in range(6500)),
             max_tokens=1)
        n = l1_count()
        if last is not None and n < last:
            drops += 1
        last = n
    print(f"[2] L1 rolled: {drops} evict batches, L1={last}")
    if drops == 0:
        print("[WARN] 没观察到淘汰批次，probe 可能仍在 L1（判定会失真）")

    # 3. 重启实例（等显存真正释放，共享 GPU 上尤其必要）
    subprocess.run(["bash", "scripts/stop_engine.sh", str(args.port)], cwd=args.repo)
    for _ in range(30):
        time.sleep(2)
        used = int(subprocess.run(
            ["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"],
            capture_output=True, text=True).stdout.strip())
        if used < 60000:
            break
    r = subprocess.run(["bash", "scripts/start_engine.sh", str(args.port), args.util],
                       cwd=args.repo, capture_output=True, text=True)
    print(f"[3] engine restart: {r.stdout.strip().splitlines()[-1]}")

    # 4. 重放（顺带采样 mooncake master 速率计数器，0.2s 粒度，抓到即加分证据）
    samples: list = []
    stop_flag = threading.Event()

    def sampler() -> None:
        while not stop_flag.is_set():
            try:
                with urllib.request.urlopen("http://localhost:9003/metrics/summary",
                                            timeout=2) as resp:
                    s = resp.read().decode()
                g = re.search(r"Get=([0-9.]+)/([0-9.]+)", s)
                e = re.search(r"Exist=([0-9.]+)/([0-9.]+)", s)
                samples.append((g.groups() if g else None, e.groups() if e else None))
            except Exception:  # noqa: BLE001
                pass
            time.sleep(0.2)

    t = threading.Thread(target=sampler)
    t.start()
    m0 = metrics(args.port)
    t0 = time.monotonic()
    post(args.port, args.model, probe)
    dt = (time.monotonic() - t0) * 1000
    time.sleep(12)  # external 计数器异步上报 ~10s
    m1 = metrics(args.port)
    stop_flag.set()
    t.join()

    q_d = m1.get("vllm:external_prefix_cache_queries_total", 0) - m0.get("vllm:external_prefix_cache_queries_total", 0)
    h_d = m1.get("vllm:external_prefix_cache_hits_total", 0) - m0.get("vllm:external_prefix_cache_hits_total", 0)
    burst = [s for s in samples
             if (s[0] and float(s[0][1]) > 0) or (s[1] and float(s[1][1]) > 0)]
    print(f"[4] replay {dt:.0f}ms | external queries d={q_d:.0f} hits d={h_d:.0f}")
    if burst:
        print(f"    master burst (Get/Exist 每秒速率>0): {burst[:4]}")
    print("    对照: grep 'Prefetch request completed' logs/lmcache-server.log 尾行")
    print(f"[{'PASS' if h_d > 0 else 'FAIL'}] L2 取回{'验证通过' if h_d > 0 else '未验证到'}")
    return 0 if h_d > 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
