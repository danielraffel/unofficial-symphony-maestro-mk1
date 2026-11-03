#!/usr/bin/env python3
"""Reject private build inputs in Git's candidate index; not a full secret audit."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
paths = subprocess.check_output(['git', 'ls-files', '-z'], cwd=root).decode().split('\0')
blocked = []
for name in filter(None, paths):
    path = Path(name)
    if (name.startswith(('og_source/', 'Docs/', 'Apps/MaestroMobile/',
                         'Drivers/USB/DriverKit/', 'Drivers/USB/Plugin/'))
            or path.suffix.lower() in {'.p12', '.p8', '.pem', '.key',
                                       '.provisionprofile', '.mobileprovision'}
            or (path.name.startswith('.env') and path.name != '.env.example')):
        blocked.append(name)
if blocked:
    raise SystemExit('Private/excluded files in index:\n' + '\n'.join(blocked))
print('Public-source boundary passed (tracked paths only; review contents separately).')
