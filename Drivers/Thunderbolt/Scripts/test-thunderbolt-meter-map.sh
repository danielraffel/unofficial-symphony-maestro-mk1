#!/bin/bash
set -euo pipefail

APP_STATE="$(cd "$(dirname "$0")/../../../Apps/Maestro/MaestroApp" && pwd)/AppState.swift"
test -f "$APP_STATE"

# The dext meter snapshot reserves two stereo master pairs: 128/129 for
# Mixer 1 and 130/131 for Mixer 2. Keep both logical UI meter pairs fed.
grep -q 'rawMixer\[4\] = dbW(128); rawMixer\[5\] = dbW(129)' "$APP_STATE"
grep -q 'rawMixer\[6\] = dbW(130); rawMixer\[7\] = dbW(131)' "$APP_STATE"
grep -q 'mixerMeterLevels.count >= 8' "$APP_STATE"

# A powered-down Symphony can remain enumerated on PCIe while Core Audio has
# stopped its I/O cycle. In that state the FPGA DMA snapshot is stale and must
# not be decoded as live input or mixer activity.
grep -q 'let tbAudioRunning = tbDev.isAudioRunning == true' "$APP_STATE"
grep -q 'let allowMeterRead = tbAudioRunning &&' "$APP_STATE"
grep -q 'self.thunderboltHardwareResponsive || extensionSwapPending' "$APP_STATE"
grep -q 'thunderboltHardwareResponsive = false' "$APP_STATE"
grep -q 'self.mixerMeterLevels = \[Double\](repeating: -60.0' "$APP_STATE"
grep -q 'self.digitalInputPeakHold = \[Double\](repeating: -60.0' "$APP_STATE"

# A newly published ThunderBridge can need a few seconds before its FPGA/XLink
# probe is usable. Preserve the startup grace while retaining the shorter loss
# threshold after the first successful live probe.
grep -q 'thunderboltHealthFailureThreshold = 4' "$APP_STATE"
grep -q 'thunderboltHasHealthyProbe' "$APP_STATE"
grep -q '? 2' "$APP_STATE"

echo "ThunderBridge meter mapping and stopped-I/O gate: PASS"
