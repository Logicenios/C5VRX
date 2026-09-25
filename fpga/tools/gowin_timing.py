#!/usr/bin/env python3
"""Summarise the Gowin EDA timing result (impl/pnr) and fail on any violation.

  python3 tools/gowin_timing.py [impl/pnr]
Prints the per-clock Fmax, the number of failing setup / hold paths among the reported ones
(gowin/tangnano20k.sdc asks for the 700 worst setup paths), and the worst paths grouped by
start and end register. Exit status 1 if any reported path has negative slack.
"""
import collections
import html
import re
import sys
from pathlib import Path

d = Path(sys.argv[1] if len(sys.argv) > 1 else "impl/pnr")
t = html.unescape(re.sub(r"<[^>]+>", " ", (d / "top_tr_content.html").read_text(errors="replace")))
t = re.sub(r"\s+", " ", t)
for m in re.finditer(r"\d+ (\S+) ([\d.]+)\(MHz\) ([\d.]+)\(MHz\)", t[t.find("Max Frequency Summary"):][:1500]):
    clk, want, got = m.group(1), float(m.group(2)), float(m.group(3))
    print(f"{clk:8s} {got:8.2f} MHz (constraint {want:.2f}, margin {100 * (got / want - 1):+.1f} %)")

paths = (d / "top.timing_paths").read_text().split("=====")
fails = {"SETUP": [], "HOLD": []}
for p in paths:
    lines = [x.strip() for x in p.strip().splitlines() if x.strip()]
    if len(lines) < 4 or lines[0] not in fails:
        continue
    slack = float(lines[1])
    nodes = [x for x in lines[4:] if not re.fullmatch(r"-?[\d.]+", x)]
    if slack < 0:
        fails[lines[0]].append((slack, nodes[0], nodes[-1]))
for kind, f in fails.items():
    print(f"{len(f)} failing {kind.lower()} paths")
    groups = collections.defaultdict(list)
    for slack, a, b in f:
        groups[(re.sub(r"(_\d+)?(_s\d*)?$", "", a), re.sub(r"(_\d+)?(_s\d*)?$", "", b))].append(slack)
    for (a, b), v in sorted(groups.items(), key=lambda kv: min(kv[1]))[:10]:
        print(f"  {min(v):7.2f} ns  {len(v):3d}  {a} -> {b}")
sys.exit(1 if fails["SETUP"] or fails["HOLD"] else 0)
