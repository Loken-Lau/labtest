#!/usr/bin/env python3
"""动态前缀命中率：两次计数器快照的增量口径（回答「刚刚这几十秒命中率多少」）。

vLLM 的 prefix_cache_* 计数器是自实例启动的累计值，status.sh 看到的是历史均值；
本脚本取 A/B 两点快照算窗口内增量，得到「当下」命中率。三层口径：
  L0    = Δprefix_cache_hits / Δprefix_cache_queries          （实例 GPU APC）
  L1/L2 = Δexternal_prefix_cache_hits / Δexternal_queries     （从 MP server 取回）
  合并  = (ΔL0命中 + Δ外命中) / Δ查询

用法:
  python3 hitrate.py                                    # 默认 8000，采样 10s
  python3 hitrate.py --ports 8000,8001 --interval 30
  python3 hitrate.py --watch --interval 5               # 持续面板，Ctrl-C 退出

注意（口径，读数前必看）:
  - 计数器经 KVConnectorStats 异步上报，实测滞后 ~10s —— interval < 10s 读数偏低
  - external 只统计「L0 未命中后由 server 供回」的 token；同实例重复请求走 L0 不增
  - 窗口内无流量（Δqueries=0）显示 n/a，不是 0%
"""
from __future__ import annotations

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bench"))
from collect import engine_metrics  # noqa: E402 — 复用唯一指标口径（含按行解码修复）

Q = "vllm:prefix_cache_queries_total"
H = "vllm:prefix_cache_hits_total"
EQ = "vllm:external_prefix_cache_queries_total"
EH = "vllm:external_prefix_cache_hits_total"


def l1_objects() -> int | None:
    from collect import http_json  # noqa: PLC0415 — 同上

    st = http_json(f"http://localhost:{os.environ.get('LMS_HTTP', '8080')}/status")
    try:
        return st["storage_manager"]["l1_manager"]["total_object_count"]
    except Exception:  # noqa: BLE001 — server 不在则不显示 L1 增量
        return None


def pct(num: int, den: int) -> str:
    return f"{num / den * 100:.2f}%" if den > 0 else "n/a"


def line(ports: list[int], b: dict, a: dict, dt: float, ts: str) -> str:
    parts = []
    for p in ports:
        m0, m1 = b.get(p, {}), a.get(p, {})
        if "error" in m1:
            parts.append(f":{p} [DOWN]")
            continue
        d = {k: m1.get(k, 0) - m0.get(k, 0) for k in (Q, H, EQ, EH)}
        parts.append(
            f":{p} L0 {pct(d[H], d[Q])} | L1/L2 {pct(d[EH], d[EQ])} | "
            f"合并 {pct(d[H] + d[EH], d[Q])}  "
            f"(Δtok 查询{d[Q] / 1e3:.0f}k L0中{d[H] / 1e3:.0f}k 外中{d[EH] / 1e3:.0f}k)"
        )
    l10, l11 = b.get("_l1"), a.get("_l1")
    l1s = f" | L1 objects {l10}->{l11}" if l10 is not None and l11 is not None else ""
    return f"[{ts}] 窗口{dt:.0f}s  " + " || ".join(parts) + l1s


def sample(ports: list[int]) -> dict:
    s = {p: engine_metrics(p) for p in ports}
    s["_l1"] = l1_objects()
    return s


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--ports", default="8000", help="逗号分隔的 vLLM 端口")
    ap.add_argument("--interval", type=float, default=10.0, help="采样窗口秒数（建议 >=10，计数器异步滞后）")
    ap.add_argument("--watch", action="store_true", help="持续刷新")
    args = ap.parse_args()
    ports = [int(p) for p in args.ports.split(",")]

    b = sample(ports)
    while True:
        time.sleep(args.interval)
        a = sample(ports)
        print(line(ports, b, a, args.interval, time.strftime("%H:%M:%S")), flush=True)
        if not args.watch:
            return 0
        b = a


if __name__ == "__main__":
    sys.exit(main())
