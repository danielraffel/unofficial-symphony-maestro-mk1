#!/usr/bin/env python3
"""Validate the explicit public app/package/driver version tuple before building."""
from pathlib import Path
import json, plistlib, re

root = Path(__file__).resolve().parents[1]
versions = json.loads((root / 'Tools/versions.json').read_text())
for key in ('appVersion', 'dextVersion'):
    if not isinstance(versions.get(key), str) or not re.fullmatch(r'\d+\.\d+\.\d+', versions[key]):
        raise SystemExit(f'Invalid {key} in Tools/versions.json')
for key in ('buildNumber', 'dextBuild'):
    if type(versions.get(key)) is not int or versions[key] <= 0:
        raise SystemExit(f'{key} must be a positive integer')
source = (root / 'Apps/Maestro/MaestroCore/MaestroCore.swift').read_text()
match = re.search(r'public static let version\s*=\s*"([^"]+)"', source)
if not match or match.group(1) != versions['appVersion']:
    raise SystemExit('App source version disagrees with Tools/versions.json')
dext = plistlib.loads((root / 'Drivers/Thunderbolt/Info.plist').read_bytes())
if dext['CFBundleShortVersionString'] != versions['dextVersion']:
    raise SystemExit('Driver source version disagrees with Tools/versions.json')
print(f"Version tuple valid: app {versions['appVersion']}, package {versions['buildNumber']}, driver {versions['dextVersion']}/{versions['dextBuild']}")
