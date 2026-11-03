#!/bin/bash
# Contract tests for MaestroAudioShm.h.
#
# Compiled BOTH ways on purpose: MaestroVolumeProxy is C, the AudioServerPlugin
# is C++, and they share this header. If the layout static_asserts ever hold in
# one language but not the other, the two processes disagree about the shared
# memory and audio breaks in ways that are miserable to debug. That is exactly
# the failure class the v1 head/tail FIFO fell into.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cp "$DIR"/*.h "$DIR/MaestroAudioShmTests.c" "$DIR/MaestroClockSlaveTests.c" "$TMP/"
cp "$TMP/MaestroAudioShmTests.c" "$TMP/MaestroAudioShmTests.cpp"

echo "[shm] compiling as C (proxy)..."
clang   -std=c11   -Wall -Wextra -Werror -O2 -I"$TMP" -o "$TMP/t_c"   "$TMP/MaestroAudioShmTests.c"
"$TMP/t_c"

echo "[shm] compiling as C++ (AudioServerPlugin)..."
clang++ -std=c++17 -Wall -Wextra -Werror -O2 -I"$TMP" -o "$TMP/t_cpp" "$TMP/MaestroAudioShmTests.cpp"
"$TMP/t_cpp"

echo "[clock] simulating both IO threads on different crystals..."
clang -std=c11 -Wall -Wextra -Werror -O2 -I"$TMP" -o "$TMP/clk" "$TMP/MaestroClockSlaveTests.c"
"$TMP/clk"

echo
echo "[ok] layout agrees in both languages, seqlock is tear-free,"
echo "     clock stays locked under drift, and D covers the worst-case writer."
