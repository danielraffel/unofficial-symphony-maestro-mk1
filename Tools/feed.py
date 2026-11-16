#!/usr/bin/env python3
"""Edit and inspect a Maestro Sparkle feed (appcast) for the Stable and Beta channels.

Every command needs --feed <path>. There is no default, so no command can
touch the tracked appcast.xml unless it is named. Every command needs
SPARKLE_ED_KEY_FILE (the file-backed Sparkle key, mode 600); edits re-sign
the feed with it and every read checks the feed's signature with it.

  feed.py add --feed F --channel stable|beta --version V --pkg P --notes N.md
              (--base-url U | --enclosure-url URL) [--notes-url URL]
      Insert a new first item (with <sparkle:channel>beta</sparkle:channel>
      for beta), sign the package and re-sign the feed. --base-url U gives
      the GitHub layout U/vV/UnofficialSymphonyMaestro.pkg.
  feed.py promote V --feed F --notes N.md
      Remove the channel element from item V and replace its notes with the
      stable notes. The enclosure element must be byte-identical afterwards.
  feed.py newest --feed F --channel stable|beta
  feed.py item V --feed F
      Print edSignature=, length=, url=, channel= for item V.
  feed.py lint --feed F [--previous OLD]
      Unique versions, no channel other than beta, every item complete,
      valid feed signature; with --previous, no beta item that is above the
      newest stable was removed.

Edits work on the text, never by re-serialising XML, so the CDATA notes, the
signing warning and every other item stay byte for byte as they were.
"""
from __future__ import annotations

import argparse
import email.utils
import os
import re
import stat
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SIGN_UPDATE = REPO_ROOT / 'Apps/Maestro/.build/artifacts/sparkle/Sparkle/bin/sign_update'
GITHUB_RELEASES = 'https://github.com/danielraffel/unofficial-symphony-maestro-mk1/releases'
ASSET = 'UnofficialSymphonyMaestro.pkg'
SIGNATURE_PREFIX = '<!-- sparkle-signatures:\n'
VERSION_RE = re.compile(r'\d+(\.\d+)*')


class FeedError(SystemExit):
    def __init__(self, message: str):
        super().__init__(f'feed.py: {message}')


def version_key(text: str) -> tuple[int, ...]:
    parts = [int(p) for p in text.split('.')]
    while parts and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


# ── Key and signing ──────────────────────────────────────────────────────────

def key_file() -> str:
    path = os.environ.get('SPARKLE_ED_KEY_FILE')
    if not path:
        raise FeedError('set SPARKLE_ED_KEY_FILE to the file-backed Sparkle key (mode 600)')
    try:
        info = os.stat(path)
    except OSError as error:
        raise FeedError(f'SPARKLE_ED_KEY_FILE is not readable: {error}')
    if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600:
        raise FeedError(f'SPARKLE_ED_KEY_FILE must be a file with mode 600: {path}')
    return path


def sign_update() -> str:
    path = os.environ.get('SPARKLE_SIGN_UPDATE', str(DEFAULT_SIGN_UPDATE))
    if not os.access(path, os.X_OK):
        raise FeedError(f'sign_update not found at {path} (build Apps/Maestro once, or set SPARKLE_SIGN_UPDATE)')
    return path


def run_sign_update(*args: str) -> str:
    result = subprocess.run([sign_update(), '--ed-key-file', key_file(), *args],
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise FeedError(f'sign_update {" ".join(args[:1])} failed: {result.stderr.strip() or result.stdout.strip()}')
    return result.stdout


def package_signature(pkg: Path) -> str:
    signature = run_sign_update('-p', str(pkg)).strip()
    if not re.fullmatch(r'[A-Za-z0-9+/=]{80,100}', signature):
        raise FeedError(f'unexpected signature from sign_update: {signature!r}')
    return signature


def verify_feed_signature(path: Path) -> None:
    run_sign_update('--verify', str(path))


# ── Text model ───────────────────────────────────────────────────────────────

def mask_cdata(text: str) -> str:
    """The text with the body of every CDATA section blanked, same length.

    Release notes are free text inside CDATA and may quote feed markup (notes
    about channels can say "<sparkle:channel>beta</sparkle:channel>"). Sparkle
    and Maestro read them as text; so must every search for an element here.
    Positions are unchanged, so matches index the original text.
    """
    return re.sub(r'(<!\[CDATA\[)(.*?)(\]\]>)',
                  lambda m: m.group(1) + ' ' * len(m.group(2)) + m.group(3), text, flags=re.S)


@dataclass
class Item:
    start: int
    end: int
    text: str

    @property
    def markup(self) -> str:
        return mask_cdata(self.text)

    def field(self, name: str) -> str | None:
        match = re.search(rf'<sparkle:{name}>\s*([^<]*?)\s*</sparkle:{name}>', self.markup)
        return match.group(1) if match else None

    @property
    def version(self) -> str | None:
        return self.field('version')

    @property
    def channel(self) -> str | None:
        return self.field('channel')

    @property
    def enclosure(self) -> str | None:
        match = re.search(r'<enclosure\b[^>]*?(?:/>|>\s*</enclosure>)', self.markup, re.S)
        return match.group(0) if match else None

    def enclosure_attribute(self, name: str) -> str | None:
        enclosure = self.enclosure
        if enclosure is None:
            return None
        match = re.search(rf'\s{re.escape(name)}="([^"]*)"', enclosure)
        return match.group(1) if match else None


def split_signature(text: str) -> str:
    """The feed content without its trailing signature block."""
    index = text.rfind(SIGNATURE_PREFIX)
    return text if index < 0 else text[:index]


def read_feed(path: Path) -> str:
    try:
        return path.read_text(encoding='utf-8')
    except OSError as error:
        raise FeedError(f'cannot read {path}: {error}')


def items_of(content: str) -> list[Item]:
    return [Item(m.start(), m.end(), content[m.start():m.end()])
            for m in re.finditer(r'<item>.*?</item>', mask_cdata(content), re.S)]


def find_item(content: str, version: str) -> Item:
    if not VERSION_RE.fullmatch(version):
        raise FeedError(f'not a version: {version}')
    matches = [i for i in items_of(content) if i.version and VERSION_RE.fullmatch(i.version)
               and version_key(i.version) == version_key(version)]
    if not matches:
        raise FeedError(f'no item {version} in the feed')
    if len(matches) > 1:
        raise FeedError(f'more than one item {version} in the feed')
    return matches[0]


def newest(content: str, channel: str) -> str | None:
    wanted = None if channel == 'stable' else channel
    versions = [i.version for i in items_of(content)
                if i.version and VERSION_RE.fullmatch(i.version) and i.channel == wanted]
    return max(versions, key=version_key, default=None)


def write_signed(path: Path, content: str) -> None:
    """Writes content to a temporary file next to path, signs and verifies it
    with sign_update, then replaces path."""
    directory = path.resolve().parent
    handle, temp = tempfile.mkstemp(prefix='.feed-', suffix='.xml', dir=directory)
    try:
        with os.fdopen(handle, 'w', encoding='utf-8') as file:
            file.write(content)
        run_sign_update(temp)
        verify_feed_signature(Path(temp))
        os.chmod(temp, 0o644)
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


def read_notes(path: str) -> str:
    try:
        notes = Path(path).read_text(encoding='utf-8').strip('\n')
    except OSError as error:
        raise FeedError(f'cannot read notes {path}: {error}')
    if not notes.strip():
        raise FeedError(f'notes file {path} is empty')
    if ']]>' in notes:
        raise FeedError('notes must not contain "]]>"')
    return notes


# ── Commands ─────────────────────────────────────────────────────────────────

def command_add(args) -> None:
    path = Path(args.feed)
    original = read_feed(path)
    verify_feed_signature(path)
    content = split_signature(original)
    version = args.version
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise FeedError(f'version must be x.y.z: {version}')
    for item in items_of(content):
        if item.version and VERSION_RE.fullmatch(item.version) and version_key(item.version) == version_key(version):
            raise FeedError(f'{version} is already in the feed')
    pkg = Path(args.pkg)
    if not pkg.is_file():
        raise FeedError(f'no package at {pkg}')
    notes = read_notes(args.notes)
    if args.enclosure_url:
        url = args.enclosure_url
    else:
        url = f'{args.base_url.rstrip("/")}/v{version}/{ASSET}'
    notes_url = args.notes_url or f'{GITHUB_RELEASES}/tag/v{version}'
    for value in (url, notes_url):
        if '"' in value or '<' in value or '&' in value:
            raise FeedError(f'unsupported character in URL: {value}')
    signature = package_signature(pkg)
    length = pkg.stat().st_size
    channel = '      <sparkle:channel>beta</sparkle:channel>\n' if args.channel == 'beta' else ''
    item = (
        '    <item>\n'
        f'      <title>Maestro {version}</title>\n'
        f'      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>\n'
        f'      <sparkle:version>{version}</sparkle:version>\n'
        f'      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>\n'
        f'{channel}'
        f'      <sparkle:minimumSystemVersion>{args.minimum_system}</sparkle:minimumSystemVersion>\n'
        '      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>\n'
        f'      <sparkle:fullReleaseNotesLink>{notes_url}</sparkle:fullReleaseNotesLink>\n'
        '      <description sparkle:format="markdown"><![CDATA[\n'
        f'{notes}\n'
        '      ]]></description>\n'
        f'      <enclosure url="{url}" sparkle:edSignature="{signature}" length="{length}" '
        'type="application/octet-stream" sparkle:installationType="package"></enclosure>\n'
        '    </item>\n'
    )
    markup = mask_cdata(content)
    first = re.search(r'^[ \t]*<item>', markup, re.M)
    if first:
        position = first.start()
    else:
        closing = re.search(r'^[ \t]*</channel>', markup, re.M)
        if not closing:
            raise FeedError('the feed has no <channel>')
        position = closing.start()
    write_signed(path, content[:position] + item + content[position:])
    print(f'Added {args.channel} {version} ({length} bytes) to {path}')


def command_promote(args) -> None:
    path = Path(args.feed)
    verify_feed_signature(path)
    content = split_signature(read_feed(path))
    item = find_item(content, args.version)
    if item.channel != 'beta':
        raise FeedError(f'{args.version} is not a beta item')
    stable = newest(content, 'stable')
    if stable and not version_key(stable) < version_key(item.version):
        raise FeedError(f'{args.version} is not above the newest stable ({stable})')
    notes = read_notes(args.notes)
    before = item.enclosure
    if before is None:
        raise FeedError(f'{args.version} has no enclosure')
    # Found in the markup only: notes may quote the element.
    tags = list(re.finditer(r'^[ \t]*<sparkle:channel>\s*beta\s*</sparkle:channel>[ \t]*\n', item.markup, flags=re.M))
    if len(tags) != 1:
        raise FeedError(f'could not remove the channel element of {args.version}')
    text = item.text[:tags[0].start()] + item.text[tags[0].end():]
    text, replaced = re.subn(r'(<!\[CDATA\[\n).*?(\n[ \t]*\]\]>)', lambda m: m.group(1) + notes + m.group(2),
                             text, count=1, flags=re.S)
    if replaced != 1:
        raise FeedError(f'{args.version} has no notes to replace')
    after = Item(0, 0, text).enclosure
    if after != before:
        raise FeedError('the enclosure element changed; refusing to promote')
    write_signed(path, content[:item.start] + text + content[item.end:])
    print(f'Promoted {args.version} to stable in {path}')


def command_newest(args) -> None:
    path = Path(args.feed)
    verify_feed_signature(path)
    version = newest(split_signature(read_feed(path)), args.channel)
    if version is None:
        raise FeedError(f'no {args.channel} item in the feed')
    print(version)


def command_item(args) -> None:
    path = Path(args.feed)
    verify_feed_signature(path)
    item = find_item(split_signature(read_feed(path)), args.version)
    print(f'edSignature={item.enclosure_attribute("sparkle:edSignature") or ""}')
    print(f'length={item.enclosure_attribute("length") or ""}')
    print(f'url={item.enclosure_attribute("url") or ""}')
    print(f'channel={item.channel or ""}')


def command_lint(args) -> None:
    path = Path(args.feed)
    content = split_signature(read_feed(path))
    problems = []
    seen: dict[tuple[int, ...], str] = {}
    for item in items_of(content):
        version = item.version
        if not version or not VERSION_RE.fullmatch(version):
            problems.append(f'item with version {version!r}')
            continue
        key = version_key(version)
        if key in seen:
            problems.append(f'{version} appears more than once')
        seen[key] = version
        if item.channel not in (None, 'beta'):
            problems.append(f'{version} has channel {item.channel!r} (only beta is allowed)')
        for name in ('url', 'sparkle:edSignature', 'length'):
            if not item.enclosure_attribute(name):
                problems.append(f'{version} has no enclosure {name}')
    try:
        verify_feed_signature(path)
    except SystemExit as error:
        problems.append(f'feed signature: {error}')
    if args.previous:
        previous = split_signature(read_feed(Path(args.previous)))
        stable = newest(content, 'stable')
        current = {version_key(i.version) for i in items_of(content) if i.version and VERSION_RE.fullmatch(i.version)}
        for item in items_of(previous):
            if item.channel != 'beta' or not item.version or not VERSION_RE.fullmatch(item.version):
                continue
            above = stable is None or version_key(stable) < version_key(item.version)
            if above and version_key(item.version) not in current:
                problems.append(f'beta {item.version} was removed while above the newest stable ({stable}); '
                                'copies of it would fall back to Stable')
    if problems:
        for problem in problems:
            print(f'lint: {problem}', file=sys.stderr)
        raise SystemExit(1)
    print(f'{path}: {len(seen)} items, newest stable {newest(content, "stable")}, '
          f'newest beta {newest(content, "beta") or "none"}')


def main(argv: list[str] | None = None) -> None:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument('--feed', required=True, help='the feed file (required; no default)')
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)

    add = commands.add_parser('add', parents=[common])
    add.add_argument('--channel', choices=('stable', 'beta'), required=True)
    add.add_argument('--version', required=True)
    add.add_argument('--pkg', required=True)
    add.add_argument('--notes', required=True)
    where = add.add_mutually_exclusive_group(required=True)
    where.add_argument('--base-url')
    where.add_argument('--enclosure-url')
    add.add_argument('--notes-url')
    add.add_argument('--minimum-system', default='26.0')
    add.set_defaults(func=command_add)

    promote = commands.add_parser('promote', parents=[common])
    promote.add_argument('version')
    promote.add_argument('--notes', required=True, help='stable notes (required)')
    promote.set_defaults(func=command_promote)

    newest_parser = commands.add_parser('newest', parents=[common])
    newest_parser.add_argument('--channel', choices=('stable', 'beta'), required=True)
    newest_parser.set_defaults(func=command_newest)

    item = commands.add_parser('item', parents=[common])
    item.add_argument('version')
    item.set_defaults(func=command_item)

    lint = commands.add_parser('lint', parents=[common])
    lint.add_argument('--previous')
    lint.set_defaults(func=command_lint)

    args = parser.parse_args(argv)
    key_file()
    args.func(args)


if __name__ == '__main__':
    main()
