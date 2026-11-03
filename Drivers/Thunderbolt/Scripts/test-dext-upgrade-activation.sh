#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
INSTALLER="$ROOT/Apps/Maestro/MaestroApp/SystemExtensionInstaller.swift"
test -f "$INSTALLER"

# A single enabled older registration must be allowed to submit one replacement
# request after a clean reboot or physical reconnect. Disabled, approval-pending,
# reboot-pending, uninstalling, or duplicate registrations must still fail closed
# because another request in those states can produce OSSystemExtensionErrorDomain
# error 4 and wedge the registration.
python3 - "$INSTALLER" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
needle = 'if registered[0].bundleVersion != bundled {'
start = text.index(needle)
end = text.index('\n        }', start)
branch = text[start:end]
if 'return true' not in branch:
    raise SystemExit('single enabled older dext must allow one replacement request')
guard = text[text.index('if registered.contains'):text.index('if registered.count', text.index('if registered.contains'))]
if 'return false' not in guard or '!$0.isEnabled' not in guard:
    raise SystemExit('disabled or pending registrations must fail closed')
if 'registered.count > 1' not in text:
    raise SystemExit('duplicate registrations must fail closed')
if 'error 4' not in text:
    raise SystemExit('guard must document the error-4 failure mode')
PY

echo "Dext upgrade activation guard: PASS"
