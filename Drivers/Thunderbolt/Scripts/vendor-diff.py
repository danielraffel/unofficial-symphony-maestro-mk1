#!/usr/bin/env python3
"""Compare the vendor messages two register traces send, ignoring sequence
numbers and CRCs: prints each message removed or added, as (direction,
command, nValue, data). Used to prove that a re-recorded golden changes only
the writes a commit names (Drivers/Thunderbolt plan rule D7).

usage: vendor-diff.py BEFORE.trace AFTER.trace
"""
import difflib, re, sys

def messages(path):
    out = []
    for line in open(path):
        m = re.search(r'W 0x0000(?:38|48) each of n=(\d+): (.*)$', line)
        if not m: continue
        words = [(int(w, 16) >> 1) & 0xFF for w in m.group(2).split()]
        # One line can carry several frames back to back:
        # [0x80][size][seq][bmRequestType][bRequest][nValue x4][wLength x2][data...][crc]
        i = 0
        while i + 4 <= len(words) and words[i] == 0x80:
            size = words[i + 1]
            b = words[i:i + size + 4]
            i += size + 4
            if len(b) < 12: break
            kind = {0x40: 'W', 0xC0: 'R'}.get(b[3], '?')
            nvalue = b[5] | b[6] << 8 | b[7] << 16 | b[8] << 24
            data = ' '.join('%02x' % x for x in b[11:-1])
            out.append('%s 0x%02x n=%u [%s]' % (kind, b[4], nvalue, data))
    return out

a, b = messages(sys.argv[1]), messages(sys.argv[2])
for d in difflib.unified_diff(a, b, lineterm='', n=0):
    if d.startswith(('---', '+++', '@@')): continue
    print(d)
