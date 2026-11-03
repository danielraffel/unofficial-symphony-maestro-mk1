#!/bin/bash
set -euo pipefail

APP_PATH="${1:-Installer/build/payload/Applications/Maestro.app}"
EXECUTABLE="$APP_PATH/Contents/MacOS/MaestroApp"
SPARKLE="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"

test -x "$EXECUTABLE"
test -f "$SPARKLE"

if ! otool -l "$EXECUTABLE" | awk '
    $1 == "path" && $2 == "@loader_path/../Frameworks" { found = 1 }
    END { exit found ? 0 : 1 }
  '; then
    echo "MaestroApp is missing the Sparkle framework rpath" >&2
    exit 1
fi

if otool -l "$EXECUTABLE" | awk '
    $1 == "path" && $2 == "@loader_path" { found = 1 }
    END { exit found ? 0 : 1 }
  '; then
    echo "MaestroApp retains the invalid standalone @loader_path rpath" >&2
    exit 1
fi

codesign --verify --deep --strict "$APP_PATH"

# Launch the disposable payload directly with no ThunderBridge attached. This catches the
# failure mode that a signature-only check misses: dyld can reject the app before SwiftUI or
# AppState gets a chance to render the normal "No device connected" state. Keep the process
# isolated from /Applications/Maestro.app and stop it after startup evidence is captured.
launch_log=$(mktemp "${TMPDIR:-/tmp}/maestro-package-launch.XXXXXX")
launch_pid=""
cleanup() {
    if [ -n "$launch_pid" ] && kill -0 "$launch_pid" 2>/dev/null; then
        kill "$launch_pid" 2>/dev/null || true
        wait "$launch_pid" 2>/dev/null || true
    fi
    rm -f "$launch_log"
}
trap cleanup EXIT

"$EXECUTABLE" >"$launch_log" 2>&1 &
launch_pid=$!
sleep 3
if ! kill -0 "$launch_pid" 2>/dev/null; then
    echo "Maestro packaged app exited during no-hardware launch" >&2
    cat "$launch_log" >&2
    exit 1
fi
if ! grep -q "No Symphony IO device found via CoreAudio" "$launch_log"; then
    echo "Maestro packaged app did not reach its no-hardware fallback" >&2
    cat "$launch_log" >&2
    exit 1
fi
echo "Maestro packaged-app signature, dyld dependencies, and no-hardware launch: PASS"
