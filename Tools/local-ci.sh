#!/bin/bash
# Local CI runner for symphony-maestro.
# Run before every commit or as a git pre-push hook.
# Compile and test locally without installing or publishing.
#
# Usage:
#   ./Tools/local-ci.sh              # Run all checks
#   ./Tools/local-ci.sh --quick      # Skip slow checks (just build + unit tests)
#   ./Tools/local-ci.sh --report     # Write results to .ci-status.json

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/Apps/Maestro"
STATUS_FILE="$REPO_ROOT/.ci-status.json"
QUICK_MODE=false
REPORT_MODE=false
FAILED=0
PASSED=0
SKIPPED=0
RESULTS=()

for arg in "$@"; do
  case "$arg" in
    --quick) QUICK_MODE=true ;;
    --report) REPORT_MODE=true ;;
  esac
done

timestamp() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

record() {
  local name="$1" status="$2" duration="$3" detail="${4:-}"
  RESULTS+=("{\"name\":\"$name\",\"status\":\"$status\",\"duration_s\":$duration,\"detail\":\"$detail\"}")
  if [ "$status" = "pass" ]; then PASSED=$((PASSED + 1)); fi
  if [ "$status" = "fail" ]; then FAILED=$((FAILED + 1)); fi
  if [ "$status" = "skip" ]; then SKIPPED=$((SKIPPED + 1)); fi
}

run_check() {
  local name="$1"
  shift
  echo "--- [$name] ---"
  local start=$SECONDS
  if "$@" 2>&1; then
    local dur=$((SECONDS - start))
    echo "  PASS ($dur s)"
    record "$name" "pass" "$dur"
  else
    local dur=$((SECONDS - start))
    echo "  FAIL ($dur s)"
    record "$name" "fail" "$dur"
  fi
}

echo "========================================="
echo " Local CI — symphony-maestro"
echo " $(timestamp)"
echo "========================================="
echo ""

# 1. Public-source boundary (tracked files, including staged additions).
run_check "public-source-boundary" python3 "$REPO_ROOT/Tools/check-public-source.py"

run_check "version-tuple" python3 "$REPO_ROOT/Tools/check-versions.py"

# 2. Swift build
run_check "swift-build" swift build --package-path "$PACKAGE_DIR" --jobs "${MAESTRO_BUILD_JOBS:-4}"

# 3. Swift tests
run_check "swift-test" swift test --package-path "$PACKAGE_DIR" --jobs "${MAESTRO_BUILD_JOBS:-4}"

# 4. Shared shm-contract tests
#
# These tests check a boundary that the Swift unit suite does not: that
# the C and C++ sides of Drivers/Shared/MaestroAudioShm.h agree on layout, that
# the seqlock is tear-free, and that D covers the worst-case writer. A mismatch
# there is SILENT at runtime -- the plugin refuses the mapping and "Maestro USB"
# is simply mute -- so it is exactly the class of break CI should catch. They ran
# only when someone remembered to invoke them by hand.
run_check "shm-contract-test" bash "$REPO_ROOT/Drivers/Shared/run-tests.sh"

# 5. Build for release (catches optimisation-only errors)
if [ "$QUICK_MODE" = false ]; then
  run_check "swift-build-release" swift build --package-path "$PACKAGE_DIR" --jobs "${MAESTRO_BUILD_JOBS:-4}" -c release
else
  echo "--- [swift-build-release] SKIPPED (--quick) ---"
  record "swift-build-release" "skip" 0
fi

# 6. Check for compiler warnings (treat warnings as errors)
if [ "$QUICK_MODE" = false ]; then
  run_check "swift-warnings" bash -c '
    OUTPUT=$(swift build --package-path "'"$PACKAGE_DIR"'" --jobs "${MAESTRO_BUILD_JOBS:-4}" 2>&1) || { printf "%s\n" "$OUTPUT"; exit 1; }
    if echo "$OUTPUT" | grep -q "warning:"; then
      echo "Compiler warnings found:"
      echo "$OUTPUT" | grep "warning:"
      exit 1
    fi
    echo "No warnings"
  '
else
  echo "--- [swift-warnings] SKIPPED (--quick) ---"
  record "swift-warnings" "skip" 0
fi

echo ""
echo "========================================="
echo " Results: $PASSED passed, $FAILED failed, $SKIPPED skipped"
echo "========================================="

# Write status file
if [ "$REPORT_MODE" = true ] || [ -f "$STATUS_FILE" ]; then
  RESULTS_JSON=$(printf '%s,' "${RESULTS[@]}" | sed 's/,$//')
  cat > "$STATUS_FILE" << EOF
{
  "timestamp": "$(timestamp)",
  "branch": "$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || echo 'unknown')",
  "commit": "$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo 'none')",
  "passed": $PASSED,
  "failed": $FAILED,
  "skipped": $SKIPPED,
  "checks": [$RESULTS_JSON]
}
EOF
  echo "Status written to .ci-status.json"
fi

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
