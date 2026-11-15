#!/bin/bash
# kSelectorRetireForUpgrade: the serving dext steps aside (Terminate(0) on
# itself) so the copy macOS registered can take the ThunderBridge after an
# update that kernelmanagerd would otherwise leave until the next restart.
# Host checks only; the real behaviour needs the hardware test (9005 → 9006).
#
#   1. The selector number, sizes and magic, and that the app sends the same.
#   2. The refusal rules (SymphonyRetire.h), compiled and run on the host.
#   3. The input is non-empty, so a no-input call on 7 (an experimental app
#      polling its port-2 read there) never reaches the handler.
#   4. Terminate is called only from RetireForUpgrade, never on xlinkQueue, and
#      Stop() drains xlinkQueue before it releases the audio objects.
#   5. The app asks only right after its own completed activation, once per
#      serving/bundled pair, quiesces first, and waits about 10 s.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
SRC="$DIR/Source"
APP="$ROOT/Apps/Maestro"
TMP="$(mktemp -d)"
trap 'rm -f "$TMP/t" "$TMP/t.cpp"; rmdir "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

cat > "$TMP/t.cpp" <<'CPP'
#include "SymphonyThunderbridgeShared.h"
#include "SymphonyRetire.h"
#include <cassert>
#include <cstdio>
static_assert(kSelectorRetireForUpgrade == 7, "app asks selector 7");
static_assert(kSelectorCount > kSelectorRetireForUpgrade, "dispatch table covers it");
static_assert(sizeof(SymphonyRetireInput) == 8, "app sends two words");
static_assert(sizeof(SymphonyRetireOutput) == 8, "app reads two words");
static_assert(kSymphonyRetireMagic == 0x52455449u, "'RETI'");
int main() {
    // The decision the driver acts on.
    assert(SymphonyDecideRetire(123, 124, false, false) == kSymphonyRetireTerminate);
    assert(SymphonyDecideRetire(9005, 9006, false, false) == kSymphonyRetireTerminate);
    assert(SymphonyDecideRetire(9004, 123, false, false) == kSymphonyRetireTerminate);  // going back
    assert(SymphonyDecideRetire(0, 124, false, false) == kSymphonyRetireUnstamped);
    assert(SymphonyDecideRetire(123, 0, false, false) == kSymphonyRetireBadReplacement);
    assert(SymphonyDecideRetire(123, 123, false, false) == kSymphonyRetireBadReplacement);
    // Idempotent: a second request, or one after Stop() has begun, does nothing.
    assert(SymphonyDecideRetire(123, 124, false, true) == kSymphonyRetireAlreadyGoing);
    assert(SymphonyDecideRetire(123, 124, true, false) == kSymphonyRetireAlreadyGoing);
    // Refusals win over "already going": a bad request is never reported as accepted.
    assert(SymphonyDecideRetire(123, 123, true, true) == kSymphonyRetireBadReplacement);
    puts("ok");
    return 0;
}
CPP
clang++ -std=c++17 -I "$SRC" -o "$TMP/t" "$TMP/t.cpp"
test "$("$TMP/t")" = ok || fail "retire decision"

# 3. Dispatch entry: exact non-empty input, so the size check rejects other shapes.
python3 - "$SRC/SymphonyUserClient.cpp" <<'PY' || exit 1
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r'\[kSelectorRetireForUpgrade\]\s*=\s*\{(.*?)\}', text, re.S)
if not m: raise SystemExit('FAIL: no dispatch entry for kSelectorRetireForUpgrade')
entry = m.group(1)
for want in ('.checkStructureInputSize  = sizeof(SymphonyRetireInput)',
             '.checkStructureOutputSize = sizeof(SymphonyRetireOutput)'):
    if want not in entry: raise SystemExit('FAIL: retire dispatch entry lacks ' + want)
handler = text[text.index('if (selector == kSelectorRetireForUpgrade)'):]
handler = handler[:handler.index('\n    }\n')]
for want in ('kSymphonyRetireMagic', 'RetireForUpgrade(input->replacementBuild)',
             'getLength() != sizeof(SymphonyRetireInput)'):
    if want not in handler: raise SystemExit('FAIL: retire handler lacks ' + want)
if 'Terminate(' in handler: raise SystemExit('FAIL: the user client must not terminate the driver itself')
PY

# 4. Terminate only in RetireForUpgrade; never inside an xlinkQueue block.
CPPSRC="$SRC/SymphonyThunderbridge.cpp"
python3 - "$CPPSRC" <<'PY' || exit 1
import sys
text = open(sys.argv[1]).read()
import re
# Calls in code, not in comments or log strings.
calls = [m.start() for m in re.finditer(r'(?m)^[^/\n"]*\bTerminate\(', text)]
fn = text.index('kern_return_t SymphonyThunderbridge::RetireForUpgrade(')
end = text.index('\n}\n', fn)
body = text[fn:end]
if not calls or any(not (fn < c < end) for c in calls):
    raise SystemExit('FAIL: Terminate(0) must be called only from RetireForUpgrade')
if 'DispatchSync' in body or 'DispatchAsync' in body:
    raise SystemExit('FAIL: RetireForUpgrade must not hop onto a queue (Stop drains xlinkQueue)')
if 'SymphonyDecideRetire(' not in body or '__atomic_compare_exchange_n(&ivars->retireRequested' not in body:
    raise SystemExit('FAIL: RetireForUpgrade must use the tested decision and a single Terminate')
if 'UNDOCUMENTED' not in text[text.rindex('//', 0, fn) - 3000:fn]:
    raise SystemExit('FAIL: the undocumented Terminate semantics must be noted at RetireForUpgrade')
stop = text[text.index('kern_return_t IMPL(SymphonyThunderbridge, Stop)'):]
stop = stop[:stop.index('\n}\n')]
cancel = stop[stop.index('interruptSource->Cancel(^{'):]
early = cancel.index('iv->xlinkQueue->DispatchSync(^{});')
if early > cancel.index('self->RemoveObject(iv->audioDevice)'):
    raise SystemExit('FAIL: Stop must drain xlinkQueue before releasing the audio objects')
fallback = stop[stop.index('// Fallback: no interrupt source'):]
if fallback.index('ivars->xlinkQueue->DispatchSync(^{});') > fallback.index('RemoveObject(ivars->audioDevice)'):
    raise SystemExit('FAIL: Stop fallback must drain xlinkQueue before releasing the audio objects')
th = text[text.index('kern_return_t SymphonyThunderbridge::ReadTimingHealth('):]
th = th[:th.index('\n}\n')]
after = th[th.index('    });'):]
if 'ivars->audioDevice->Get' in after:
    raise SystemExit('FAIL: ReadTimingHealth must read the audio device inside the queue block')
PY

# 5. App side.
grep -q 'static let selectorRetireForUpgrade: UInt32 = 7' "$APP/MaestroDevice/DextUserClient.swift" || fail "app selector"
grep -q 'static let retireMagic: UInt32 = 0x52455449' "$APP/MaestroDevice/DextUserClient.swift" || fail "app magic"
grep -q 'var input: \[UInt32\] = \[Self.retireMagic, replacementBuild\]' "$APP/MaestroDevice/DextUserClient.swift" || fail "app input"
H="$APP/MaestroApp/DriverHandover.swift"
grep -q 'shouldAskServingDriverToRetire(activationCompleted: true)' "$H" || fail "app gate"
grep -q 'driverHandoverAttempts.contains(key)' "$H" || fail "one attempt per pair"
grep -q 'static let driverHandoverTimeout: Duration = .seconds(10)' "$H" || fail "10 s"
python3 - "$H" <<'PY' || exit 1
import sys
t = open(sys.argv[1]).read()
f = t[t.index('private func retireServingDriverIfNeeded'):]
order = [f.index(s) for s in ('stopMeterPolling()', 'stopThunderboltHealthCheck()',
                              'tb.retireServingDriver(', 'driverHandover = .finishing')]
if order != sorted(order): raise SystemExit('FAIL: quiesce, then retire, then show finishing')
PY
grep -q 'activationCompletedNotification' "$APP/MaestroApp/SystemExtensionInstaller.swift" || fail "completion notice"

echo "Retire for upgrade (selector 7): PASS"
