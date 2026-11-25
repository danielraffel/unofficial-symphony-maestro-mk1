#!/bin/bash
# The card mixer coefficients: the generated table equals the original's
# arithmetic for every fader, Master and pan (Scripts/gen-mixer-coef.py
# --check), the checked-in header is what the generator writes, and the
# header's lookup gives the spot values of the original.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
python3 "$DIR/Scripts/gen-mixer-coef.py" --check
python3 "$DIR/Scripts/gen-mixer-coef.py" "$TMP/SymphonyMixerCoef.h"
cmp -s "$TMP/SymphonyMixerCoef.h" "$DIR/Source/SymphonyMixerCoef.h" || { echo "Source/SymphonyMixerCoef.h is not what the generator writes"; exit 1; }
cat > "$TMP/t.cpp" <<'CPP'
#include <cassert>
#include <cstdio>
#include "SymphonyMixerCoef.h"
int main() {
    assert(SymphonyMixerCoef(0, 128) == 0x20000000u);         // unity
    assert(SymphonyMixerCoef(0, 64) == 0x16A00000u);          // centre, -3.01 dB
    assert(SymphonyMixerCoef(6, 128) == 0x3FD90000u);         // +6
    assert(SymphonyMixerCoef(12, 128) == 0x7F640000u);        // +12, below the sign bit
    assert(SymphonyMixerCoef(0, 0) == 0);                     // hard pan: far side off
    assert(SymphonyMixerCoef(-200, 128) == 0);                // below the table: off
    assert(SymphonyMixerCoef(-79, 128) == 0);                 // under 1/2^16
    puts("Mixer coefficients: PASS");
}
CPP
clang++ -std=c++17 -I "$DIR/Source" "$TMP/t.cpp" -o "$TMP/t" && "$TMP/t"
