#!/usr/bin/env python3
"""Prove that two register traces differ only in values written to the card
mixer's coefficient registers (same lines, same addresses, same order).
usage: mixer-only-diff.py BEFORE AFTER BASE  (BASE = kRegMixerCoeff, hex)
Prints each changed write; exits 1 if anything else differs."""
import re, sys
a, b = open(sys.argv[1]).read().splitlines(), open(sys.argv[2]).read().splitlines()
base = int(sys.argv[3], 16); end = base + 0x1000 * 4
if len(a) != len(b): print('line count differs'); sys.exit(1)
bad = 0
for x, y in zip(a, b):
    if x == y: continue
    mx, my = re.match(r'W 0x([0-9a-f]+) 0x([0-9a-f]+)$', x), re.match(r'W 0x([0-9a-f]+) 0x([0-9a-f]+)$', y)
    if mx and my and mx.group(1) == my.group(1) and base <= int(mx.group(1), 16) < end:
        print('  %s: %s -> %s' % (mx.group(1), mx.group(2), my.group(2))); continue
    print('NOT a mixer coefficient change:\n  - %s\n  + %s' % (x, y)); bad += 1
sys.exit(1 if bad else 0)
