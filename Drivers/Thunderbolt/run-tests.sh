#!/bin/bash
# Host-side tests for the ThunderBridge driver. No hardware, no install.
#
# Part 1: Scripts/test-*.sh that compile a driver header with clang++ or check
# driver source text (optical format, mixer route/pan, timing profile,
# lifecycle, channel names, driver build report), and
# test-thunderbolt-meter-map.sh, which checks app source text (the meter and
# health code in AppState.swift) and runs here so that it runs somewhere. The
# other Scripts/test-*.sh that check app sources (control tab scroll, dext
# upgrade activation) or a built package are not run here.
#
# Part 2: the register-trace test.
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
#      the release driver source (option-card parity, 0.10.17 build 123).
#   2. If git and the base ref are available, the base ref's driver source is
#      compiled with the same harness and its traces are compared directly with
#      the working tree's. This is the before/after check. The default base is
#      the first of fix/card-parity and main that exists: the release driver
#      this branch is built on (option-card parity) until it is on main.
#   3. The two-port traces (p2-*) are compared with golden/ so a change to the
#      port-2 sequence is always a visible diff, and the harness asserts the
#      Stage 1 limits (no port-2 DMA, no channel-count or routing change).
#      p2-rate-change also asserts that a device rate change reaches port 2 in
#      the original's order (port 2 told first, port 1 changed and verified,
#      then port 2 again and verified), that a port-2 failure does not fail the
#      change, and that port 2 is put back when port 1 could not be told.
#   4. Stage 2 (p2-audio-*): the port selector and audio on port 2. The traces
#      pin, and the harness asserts: switching 32 <-> 64 (buffer registers,
#      routing entries 32..63, unmute, the engines started port 2 first, the
#      64-channel stream formats, the IO handler splitting each frame between
#      the two ports); the phase alignment; a request refused with nothing on
#      port 2 leaving every register as it was; rate changes at 64; and the
#      port-2 chain disappearing in mid-stream, after which port 1 must be
#      running alone again and Core Audio asked to go back to 32 channels.
#      p2-audio-sleep-mid-select: a switch abandoned because the Mac went to
#      sleep during it leaves port 2 enabled; the first link-watch tick after
#      a wake that kept the card's registers disables it again.
#      Until 64 is selected a two-port build writes exactly what stage 1 wrote.
#
# Usage:
#   Drivers/Thunderbolt/run-tests.sh                 # all checks, default base ref
#   Drivers/Thunderbolt/run-tests.sh --against REF   # use another base ref
#   Drivers/Thunderbolt/run-tests.sh --no-ref        # golden files only
#   Drivers/Thunderbolt/run-tests.sh --record-p2     # rewrite golden/p2-*.trace
#   Drivers/Thunderbolt/run-tests.sh --record-p1     # rewrite golden/p1-*.trace
#                                                    # (only when the default
#                                                    # path is MEANT to change)
#   Drivers/Thunderbolt/run-tests.sh --verbose       # driver log + raw accesses
#   Drivers/Thunderbolt/run-tests.sh --traces-only   # skip part 1
#
# No hardware is touched and nothing is installed.
set -euo pipefail

TB_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$TB_DIR/Tests/RegisterTrace"
GOLDEN="$TEST_DIR/golden"
BASE_REF=""
RUN_HOST_TESTS=true
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
        --traces-only) RUN_HOST_TESTS=false ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

# ── Part 1: host tests of driver headers and sources ────────────────────────
HOST_TESTS=(
    test-optical-format.sh
    test-mixer-route.sh
    test-mixer-pan.sh
    test-timing-profile.sh
    test-thunderbolt-lifecycle.sh
    test-channel-names.sh
    test-driver-build.sh
    test-retire-for-upgrade.sh
    test-thunderbolt-meter-map.sh
)
if $RUN_HOST_TESTS; then
    for t in "${HOST_TESTS[@]}"; do
        echo "[tb] $t"
        bash "$TB_DIR/Scripts/$t"
    done
    echo "[ok] ThunderBridge driver host tests passed (${#HOST_TESTS[@]})"
    echo
fi

# ── Part 2: register traces ─────────────────────────────────────────────────
if [[ -z "$BASE_REF" ]]; then
    for candidate in fix/card-parity main; do
        if git -C "$TB_DIR" rev-parse --verify --quiet "$candidate^{commit}" > /dev/null 2>&1; then
            BASE_REF="$candidate"; break
        fi
    done
    BASE_REF="${BASE_REF:-main}"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# build_and_run <source dir> <output dir> <label>
build_and_run() {
    local src="$1" out="$2" label="$3"
    local defs=()
    if grep -q 'ReadPort2State' "$src/SymphonyThunderbridge.cpp"; then
        defs=(-DTRACE_HAVE_PORT2)
    fi
    if grep -q 'PerformPortModeChange' "$src/SymphonyThunderbridge.cpp"; then
        defs+=(-DTRACE_HAVE_PORT2_AUDIO)
    fi
    # Retire for upgrade (selector 7, release driver 123). It refuses an
    # unstamped build, so the harness stamps one; nothing else reads it.
    if grep -q 'RetireForUpgrade' "$src/SymphonyThunderbridge.cpp"; then
        defs+=(-DTRACE_HAVE_RETIRE -DSYMPHONY_DEXT_BUILD=1000)
    fi
    mkdir -p "$out"
    echo "[trace] compiling the driver source ($label) for the host..."
    clang++ -std=c++17 -fblocks -O1 -Wall -Wno-unused-function -Wno-unused-variable \
        -Wno-unused-parameter -Wno-unused-but-set-variable \
        ${defs[@]+"${defs[@]}"} \
        -I "$TEST_DIR/shim" -I "$src" \
        "$TEST_DIR/RegisterTrace.cpp" "$src/SymphonyThunderbridge.cpp" \
        -o "$out/register-trace"
    # A failed check inside the harness is reported with the trace comparisons
    # below rather than instead of them.
    "$out/register-trace" --out "$out" ${VERBOSE[@]+"${VERBOSE[@]}"} || status=1
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

# The two-port experiment is switched on by a personality key that must never
# be in the checked-in Info.plist: released builds are made from it.
if grep -q 'SymphonyPortCount' "$TB_DIR/Info.plist"; then
    echo "[FAIL] Drivers/Thunderbolt/Info.plist contains SymphonyPortCount; the key belongs" >&2
    echo "       only in an experimental package's personality, never in the repository." >&2
    exit 1
fi

status=0
build_and_run "$TB_DIR/Source" "$TMP/work" "working tree"

if $RECORD_P1; then
    cp "$TMP/work"/p1-*.trace "$GOLDEN/"
    echo "[trace] recorded single-port golden traces from the working tree"
fi
if $RECORD_P2; then
    cp "$TMP/work"/p2-*.trace "$GOLDEN/"
    echo "[trace] recorded two-port golden traces from the working tree"
fi

compare_dir 'p1-*.trace' "$GOLDEN" "$TMP/work" "golden (release driver)" || status=1

# A single-port trace the harness produced but nobody recorded is a hole.
for f in "$TMP/work"/p1-*.trace; do
    if [[ ! -e "$GOLDEN/$(basename "$f")" ]]; then
        echo "[trace] FAIL $(basename "$f") has no golden file"; status=1
    fi
done

if ls "$TMP/work"/p2-*.trace > /dev/null 2>&1; then
    compare_dir 'p2-*.trace' "$GOLDEN" "$TMP/work" "golden (two-port)" || status=1
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
