#!/usr/bin/env python3
"""Compare an RTL dump with a Python reference over the RTL's length (the reference may
hold a few extra samples that the RTL pipeline has not flushed). Exit 1 on any mismatch."""
import sys

rtl = open(sys.argv[1]).read().split("\n")
ref = open(sys.argv[2]).read().split("\n")
rtl = [l for l in rtl if l.strip()]
ref = [l for l in ref if l.strip()]
bad = [i for i, (a, b) in enumerate(zip(rtl, ref)) if a.split() != b.split()]
short = len(rtl) > len(ref) or len(rtl) < len(ref) - 16
ok = not bad and not short and len(rtl) > 0
print(f"{sys.argv[1]}: {len(rtl) - len(bad)}/{len(rtl)} lines match {sys.argv[2]}"
      + (f", first mismatch at line {bad[0] + 1}" if bad else "") + (" LENGTH" if short else "")
      + (" PASS" if ok else " FAIL"))
sys.exit(0 if ok else 1)
