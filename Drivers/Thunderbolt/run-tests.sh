#!/bin/bash
# Host-side tests for the ThunderBridge driver sources. No hardware, no install:
# each test compiles a driver header with clang++ or checks driver source text.
#
# Scripts/test-*.sh that check app sources (meter map, control tab scroll,
# dext upgrade activation) or a built package are not run here.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

TESTS=(
    test-optical-format.sh
    test-mixer-route.sh
    test-mixer-pan.sh
    test-timing-profile.sh
    test-thunderbolt-lifecycle.sh
    test-channel-names.sh
    test-driver-build.sh
)

for t in "${TESTS[@]}"; do
    echo "[tb] $t"
    bash "$DIR/Scripts/$t"
done
echo "[ok] ThunderBridge driver host tests passed (${#TESTS[@]})"
