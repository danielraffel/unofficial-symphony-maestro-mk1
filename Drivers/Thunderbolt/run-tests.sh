#!/bin/bash
# Register-trace test for the ThunderBridge driver.
#
# What it proves: with the two-port experiment off (no SymphonyPortCount key in
# the personality, which is how every released build runs), the driver does to
# the card exactly what it did before the experiment existed: the same BAR
# reads and writes with the same values, the same PCI config accesses, the same
# sleeps between them, the same DMA mappings and stream formats, in the same
# order.
#
# How: Tests/RegisterTrace compiles the real Source/SymphonyThunderbridge.cpp on
# the host against small stand-ins for DriverKit (Tests/RegisterTrace/shim) and
# runs Start, StartDevice, interrupts, six rate changes, a failed rate change,
# app commands, the link watch, sleep/wake with and without an FPGA reset, link
# recovery and Stop against a simulated card that records every access.
#
#   1. The single-port traces (p1-*) are compared with golden/, recorded from
#      the driver source as it is on main.
#   2. If git and the base ref are available, the base ref's driver source is
#      compiled with the same harness and its traces are compared directly with
#      the working tree's. This is the before/after check.
#   3. The two-port traces (p2-*) are compared with golden/ so a change to the
#      port-2 sequence is always a visible diff, and the harness asserts the
#      Stage 1 limits (no port-2 DMA, no channel-count or routing change).
#
# Usage:
#   Drivers/Thunderbolt/run-tests.sh                 # all checks, base ref "main"
#   Drivers/Thunderbolt/run-tests.sh --against REF   # use another base ref
#   Drivers/Thunderbolt/run-tests.sh --no-ref        # golden files only
#   Drivers/Thunderbolt/run-tests.sh --record-p2     # rewrite golden/p2-*.trace
#   Drivers/Thunderbolt/run-tests.sh --record-p1     # rewrite golden/p1-*.trace
#                                                    # (only when the default
#                                                    # path is MEANT to change)
#   Drivers/Thunderbolt/run-tests.sh --verbose       # driver log + raw accesses
#
# No hardware is touched and nothing is installed.
set -euo pipefail

TB_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$TB_DIR/Tests/RegisterTrace"
GOLDEN="$TEST_DIR/golden"
BASE_REF="main"
USE_REF=true
RECORD_P1=false
RECORD_P2=false
VERBOSE=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --against)   BASE_REF="$2"; shift ;;
        --no-ref)    USE_REF=false ;;
        --record-p1) RECORD_P1=true ;;
        --record-p2) RECORD_P2=true ;;
        --verbose)   VERBOSE=(--verbose) ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# build_and_run <source dir> <output dir> <label>
build_and_run() {
    local src="$1" out="$2" label="$3"
    local defs=()
    if grep -q 'ReadPort2State' "$src/SymphonyThunderbridge.cpp"; then
        defs=(-DTRACE_HAVE_PORT2)
    fi
    mkdir -p "$out"
    echo "[trace] compiling the driver source ($label) for the host..."
    clang++ -std=c++17 -fblocks -O1 -Wall -Wno-unused-function -Wno-unused-variable \
        -Wno-unused-parameter -Wno-unused-but-set-variable \
        ${defs[@]+"${defs[@]}"} \
        -I "$TEST_DIR/shim" -I "$src" \
        "$TEST_DIR/RegisterTrace.cpp" "$src/SymphonyThunderbridge.cpp" \
        -o "$out/register-trace"
    "$out/register-trace" --out "$out" ${VERBOSE[@]+"${VERBOSE[@]}"}
}

compare_dir() {
    local pattern="$1" want="$2" got="$3" what="$4" failed=0 n=0
    for f in "$want"/$pattern; do
        [[ -e "$f" ]] || continue
        local name; name="$(basename "$f")"
        n=$((n + 1))
        if [[ ! -e "$got/$name" ]]; then
            echo "[trace] FAIL $name: not produced ($what)"; failed=1; continue
        fi
        if ! diff -u "$f" "$got/$name" > "$TMP/diff.txt"; then
            echo "[trace] FAIL $name differs from $what:"
            head -60 "$TMP/diff.txt"
            failed=1
        else
            echo "[trace] ok   $name == $what ($(wc -l < "$f" | tr -d ' ') lines)"
        fi
    done
    if [[ $n -eq 0 ]]; then
        echo "[trace] FAIL no $pattern traces in $want ($what)"; failed=1
    fi
    return $failed
}

build_and_run "$TB_DIR/Source" "$TMP/work" "working tree"

if $RECORD_P1; then
    cp "$TMP/work"/p1-*.trace "$GOLDEN/"
    echo "[trace] recorded single-port golden traces from the working tree"
fi
if $RECORD_P2; then
    cp "$TMP/work"/p2-*.trace "$GOLDEN/"
    echo "[trace] recorded two-port golden traces from the working tree"
fi

status=0
compare_dir 'p1-*.trace' "$GOLDEN" "$TMP/work" "golden (driver as on main)" || status=1

# A single-port trace the harness produced but nobody recorded is a hole.
for f in "$TMP/work"/p1-*.trace; do
    if [[ ! -e "$GOLDEN/$(basename "$f")" ]]; then
        echo "[trace] FAIL $(basename "$f") has no golden file"; status=1
    fi
done

if ls "$TMP/work"/p2-*.trace > /dev/null 2>&1; then
    compare_dir 'p2-*.trace' "$GOLDEN" "$TMP/work" "golden (two-port, Stage 1)" || status=1
fi

if $USE_REF; then
    REPO_ROOT="$(git -C "$TB_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
    if [[ -n "$REPO_ROOT" ]] && git -C "$REPO_ROOT" rev-parse --verify --quiet "$BASE_REF^{commit}" > /dev/null; then
        mkdir -p "$TMP/ref-src"
        git -C "$REPO_ROOT" archive "$BASE_REF" Drivers/Thunderbolt/Source | tar -x -C "$TMP/ref-src"
        build_and_run "$TMP/ref-src/Drivers/Thunderbolt/Source" "$TMP/ref" \
            "$BASE_REF @ $(git -C "$REPO_ROOT" rev-parse --short "$BASE_REF")"
        compare_dir 'p1-*.trace' "$TMP/ref" "$TMP/work" "driver source at $BASE_REF" || status=1
    else
        echo "[trace] note: base ref '$BASE_REF' not available; compared with golden files only"
    fi
fi

echo
if [[ $status -ne 0 ]]; then
    echo "[FAIL] the driver no longer programs the card the way the baseline does"
    exit 1
fi
echo "[ok] single-port register traces are identical to the baseline"
