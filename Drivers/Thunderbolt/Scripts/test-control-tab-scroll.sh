#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../../" && pwd)"
APP_DIR="$ROOT_DIR/Apps/Maestro/MaestroApp"

for view in InputViews.swift OutputViews.swift MixerViews.swift; do
    file="$APP_DIR/$view"
    test -f "$file"
    grep -q 'ScrollView(\.horizontal)' "$file"
    grep -q '\.scrollPosition(\$scrollPosition)' "$file"
    grep -q 'setControlTabScrollOffset' "$file"
    grep -q 'onDetachOffset: { offset in' "$file"
    grep -q 'restoreSessionScrollPosition' "$file"
    grep -q 'scrollPosition.isPositionedByUser' "$file"
    grep -q 'scrollObservationEnabled' "$file"
    if grep -q 'ScrollView(\[\.horizontal, \.vertical\])' "$file"; then
        echo "$view regressed to a vertical outer scroll view" >&2
        exit 1
    fi
    if grep -q '\.onScrollGeometryChange' "$file"; then
        echo "$view retains duplicate SwiftUI scroll persistence; native observer must be the sole writer" >&2
        exit 1
    fi
done

APP_STATE="$APP_DIR/AppState.swift"
grep -q 'controlTabScrollOffsets: \[NavigationArea: CGFloat\]' "$APP_STATE"
grep -q 'controlTabScrollOffset(for area: NavigationArea)' "$APP_STATE"
grep -q 'setControlTabScrollOffset(_ offset: CGFloat, for area: NavigationArea)' "$APP_STATE"
grep -q 'willStartLiveScrollNotification' "$APP_DIR/ControlTabScrollObserver.swift"
grep -q 'scheduleOffsetWrite' "$APP_DIR/ControlTabScrollObserver.swift"
grep -q 'offsetWriteScheduled' "$APP_DIR/ControlTabScrollObserver.swift"
grep -q 'onDetachOffset' "$APP_DIR/ControlTabScrollObserver.swift"
grep -q 'observedClipView' "$APP_DIR/ControlTabScrollObserver.swift"
grep -q 'Commit the native position synchronously' "$APP_DIR/ControlTabScrollObserver.swift"
grep -q '@ObservationIgnored' "$APP_STATE"

echo "Control-tab horizontal session-scroll invariants: PASS"
