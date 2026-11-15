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

# ── publish-release.sh and promote-beta.sh ──────────────────────────────────
# A copy of the tools in a scratch repository with one pushed commit, real
# (unsigned) product packages, and stubs for gh, ghapp and spctl. Downloads
# come from a local web server standing in for GitHub.
R="$WORK/repo"
mkdir -p "$R/Tools/lib" "$R/Apps/Maestro/MaestroCore" "$R/Apps/Maestro/MaestroApp/Resources" "$R/Drivers/Thunderbolt"
cp "$REPO_ROOT/Tools/feed.py" "$REPO_ROOT/Tools/check-versions.py" "$REPO_ROOT/Tools/publish-release.sh" \
   "$REPO_ROOT/Tools/promote-beta.sh" "$REPO_ROOT/Tools/verify-sparkle-feed.sh" "$R/Tools/"
cp "$REPO_ROOT/Tools/lib/release-common.sh" "$R/Tools/lib/"
cat > "$R/Apps/Maestro/MaestroApp/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>SUPublicEDKey</key><string>$PUBLIC_KEY</string></dict></plist>
PLIST
cat > "$R/Drivers/Thunderbolt/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>0.10.17</string><key>CFBundleVersion</key><string>123</string></dict></plist>
PLIST
set_repo_version() {
    printf '{"appVersion": "%s", "buildNumber": 1, "dextVersion": "0.10.17", "dextBuild": 123}\n' "$1" > "$R/Tools/versions.json"
    printf 'public enum MaestroCore {\n    public static let version = "%s"\n}\n' "$1" > "$R/Apps/Maestro/MaestroCore/MaestroCore.swift"
}
set_repo_version 0.8.40
git -C "$R" init -q
git -C "$R" -c user.name=t -c user.email=t@t add -A
git -C "$R" -c user.name=t -c user.email=t@t commit -q -m fixture
COMMIT="$(git -C "$R" rev-parse HEAD)"
git -C "$R" update-ref refs/remotes/origin/main "$COMMIT"

make_pkg() {  # $1 = version, $2 = out, [$3 = commit], [$4 = public key]
    local d="$WORK/build-$1-$RANDOM"
    mkdir -p "$d/root/Applications/Maestro.app/Contents" "$d/c"
    cat > "$d/root/Applications/Maestro.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.danielraffel.maestro</string>
<key>CFBundleShortVersionString</key><string>$1</string>
<key>CFBundleVersion</key><string>$1</string>
<key>MaestroSourceCommit</key><string>${3-$COMMIT}</string>
<key>SUPublicEDKey</key><string>${4:-$PUBLIC_KEY}</string>
</dict></plist>
PLIST
    pkgbuild --root "$d/root" --identifier com.generouscorp.maestro.core --version "$1" "$d/c/SymphonyMaestroCore.pkg" >/dev/null
    productbuild --package "$d/c/SymphonyMaestroCore.pkg" "$2" >/dev/null
}

S="$WORK/stubs"
mkdir -p "$S"
cat > "$S/spctl" <<'SH'
#!/bin/bash
echo "${@: -1}: accepted" >&2
echo "source=Notarized Developer ID" >&2
echo "origin=Developer ID Installer: Daniel Raffel (95CX6P84C4)" >&2
SH
cat > "$S/spctl-reject" <<'SH'
#!/bin/bash
echo "${@: -1}: rejected" >&2
echo "source=no usable signature" >&2
exit 3
SH
# gh: records every call; "release create/edit ... --latest" makes that tag latest
# and stages the asset where the stand-in "GitHub" serves it.
cat > "$S/gh" <<SH
#!/bin/bash
echo "gh \$*" >> "$S/calls"
tag="\$3"
if [ "\$1 \$2" = "release create" ]; then
    mkdir -p "$WORK/www/releases/download/\$tag"
    cp "\$4" "$WORK/www/releases/download/\$tag/UnofficialSymphonyMaestro.pkg"
fi
for a in "\$@"; do
    if [ "\$a" = --latest ]; then
        echo "\$tag" > "$S/latest"
        mkdir -p "$WORK/www/releases/latest/download"
        cp "$WORK/www/releases/download/\$tag/UnofficialSymphonyMaestro.pkg" "$WORK/www/releases/latest/download/"
    fi
done
SH
cat > "$S/ghapp" <<SH
#!/bin/bash
echo "ghapp \$*" >> "$S/calls"
case "\$2" in
    */releases/latest) cat "$S/latest" ;;
    */releases/tags/*) tag="\${2##*/}"; if [ -d "$WORK/www/releases/download/\$tag" ]; then echo '{"tag_name":"'\$tag'"}'; else echo 'gh: Not Found (HTTP 404)' >&2; exit 1; fi ;;
    *) exit 1 ;;
esac
SH
chmod +x "$S"/*
echo v0.8.39 > "$S/latest"
mkdir -p "$WORK/www"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WORK/www" >/dev/null 2>&1 &
SERVER_PID=$!
disown "$SERVER_PID"
for _ in $(seq 50); do curl -s "http://127.0.0.1:$PORT/" >/dev/null && break; sleep 0.1; done
export GH_BIN="$S/gh" GHAPP_BIN="$S/ghapp" SPCTL_BIN="$S/spctl"
export MAESTRO_RELEASES_BASE="http://127.0.0.1:$PORT/releases"
export SPARKLE_PUBLIC_ED_KEY="$PUBLIC_KEY"

FEED="$WORK/www/appcast.xml"
cp "$F/base.xml" "$FEED"
make_pkg 0.8.40 "$WORK/S40.pkg"

# Refusals before anything is created.
make_pkg 0.8.40 "$WORK/dirty.pkg" "$COMMIT-dirty"
if "$R/Tools/publish-release.sh" --channel stable --pkg "$WORK/dirty.pkg" --notes "$F/n-0.8.40.md" --feed "$FEED" >/dev/null 2>&1; then fail "published a dirty build"; fi
make_pkg 0.8.40 "$WORK/otherkey.pkg" "$COMMIT" "AAAA"
if "$R/Tools/publish-release.sh" --channel stable --pkg "$WORK/otherkey.pkg" --notes "$F/n-0.8.40.md" --feed "$FEED" >/dev/null 2>&1; then fail "published a package with another Sparkle key"; fi
if SPCTL_BIN="$S/spctl-reject" "$R/Tools/publish-release.sh" --channel stable --pkg "$WORK/S40.pkg" --notes "$F/n-0.8.40.md" --feed "$FEED" >/dev/null 2>&1; then fail "published a package spctl rejects"; fi
if "$R/Tools/publish-release.sh" --channel stable --pkg "$WORK/S40.pkg" --notes "$F/n-0.8.40.md" >/dev/null 2>&1; then fail "ran without --feed"; fi
[ ! -e "$S/calls" ] || ! grep -q '^gh ' "$S/calls" || fail "gh called during a refused publish"
cmp -s "$FEED" "$F/base.xml" || fail "feed changed by a refused publish"
ok "publish-release refuses dirty builds, another key, unnotarized packages, and a missing --feed"

# Dry run: no release, no feed change.
"$R/Tools/publish-release.sh" --channel stable --pkg "$WORK/S40.pkg" --notes "$F/n-0.8.40.md" --feed "$FEED" --dry-run > "$WORK/dry.out"
grep -q 'would run:.*release create v0.8.40' "$WORK/dry.out" || fail "dry run did not show the release"
grep -q '^+.*<sparkle:version>0.8.40</sparkle:version>' "$WORK/dry.out" || fail "dry run did not show the feed diff"
cmp -s "$FEED" "$F/base.xml" || fail "dry run changed the feed"
! grep -q '^gh ' "$S/calls" 2>/dev/null || fail "dry run called gh"
ok "publish-release --dry-run shows the release and the diff and changes nothing"

# Stable publish.
"$R/Tools/publish-release.sh" --channel stable --pkg "$WORK/S40.pkg" --notes "$F/n-0.8.40.md" --feed "$FEED" > "$WORK/pub.out"
grep -Fq "gh release create v0.8.40 " "$S/calls" || fail "release not created"
grep -Fq -- "--target $COMMIT" "$S/calls" || fail "release not tagged at the build commit"
grep "release create v0.8.40" "$S/calls" | grep -q -- '--latest' || fail "stable not marked latest"
grep "release create v0.8.40" "$S/calls" | grep -q -- '--prerelease' && fail "stable marked prerelease"
grep "release create v0.8.40" "$S/calls" | grep -q -- "--repo danielraffel/unofficial-symphony-maestro-mk1" || fail "release repo"
cmp -s "$WORK/www/releases/download/v0.8.40/UnofficialSymphonyMaestro.pkg" "$WORK/S40.pkg" || fail "asset is not the package"
[ "$(field "$FEED" 0.8.40 url)" = "$MAESTRO_RELEASES_BASE/download/v0.8.40/UnofficialSymphonyMaestro.pkg" ] || fail "stable enclosure URL"
[ -z "$(field "$FEED" 0.8.40 channel)" ] || fail "stable item tagged"
git -C "$R" status --porcelain | grep -q . && fail "publish committed or left changes in the repo"
ok "publish stable: release at the build commit, latest, feed item added, nothing committed"

# Beta publish.
set_repo_version 0.9.0
git -C "$R" -c user.name=t -c user.email=t@t commit -qam beta
COMMIT="$(git -C "$R" rev-parse HEAD)"
git -C "$R" update-ref refs/remotes/origin/dev "$COMMIT"
make_pkg 0.9.0 "$WORK/B0.pkg"
"$R/Tools/publish-release.sh" --channel beta --pkg "$WORK/B0.pkg" --notes "$F/n-0.9.0.md" --feed "$FEED" > "$WORK/pub.out"
grep "release create v0.9.0" "$S/calls" | grep -q -- '--prerelease' || fail "beta not a prerelease"
grep "release create v0.9.0" "$S/calls" | grep -q -- '--latest' && fail "beta marked latest"
[ "$(cat "$S/latest")" = v0.8.40 ] || fail "beta changed GitHub's latest"
[ "$(field "$FEED" 0.9.0 channel)" = beta ] || fail "beta item not tagged"
if "$R/Tools/publish-release.sh" --channel beta --pkg "$WORK/B0.pkg" --notes "$F/n-0.9.0.md" --feed "$FEED" >/dev/null 2>&1; then fail "published the same version twice"; fi
ok "publish beta: prerelease, latest unchanged, tagged item, no second publish"

# A stable hotfix below the beta prints the hotfix rule.
git -C "$R" checkout -q -b hotfix "$(git -C "$R" rev-list --max-parents=0 HEAD)"
set_repo_version 0.8.41
git -C "$R" -c user.name=t -c user.email=t@t commit -qam hotfix
COMMIT="$(git -C "$R" rev-parse HEAD)"
make_pkg 0.8.41 "$WORK/S41.pkg"
if "$R/Tools/publish-release.sh" --channel stable --pkg "$WORK/S41.pkg" --notes "$F/n-0.8.40.md" --feed "$FEED" --dry-run >/dev/null 2>&1; then fail "published from an unpushed commit"; fi
git -C "$R" update-ref refs/remotes/origin/main "$COMMIT"
"$R/Tools/publish-release.sh" --channel stable --pkg "$WORK/S41.pkg" --notes "$F/n-0.8.40.md" --feed "$FEED" --dry-run > "$WORK/hotfix.out"
grep -q "Hotfix rule: beta 0.9.0 is above 0.8.41" "$WORK/hotfix.out" || fail "no hotfix reminder"
ok "publish refuses an unpushed commit; a stable hotfix below a beta prints the hotfix rule"

# Promote the beta.
cp "$FEED" "$WORK/before-promote.xml"
if "$R/Tools/promote-beta.sh" --feed "$FEED" >/dev/null 2>&1; then fail "promoted without notes"; fi
"$R/Tools/promote-beta.sh" --notes "$F/stable-notes.md" --feed "$FEED" --dry-run > "$WORK/promote-dry.out"
cmp -s "$FEED" "$WORK/before-promote.xml" || fail "promote dry run changed the feed"
grep -q 'would run:.*release edit v0.9.0' "$WORK/promote-dry.out" || fail "promote dry run did not show the edit"
"$R/Tools/promote-beta.sh" --notes "$F/stable-notes.md" --feed "$FEED" > "$WORK/promote.out"
grep -Fq "gh release edit v0.9.0 --repo danielraffel/unofficial-symphony-maestro-mk1 --prerelease=false --latest --notes-file $F/stable-notes.md" "$S/calls" || fail "release not flipped"
[ "$(cat "$S/latest")" = v0.9.0 ] || fail "promoted release is not latest"
[ -z "$(field "$FEED" 0.9.0 channel)" ] || fail "promoted item still tagged"
[ "$("${FEED_PY[@]}" newest --feed "$FEED" --channel stable)" = 0.9.0 ] || fail "newest stable after promotion"
cmp -s "$WORK/www/releases/latest/download/UnofficialSymphonyMaestro.pkg" "$WORK/B0.pkg" || fail "latest download is not the tested beta"
ok "promote-beta: newest beta by default, verified bytes, release flipped to latest, feed promoted"

# A swapped release asset is refused before anything changes.
cp "$WORK/before-promote.xml" "$FEED"
echo v0.8.40 > "$S/latest"
cp "$WORK/S40.pkg" "$WORK/www/releases/download/v0.9.0/UnofficialSymphonyMaestro.pkg"
: > "$S/calls"
if "$R/Tools/promote-beta.sh" 0.9.0 --notes "$F/stable-notes.md" --feed "$FEED" >/dev/null 2>&1; then fail "promoted a swapped asset"; fi
grep -q '^gh ' "$S/calls" && fail "gh called after a failed asset check"
cmp -s "$FEED" "$WORK/before-promote.xml" || fail "feed changed after a failed asset check"
cp "$WORK/B0.pkg" "$WORK/www/releases/download/v0.9.0/UnofficialSymphonyMaestro.pkg"
ok "promote-beta refuses a release asset that is not the tested package"

# Local feed: no GitHub at all.
git -C "$R" checkout -q -
L="$WORK/www/rehearsal"
mkdir -p "$L"
cp "$F/base.xml" "$L/appcast.xml"
: > "$S/calls"
"$R/Tools/publish-release.sh" --channel beta --pkg "$WORK/B0.pkg" --notes "$F/n-0.9.0.md" --feed "$L/appcast.xml" \
    --local-base-url "http://127.0.0.1:$PORT/rehearsal" >/dev/null
cmp -s "$L/0.9.0.pkg" "$WORK/B0.pkg" || fail "local package not copied"
[ -f "$L/0.9.0.notes.md" ] || fail "local notes not copied"
[ "$(field "$L/appcast.xml" 0.9.0 url)" = "http://127.0.0.1:$PORT/rehearsal/0.9.0.pkg" ] || fail "local enclosure URL"
"$R/Tools/promote-beta.sh" --notes "$F/stable-notes.md" --feed "$L/appcast.xml" >/dev/null
[ -z "$(field "$L/appcast.xml" 0.9.0 channel)" ] || fail "local promotion"
[ ! -s "$S/calls" ] || fail "local mode called GitHub: $(cat "$S/calls")"
if "$R/Tools/publish-release.sh" --channel beta --pkg "$WORK/B0.pkg" --notes "$F/n-0.9.0.md" --feed "$L/appcast.xml" \
    --local-base-url "http://example.com" >/dev/null 2>&1; then fail "accepted a non-local base URL"; fi
ok "local feed: publish and promote without GitHub"

# ── verify-sparkle-feed.sh ──────────────────────────────────────────────────
V="$R/Tools/verify-sparkle-feed.sh"
VF="http://127.0.0.1:$PORT/rehearsal/appcast.xml"
cp "$F/base.xml" "$L/appcast.xml"
/bin/rm -f "$L/0.9.0.pkg" "$L/0.9.0.notes.md"
git -C "$R" checkout -q hotfix
make_pkg 0.8.41 "$WORK/S41.pkg"
"$R/Tools/publish-release.sh" --channel stable --pkg "$WORK/S41.pkg" --notes "$F/n-0.8.40.md" --feed "$L/appcast.xml" \
    --local-base-url "http://127.0.0.1:$PORT/rehearsal" >/dev/null
git -C "$R" checkout -q -
"$R/Tools/publish-release.sh" --channel beta --pkg "$WORK/B0.pkg" --notes "$F/n-0.9.0.md" --feed "$L/appcast.xml" \
    --local-base-url "http://127.0.0.1:$PORT/rehearsal" >/dev/null
"$V" 0.8.41 "$VF" stable >/dev/null || fail "verify stable with a beta on top"
"$V" 0.9.0 "$VF" beta >/dev/null || fail "verify beta"
"$V" 0.9.0 "$VF" >/dev/null || fail "verify without a channel"
if "$V" 0.9.0 "$VF" stable >/dev/null 2>&1; then fail "a beta verified as stable"; fi
if "$V" 0.8.41 "$VF" beta >/dev/null 2>&1; then fail "a stable verified as beta"; fi
if "$V" 0.8.39 "$VF" stable >/dev/null 2>&1; then fail "an old stable verified as the newest"; fi
if "$V" 0.9.5 "$VF" >/dev/null 2>&1; then fail "a missing version verified"; fi
ok "verify-sparkle-feed selects by version and checks the channel and the newest stable"

cp "$L/0.9.0.pkg" "$WORK/keep.pkg"
printf 'x' | dd of="$L/0.9.0.pkg" bs=1 seek=100 conv=notrunc 2>/dev/null
if "$V" 0.9.0 "$VF" beta >/dev/null 2>&1; then fail "a changed package verified"; fi
cp "$WORK/keep.pkg" "$L/0.9.0.pkg"
cp "$L/appcast.xml" "$WORK/keep.xml"
sed -i '' 's/Beta notes for testers/Beta notes for Testers/' "$L/appcast.xml"
if "$V" 0.9.0 "$VF" beta >/dev/null 2>&1; then fail "an edited feed verified"; fi
cp "$WORK/keep.xml" "$L/appcast.xml"
if SPARKLE_PUBLIC_ED_KEY=AAAA "$V" 0.9.0 "$VF" beta >/dev/null 2>&1; then fail "a package with another app key verified"; fi
"$V" 0.9.0 "$VF" beta >/dev/null || fail "control after restoring"
ok "verify-sparkle-feed refuses a changed package, an edited feed and a key mismatch"

[ "$(shasum -a 256 "$REPO_ROOT/appcast.xml" | cut -d' ' -f1)" = "$TRACKED_BEFORE" ] || fail "the tracked appcast.xml changed"
ok "tracked appcast.xml untouched"

echo "Feed tool tests passed ($PASS)"
