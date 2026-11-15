#!/bin/bash
# Host tests for the installer pieces that need no signing identity, no root
# and no install: the postinstall reopen of Maestro, the package-content
# checks and the driver CDHash gate. Nothing here installs anything or
# touches the system; every command that would is replaced by a stub.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/maestro-installer-tests.XXXXXX")"
# shellcheck source=lib/package-checks.sh
. "$REPO_ROOT/Tools/lib/package-checks.sh"
trap 'remove_scratch "$WORK"' EXIT
PASS=0
fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { PASS=$((PASS + 1)); echo "ok - $*"; }

# ── Postinstall: reopen Maestro ─────────────────────────────────────────────
CORE="$REPO_ROOT/Installer/scripts-core/postinstall"
USB="$REPO_ROOT/Installer/scripts-usb/postinstall"

mkstub() {  # $1 = path, $2 = body
    printf '#!/bin/bash\n%s\n' "$2" > "$1"
    chmod +x "$1"
}

# Runs start_reopen with stubs. $1 = console user, $2 = uid, $3 = case dir.
run_reopen() {
    local user="$1" uid="$2" dir="$3"
    mkdir -p "$dir"
    mkstub "$dir/stat" "echo '$user'"
    mkstub "$dir/id" "echo '$uid'"
    mkstub "$dir/launchctl" "echo \"\$*\" >> '$dir/launched'"
    (
        set +e
        # shellcheck source=/dev/null
        . "$CORE"
        LOG="$dir/log"; USB_MARKER="$dir/marker"; REOPEN_GRACE=0; REOPEN_MAX_WAIT="${MAX_WAIT:-60}"
        STAT="$dir/stat"; ID="$dir/id"; LAUNCHCTL="$dir/launchctl"
        start_reopen
    )
}

wait_for_file() {  # $1 = file, $2 = seconds
    local i=0
    while [ ! -s "$1" ] && [ "$i" -lt $(( $2 * 10 )) ]; do sleep 0.1; i=$((i + 1)); done
    [ -s "$1" ]
}

C="$WORK/reopen-plain"
START=$SECONDS
run_reopen tester 501 "$C"
[ $((SECONDS - START)) -le 1 ] || fail "start_reopen did not return at once"
wait_for_file "$C/launched" 5 || fail "Maestro was not reopened"
[ "$(cat "$C/launched")" = "asuser 501 /usr/bin/sudo -u tester /usr/bin/open /Applications/Maestro.app" ] \
    || fail "unexpected reopen command: $(cat "$C/launched")"
grep -q "reopening Maestro for tester" "$C/log" || fail "reopen not logged"
grep -Eq '^\[postinstall/core\] [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} ' "$C/log" || fail "log lines carry no time"
ok "reopens Maestro for the console user with plain open, detached"

C="$WORK/reopen-marker"
mkdir -p "$C"; touch "$C/marker"
run_reopen tester 501 "$C"
sleep 2
[ ! -e "$C/launched" ] || fail "reopened while the USB marker was present"
rm -f "$C/marker"
wait_for_file "$C/launched" 4 || fail "not reopened after the USB marker went away"
ok "waits for the USB step's marker"

C="$WORK/reopen-maxwait"
mkdir -p "$C"; touch "$C/marker"
MAX_WAIT=2 run_reopen tester 501 "$C"
wait_for_file "$C/launched" 6 || fail "did not give up waiting for the marker"
grep -q "waited 2s" "$C/log" || fail "max wait not logged"
ok "stops waiting after the maximum"

for case in "root 0" "loginwindow 0" "_mbsetupuser 248" " 0"; do
    set -- $case
    C="$WORK/reopen-none-${1:-empty}"
    run_reopen "${1:-}" "${2:-0}" "$C"
    sleep 0.5
    [ ! -e "$C/launched" ] || fail "reopened with console user '${1:-}'"
    grep -q "Maestro is not reopened" "$C/log" || fail "no-user case not logged for '${1:-}'"
done
ok "no reopen without a person at the console"

grep -v '^[[:space:]]*#' "$CORE" | grep -q 'open -n' && fail "core postinstall uses open -n"
CORE_MARKER="$(sed -n 's/^USB_MARKER="\(.*\)"$/\1/p' "$CORE")"
USB_MARKER_PATH="$(sed -n 's/^USB_MARKER="\(.*\)"$/\1/p' "$USB")"
[ "$CORE_MARKER" = "/var/run/maestro-usb-postinstall.running" ] || fail "core marker is not under /var/run"
[ "$CORE_MARKER" = "$USB_MARKER_PATH" ] || fail "core and USB scripts disagree on the marker"
TOUCH_LINE="$(grep -n 'touch "\$USB_MARKER"' "$USB" | head -1 | cut -d: -f1)"
KILL_LINE="$(grep -n 'killall coreaudiod' "$USB" | head -1 | cut -d: -f1)"
RM_LINE="$(grep -n '^/bin/rm -f "\$USB_MARKER"' "$USB" | head -1 | cut -d: -f1)"
FIRST_CMD="$(grep -n -E '^(chown|launchctl|killall)' "$USB" | head -1 | cut -d: -f1)"
[ -n "$TOUCH_LINE" ] && [ "$TOUCH_LINE" -lt "$FIRST_CMD" ] || fail "USB marker is not created first"
[ -n "$RM_LINE" ] && [ "$RM_LINE" -gt "$KILL_LINE" ] || fail "USB marker is not removed after the coreaudiod restart"
grep -q "trap '/bin/rm -f \"\$USB_MARKER\"' EXIT" "$USB" || fail "USB marker is not removed on failure"
bash -n "$CORE" && bash -n "$USB" || fail "syntax"
ok "USB postinstall holds the marker around the coreaudiod restart"

# ── Package: an older Maestro replaces a newer one ──────────────────────────
# shellcheck source=lib/package-checks.sh
. "$REPO_ROOT/Tools/lib/package-checks.sh"

make_fake_app() {  # $1 = payload root
    local app="$1/Applications/Fake.app" dext
    dext="$app/Contents/Library/SystemExtensions/com.example.fake.dext"
    mkdir -p "$app/Contents/MacOS" "$dext"
    cp /usr/bin/true "$app/Contents/MacOS/Fake"
    cp /usr/bin/true "$dext/com.example.fake.dext"
    for pair in "$app/Contents:com.example.fake:Fake:APPL" "$dext:com.example.fake.dext:com.example.fake.dext:DEXT"; do
        IFS=: read -r dir id exe type <<<"$pair"
        cat > "$dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$id</string>
<key>CFBundleExecutable</key><string>$exe</string>
<key>CFBundlePackageType</key><string>$type</string>
<key>CFBundleVersion</key><string>1.2.3</string>
<key>CFBundleShortVersionString</key><string>1.2.3</string>
</dict></plist>
PLIST
    done
}

P="$WORK/pkg"
mkdir -p "$P/root"
make_fake_app "$P/root"
make_component_plist "$P/root" "$P/component.plist" >/dev/null
python3 - "$P/component.plist" <<'PY' || fail "component plist flags"
import plistlib, sys
comps = plistlib.load(open(sys.argv[1], 'rb'))
assert comps and all(c['BundleIsVersionChecked'] is False and c['BundleIsRelocatable'] is False for c in comps), comps
PY
pkgbuild --root "$P/root" --component-plist "$P/component.plist" --identifier com.example.fake --version 1 "$P/fixed.pkg" >/dev/null
check_not_version_checked "$P/fixed.pkg" >/dev/null || fail "a package built with the fixed plist is still version-checked"
pkgutil --expand "$P/fixed.pkg" "$P/fixed-expanded"
grep -q '<upgrade-bundle>' "$P/fixed-expanded/PackageInfo" || fail "upgrade-bundle changed"
grep -q '<strict-identifier>' "$P/fixed-expanded/PackageInfo" || fail "strict-identifier changed"
ok "component plist turns the version check off; PackageInfo has an empty bundle-version"

# Control: pkgbuild's default plist is version-checked, and the check says so.
pkgbuild --analyze --root "$P/root" "$P/default.plist" >/dev/null
pkgbuild --root "$P/root" --component-plist "$P/default.plist" --identifier com.example.fake --version 1 "$P/default.pkg" >/dev/null
if check_not_version_checked "$P/default.pkg" 2>/dev/null; then fail "the check passed a version-checked package"; fi
ok "the check refuses a version-checked package"

grep -q 'check_not_version_checked "\$CORE_PKG"' "$REPO_ROOT/Installer/build-installer.sh" || fail "build does not check the core package"
grep -q 'check_not_version_checked "\$USB_PKG"' "$REPO_ROOT/Installer/build-installer.sh" || fail "build does not check the USB package"
ok "the build checks both component packages"

# ── Driver CDHash gate ──────────────────────────────────────────────────────
G="$WORK/gate"
mkdir -p "$G"
cp /usr/bin/true "$G/driver"
codesign -s - -f "$G/driver" 2>/dev/null
HASH="$(code_cdhash "$G/driver")"
[[ "$HASH" =~ ^[0-9a-f]{40}$ ]] || fail "code_cdhash did not read a CDHash ($HASH)"
check_dext_cdhash "$G/driver" "$HASH" 123 >/dev/null || fail "gate refused the matching driver"
if check_dext_cdhash "$G/driver" 0000000000000000000000000000000000000000 123 2>"$G/err"; then fail "gate passed a different driver"; fi
grep -q "$HASH" "$G/err" && grep -q 0000000000000000000000000000000000000000 "$G/err" || fail "gate does not print both hashes"
check_dext_cdhash "$G/driver" "" 124 | grep -q "$HASH" || fail "first build of a driver number does not print its hash"
grep -q 'check_dext_cdhash "\$DEXT_SRC"' "$REPO_ROOT/Installer/build-installer.sh" || fail "build does not gate the driver"
ok "driver CDHash gate"

# ── Version tuple (Tools/check-versions.py) ─────────────────────────────────
V="$WORK/versions"
mkdir -p "$V/Tools" "$V/Apps/Maestro/MaestroCore" "$V/Drivers/Thunderbolt"
cp "$REPO_ROOT/Tools/check-versions.py" "$V/Tools/"
set_tuple() {  # app dextVersion dextBuild plistBuild [cdhash]
    printf '{"appVersion": "%s", "buildNumber": 1, "dextVersion": "%s", "dextBuild": %s%s}\n' \
        "$1" "$2" "$3" "${5:+, \"dextCDHash\": \"$5\"}" > "$V/Tools/versions.json"
    printf 'public enum MaestroCore {\n    public static let version = "%s"\n}\n' "$1" > "$V/Apps/Maestro/MaestroCore/MaestroCore.swift"
    cat > "$V/Drivers/Thunderbolt/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>$2</string>
<key>CFBundleVersion</key><string>$4</string>
</dict></plist>
PLIST
}
cv() { python3 "$V/Tools/check-versions.py" "$@" >/dev/null 2>&1; }
H40=1cb0362e5a8ab718cf839c5ee2a54a3c7c7f21a0
set_tuple 0.8.40 0.10.17 123 123 "$H40"; cv || fail "valid tuple refused"
set_tuple 0.8.40 0.10.17 123 123; cv || fail "tuple without a recorded CDHash refused"
set_tuple 0.8.40 0.10.17 123 123 "1CB0"; cv && fail "short CDHash accepted"
set_tuple 0.8.40 0.10.17 124 123 "$H40"; cv && fail "driver plist build disagreeing with dextBuild accepted"
ok "check-versions: dextCDHash format and driver plist build"

cat > "$V/feed.xml" <<'XML'
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<item><sparkle:version>0.9.0</sparkle:version><sparkle:channel>beta</sparkle:channel></item>
<item><sparkle:version>0.8.40</sparkle:version></item>
<item><sparkle:version>0.8.39</sparkle:version></item>
</channel></rss>
XML
set_tuple 0.8.41 0.10.17 123 123 "$H40"
cv --feed "$V/feed.xml" --channel stable || fail "hotfix below an outstanding beta refused"
cv --feed "$V/feed.xml" --channel beta && fail "beta below an existing beta accepted"
set_tuple 0.8.40 0.10.17 123 123 "$H40"
cv --feed "$V/feed.xml" --channel stable && fail "version already in the feed accepted"
set_tuple 0.8.39 0.10.17 123 123 "$H40"
cv --feed "$V/feed.xml" --channel stable && fail "stable below the newest stable accepted"
set_tuple 0.9.1 0.10.17 123 123 "$H40"
cv --feed "$V/feed.xml" --channel beta || fail "beta above everything refused"
python3 "$V/Tools/check-versions.py" --feed "$V/feed.xml" >/dev/null 2>&1 && fail "--feed without --channel accepted"
# Notes are text: a stable item whose notes quote the channel element is still stable.
cat > "$V/quoting.xml" <<'XML'
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>
<item><sparkle:version>0.8.42</sparkle:version><description><![CDATA[
Beta items carry <sparkle:channel>beta</sparkle:channel>. </item><item><sparkle:version>0.8.99</sparkle:version>
]]></description></item>
<item><sparkle:version>0.8.40</sparkle:version></item>
</channel></rss>
XML
set_tuple 0.8.41 0.10.17 123 123 "$H40"
cv --feed "$V/quoting.xml" --channel stable && fail "a stable item was read as beta from its notes (0.8.41 accepted below stable 0.8.42)"
set_tuple 0.8.43 0.10.17 123 123 "$H40"
cv --feed "$V/quoting.xml" --channel stable || fail "a version was read from notes (0.8.43 refused)"
ok "check-versions --feed: stable above the newest stable, beta above everything, no duplicates, notes read as text"

# ── Driver port count (dextPortCount) ───────────────────────────────────────
D="$WORK/portcount"
mkdir -p "$D"
cat > "$D/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>IOKitPersonalities</key><dict><key>SymphonyThunderbridge</key><dict>
<key>IOClass</key><string>IOUserService</string></dict></dict></dict></plist>
PLIST
KEY=":IOKitPersonalities:SymphonyThunderbridge:SymphonyPortCount"
inject_dext_port_count "$D/Info.plist" 2 >/dev/null
[ "$(/usr/libexec/PlistBuddy -c "Print $KEY" "$D/Info.plist")" = 2 ] || fail "port count 2 not injected"
inject_dext_port_count "$D/Info.plist" "" >/dev/null
/usr/libexec/PlistBuddy -c "Print $KEY" "$D/Info.plist" >/dev/null 2>&1 && fail "port count left in place when absent"
if inject_dext_port_count "$D/Info.plist" 3 2>/dev/null; then fail "port count 3 accepted"; fi
grep -q 'MAESTRO_EXPERIMENT_PORT_COUNT' "$REPO_ROOT/Installer/build-installer.sh" && fail "the environment switch is still in the build"
grep -q 'inject_dext_port_count "\$DEXT_SRC/Info.plist" "\$DEXT_PORT_COUNT"' "$REPO_ROOT/Installer/build-installer.sh" || fail "build does not inject from versions.json"
INJECT_LINE="$(grep -n 'inject_dext_port_count "\$DEXT_SRC' "$REPO_ROOT/Installer/build-installer.sh" | cut -d: -f1)"
SIGN_LINE="$(grep -n 'Signing dext (Developer ID' "$REPO_ROOT/Installer/build-installer.sh" | cut -d: -f1)"
[ "$INJECT_LINE" -lt "$SIGN_LINE" ] || fail "port count injected after signing"
H40=1cb0362e5a8ab718cf839c5ee2a54a3c7c7f21a0
set_tuple 0.9.0 0.11.0 124 124 "$H40"
python3 - "$V/Tools/versions.json" <<'PY'
import json, sys; p = sys.argv[1]; v = json.load(open(p)); v['dextPortCount'] = 2; json.dump(v, open(p, 'w'))
PY
cv || fail "dextPortCount 2 refused"
for bad in 3 '"2"' 0; do
    python3 - "$V/Tools/versions.json" "$bad" <<'PY'
import json, sys; p = sys.argv[1]; v = json.load(open(p)); v['dextPortCount'] = json.loads(sys.argv[2]); json.dump(v, open(p, 'w'))
PY
    cv && fail "dextPortCount $bad accepted"
done
ok "dextPortCount from versions.json: 1 or 2, injected before signing, no environment switch"

echo "Installer tool tests passed ($PASS)"
