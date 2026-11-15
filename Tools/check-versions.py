#!/usr/bin/env python3
"""Validate the explicit public app/package/driver version tuple before building.

    python3 Tools/check-versions.py
    python3 Tools/check-versions.py --feed <appcast.xml> --channel stable|beta

With --feed, also check that the app version can be published on that channel:
it must not be in the feed yet; a stable version must be above the newest
untagged (stable) item, so a hotfix may sit below an outstanding beta; a beta
must be above every item.
"""
from pathlib import Path
import argparse, json, plistlib, re, sys

VERSION_RE = r'\d+\.\d+\.\d+'


def version_key(text):
    return tuple(int(p) for p in text.split('.'))


def feed_items(path):
    """(version, channel) for each <item>; channel is None for stable."""
    text = Path(path).read_text(encoding='utf-8')
    items = []
    for block in re.findall(r'<item>(.*?)</item>', text, re.S):
        version = re.search(r'<sparkle:version>\s*([^<]*?)\s*</sparkle:version>', block)
        if not version:
            raise SystemExit(f'{path}: an item has no sparkle:version')
        channel = re.search(r'<sparkle:channel>\s*([^<]*?)\s*</sparkle:channel>', block)
        items.append((version.group(1), channel.group(1) if channel else None))
    return items


def check_feed(app_version, feed, channel):
    items = feed_items(feed)
    numeric = [(v, c) for v, c in items if re.fullmatch(VERSION_RE, v)]
    mine = version_key(app_version)
    if any(version_key(v) == mine for v, _ in numeric):
        raise SystemExit(f'{app_version} is already in {feed}')
    stable = [v for v, c in numeric if c is None]
    if channel == 'stable':
        newest = max(stable, key=version_key, default=None)
        if newest and not version_key(newest) < mine:
            raise SystemExit(f'Stable {app_version} must be above the newest stable item ({newest})')
        above = sorted((v for v, c in numeric if c is not None and version_key(v) > mine), key=version_key)
        if above:
            print(f'Note: beta {above[-1]} is above {app_version}; beta users will not be offered this hotfix.')
    else:
        newest = max((v for v, _ in numeric), key=version_key, default=None)
        if newest and not version_key(newest) < mine:
            raise SystemExit(f'Beta {app_version} must be above every item in the feed (newest is {newest})')
    print(f'{app_version} can be published as {channel} in {feed}')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--feed')
    parser.add_argument('--channel', choices=('stable', 'beta'))
    args = parser.parse_args()
    if bool(args.feed) != bool(args.channel):
        parser.error('--feed and --channel go together')

    root = Path(__file__).resolve().parents[1]
    versions = json.loads((root / 'Tools/versions.json').read_text())
    for key in ('appVersion', 'dextVersion'):
        if not isinstance(versions.get(key), str) or not re.fullmatch(VERSION_RE, versions[key]):
            raise SystemExit(f'Invalid {key} in Tools/versions.json')
    for key in ('buildNumber', 'dextBuild'):
        if type(versions.get(key)) is not int or versions[key] <= 0:
            raise SystemExit(f'{key} must be a positive integer')
    # The recorded code identity of driver build dextBuild. Absent only before
    # the first build of a new driver number, which prints the hash to record.
    if 'dextCDHash' in versions and (not isinstance(versions['dextCDHash'], str)
                                      or not re.fullmatch(r'[0-9a-f]{40}', versions['dextCDHash'])):
        raise SystemExit('dextCDHash must be 40 lowercase hex characters')
    source = (root / 'Apps/Maestro/MaestroCore/MaestroCore.swift').read_text()
    match = re.search(r'public static let version\s*=\s*"([^"]+)"', source)
    if not match or match.group(1) != versions['appVersion']:
        raise SystemExit('App source version disagrees with Tools/versions.json')
    dext = plistlib.loads((root / 'Drivers/Thunderbolt/Info.plist').read_bytes())
    if dext['CFBundleShortVersionString'] != versions['dextVersion']:
        raise SystemExit('Driver source version disagrees with Tools/versions.json')
    if str(dext.get('CFBundleVersion')) != str(versions['dextBuild']):
        raise SystemExit(f"Driver source build {dext.get('CFBundleVersion')} disagrees with dextBuild {versions['dextBuild']} in Tools/versions.json")
    cdhash = versions.get('dextCDHash', 'not recorded')
    print(f"Version tuple valid: app {versions['appVersion']}, package {versions['buildNumber']}, "
          f"driver {versions['dextVersion']}/{versions['dextBuild']} (CDHash {cdhash})")
    if args.feed:
        check_feed(versions['appVersion'], args.feed, args.channel)


if __name__ == '__main__':
    main()
