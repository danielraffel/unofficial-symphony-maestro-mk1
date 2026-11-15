# shellcheck shell=bash
# Package-building helpers shared by Installer/build-installer.sh and
# Tools/test-installer-tools.sh. Sourced, never run. No signing identity needed.

# Removes a scratch directory this script made with mktemp, and nothing else:
# the path must be one mktemp returned under $TMPDIR (or /tmp). No rm -rf.
remove_scratch() {  # $1 = directory from mktemp -d
    local dir="$1" base="${TMPDIR:-/tmp}"
    dir="$(printf '%s' "$dir" | /usr/bin/tr -s /)"
    base="${base%/}"
    case "$dir" in
        "$base"/maestro-*.??????|/tmp/maestro-*.??????|/private/tmp/maestro-*.??????) ;;
        *) echo "remove_scratch: refusing to remove $dir" >&2; return 1 ;;
    esac
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
    /usr/bin/find "$dir" -depth -delete
}

# Writes the component plist for a payload root with every top-level bundle
# non-relocatable and not version-checked.
#
# BundleIsRelocatable: without this, pkgbuild treats .app bundles as
# relocatable and macOS Installer moves Maestro.app to wherever LaunchServices
# last saw a copy with the same bundle ID, instead of /Applications.
#
# BundleIsVersionChecked: pkgbuild defaults it to true ("Don't install bundle
# if newer version on disk"). Going back to stable installs an older Maestro
# over a newer one, so from 0.8.40 on the package always replaces the app.
#
# Do not count "BundleOverwriteAction" occurrences to size a loop: the embedded dext appears
# as a ChildBundles entry inside Maestro.app and carries its own, so the count overshoots the
# array length and PlistBuddy silently appends a junk dict with no RootRelativeBundlePath,
# which pkgbuild then rejects. Edit the array directly.
make_component_plist() {  # $1 = payload root, $2 = output plist
    pkgbuild --analyze --root "$1" "$2" >/dev/null
    python3 - "$2" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as f:
    comps = plistlib.load(f)
for c in comps:
    c['BundleIsRelocatable'] = False
    c['BundleIsVersionChecked'] = False
    print(f"    non-relocatable, not version-checked: {c.get('RootRelativeBundlePath', '<no path>')}")
    for child in c.get('ChildBundles', []):
        print(f"        child: {child.get('RootRelativeBundlePath', '<no path>')}")
with open(path, 'wb') as f:
    plistlib.dump(comps, f)
PY
}

# Fails unless the component package's PackageInfo lists no version-checked
# bundle (`<bundle-version/>` or an empty element).
check_not_version_checked() {  # $1 = component .pkg
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/maestro-pkginfo.XXXXXX")"
    /bin/rmdir "$dir"
    pkgutil --expand "$1" "$dir" >/dev/null
    if ! python3 - "$dir/PackageInfo" <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
elements = root.findall('bundle-version')
checked = [b.get('id') for e in elements for b in e.findall('bundle')]
if checked:
    print(f"ERROR: {sys.argv[1]} still version-checks: {', '.join(checked)}", file=sys.stderr)
    sys.exit(1)
PY
    then
        remove_scratch "$dir"
        return 1
    fi
    remove_scratch "$dir"
    echo "    not version-checked: $(basename "$1")"
}

# Prints the CDHash `codesign` reports for a signed bundle or binary.
code_cdhash() {  # $1 = path
    codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=\([0-9a-f]*\)$/\1/p' | head -1
}

# The driver gate: one driver build number per CDHash, for ever. Fails with
# both hashes printed when the signed driver differs from the recorded one.
# With no recorded hash (the first build of a new driver number) it prints the
# measured hash so it can be recorded in Tools/versions.json.
check_dext_cdhash() {  # $1 = signed dext bundle, $2 = expected CDHash (may be empty), $3 = build number
    local actual
    actual="$(code_cdhash "$1")"
    if [ -z "$actual" ]; then
        echo "ERROR: could not read the CDHash of $1" >&2
        return 1
    fi
    if [ -z "$2" ]; then
        echo "    driver $3 CDHash $actual (no dextCDHash recorded yet: record it in Tools/versions.json)"
        return 0
    fi
    if [ "$actual" != "$2" ]; then
        echo "ERROR: driver build $3 has CDHash $actual, but Tools/versions.json records $2." >&2
        echo "       The driver code changed. Do not edit the recorded hash: give the driver a new" >&2
        echo "       dextBuild and record its CDHash (and test the driver on hardware again)." >&2
        return 1
    fi
    echo "    driver $3 CDHash matches $actual"
}
