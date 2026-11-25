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
    # `kmutil inspect` reads the auxiliary collection: aux.txt when the case
    # has one, a failure otherwise. Anything else is `showloaded`.
    mkstub "$dir/kmutil" "if [ \"\$1\" = inspect ]; then cat '$dir/aux.txt' 2>/dev/null; else cat '$dir/loaded.txt'; fi"
    (
        # shellcheck source=/dev/null
        . "$PRE"
        MAESTRO_PREINSTALL_TEST=1 APOGEE_ROOT="$dir/root" KMUTIL="$dir/kmutil" KEXTSTAT=/usr/bin/false \
            find_original_apogee
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
    # After Apogee's Uninstall the kext can still be loaded and still be in the
    # auxiliary collection until the restart: that is the restart case too.
    only_awaiting_restart "Loaded kernel extension: com.apogeedigital.driver.Symphony64ThunderBridge
Kernel extension (in macOS's auxiliary kernel collection): com.apogeedigital.driver.Symphony64ThunderBridge" \
        || fail "loaded plus an auxiliary-collection line not treated as awaiting restart"
    only_awaiting_restart "Kernel extension (in macOS's auxiliary kernel collection): com.apogeedigital.driver.Symphony64" \
        && fail "an auxiliary-collection line alone treated as awaiting restart"
    only_awaiting_restart "Loaded kernel extension: com.apogeedigital.driver.Symphony64
Kernel extension (copy kept by macOS): /Library/StagedExtensions/Library/Extensions/Symphony64.kext" \
        && fail "a staged copy treated as awaiting restart"
    grep -q 'Restart your Mac, then run this installer again.' "$PRE" || fail "no restart-only dialog"
) || exit 1
ok "preinstall: a kext loaded with its file gone asks for a restart, not Uninstall again"

# The decision: a fresh install is blocked by anything found; an update of
# Maestro only by a kernel driver for the ThunderBridge or PCIe card.
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
        MAESTRO_PREINSTALL_TEST=1 APOGEE_ROOT="$dir/root" original_apogee_decision "$found"
    )
}
FOUND_FILE="Kernel extension: /Library/Extensions/Symphony64Thunderbridge.kext"
FOUND_HAL="HAL plug-in: /Library/Audio/Plug-Ins/HAL/Apogee/Symphony Systems/SymphonyPlugin.bundle"
FOUND_LOADED="Loaded kernel extension: com.apogeedigital.driver.Symphony64ThunderBridge"
[ "$(decide "$WORK/d-none" "" "")" = clear ] || fail "nothing found: not clear"
[ "$(decide "$WORK/d-fresh" "" "$FOUND_FILE")" = block ] || fail "fresh install with the kext: not blocked"
[ "$(decide "$WORK/d-fresh-hal" "" "$FOUND_HAL")" = block ] || fail "fresh install with a HAL plug-in: not blocked"
[ "$(decide "$WORK/d-restart" "" "$FOUND_LOADED")" = restart ] || fail "fresh install, loaded only: not restart"
[ "$(decide "$WORK/d-update" com.danielraffel.maestro "$FOUND_FILE")" = block ] || fail "update with the kext: not blocked"
[ "$(decide "$WORK/d-update-hal" com.danielraffel.maestro "$FOUND_HAL")" = update ] || fail "update with a HAL plug-in: blocked"
[ "$(decide "$WORK/d-update-loaded" com.danielraffel.maestro "$FOUND_LOADED")" = restart ] \
    || fail "update, kext loaded with its file gone: not asked to restart"
# An update weighs only the kernel drivers for the card: a HAL plug-in next to a
# kext that is loaded with its file gone does not turn "restart" into "uninstall".
[ "$(decide "$WORK/d-update-loaded-hal" com.danielraffel.maestro "$FOUND_LOADED
$FOUND_HAL")" = restart ] || fail "update, loaded kext (file gone) and a HAL plug-in: not asked to restart"
[ "$(decide "$WORK/d-fresh-loaded-hal" "" "$FOUND_LOADED
$FOUND_HAL")" = block ] || fail "fresh install, loaded kext and a HAL plug-in: not blocked"
FOUND_STAGED="Kernel extension (copy kept by macOS): /Library/StagedExtensions/Library/Extensions/Symphony64Thunderbridge.kext"
FOUND_AUX="Kernel extension (in macOS's auxiliary kernel collection): com.apogeedigital.driver.Symphony64ThunderBridge"
# Staged only, or only in the auxiliary collection: an update goes ahead (the
# app warns); a first install is stopped and sent to the removal guide.
for F in "$FOUND_STAGED" "$FOUND_AUX" "$FOUND_STAGED
$FOUND_AUX" "$FOUND_STAGED
$FOUND_HAL"; do
    [ "$(decide "$WORK/d-update-kept" com.danielraffel.maestro "$F")" = update ] || fail "update blocked by a copy macOS keeps: $F"
done
[ "$(decide "$WORK/d-fresh-staged" "" "$FOUND_STAGED")" = guide ] || fail "fresh install, staged only: not the removal guide"
[ "$(decide "$WORK/d-fresh-aux" "" "$FOUND_AUX")" = guide ] || fail "fresh install, auxiliary collection only: not the removal guide"
[ "$(decide "$WORK/d-fresh-staged-hal" "" "$FOUND_STAGED
$FOUND_HAL")" = block ] || fail "fresh install, staged copy and a HAL plug-in: not Apogee's uninstaller"
# Loaded now: an update stops. With the file gone, a restart; with a staged
# copy as well, the guide (a restart can load that copy again).
[ "$(decide "$WORK/d-update-loaded-aux" com.danielraffel.maestro "$FOUND_LOADED
$FOUND_AUX")" = restart ] || fail "update, loaded and in the auxiliary collection: not asked to restart"
[ "$(decide "$WORK/d-fresh-loaded-aux" "" "$FOUND_LOADED
$FOUND_AUX")" = restart ] || fail "fresh install, loaded and in the auxiliary collection: not asked to restart"
[ "$(decide "$WORK/d-update-loaded-staged" com.danielraffel.maestro "$FOUND_LOADED
$FOUND_STAGED")" = guide ] || fail "update, loaded with a staged copy: not the removal guide"
[ "$(decide "$WORK/d-update-loaded-file" com.danielraffel.maestro "$FOUND_LOADED
$FOUND_FILE")" = block ] || fail "update, loaded with its file installed: not blocked"
# The USB override kext loaded is not a driver for the card: an update goes ahead.
[ "$(decide "$WORK/d-update-usb" com.danielraffel.maestro "Loaded kernel extension: com.apogee.driver.ApogeeUSBSymphonyIOAudio")" = update ] \
    || fail "update blocked by the loaded USB override kext"
[ "$(decide "$WORK/d-apogee-app" com.apogee.Maestro "$FOUND_FILE")" = block ] \
    || fail "Apogee's own /Applications/Maestro.app taken for ours"
[ "$(decide "$WORK/d-update-clear" com.danielraffel.maestro "")" = clear ] || fail "update, nothing found: not clear"
ok "preinstall: Apogee's drivers block a fresh install; an update only for a ThunderBridge or PCIe kernel driver that is loaded or in an Extensions folder (Maestro by bundle ID, not name)"

C="$WORK/apogee-kext-pcie"
OUT="$(run_find "$C" "  191  0 0 0 0 com.apogeedigital.driver.Symphony64 (5.5) ABC <8 6 5 3 2 1>")"
[ "$OUT" = "Loaded kernel extension: com.apogeedigital.driver.Symphony64" ] || fail "loaded PCIe kext: $OUT"
C="$WORK/apogee-kextstat"
mkdir -p "$C/root"
# shellcheck source=/dev/null
OUT="$(. "$PRE"; MAESTRO_PREINSTALL_TEST=1 APOGEE_ROOT="$C/root" KMUTIL=/usr/bin/false \
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

# ── Preinstall step 3 as main runs it: update and first install ─────────────
# Runs original_apogee_gate against the fake root in $1/root with a stubbed
# kmutil, kextstat and osascript. $2 = bundle ID of /Applications/Maestro.app
# ("" = a first install), $3 = what kmutil showloaded prints, $4 = "fail" makes
# kmutil and kextstat both fail, "hang" makes kmutil never answer. Prints
# "blocked" or "proceeds"; the dialog text lands in $1/dialog.txt, osascript's
# arguments in $1/osascript-args.txt, the gate's stderr in $1/stderr and the
# install log in $1/log. GATE_CONSOLE_USER is who is at the console (default:
# whoever runs the tests); GATE_OSASCRIPT replaces the osascript stub's body.
gate() {
    local dir="$1" id="$2" loaded="${3:-}" tools="${4:-ok}"
    mkdir -p "$dir/root"
    if [ -n "$id" ]; then
        mkdir -p "$dir/root/Applications/Maestro.app/Contents"
        plutil -create xml1 "$dir/root/Applications/Maestro.app/Contents/Info.plist"
        plutil -insert CFBundleIdentifier -string "$id" "$dir/root/Applications/Maestro.app/Contents/Info.plist"
    fi
    printf '%s\n' "$loaded" > "$dir/loaded.txt"
    case "$tools" in
        fail) mkstub "$dir/kmutil" "exit 71" ;;
        hang) mkstub "$dir/kmutil" "exec sleep 20" ;;
        *) mkstub "$dir/kmutil" "if [ \"\$1\" = inspect ]; then cat '$dir/aux.txt' 2>/dev/null; else cat '$dir/loaded.txt'; fi" ;;
    esac
    mkstub "$dir/osascript" "${GATE_OSASCRIPT:-printf '%s' \"\$BLOCKED_TEXT\" > '$dir/dialog.txt'; printf '%s\n' \"\$@\" > '$dir/osascript-args.txt'; echo 'button returned:OK, gave up:false'}"
    (
        # shellcheck source=/dev/null
        . "$PRE"
        if MAESTRO_PREINSTALL_TEST=1 APOGEE_ROOT="$dir/root" KMUTIL="$dir/kmutil" KEXTSTAT=/usr/bin/false \
            OSASCRIPT="$dir/osascript" CONSOLE_USER="${GATE_CONSOLE_USER:-$(id -un)}" PROBE_TIMEOUT=1 \
            LOG="$dir/log" original_apogee_gate 2> "$dir/stderr"; then echo proceeds; else echo blocked; fi
    )
}
OURS=com.danielraffel.maestro
TB_LOADED="  190  0 0 0 0 com.apogeedigital.driver.Symphony64ThunderBridge (1.5) ABC <8 6 5 3 2 1>"
GUIDE_URL="https://github.com/danielraffel/unofficial-symphony-maestro-mk1/blob/dev/docs/UserManual.md#removing-apogees-original-drivers"
REPORT_URL="https://github.com/danielraffel/unofficial-symphony-maestro-mk1/issues/32#issuecomment-7050613371"
OPENING_TEXT="Apogee's original Symphony I/O drivers were detected.

Symphony Maestro cannot be installed or updated while they are installed or loaded. Running both can crash your Mac and make it restart repeatedly."
UPDATE_NOTE_TEXT="You are seeing this while updating because this version now checks for them. Your current Maestro is unchanged."
CLOSING_TEXT="If you are still blocked after uninstalling and restarting, or Apogee's uninstaller won't run on your Mac, choose Open Removal Guide: \"Removing Apogee's original drivers\" in the Maestro user guide. It includes steps a user reported worked for them:
$REPORT_URL

$GUIDE_URL"
FIX_TEXT="To fix this:
1. Download Apogee's latest installer, Symphony I/O Release 5.5:
   https://knowledge.apogeedigital.com/hubfs/Software%20Installers/Symphony%20IO/SymphonyIO_Release_5.5.dmg
2. Open the DMG and choose Uninstall
3. Restart your Mac
4. Run this installer again (Apogee's Uninstall also removes Maestro; this puts it back)

$CLOSING_TEXT"
GUIDE_FIX_TEXT="To fix this:
1. Choose Open Removal Guide and follow \"Removing Apogee's original drivers\"
2. Run this installer again

$CLOSING_TEXT"
RESTART_FIX_TEXT="To fix this:
1. Restart your Mac
2. Run this installer again

If you have already restarted and still see this, choose Open Removal Guide.

$GUIDE_URL"
# A dialog, whole: the shared opening, the update sentence for an update only,
# "To fix this:" with the case's steps, the closing, the guide's address.
# $1 = dialog file, $2 = update|install, $3 = block|guide|restart.
check_dialog_text() {
    local text fix="$FIX_TEXT" want
    text="$(cat "$1")"
    case "$3" in
        guide) fix="$GUIDE_FIX_TEXT" ;;
        restart) fix="$RESTART_FIX_TEXT" ;;
    esac
    if [ "$2" = update ]; then
        want="$OPENING_TEXT

$UPDATE_NOTE_TEXT

$fix"
    else
        want="$OPENING_TEXT

$fix"
    fi
    [ "$text" = "$want" ] || fail "$3 dialog text ($2): $text"
    # Maestro's own removal commands are never the installer's advice, and
    # there is no separate "changed nothing" line.
    case "$text" in *kmutil*|*sudo*|*"changed nothing"*) fail "dialog offers removal commands or the old closing line: $text" ;; esac
    [ "$(printf '%s' "$text" | wc -c)" -le 1400 ] || fail "dialog text is too long for a dialog"
}
# Every variant is the same message: the shared opening first, the update
# sentence only for an update, then "To fix this:".
(
    # shellcheck source=/dev/null
    . "$PRE"
    for CASE in block guide restart; do
        for KIND in install update; do
            TEXT="$(dialog_text "$CASE" "$KIND")"
            case "$TEXT" in "$OPENING_TEXT"$'\n\n'*) ;; *) fail "the $CASE dialog ($KIND) does not start with the shared opening: $TEXT" ;; esac
            [ "$(printf '%s\n' "$TEXT" | grep -cx "To fix this:")" = 1 ] || fail "the $CASE dialog ($KIND) lacks 'To fix this:'"
            case "$TEXT" in *"To fix this:"$'\n'"1. "*) ;; *) fail "the $CASE dialog ($KIND) has no numbered steps under 'To fix this:'" ;; esac
            if [ "$KIND" = update ]; then
                case "$TEXT" in "$OPENING_TEXT"$'\n\n'"$UPDATE_NOTE_TEXT"$'\n\n'"To fix this:"*) ;; *) fail "the $CASE dialog (update): update sentence not between the opening and the fix" ;; esac
            else
                case "$TEXT" in "$OPENING_TEXT"$'\n\n'"To fix this:"*) ;; *) fail "the $CASE dialog (install) has something between the opening and the fix" ;; esac
            fi
            case "$TEXT" in *"Run this installer again"*) ;; *) fail "the $CASE dialog ($KIND) does not end at running the installer again" ;; esac
        done
    done
    # One place for each shared part: the opening and the closing are written once.
    [ "$(grep -c "Apogee's original Symphony I/O drivers were detected\.$" "$PRE")" = 1 ] || fail "the opening is written more than once"
    [ "$(grep -c "It includes steps a user reported worked for them" "$PRE")" = 1 ] || fail "the closing is written more than once"
    [ "$(grep -c '^UPDATE_NOTE=' "$PRE")" = 1 ] || fail "the update sentence is written more than once"
) || exit 1
ok "preinstall: every dialog starts with the shared opening and has 'To fix this:' with numbered steps; the update sentence only for an update"
check_block_text() { check_dialog_text "$1" "$2" block; }
# What a blocked install always says on stderr and in the log, dialog or not.
check_reason() {  # $1 = case dir, $2 = block|restart
    local first="Symphony Maestro was not installed: Apogee's original Symphony I/O drivers were detected, and running both can crash your Mac and make it restart repeatedly."
    if [ "$2" = restart ]; then
        first="Symphony Maestro was not installed: one of Apogee's original Symphony I/O drivers is still loaded. Restart your Mac, then run this installer again."
    fi
    [ "$(cat "$1/stderr")" = "$first
How to fix this: $GUIDE_URL" ] || fail "stderr of a blocked install: $(cat "$1/stderr")"
    grep -qF "[preinstall] $first" "$1/log" || fail "the reason is not in the log: $(cat "$1/log")"
    grep -qF "[preinstall] How to fix this: $GUIDE_URL" "$1/log" || fail "the fix address is not in the log"
}

C="$WORK/g-update-loaded"
mkbundle "$C/root/Library/Extensions/Symphony64Thunderbridge.kext"
[ "$(gate "$C" "$OURS" "$TB_LOADED")" = blocked ] || fail "update with Apogee's ThunderBridge kext loaded was not blocked"
check_block_text "$C/dialog.txt" update
check_reason "$C" block
grep -q "BLOCKED (update)" "$C/log" || fail "update block not logged: $(cat "$C/log")"
ok "preinstall: an update is blocked while Apogee's ThunderBridge kext is loaded, and says why an update was stopped"

C="$WORK/g-update-loaded-only"
[ "$(gate "$C" "$OURS" "  191  0 0 0 0 com.apogeedigital.driver.Symphony64 (1.5) ABC <8 6>")" = blocked ] \
    || fail "update with the PCIe kext loaded and its file gone was not blocked"
check_dialog_text "$C/dialog.txt" update restart
check_reason "$C" restart
# Still loaded and still in the auxiliary collection after Apogee's Uninstall.
C="$WORK/g-update-loaded-aux"
mkdir -p "$C/root/Library/KernelCollections"; touch "$C/root/Library/KernelCollections/AuxiliaryKernelExtensions.kc"
printf '%s\n' "com.apogeedigital.driver.Symphony64ThunderBridge (1.5)" > "$C/aux.txt"
[ "$(gate "$C" "$OURS" "$TB_LOADED")" = blocked ] || fail "update, loaded and in the auxiliary collection, was not blocked"
check_dialog_text "$C/dialog.txt" update restart
C="$WORK/g-fresh-loaded-aux"
mkdir -p "$C/root/Library/KernelCollections"; touch "$C/root/Library/KernelCollections/AuxiliaryKernelExtensions.kc"
printf '%s\n' "com.apogeedigital.driver.Symphony64ThunderBridge (1.5)" > "$C/aux.txt"
[ "$(gate "$C" "" "$TB_LOADED")" = blocked ] || fail "first install, loaded and in the auxiliary collection, was not blocked"
check_dialog_text "$C/dialog.txt" install restart
ok "preinstall: a kext still loaded with its file gone, with or without an auxiliary-collection entry, is asked to restart"

for WHERE in "Library/Extensions/Symphony64.kext" "System/Library/Extensions/Symphony64Thunderbridge.kext"; do
    C="$WORK/g-update-$(echo "$WHERE" | tr '/ ' '__')"
    mkbundle "$C/root/$WHERE"
    [ "$(gate "$C" "$OURS" "$OURS_LOADED")" = blocked ] || fail "update with $WHERE (not loaded) was not blocked"
    check_block_text "$C/dialog.txt" update
done
ok "preinstall: an update is blocked by a ThunderBridge or PCIe kext in an Extensions folder, not loaded"

# A copy only macOS keeps does not stop an update: Apogee's uninstaller would
# not remove it, and would remove Maestro. The app's warning covers it.
C="$WORK/g-update-staged"
mkbundle "$C/root/Library/StagedExtensions/Library/Extensions/Symphony64Thunderbridge.kext"
[ "$(gate "$C" "$OURS" "$OURS_LOADED")" = proceeds ] || fail "update blocked by a staged copy alone: $(cat "$C/log")"
[ ! -e "$C/dialog.txt" ] || fail "a dialog was shown for an update over a staged copy"
[ ! -s "$C/stderr" ] || fail "an update that goes ahead wrote to stderr: $(cat "$C/stderr")"
grep -q "Found original Apogee driver: Kernel extension (copy kept by macOS)" "$C/log" || fail "staged copy not logged"
grep -q "only in a copy macOS keeps .*Updating\. Device Settings warns about a staged copy; it does not show one that is only in the auxiliary kernel collection" "$C/log" || fail "staged-only update not explained in the log: $(cat "$C/log")"
C="$WORK/g-update-aux"
mkdir -p "$C/root/Library/KernelCollections"; touch "$C/root/Library/KernelCollections/AuxiliaryKernelExtensions.kc"
printf '%s\n' "com.example.other (1.0)" "com.apogeedigital.driver.Symphony64ThunderBridge (1.5)" > "$C/aux.txt"
[ "$(gate "$C" "$OURS" "$OURS_LOADED")" = proceeds ] || fail "update blocked by the auxiliary collection alone"
[ ! -e "$C/dialog.txt" ] || fail "a dialog was shown for an update over an auxiliary-collection entry"
grep -q "auxiliary kernel collection): com.apogeedigital.driver.Symphony64ThunderBridge" "$C/log" \
    || fail "auxiliary collection finding not logged: $(cat "$C/log")"
ok "preinstall: an update goes ahead over a copy that is only staged or only in the auxiliary kernel collection, and logs it"

# A first install is still stopped by such a copy, but is not sent to Apogee's
# uninstaller: straight to the removal guide and the user-reported steps.
C="$WORK/g-fresh-staged"
mkbundle "$C/root/Library/StagedExtensions/Library/Extensions/Symphony64Thunderbridge.kext"
[ "$(gate "$C" "" "$OURS_LOADED")" = blocked ] || fail "first install with a staged copy was not blocked"
check_dialog_text "$C/dialog.txt" install guide
grep -q "Uninstall" "$C/dialog.txt" && fail "a staged-only first install is sent to Apogee's Uninstall"
check_reason "$C" block
C="$WORK/g-fresh-aux"
mkdir -p "$C/root/Library/KernelCollections"; touch "$C/root/Library/KernelCollections/AuxiliaryKernelExtensions.kc"
printf '%s\n' "com.apogeedigital.driver.Symphony64 (1.5)" > "$C/aux.txt"
[ "$(gate "$C" "" "$OURS_LOADED")" = blocked ] || fail "first install with an auxiliary-collection entry was not blocked"
check_dialog_text "$C/dialog.txt" install guide
# Loaded from a staged copy, on an update: stopped, and the guide again.
C="$WORK/g-update-loaded-staged"
mkbundle "$C/root/Library/StagedExtensions/Library/Extensions/Symphony64Thunderbridge.kext"
[ "$(gate "$C" "$OURS" "$TB_LOADED")" = blocked ] || fail "update, loaded with a staged copy, was not blocked"
check_dialog_text "$C/dialog.txt" update guide
ok "preinstall: when only a copy macOS keeps is left, the dialog leads with the removal guide, not Apogee's uninstaller"

# Leftovers that cannot put a second driver on the card: an update goes ahead.
C="$WORK/g-update-leftovers"
mkdir -p "$C/root/Library/LaunchDaemons" "$C/root/Library/Application Support/Apogee" "$C/root/Library/Audio/Plug-Ins/HAL/Apogee"
touch "$C/root/Library/LaunchDaemons/com.SymphonyDaemon.plist" "$C/root/Library/LaunchDaemons/com.SymphonyIOUSBDaemon.plist" \
    "$C/root/Library/LaunchDaemons/com.apogee.other.plist"
mkbundle "$C/root/$HAL_DIR/SymphonyPlugin.bundle"
mkbundle "$C/root/$HAL_DIR/SymphonyIOUSBPlugIn.bundle"
mkbundle "$C/root/Library/Extensions/SymphonyIOUSBOverideDriver.kext"
mkbundle "$C/root/Library/Extensions/SymphonyMobile.kext"
[ "$(gate "$C" "$OURS" "$OURS_LOADED
    5 0 0 0 0 com.apogee.driver.ApogeeUSBSymphonyIOAudio (1.0)")" = proceeds ] \
    || fail "update blocked by launch daemons, the HAL folder, Application Support or USB-only parts: $(cat "$C/log")"
[ ! -e "$C/dialog.txt" ] || fail "a dialog was shown for an update that goes ahead"
[ "$(grep -c "Found original Apogee driver" "$C/log")" = 7 ] || fail "leftovers not all logged: $(cat "$C/log")"
ok "preinstall: an update goes ahead with only launch daemons, HAL plug-ins, Application Support or USB-only parts"

# A first install is as before: anything found blocks; no update sentence.
C="$WORK/g-fresh-leftovers"
mkdir -p "$C/root/Library/LaunchDaemons"; touch "$C/root/Library/LaunchDaemons/com.SymphonyDaemon.plist"
[ "$(gate "$C" "" "$OURS_LOADED")" = blocked ] || fail "first install with a Symphony launch daemon was not blocked"
check_block_text "$C/dialog.txt" install
C="$WORK/g-fresh-kext"
mkbundle "$C/root/Library/Extensions/Symphony64Thunderbridge.kext"
[ "$(gate "$C" "" "$TB_LOADED")" = blocked ] || fail "first install with the kext loaded was not blocked"
check_block_text "$C/dialog.txt" install
grep -q "BLOCKED (install)" "$C/log" || fail "first-install block not logged"
C="$WORK/g-fresh-restart"
[ "$(gate "$C" "" "$TB_LOADED")" = blocked ] || fail "first install with a loaded kext was not stopped"
check_dialog_text "$C/dialog.txt" install restart
C="$WORK/g-fresh-clear"
[ "$(gate "$C" "" "$OURS_LOADED")" = proceeds ] || fail "first install with nothing found was blocked"
[ ! -s "$C/stderr" ] || fail "a clear install wrote to stderr"
C="$WORK/g-update-clear"
[ "$(gate "$C" "$OURS" "$OURS_LOADED")" = proceeds ] || fail "update with nothing found was blocked"
ok "preinstall: a first install is blocked as before, without the update sentence; nothing found goes ahead"

# The dialog cannot hold an unattended install: it gives up by itself, and with
# no one at the console, or osascript failing, there is none. The install fails
# every time, and stderr and the log say why.
C="$WORK/g-dialog-gives-up"
mkbundle "$C/root/Library/Extensions/Symphony64Thunderbridge.kext"
[ "$(gate "$C" "$OURS" "$TB_LOADED")" = blocked ] || fail "blocked update did not fail"
grep -q 'buttons {"Open Removal Guide", "OK"} default button "OK" .* giving up after 300$' "$C/osascript-args.txt" \
    || fail "the dialog has no give-up time: $(cat "$C/osascript-args.txt")"
C="$WORK/g-dialog-gave-up"
mkbundle "$C/root/Library/Extensions/Symphony64Thunderbridge.kext"
[ "$(GATE_OSASCRIPT="echo 'button returned:, gave up:true'" gate "$C" "$OURS" "$TB_LOADED")" = blocked ] \
    || fail "a dialog that gave up did not fail the install"
grep -q "Opened the removal guide" "$C/log" && fail "a dialog that gave up opened the guide"
check_reason "$C" block
C="$WORK/g-dialog-no-console"
mkbundle "$C/root/Library/Extensions/Symphony64Thunderbridge.kext"
[ "$(GATE_CONSOLE_USER=root gate "$C" "$OURS" "$TB_LOADED")" = blocked ] || fail "blocked update with no console user did not fail"
[ ! -e "$C/dialog.txt" ] || fail "a dialog was shown with no one at the console"
grep -q "No one is logged in at the console: no dialog shown" "$C/log" || fail "the skipped dialog is not logged"
check_reason "$C" block
C="$WORK/g-dialog-osascript-fails"
mkbundle "$C/root/Library/Extensions/Symphony64Thunderbridge.kext"
[ "$(GATE_OSASCRIPT="exit 1" gate "$C" "" "$TB_LOADED")" = blocked ] || fail "a failing osascript let the install through"
check_reason "$C" block
ok "preinstall: the dialog gives up after 300 s, is skipped with no console user, and the install fails with the reason on stderr and in the log either way"

# Detection that fails is not a finding: log it and go ahead.
C="$WORK/g-detect-fail"
[ "$(gate "$C" "$OURS" "$TB_LOADED" fail)" = proceeds ] || fail "update blocked when kmutil and kextstat both failed"
grep -q "Could not check: the loaded kernel extensions" "$C/log" || fail "failed detection not logged: $(cat "$C/log")"
C="$WORK/g-detect-fail-fresh"
[ "$(gate "$C" "" "" fail)" = proceeds ] || fail "first install blocked when kmutil and kextstat both failed"
C="$WORK/g-detect-fail-aux"
mkdir -p "$C/root/Library/KernelCollections"; touch "$C/root/Library/KernelCollections/AuxiliaryKernelExtensions.kc"
[ "$(gate "$C" "$OURS" "$OURS_LOADED")" = proceeds ] || fail "update blocked when the auxiliary collection could not be read"
grep -q "Could not check: the auxiliary kernel collection" "$C/log" || fail "unreadable collection not logged: $(cat "$C/log")"
[ ! -e "$C/dialog.txt" ] || fail "a dialog was shown for a failed detection"
ok "preinstall: detection that fails (kmutil and kextstat, or an unreadable collection) is logged and does not block"

# A probe that never answers is given up on after a few seconds (1 s here), and
# is "could not check": kmutil showloaded, kextstat and kmutil inspect alike.
C="$WORK/g-detect-hang"
mkdir -p "$C/root/Library/KernelCollections"; touch "$C/root/Library/KernelCollections/AuxiliaryKernelExtensions.kc"
STARTED=$SECONDS
[ "$(gate "$C" "$OURS" "$TB_LOADED" hang)" = proceeds ] || fail "a kmutil that never answers blocked or failed the install"
[ $((SECONDS - STARTED)) -le 8 ] || fail "a kmutil that never answers held the install for $((SECONDS - STARTED)) s"
grep -q "Could not check: the loaded kernel extensions" "$C/log" || fail "a hung kmutil showloaded is not logged: $(cat "$C/log")"
grep -q "Could not check: the auxiliary kernel collection" "$C/log" || fail "a hung kmutil inspect is not logged: $(cat "$C/log")"
(
    # shellcheck source=/dev/null
    . "$PRE"
    mkstub "$C/slow" "exec sleep 20"
    mkstub "$C/kextstat" "echo '  5 0 0 0 0 com.apogeedigital.driver.Symphony64 (1.5)'"
    STARTED=$SECONDS
    OUT="$(MAESTRO_PREINSTALL_TEST=1 PROBE_TIMEOUT=1 KMUTIL="$C/slow" KEXTSTAT="$C/kextstat" loaded_apogee_pcie_kexts)" \
        || fail "kextstat was not asked after kmutil timed out"
    [ "$OUT" = "com.apogeedigital.driver.Symphony64" ] || fail "kextstat after a kmutil timeout: $OUT"
    MAESTRO_PREINSTALL_TEST=1 PROBE_TIMEOUT=1 KMUTIL="$C/slow" KEXTSTAT="$C/slow" loaded_apogee_pcie_kexts >/dev/null \
        && fail "two probes that never answer were reported as checked"
    [ $((SECONDS - STARTED)) -le 8 ] || fail "the probes' deadline was not kept"
    # No probe is run without the deadline: every use of kmutil or kextstat is
    # the command of a run_with_timeout, on its line or the continued one before.
    BARE="$(awk '/test_override (KMUTIL|KEXTSTAT) / && !/run_with_timeout/ && !(prev ~ /run_with_timeout.*\\$/) { print NR": "$0 } { prev = $0 }' "$PRE")"
    [ -z "$BARE" ] || fail "a kmutil or kextstat call in the preinstall has no deadline: $BARE"
    [ "$(grep -c 'test_override KMUTIL ' "$PRE")" = 2 ] && [ "$(grep -c 'test_override KEXTSTAT ' "$PRE")" = 1 ] \
        || fail "the preinstall's probes are not the three expected"
    if grep -v 'test_override' "$PRE" | grep -v '^ *#' | grep -Eq '(/usr/bin/kmutil|/usr/sbin/kextstat)'; then
        fail "kmutil or kextstat is called outside test_override"
    fi
) || exit 1
ok "preinstall: kmutil showloaded, kextstat and kmutil inspect each have a deadline; none answering is 'could not check'"

# A long listing (over the 64 KB a pipe holds) with the match near the top:
# `printf | grep -q` under pipefail reported that as no match.
C="$WORK/g-long-listing"
mkdir -p "$C/root"
{
    echo "    1  0 0 0 0 com.apogeedigital.driver.Symphony64ThunderBridge (1.5) ABC <8 6 5 3 2 1>"
    i=0
    while [ "$i" -lt 2500 ]; do
        echo "  $((i + 2))  0 0xfffffe0000000000 0x4000 0x4000 com.example.driver.padding$i (1.0.0) 00000000-0000-0000-0000-000000000000 <8 6 5 3 2 1>"
        i=$((i + 1))
    done
} > "$C/long.txt"
[ "$(wc -c < "$C/long.txt")" -gt 200000 ] || fail "the long listing is not long"
mkstub "$C/kmutil" "cat '$C/long.txt'"
I=0
while [ "$I" -lt 20 ]; do   # the old pipe lost the race only some of the time
    OUT="$(. "$PRE"; MAESTRO_PREINSTALL_TEST=1 APOGEE_ROOT="$C/root" KMUTIL="$C/kmutil" KEXTSTAT=/usr/bin/false find_original_apogee)"
    [ "$OUT" = "Loaded kernel extension: com.apogeedigital.driver.Symphony64ThunderBridge" ] \
        || fail "a loaded kext early in a long listing was missed (run $I): $OUT"
    I=$((I + 1))
done
grep -n 'printf .*| *grep' "$PRE" | grep -v '^[0-9]*: *#' | grep -q . && fail "the preinstall pipes into grep again"
ok "preinstall: a loaded kext is found early in a listing longer than a pipe holds (here-string, not a pipe)"

# The overrides the tests use do nothing without MAESTRO_PREINSTALL_TEST=1.
C="$WORK/g-seam"
mkbundle "$C/root/Library/Extensions/Symphony64Thunderbridge.kext"
mkstub "$C/kmutil" "echo '  190  0 0 0 0 com.apogeedigital.driver.Symphony64ThunderBridge (1.5)'"
(
    # shellcheck source=/dev/null
    . "$PRE"
    for NAME in APOGEE_ROOT KMUTIL KEXTSTAT PLISTBUDDY OSASCRIPT CONSOLE_USER PROBE_TIMEOUT; do
        [ "$(env "$NAME=/tmp/override" bash -c ". '$PRE'; test_override $NAME real")" = real ] \
            || fail "$NAME is honoured without MAESTRO_PREINSTALL_TEST"
        [ "$(env MAESTRO_PREINSTALL_TEST=1 "$NAME=/tmp/override" bash -c ". '$PRE'; test_override $NAME real")" = /tmp/override ] \
            || fail "$NAME is not honoured with MAESTRO_PREINSTALL_TEST=1"
    done
    # Unguarded, the fake root's kext and the fake kmutil's loaded kext are not seen.
    OUT="$(APOGEE_ROOT="$C/root" KMUTIL="$C/kmutil" KEXTSTAT="$C/kmutil" find_original_apogee 2>/dev/null)"
    case "$OUT" in *"$C/root"*) fail "APOGEE_ROOT honoured without the guard: $OUT" ;; esac
    OUT="$(MAESTRO_PREINSTALL_TEST=1 APOGEE_ROOT="$C/root" KMUTIL="$C/kmutil" KEXTSTAT="$C/kmutil" find_original_apogee)"
    case "$OUT" in *"$C/root/Library/Extensions/Symphony64Thunderbridge.kext"*"Loaded kernel extension"*) ;; *) fail "guarded overrides not used: $OUT" ;; esac
    # Every override is read through test_override, never straight from the environment.
    if grep -nE '\$\{?(APOGEE_ROOT|KMUTIL|KEXTSTAT|PLISTBUDDY|OSASCRIPT|CONSOLE_USER|PROBE_TIMEOUT|SYSTEMEXTENSIONSCTL)\b' "$PRE" "$REPO_ROOT/Installer/uninstall.sh" | grep -q .; then
        fail "an override variable is read without test_override"
    fi
) || exit 1
ok "preinstall: APOGEE_ROOT, KMUTIL, KEXTSTAT, PLISTBUDDY, OSASCRIPT and the rest are honoured only with MAESTRO_PREINSTALL_TEST=1"

# ── Uninstall: never stop Maestro's driver next to Apogee's loaded one ──────
UNINSTALL="$REPO_ROOT/Installer/uninstall.sh"
kext_block() { sed -n '/^# >>> apogee-kext-check$/,/^# <<< apogee-kext-check$/p' "$1"; }
[ -n "$(kext_block "$PRE")" ] || fail "the preinstall has no apogee-kext-check block"
[ "$(kext_block "$PRE")" = "$(kext_block "$UNINSTALL")" ] \
    || fail "Installer/uninstall.sh and the preinstall carry different apogee-kext-check blocks"
# $1 = case dir, $2 = what kmutil prints, $3 = what systemextensionsctl list
# prints. Prints "refused" or "goes ahead"; the explanation lands in $1/out.
uninstall_check() {
    local dir="$1"
    mkdir -p "$dir"
    printf '%s\n' "$2" > "$dir/loaded.txt"
    printf '%s\n' "$3" > "$dir/sysext.txt"
    mkstub "$dir/kmutil" "cat '$dir/loaded.txt'"
    mkstub "$dir/systemextensionsctl" "cat '$dir/sysext.txt'"
    (
        # shellcheck source=/dev/null
        . "$UNINSTALL"
        if MAESTRO_PREINSTALL_TEST=1 KMUTIL="$dir/kmutil" KEXTSTAT=/usr/bin/false PROBE_TIMEOUT=1 \
            SYSTEMEXTENSIONSCTL="$dir/systemextensionsctl" uninstall_blocked_by_apogee_driver > "$dir/out"; then
            echo refused
        else
            echo "goes ahead"
        fi
    )
}
SYSEXT_OURS="1 extension(s)
--- com.apple.system_extension.driver_extension
enabled	active	teamID	bundleID (version)	name	[state]
*	*	ABCDE12345	com.danielraffel.maestro.thunderbridge (0.11.17/143)	Symphony Thunderbridge	[activated enabled]"
C="$WORK/u-both"
[ "$(uninstall_check "$C" "$TB_LOADED" "$SYSEXT_OURS")" = refused ] || fail "uninstall goes ahead with both drivers running"
grep -q "Symphony Maestro was not removed, and nothing was changed." "$C/out" || fail "uninstall refusal: $(cat "$C/out")"
grep -q "Shut down your Mac and disconnect the ThunderBridge or PCIe chassis" "$C/out" || fail "uninstall refusal lacks the safe sequence"
grep -qF "$GUIDE_URL" "$C/out" || fail "uninstall refusal lacks the guide"
grep -q "Shut down your Mac and disconnect the ThunderBridge or PCIe chassis, then start up again" "$REPO_ROOT/docs/UserManual.md" \
    || fail "the user guide no longer gives the sequence the uninstall refusal uses"
[ "$(uninstall_check "$WORK/u-pcie" "  191  0 0 0 0 com.apogeedigital.driver.Symphony64 (1.5)" "$SYSEXT_OURS")" = refused ] \
    || fail "uninstall goes ahead with Apogee's PCIe kext loaded"
[ "$(uninstall_check "$WORK/u-ours-only" "$OURS_LOADED" "$SYSEXT_OURS")" = "goes ahead" ] || fail "uninstall refused with no Apogee kext loaded"
[ "$(uninstall_check "$WORK/u-no-dext" "$TB_LOADED" "0 extension(s)")" = "goes ahead" ] \
    || fail "uninstall refused although Maestro's driver is not registered"
[ "$(uninstall_check "$WORK/u-usb-kext" "    5 0 0 0 0 com.apogee.driver.ApogeeUSBSymphonyIOAudio (1.0)" "$SYSEXT_OURS")" = "goes ahead" ] \
    || fail "uninstall refused for the USB override kext"
# The check comes before the confirmation and before anything is stopped or removed.
CHECK_LINE="$(grep -n '^if uninstall_blocked_by_apogee_driver; then$' "$UNINSTALL" | cut -d: -f1)"
[ -n "$CHECK_LINE" ] || fail "uninstall.sh does not make the check"
for PATTERN in 'read -p "Proceed with uninstall' 'pkill -x MaestroApp' 'if ! deactivate_maestro_driver; then' 'rm -rf "\$APP"' 'launchctl bootout'; do
    FIRST="$(grep -n -- "$PATTERN" "$UNINSTALL" | head -1 | cut -d: -f1)"
    [ -n "$FIRST" ] && [ "$CHECK_LINE" -lt "$FIRST" ] || fail "uninstall.sh reaches '$PATTERN' before the Apogee driver check"
done
# The app must still exist at step 7, and receipts are forgotten at the end.
DRIVER_LINE="$(grep -n '^    if ! deactivate_maestro_driver; then$' "$UNINSTALL" | cut -d: -f1)"
APP_LINE="$(grep -n 'rm -rf "\$APP"' "$UNINSTALL" | cut -d: -f1)"
RECEIPTS_LINE="$(grep -n '^forget_maestro_receipts$' "$UNINSTALL" | cut -d: -f1)"
RESTART_LINE="$(grep -n '^killall coreaudiod' "$UNINSTALL" | cut -d: -f1)"
[ -n "$DRIVER_LINE" ] && [ -n "$APP_LINE" ] && [ -n "$RESTART_LINE" ] && [ -n "$RECEIPTS_LINE" ] \
    && [ "$DRIVER_LINE" -lt "$APP_LINE" ] && [ "$APP_LINE" -lt "$RESTART_LINE" ] \
    && [ "$RESTART_LINE" -lt "$RECEIPTS_LINE" ] \
    || fail "uninstall: driver removal, app removal, audio restart and receipt cleanup are out of order"
ok "uninstall: requests deactivation before removing the app and forgets receipts after the audio restart"
ok "uninstall: refuses, changing nothing, while Apogee's ThunderBridge or PCIe kext is loaded and Maestro's driver is registered"

# A driver extension macOS has already terminated is not on the card: it does
# not count as registered (the app leaves out isUninstalling in the same way).
SYSEXT_HEAD="1 extension(s)
--- com.apple.system_extension.driver_extension
enabled	active	teamID	bundleID (version)	name	[state]"
SYSEXT_GOING="$SYSEXT_HEAD
	*	ABCDE12345	com.danielraffel.maestro.thunderbridge (0.11.17/143)	Symphony Thunderbridge	[terminated waiting to uninstall on reboot]"
SYSEXT_WAITING="$SYSEXT_HEAD
	*	ABCDE12345	com.danielraffel.maestro.thunderbridge (0.11.17/143)	Symphony Thunderbridge	[activated waiting for user]"
SYSEXT_OTHER="$SYSEXT_HEAD
*	*	ABCDE12345	com.example.other (1.0/1)	Other	[activated enabled]"
[ "$(uninstall_check "$WORK/u-going" "$TB_LOADED" "$SYSEXT_GOING")" = "goes ahead" ] \
    || fail "uninstall refused for a driver extension that is already terminated and waiting to uninstall"
[ "$(uninstall_check "$WORK/u-going-and-ours" "$TB_LOADED" "$SYSEXT_GOING
*	*	ABCDE12345	com.danielraffel.maestro.thunderbridge (0.11.17/143)	Symphony Thunderbridge	[activated enabled]")" = refused ] \
    || fail "uninstall goes ahead with an activated driver extension listed after a terminated one"
[ "$(uninstall_check "$WORK/u-waiting" "$TB_LOADED" "$SYSEXT_WAITING")" = refused ] \
    || fail "uninstall goes ahead with an activated driver extension that waits for approval"
[ "$(uninstall_check "$WORK/u-other" "$TB_LOADED" "$SYSEXT_OTHER")" = "goes ahead" ] \
    || fail "uninstall refused for another vendor's activated extension"
ok "uninstall: a driver extension already terminated and waiting to uninstall is not counted as registered"

# Load only step 7 in a subshell. Its registration check and launch command
# are stubs, so the test can never start Maestro or reach app removal.
run_uninstall_driver_step() (
    local registered="$1" status="$2"
    . "$UNINSTALL"
    maestro_dext_registered() { [ "$registered" = yes ]; }
    deactivate_maestro_driver() { echo "stub: requested deactivation"; return "$status"; }
    eval "$(sed -n '/^# .*7\. Deactivate/,/^# .*8\. Remove app/p' "$UNINSTALL")"
    eval "$(sed -n '/^if \[ "\${DEXT_NEEDS_MANUAL:-0}" -eq 1 \]; then$/,/^fi$/p' "$UNINSTALL")"
    echo "manual=$DEXT_NEEDS_MANUAL"
)
# Receipt cleanup only sees this stub. The two identifiers must match both
# component package builds and the distribution, even on a USB-free install.
run_receipt_cleanup() (
    . "$UNINSTALL"
    pkgutil() {
        case "$1" in
            --pkg-info) return 0 ;;
            --forget) echo "$2" ;;
            *) return 1 ;;
        esac
    }
    forget_maestro_receipts
)
EXPECTED_RECEIPTS="$(sed -n 's/.*--identifier "\(com\.generouscorp\.maestro\.[^"]*\)".*/\1/p' "$REPO_ROOT/Installer/build-installer.sh")"
# Every identifier the current build writes is forgotten (older builds' ids
# may follow; they are forgotten too).
FORGOTTEN="$(run_receipt_cleanup)"
[ -n "$EXPECTED_RECEIPTS" ] || fail "uninstall: no package identifiers found in build-installer.sh"
for id in $EXPECTED_RECEIPTS; do
    printf '%s\n' "$FORGOTTEN" | grep -qx "$id" || fail "uninstall: did not forget the receipt $id"
done
printf '%s\n' "$FORGOTTEN" | grep -qx "com.danielraffel.maestro" \
    || fail "uninstall: did not forget the 0.8.x receipt com.danielraffel.maestro"
while IFS= read -r RECEIPT; do
    grep -qF "<pkg-ref id=\"$RECEIPT\"" "$REPO_ROOT/Installer/distribution.xml" \
        || fail "uninstall: receipt $RECEIPT is missing from the distribution"
done <<< "$EXPECTED_RECEIPTS"
ok "uninstall: forgets the package receipts from the installer distribution"

OUT="$(run_uninstall_driver_step yes 0)"
[[ "$OUT" == *"stub: requested deactivation"* && "$OUT" == *"manual=0"* && "$OUT" != *"System Settings"* ]] \
    || fail "uninstall: successful deactivation should skip manual instructions: $OUT"
OUT="$(run_uninstall_driver_step yes 1)"
[[ "$OUT" == *"stub: requested deactivation"* && "$OUT" == *"manual=1"* && "$OUT" == *"Driver Extensions"* ]] \
    || fail "uninstall: failed deactivation should print manual instructions: $OUT"
OUT="$(run_uninstall_driver_step no 0)"
[[ "$OUT" != *"stub: requested deactivation"* && "$OUT" == *"manual=0"* ]] \
    || fail "uninstall: requested deactivation without a registered driver: $OUT"
ok "uninstall: requests deactivation only for a registered driver and gives manual instructions on failure"

# Check the actual command with a scratch app and a fake GUI session. The
# fake executable is never started: launchctl only reports its arguments.
run_driver_launch() (
    . "$UNINSTALL"
    APP="$WORK/$1/Maestro.app"
    mkdir -p "$APP/Contents/MacOS"
    cp "$REPO_ROOT/Apps/Maestro/MaestroApp/Resources/Info.plist" "$APP/Contents/Info.plist"
    mkstub "$APP/Contents/MacOS/MaestroApp" 'echo "unexpected start" >&2; exit 1'
    if [ "$1" = older ]; then
        /usr/libexec/PlistBuddy -c 'Delete :MaestroSupportsDriverDeactivation' "$APP/Contents/Info.plist"
    fi
    # The mocks check the actual user path even if a different user ran sudo.
    local console="$2"
    stat() { [ "$*" = '-f %Su /dev/console' ] && echo "$console"; }
    id() {
        case "$*" in
            '-u console-owner') echo 502 ;;
            '-u root') echo 0 ;;
            *) return 1 ;;
        esac
    }
    launchctl() { printf 'launchctl:%s\n' "$*"; }
    export SUDO_USER=ssh-user
    deactivate_maestro_driver
)
OUT="$(run_driver_launch current console-owner)"
[ "$OUT" = "launchctl:asuser 502 /usr/bin/sudo -n -u console-owner -- $WORK/current/Maestro.app/Contents/MacOS/MaestroApp --deactivate-driver" ] \
    || fail "uninstall: did not run the headless command in the console user's GUI session: $OUT"
if OUT="$(run_driver_launch older console-owner)" || [[ "$OUT" == *"launchctl:"* ]]; then
    fail "uninstall: attempted to start a Maestro app without the headless command: $OUT"
fi
if OUT="$(run_driver_launch at-login root)" || [[ "$OUT" == *"launchctl:"* ]]; then
    fail "uninstall: attempted to start the app with no signed-in console user: $OUT"
fi
ok "uninstall: launches as the console user and skips the launch with an older app or no GUI user"

echo "Installer tool tests passed ($PASS)"
