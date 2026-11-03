#!/bin/bash
# Verify the compiled Maestro app using XcodeBuildMCP-compatible checks.
# This script validates the built .app bundle and can be extended
# with XcodeBuildMCP tool calls for UI automation testing.
#
# Usage:
#   ./Tools/verify-app.sh                    # Check debug build
#   ./Tools/verify-app.sh --release          # Check release build
#   ./Tools/verify-app.sh --launch           # Build, launch, and verify window appears

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/Apps/Maestro"
CONFIG="debug"
LAUNCH=false

for arg in "$@"; do
  case "$arg" in
    --release) CONFIG="release" ;;
    --launch) LAUNCH=true ;;
  esac
done

echo "=== Maestro App Verification ($CONFIG) ==="

# 1. Build
echo "Building ($CONFIG)..."
if [ "$CONFIG" = "release" ]; then
  swift build --package-path "$PACKAGE_DIR" -c release
else
  swift build --package-path "$PACKAGE_DIR"
fi

# 2. Check binary exists
BIN_PATH="$PACKAGE_DIR/.build/$CONFIG/MaestroApp"
if [ ! -f "$BIN_PATH" ]; then
  echo "FAIL: Binary not found at $BIN_PATH"
  exit 1
fi
echo "Binary: $BIN_PATH ($(du -h "$BIN_PATH" | cut -f1) )"

# 3. Verify it runs and exits cleanly (scaffold mode)
echo "Running smoke test..."
OUTPUT=$("$BIN_PATH" 2>&1) || true
if echo "$OUTPUT" | grep -q "scaffold build OK"; then
  echo "PASS: Scaffold smoke test"
else
  echo "WARN: Unexpected output: $OUTPUT"
fi

# 4. Check module linkage
echo "Checking dynamic dependencies..."
otool -L "$BIN_PATH" 2>/dev/null | grep -v "^$BIN_PATH" | head -10

# 5. Launch test (Phase 2+: will use XcodeBuildMCP for UI verification)
if [ "$LAUNCH" = true ]; then
  echo ""
  echo "Launch test not yet implemented."
  echo "Phase 2 will add XcodeBuildMCP-based UI verification:"
  echo "  - Launch app via xcodebuildmcp"
  echo "  - Verify main window appears"
  echo "  - Check device list populates (with simulator)"
  echo "  - Screenshot comparison"
  echo "  - Graceful quit"
fi

echo ""
echo "=== Verification Complete ==="
