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

# ── Preinstall: Apogee's original Symphony I/O MkI drivers ──────────────────
PRE="$REPO_ROOT/Installer/scripts-core/preinstall"

# Runs find_original_apogee against a fake root. $1 = case dir, $2 = what the
# stubbed kmutil prints (empty: nothing loaded).
run_find() {
    local dir="$1" loaded="${2:-}"
    mkdir -p "$dir/root"
    printf '%s\n' "$loaded" > "$dir/loaded.txt"
    mkstub "$dir/kmutil" "cat '$dir/loaded.txt'"
    (
        # shellcheck source=/dev/null
        . "$PRE"
        APOGEE_ROOT="$dir/root" KMUTIL="$dir/kmutil" KEXTSTAT=/usr/bin/false find_original_apogee
    )
}
mkbundle() { mkdir -p "$1/Contents"; touch "$1/Contents/Info.plist"; }
HAL_DIR="Library/Audio/Plug-Ins/HAL/Apogee/Symphony Systems"
OURS_LOADED="    1  0 0 0 0 com.danielraffel.maestro.thunderbridge (0.11.12) ABC <8 6 5 3 2 1>
    2  0 0 0 0 com.apple.iokit.IOPCIFamily (2.9) DEF <8 6 5 3>"

C="$WORK/apogee-none"
mkdir -p "$C/root/Applications/Apogee Maestro 2.app" "$C/root/Library/Application Support/Apogee/ApogeePopup.bundle"
mkbundle "$C/root/Library/Frameworks/ApogeeServices.framework"
mkbundle "$C/root/Library/Audio/Plug-Ins/HAL/ApogeeSymIO.driver"
mkdir -p "$C/root/Library/LaunchDaemons"; touch "$C/root/Library/LaunchDaemons/com.usbApogeeDaemon.plist"
OUT="$(run_find "$C" "$OURS_LOADED")"
[ -z "$OUT" ] || fail "flagged Maestro, Maestro 2 or shared Apogee software: $OUT"
# shellcheck disable=SC2016  # the pattern is the script's literal text
if ! grep -q '^if \[ "${BASH_SOURCE\[0\]}" = "\$0" \]; then' "$PRE"; then
    fail "preinstall no longer runs main only when executed"
fi
ok "preinstall: nothing flagged for Maestro's own driver, Apogee Maestro 2, ApogeePopup or ApogeeServices"

C="$WORK/apogee-staged"
mkbundle "$C/root/Library/StagedExtensions/Library/Extensions/Symphony64Thunderbridge.kext"
OUT="$(run_find "$C" "    9  0 0 0 0 com.apogeedigital.driver.Symphony64ThunderBridge (5.5) XYZ <8 6>")"
WANT="Kernel extension (copy kept by macOS): $C/root/Library/StagedExtensions/Library/Extensions/Symphony64Thunderbridge.kext
Loaded kernel extension: com.apogeedigital.driver.Symphony64ThunderBridge"
[ "$OUT" = "$WANT" ] || fail "staged kext copy: $OUT"
# Not the restart-only case: a restart loads the staged copy again.
( . "$PRE"; [ "$(MAESTRO_APP_PATH=/nonexistent original_apogee_decision "$OUT" 2>/dev/null)" != "restart" ] ) \
    || fail "a staged kext copy was treated as restart-only"
ok "preinstall: macOS's staged copy of an Apogee kext is found and is not a restart-only case"

C="$WORK/apogee-hal"
mkbundle "$C/root/$HAL_DIR/SymphonyPlugin.bundle"
mkdir -p "$C/root/$HAL_DIR/SymphonyIOUSBPlugIn.bundle/Contents"
touch "$C/root/$HAL_DIR/SymphonyIOUSBPlugIn.bundle/Contents/Info.plist.disabled-maestro"
mkdir -p "$C/root/$HAL_DIR/usbApogeePlugin.bundle.disabled-asp/Contents"
touch "$C/root/$HAL_DIR/usbApogeePlugin.bundle.disabled-asp/Contents/Info.plist"
OUT="$(run_find "$C")"
[ "$OUT" = "HAL plug-in: $C/root/$HAL_DIR/SymphonyPlugin.bundle" ] || fail "HAL plug-ins: $OUT"
ok "preinstall: an active HAL plug-in blocks; .disabled-maestro and .disabled-asp ones do not"

C="$WORK/apogee-kext-file"
mkbundle "$C/root/Library/Extensions/Symphony64Thunderbridge.kext"
OUT="$(run_find "$C" "$OURS_LOADED")"
[ "$OUT" = "Kernel extension: $C/root/Library/Extensions/Symphony64Thunderbridge.kext" ] || fail "kext file: $OUT"
ok "preinstall: the ThunderBridge kext in /Library/Extensions blocks"

C="$WORK/apogee-kext-loaded"
OUT="$(run_find "$C" "$OURS_LOADED
  190  0 0 0 0 com.apogeedigital.driver.Symphony64ThunderBridge (5.5) ABC <8 6 5 3 2 1>")"
[ "$OUT" = "Loaded kernel extension: com.apogeedigital.driver.Symphony64ThunderBridge" ] \
    || fail "loaded ThunderBridge kext: $OUT"
ok "preinstall: a loaded ThunderBridge kext blocks after its file is gone, and does not also match Symphony64"

(
    # shellcheck source=/dev/null
    . "$PRE"
    only_awaiting_restart "Loaded kernel extension: com.apogeedigital.driver.Symphony64ThunderBridge" \
        || fail "loaded-only finding not treated as awaiting restart"
    only_awaiting_restart "Loaded kernel extension: com.apogeedigital.driver.Symphony64
Kernel extension: /Library/Extensions/Symphony64.kext" && fail "an installed kext treated as awaiting restart"
    grep -q 'Restart your Mac, then run this installer again.' "$PRE" || fail "no restart-only dialog"
) || exit 1
ok "preinstall: a kext loaded with its file gone asks for a restart, not Uninstall again"

# The decision: fresh installs are blocked; an update of Maestro goes ahead.
# $1 = case dir, $2 = bundle ID of /Applications/Maestro.app ("" = none), $3 = findings.
decide() {
    local dir="$1" id="$2" found="$3"
    mkdir -p "$dir/root"
    if [ -n "$id" ]; then
        mkdir -p "$dir/root/Applications/Maestro.app/Contents"
        plutil -create xml1 "$dir/root/Applications/Maestro.app/Contents/Info.plist"
        plutil -insert CFBundleIdentifier -string "$id" "$dir/root/Applications/Maestro.app/Contents/Info.plist"
    fi
    (
        # shellcheck source=/dev/null
        . "$PRE"
        APOGEE_ROOT="$dir/root" original_apogee_decision "$found"
    )
}
FOUND_FILE="Kernel extension: /Library/Extensions/Symphony64Thunderbridge.kext"
FOUND_HAL="HAL plug-in: /Library/Audio/Plug-Ins/HAL/Apogee/Symphony Systems/SymphonyPlugin.bundle"
FOUND_LOADED="Loaded kernel extension: com.apogeedigital.driver.Symphony64ThunderBridge"
[ "$(decide "$WORK/d-none" "" "")" = clear ] || fail "nothing found: not clear"
[ "$(decide "$WORK/d-fresh" "" "$FOUND_FILE")" = block ] || fail "fresh install with the kext: not blocked"
[ "$(decide "$WORK/d-fresh-hal" "" "$FOUND_HAL")" = block ] || fail "fresh install with a HAL plug-in: not blocked"
[ "$(decide "$WORK/d-restart" "" "$FOUND_LOADED")" = restart ] || fail "fresh install, loaded only: not restart"
[ "$(decide "$WORK/d-update" com.danielraffel.maestro "$FOUND_FILE")" = update ] || fail "update with the kext: blocked"
[ "$(decide "$WORK/d-update-hal" com.danielraffel.maestro "$FOUND_HAL")" = update ] || fail "update with a HAL plug-in: blocked"
[ "$(decide "$WORK/d-update-loaded" com.danielraffel.maestro "$FOUND_LOADED")" = update ] || fail "update, loaded only: blocked"
[ "$(decide "$WORK/d-apogee-app" com.apogee.Maestro "$FOUND_FILE")" = block ] \
    || fail "Apogee's own /Applications/Maestro.app taken for ours"
[ "$(decide "$WORK/d-update-clear" com.danielraffel.maestro "")" = clear ] || fail "update, nothing found: not clear"
ok "preinstall: Apogee's drivers block a fresh install, not an update of Maestro (by bundle ID, not name)"

C="$WORK/apogee-kext-pcie"
OUT="$(run_find "$C" "  191  0 0 0 0 com.apogeedigital.driver.Symphony64 (5.5) ABC <8 6 5 3 2 1>")"
[ "$OUT" = "Loaded kernel extension: com.apogeedigital.driver.Symphony64" ] || fail "loaded PCIe kext: $OUT"
C="$WORK/apogee-kextstat"
mkdir -p "$C/root"
# shellcheck source=/dev/null
OUT="$(. "$PRE"; APOGEE_ROOT="$C/root" KMUTIL=/usr/bin/false \
    KEXTSTAT="$(printf '#!/bin/bash\necho "  5 0 0 0 0 com.apogee.driver.ApogeeUSBSymphonyIOAudio (1.0)"\n' > "$C/kextstat"; chmod +x "$C/kextstat"; echo "$C/kextstat")" \
    find_original_apogee)"
[ "$OUT" = "Loaded kernel extension: com.apogee.driver.ApogeeUSBSymphonyIOAudio" ] || fail "kextstat fallback: $OUT"
ok "preinstall: the Symphony 64 PCIe kext is matched exactly, and kextstat is the fallback"

C="$WORK/apogee-daemons"
mkdir -p "$C/root/Library/LaunchDaemons"
touch "$C/root/Library/LaunchDaemons/com.SymphonyDaemon.plist" "$C/root/Library/LaunchDaemons/com.SymphonyIOUSBDaemon.plist"
mkbundle "$C/root/System/Library/Extensions/SymphonyIOUSBOverideDriver.kext"
mkbundle "$C/root/Library/Extensions/SymphonyPlugin.bundle"
mkbundle "$C/root/System/Library/Extensions/usbApogeePlugin.bundle"  # other Apogee USB products' home too
OUT="$(run_find "$C")"
[ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = 4 ] || fail "daemons, old plug-in and USB override kext: $OUT"
printf '%s\n' "$OUT" | grep -q usbApogeePlugin && fail "flagged usbApogeePlugin outside Symphony Systems"
ok "preinstall: the Symphony launch daemons, an old-location Symphony plug-in and the USB override kext block"

echo "Installer tool tests passed ($PASS)"
