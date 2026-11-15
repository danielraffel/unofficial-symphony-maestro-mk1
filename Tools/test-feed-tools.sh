#!/bin/bash
# Tests for the feed tools (Tools/feed.py, Tools/check-versions.py --feed,
# Tools/publish-release.sh, Tools/promote-beta.sh, Tools/verify-sparkle-feed.sh)
# with fixtures and a throwaway Ed25519 key made for this run. Nothing here
# reads the real Sparkle key, calls GitHub or touches the tracked appcast.xml.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/maestro-feed-tests.XXXXXX")"
SERVER_PID=""
cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
    /bin/rm -rf "$WORK"
}
trap cleanup EXIT
PASS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); echo "ok - $*"; }

SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-$REPO_ROOT/Apps/Maestro/.build/artifacts/sparkle/Sparkle/bin/sign_update}"
if [ ! -x "$SIGN_UPDATE" ]; then
    echo "Resolving Sparkle for sign_update..."
    swift package --package-path "$REPO_ROOT/Apps/Maestro" resolve >/dev/null
fi
[ -x "$SIGN_UPDATE" ] || fail "sign_update not found at $SIGN_UPDATE"
export SPARKLE_SIGN_UPDATE="$SIGN_UPDATE"
TRACKED_BEFORE="$(shasum -a 256 "$REPO_ROOT/appcast.xml" | cut -d' ' -f1)"

# ── Throwaway key ───────────────────────────────────────────────────────────
mkdir -m 700 "$WORK/key"
cat > "$WORK/key/gen.swift" <<'SWIFT'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
FileHandle.standardError.write(Data((key.publicKey.rawRepresentation.base64EncodedString() + "\n").utf8))
SWIFT
(umask 077; swift "$WORK/key/gen.swift" > "$WORK/key/private" 2> "$WORK/key/public")
chmod 600 "$WORK/key/private"
export SPARKLE_ED_KEY_FILE="$WORK/key/private"
PUBLIC_KEY="$(cat "$WORK/key/public")"
FEED_PY=(python3 "$REPO_ROOT/Tools/feed.py")

# ── Fixtures ────────────────────────────────────────────────────────────────
F="$WORK/feed"
mkdir -p "$F"
cat > "$F/base.xml" <<'XML'
<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0">
  <channel>
    <title>Maestro Updates</title>
    <item>
      <title>Maestro 0.8.39</title>
      <sparkle:version>0.8.39</sparkle:version>
      <sparkle:shortVersionString>0.8.39</sparkle:shortVersionString>
      <description sparkle:format="markdown"><![CDATA[
## What's new

- Old notes & <stuff>.
      ]]></description>
      <enclosure url="https://github.com/danielraffel/unofficial-symphony-maestro-mk1/releases/download/v0.8.39/UnofficialSymphonyMaestro.pkg" sparkle:edSignature="i8KEMhoQ0PceRhpT7VdA729p6k1fblWliPJBGisoVlr/CW/kHyjt+Vsm8ei7ypS4jvgUnDZdfP/yypDkCPzvCQ==" length="3944439" type="application/octet-stream" sparkle:installationType="package"></enclosure>
    </item>
  </channel>
</rss>
XML
"$SIGN_UPDATE" --ed-key-file "$SPARKLE_ED_KEY_FILE" "$F/base.xml" >/dev/null
for v in 0.8.40 0.9.0 0.9.1 0.8.41; do
    head -c $((40000 + ${#v} * 1000)) /dev/urandom > "$F/$v.pkg"
done
printf '## 0.8.40\n\n- Stable notes.\n' > "$F/n-0.8.40.md"
printf '## 0.9.0 beta\n\n- Beta notes for testers.\n' > "$F/n-0.9.0.md"
printf '## 0.9.1 beta\n\n- More beta notes.\n' > "$F/n-0.9.1.md"
printf '## What is new since 0.8.40\n\n- Everything, for stable readers.\n' > "$F/stable-notes.md"
content_of() { python3 -c 'import sys; t=open(sys.argv[1]).read(); i=t.rfind("<!-- sparkle-signatures:\n"); print(t[:i] if i>=0 else t, end="")' "$1"; }
field() { "${FEED_PY[@]}" item "$2" --feed "$1" | sed -n "s/^$3=//p"; }

# ── feed.py: guard rails ────────────────────────────────────────────────────
cp "$F/base.xml" "$F/t.xml"
if "${FEED_PY[@]}" newest --channel stable >/dev/null 2>&1; then fail "ran without --feed"; fi
if SPARKLE_ED_KEY_FILE= "${FEED_PY[@]}" newest --feed "$F/t.xml" --channel stable >/dev/null 2>&1; then fail "ran without a key"; fi
cp "$SPARKLE_ED_KEY_FILE" "$WORK/key/open"; chmod 644 "$WORK/key/open"
if SPARKLE_ED_KEY_FILE="$WORK/key/open" "${FEED_PY[@]}" newest --feed "$F/t.xml" --channel stable >/dev/null 2>&1; then fail "accepted a mode-644 key"; fi
if "${FEED_PY[@]}" promote 0.8.39 --feed "$F/t.xml" >/dev/null 2>&1; then fail "promote without --notes"; fi
ok "feed.py needs --feed, a mode-600 key, and promote needs notes"

# ── feed.py add ─────────────────────────────────────────────────────────────
BEFORE="$(content_of "$F/t.xml")"
"${FEED_PY[@]}" add --feed "$F/t.xml" --channel stable --version 0.8.40 --pkg "$F/0.8.40.pkg" \
    --notes "$F/n-0.8.40.md" --base-url https://github.com/danielraffel/unofficial-symphony-maestro-mk1/releases/download >/dev/null
"$SIGN_UPDATE" --ed-key-file "$SPARKLE_ED_KEY_FILE" --verify "$F/t.xml" >/dev/null || fail "feed not signed after add"
[ "$("${FEED_PY[@]}" newest --feed "$F/t.xml" --channel stable)" = 0.8.40 ] || fail "newest stable after add"
[ "$(field "$F/t.xml" 0.8.40 url)" = "https://github.com/danielraffel/unofficial-symphony-maestro-mk1/releases/download/v0.8.40/UnofficialSymphonyMaestro.pkg" ] || fail "enclosure URL"
[ "$(field "$F/t.xml" 0.8.40 length)" = "$(stat -f %z "$F/0.8.40.pkg")" ] || fail "enclosure length"
"$SIGN_UPDATE" --ed-key-file "$SPARKLE_ED_KEY_FILE" --verify "$F/0.8.40.pkg" "$(field "$F/t.xml" 0.8.40 edSignature)" >/dev/null || fail "enclosure signature"
[ -z "$(field "$F/t.xml" 0.8.40 channel)" ] || fail "stable item has a channel"
AFTER="$(content_of "$F/t.xml")"
python3 - "$BEFORE" "$AFTER" <<'PY' || fail "add changed existing bytes"
import sys
before, after = sys.argv[1], sys.argv[2]
start = before.index('    <item>')
assert after.startswith(before[:start]) and after.endswith(before[start:]), 'existing text changed'
PY
ok "add stable: signed item first, other bytes unchanged, feed re-signed"

"${FEED_PY[@]}" add --feed "$F/t.xml" --channel beta --version 0.9.0 --pkg "$F/0.9.0.pkg" \
    --notes "$F/n-0.9.0.md" --enclosure-url http://127.0.0.1:8765/0.9.0.pkg >/dev/null
[ "$(field "$F/t.xml" 0.9.0 channel)" = beta ] || fail "beta item has no channel"
[ "$("${FEED_PY[@]}" newest --feed "$F/t.xml" --channel beta)" = 0.9.0 ] || fail "newest beta"
[ "$("${FEED_PY[@]}" newest --feed "$F/t.xml" --channel stable)" = 0.8.40 ] || fail "newest stable after beta"
if "${FEED_PY[@]}" add --feed "$F/t.xml" --channel beta --version 0.9.0 --pkg "$F/0.9.0.pkg" \
    --notes "$F/n-0.9.0.md" --enclosure-url http://127.0.0.1:8765/x.pkg >/dev/null 2>&1; then fail "duplicate version added"; fi
"${FEED_PY[@]}" lint --feed "$F/t.xml" >/dev/null || fail "lint of a good feed"
ok "add beta: tagged, newest stable unchanged, duplicates refused, lint passes"

# ── feed.py promote ─────────────────────────────────────────────────────────
cp "$F/t.xml" "$F/p.xml"
ENCLOSURE_BEFORE="$(grep -F 'url="http://127.0.0.1:8765/0.9.0.pkg"' "$F/p.xml")"
"${FEED_PY[@]}" promote 0.9.0 --feed "$F/p.xml" --notes "$F/stable-notes.md" >/dev/null
[ -z "$(field "$F/p.xml" 0.9.0 channel)" ] || fail "promoted item still tagged"
[ "$("${FEED_PY[@]}" newest --feed "$F/p.xml" --channel stable)" = 0.9.0 ] || fail "promoted item is not the newest stable"
[ "$(grep -F 'url="http://127.0.0.1:8765/0.9.0.pkg"' "$F/p.xml")" = "$ENCLOSURE_BEFORE" ] || fail "enclosure changed"
grep -q "Everything, for stable readers." "$F/p.xml" || fail "stable notes not written"
grep -q "Beta notes for testers." "$F/p.xml" && fail "beta notes left in place"
DIFF="$(diff <(content_of "$F/t.xml") <(content_of "$F/p.xml") | grep '^[<>]' || true)"
echo "$DIFF" | grep -v -e 'sparkle:channel' -e 'Beta notes' -e '0.9.0 beta' -e 'stable readers' -e 'What is new since' -e '^[<>] *$' && fail "promote changed more than the channel and notes"
if "${FEED_PY[@]}" promote 0.8.40 --feed "$F/p.xml" --notes "$F/stable-notes.md" >/dev/null 2>&1; then fail "promoted a stable item"; fi
"${FEED_PY[@]}" lint --feed "$F/p.xml" >/dev/null || fail "lint after promote"
ok "promote: channel removed, notes replaced, enclosure byte-identical, nothing else changed"

# ── feed.py lint ────────────────────────────────────────────────────────────
sed 's/Stable notes\./Stable notez./' "$F/t.xml" > "$F/tampered.xml"
if "${FEED_PY[@]}" lint --feed "$F/tampered.xml" >/dev/null 2>&1; then fail "lint passed an edited feed"; fi
sed 's#<sparkle:channel>beta</sparkle:channel>#<sparkle:channel>alpha</sparkle:channel>#' "$F/t.xml" > "$F/alpha.xml"
"$SIGN_UPDATE" --ed-key-file "$SPARKLE_ED_KEY_FILE" "$F/alpha.xml" >/dev/null
if "${FEED_PY[@]}" lint --feed "$F/alpha.xml" >/dev/null 2>&1; then fail "lint passed a channel other than beta"; fi
cp "$F/base.xml" "$F/nobeta.xml"
"${FEED_PY[@]}" add --feed "$F/nobeta.xml" --channel stable --version 0.8.40 --pkg "$F/0.8.40.pkg" \
    --notes "$F/n-0.8.40.md" --enclosure-url http://127.0.0.1:8765/0.8.40.pkg >/dev/null
if "${FEED_PY[@]}" lint --feed "$F/nobeta.xml" --previous "$F/t.xml" >/dev/null 2>&1; then fail "lint passed a removed beta above stable"; fi
"${FEED_PY[@]}" lint --feed "$F/p.xml" --previous "$F/t.xml" >/dev/null || fail "lint refused a promotion (beta no longer above stable)"
ok "lint: signature, channel names, a beta above stable must not disappear"

[ "$(shasum -a 256 "$REPO_ROOT/appcast.xml" | cut -d' ' -f1)" = "$TRACKED_BEFORE" ] || fail "the tracked appcast.xml changed"
ok "tracked appcast.xml untouched"

echo "Feed tool tests passed ($PASS)"
