#!/bin/bash
# build-installer.sh — Build, sign, notarize, and staple the Symphony Maestro .pkg installer.
#
# Usage:
#   ./Installer/build-installer.sh                    # full pipeline
#   ./Installer/build-installer.sh --skip-notarize    # build + sign only (faster for testing)
#   ./Installer/build-installer.sh --skip-build       # package only (reuse existing builds)
#
# Prerequisites:
#   - Developer ID Application cert in keychain (for signing binaries)
#   - Developer ID Installer cert in keychain (for signing .pkg)
#   - External App Store Connect API key or notarytool Keychain profile
#   - Xcode command line tools
#
# Configuration: copy .env.example to an external mode-600 file and pass
# MAESTRO_ENV_FILE=/absolute/path/to/config.env. See docs/BUILDING.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

. "$REPO_ROOT/Tools/lib/build-config.sh"

BUILD_DIR="$SCRIPT_DIR/build"
PAYLOAD_DIR="$BUILD_DIR/payload"
OUTPUT_DIR="$BUILD_DIR/output"
# Read version from MaestroCore.swift (single source of truth)
DEFAULT_VERSION=$(grep -o '"[0-9]*\.[0-9]*\.[0-9]*"' "$REPO_ROOT/Apps/Maestro/MaestroCore/MaestroCore.swift" | tr -d '"' || echo "0.0.0")
VERSION="${VERSION:-$DEFAULT_VERSION}"

SKIP_BUILD=false
SKIP_NOTARIZE=false

for arg in "$@"; do
    case "$arg" in
        --skip-build)    SKIP_BUILD=true ;;
        --skip-notarize) SKIP_NOTARIZE=true ;;
        --help|-h)
            echo "Usage: $0 [--skip-build] [--skip-notarize]"
            exit 0
            ;;
    esac
done

python3 "$REPO_ROOT/Tools/check-versions.py"

# ── Keychain search list ────────────────────────────────────────────────────
# Must run BEFORE identity auto-detection: a locked keychain earlier in the user
# search list both shadows login.keychain-db for `codesign` (errSecInternalComponent)
# and can win the `find-identity | head -1` race below. Restored on exit.
# shellcheck source=../Tools/lib/signing-keychain.sh
. "$REPO_ROOT/Tools/lib/signing-keychain.sh"
maestro_signing_keychain_guard

# ── Auto-detect signing identities ──────────────────────────────────────────

if [ -z "${SIGNING_IDENTITY:-}" ]; then
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
    if [ -z "$SIGNING_IDENTITY" ]; then
        echo "ERROR: No Developer ID Application cert found in keychain."
        echo "Install your Developer ID cert or set SIGNING_IDENTITY env var."
        exit 1
    fi
fi
echo "Signing identity (app): $SIGNING_IDENTITY"

if [ -z "${INSTALLER_IDENTITY:-}" ]; then
    INSTALLER_IDENTITY=$(security find-identity -v -p basic | grep "Developer ID Installer" | head -1 | sed 's/.*"\(.*\)"/\1/' || true)
    if [ -z "$INSTALLER_IDENTITY" ]; then
        echo "ERROR: No Developer ID Installer cert found in keychain."
        echo "Install your Developer ID Installer cert or set INSTALLER_IDENTITY env var."
        exit 1
    fi
fi
echo "Signing identity (pkg): $INSTALLER_IDENTITY"

TEAM_ID="${TEAM_ID:-95CX6P84C4}"

# Version numbering is explicit and independent of repository history length.
BUILD_NUM="${BUILD_NUM:-$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["buildNumber"])' "$REPO_ROOT/Tools/versions.json")}"
MAESTRO_DEXT_BUILD="${MAESTRO_DEXT_BUILD:-$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["dextBuild"])' "$REPO_ROOT/Tools/versions.json")}"
export MAESTRO_DEXT_BUILD
case "$BUILD_NUM" in ''|*[!0-9]*) echo "BUILD_NUM must be numeric" >&2; exit 1;; esac
BUILD_HASH=$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD)
if ! git -C "$REPO_ROOT" diff --quiet || ! git -C "$REPO_ROOT" diff --cached --quiet; then BUILD_HASH="$BUILD_HASH-dirty"; fi
: "${MAESTRO_APP_PROFILE:?Set MAESTRO_APP_PROFILE to your external Developer ID app profile}"
: "${MAESTRO_DEXT_PROFILE:?Set MAESTRO_DEXT_PROFILE to your external Developer ID extension profile}"
export SIGNING_IDENTITY INSTALLER_IDENTITY
if [ "$SKIP_BUILD" = false ]; then
    python3 "$REPO_ROOT/Tools/clean-build-dir.py" "$SCRIPT_DIR" "$BUILD_DIR"
fi
mkdir -p "$PAYLOAD_DIR" "$OUTPUT_DIR"
echo "Version: $VERSION  Build: $BUILD_NUM ($BUILD_HASH)"

# ── 1. Build all components ─────────────────────────────────────────────────

if [ "$SKIP_BUILD" = false ]; then
    echo ""
    echo "=== Building Components ==="

    bash "$REPO_ROOT/Drivers/Thunderbolt/Scripts/test-dext-upgrade-activation.sh"

    # 1a. Maestro app (release)
    echo "[1/3] Building Maestro.app..."
    # SwiftPM compiles a temporary metadata override; preserve the checked-in
    # development defaults on both success and failure.
    (
    BUILD_INFO="$REPO_ROOT/Apps/Maestro/MaestroCore/BuildInfo.generated.swift"
    BUILD_INFO_BACKUP=$(mktemp "$BUILD_DIR/build-info.XXXXXX")
    cp "$BUILD_INFO" "$BUILD_INFO_BACKUP"
    trap 'cp "$BUILD_INFO_BACKUP" "$BUILD_INFO"; rm -f "$BUILD_INFO_BACKUP"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    cat > "$BUILD_INFO" <<SWIFT
// Auto-generated by build-installer.sh at $(date -u +"%Y-%m-%dT%H:%M:%SZ")
extension MaestroCore {
    public static let buildNumber: Int = $BUILD_NUM
    public static let gitHash: String = "$BUILD_HASH"
}
SWIFT
    swift build --package-path "$REPO_ROOT/Apps/Maestro" -c release --jobs "$MAESTRO_BUILD_JOBS"
    )
    echo "  Maestro.app built OK"

    # 1b. AudioServerPlugin
    echo "[2/3] Building ApogeeSymIO.driver..."
    bash "$REPO_ROOT/Drivers/AudioServerPlugin/Scripts/build.sh"
    echo "  ApogeeSymIO.driver built OK"

    # 1c. MaestroVolumeProxy (build into installer's own directory to avoid root-owned stale files)
    echo "[3/3] Building MaestroVolumeProxy..."
    PROXY_OUT="$BUILD_DIR/MaestroVolumeProxy"
    clang -o "$PROXY_OUT" "$REPO_ROOT/Drivers/VolumeProxy/MaestroVolumeProxy.c" \
        -I "$REPO_ROOT/Drivers/Shared" \
        -arch arm64 \
        -mmacosx-version-min=15.0 \
        -framework Foundation \
        -framework CoreAudio \
        -framework AudioToolbox \
        -framework IOKit \
        -Wall -Wextra -O2
    echo "  MaestroVolumeProxy built OK"
else
    echo ""
    echo "=== Skipping builds (--skip-build) ==="
fi

# ── 2. Assemble payload ────────────────────────────────────────────────────

echo ""
echo "=== Assembling Payload ==="

# 2a. Maestro.app — assemble .app bundle from build output + repo resources
APP_BINARY="$REPO_ROOT/Apps/Maestro/.build/release/MaestroApp"
APP_RESOURCES="$REPO_ROOT/Apps/Maestro/MaestroApp/Resources"
if [ ! -f "$APP_BINARY" ]; then
    echo "ERROR: MaestroApp binary not found. Run build first (or remove --skip-build)."
    exit 1
fi

APP_BUNDLE="$PAYLOAD_DIR/Applications/Maestro.app"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

# Binary
cp "$APP_BINARY" "$APP_BUNDLE/Contents/MacOS/MaestroApp"
# SwiftPM links Sparkle through @rpath. Point the installed executable at the
# framework directory inside this app bundle before signing it. Older build
# products carried @loader_path, which resolves beside Contents/MacOS and caused
# dyld to miss Contents/Frameworks. Remove that stale path before adding the
# bundle-relative path so a package cannot regress to the launch failure.
if otool -l "$APP_BUNDLE/Contents/MacOS/MaestroApp" \
    | awk '$1 == "path" && $2 == "@loader_path" { found = 1 } END { exit found ? 0 : 1 }'; then
    install_name_tool -delete_rpath "@loader_path" "$APP_BUNDLE/Contents/MacOS/MaestroApp"
fi
install_name_tool -add_rpath "@loader_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/MaestroApp"

# Info.plist (from repo, then stamp version)
cp "$APP_RESOURCES/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_BUNDLE/Contents/Info.plist"

# Resources (icon, legal pages)
for RES in AppIcon.icns AppIconRounded.icns Acknowledgements.html Privacy.html Terms.html; do
    if [ -f "$APP_RESOURCES/$RES" ]; then
        cp "$APP_RESOURCES/$RES" "$APP_BUNDLE/Contents/Resources/$RES"
    fi
done

# Sparkle is linked with @rpath by the Swift package build. Embed the exact
# resolved framework in the app so the signed PKG is self-contained and can
# perform package updates on another Mac.
SPARKLE_SRC="$REPO_ROOT/Apps/Maestro/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ ! -d "$SPARKLE_SRC" ]; then
    echo "ERROR: Sparkle.framework not found at $SPARKLE_SRC"
    echo "Run a release build first so SwiftPM resolves Sparkle 2.10.0."
    exit 1
fi
ditto "$SPARKLE_SRC" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
echo "  Embedded Sparkle.framework"

# UserManual
if [ -f "$REPO_ROOT/docs/UserManual.md" ]; then
    cp "$REPO_ROOT/docs/UserManual.md" "$APP_BUNDLE/Contents/Resources/UserManual.md"
fi

# Uninstall script
cp "$SCRIPT_DIR/uninstall.sh" "$APP_BUNDLE/Contents/Resources/uninstall.sh"
chmod 755 "$APP_BUNDLE/Contents/Resources/uninstall.sh"

# 2a-bis. Embed the ThunderBridge dext inside Maestro.app
#
# Maestro.app activates it via OSSystemExtensionManager on first launch. The dext must be
# signed (Developer ID + its own Developer ID profile) BEFORE the app is signed around it,
# and the app must never be signed with --deep.
DEXT_BUNDLE="com.danielraffel.maestro.thunderbridge.dext"
DEXT_SRC="$REPO_ROOT/Drivers/Thunderbolt/build/$DEXT_BUNDLE"

if [ "$SKIP_BUILD" != true ]; then
    echo "Building ThunderBridge dext (production)..."
    "$REPO_ROOT/Drivers/Thunderbolt/Scripts/build.sh" --clean --production
fi

if [ ! -d "$DEXT_SRC" ]; then
    echo "ERROR: dext not found at $DEXT_SRC"
    echo "Run: Drivers/Thunderbolt/Scripts/build.sh --clean --production"
    exit 1
fi

# The embedded profile must be Developer ID, else the dext will not load on other Macs.
"$REPO_ROOT/Tools/verify-profile.sh" \
    "$MAESTRO_DEXT_PROFILE" \
    com.danielraffel.maestro.thunderbridge developerid

echo "Signing dext (Developer ID, DriverKit entitlements)..."
codesign --sign "$SIGNING_IDENTITY" --force --options runtime --timestamp \
    --entitlements "$REPO_ROOT/Drivers/Thunderbolt/Entitlements/SymphonyThunderbridge-production.entitlements" \
    --generate-entitlement-der \
    "$DEXT_SRC"

mkdir -p "$APP_BUNDLE/Contents/Library/SystemExtensions"
ditto "$DEXT_SRC" "$APP_BUNDLE/Contents/Library/SystemExtensions/$DEXT_BUNDLE"
echo "  Embedded $DEXT_BUNDLE (v$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$DEXT_SRC/Info.plist"))"

# Embed the app's Developer ID profile — required for system-extension.install to survive AMFI.
APP_PROFILE="$MAESTRO_APP_PROFILE"
"$REPO_ROOT/Tools/verify-profile.sh" "$APP_PROFILE" com.danielraffel.maestro developerid
cp "$APP_PROFILE" "$APP_BUNDLE/Contents/embedded.provisionprofile"
# Embedded profiles are public distribution metadata, unlike their private inputs.
chmod 644 "$APP_BUNDLE/Contents/embedded.provisionprofile"
echo "  Embedded app provisioning profile"

# 2b. AudioServerPlugin
ASP_SRC="$REPO_ROOT/Drivers/AudioServerPlugin/build/ApogeeSymIO.driver"
if [ ! -d "$ASP_SRC" ]; then
    echo "ERROR: ApogeeSymIO.driver not found. Run build first."
    exit 1
fi
mkdir -p "$PAYLOAD_DIR/Library/Audio/Plug-Ins/HAL"
cp -R "$ASP_SRC" "$PAYLOAD_DIR/Library/Audio/Plug-Ins/HAL/ApogeeSymIO.driver"

# 2c. MaestroVolumeProxy
# Prefer installer's own build, fall back to shared build directory
if [ -f "$BUILD_DIR/MaestroVolumeProxy" ]; then
    PROXY_SRC="$BUILD_DIR/MaestroVolumeProxy"
else
    PROXY_SRC="$REPO_ROOT/Drivers/VolumeProxy/build/MaestroVolumeProxy"
fi
if [ ! -f "$PROXY_SRC" ]; then
    echo "ERROR: MaestroVolumeProxy not found. Run build first."
    exit 1
fi
mkdir -p "$PAYLOAD_DIR/usr/local/bin"
cp "$PROXY_SRC" "$PAYLOAD_DIR/usr/local/bin/MaestroVolumeProxy"

# 2d. LaunchDaemon plist
PLIST_SRC="$REPO_ROOT/Drivers/VolumeProxy/com.danielraffel.Maestro.volumeproxy.plist"
mkdir -p "$PAYLOAD_DIR/Library/LaunchDaemons"
cp "$PLIST_SRC" "$PAYLOAD_DIR/Library/LaunchDaemons/com.danielraffel.Maestro.volumeproxy.plist"

# Clean macOS extended attribute files from payload (._* files)
find "$PAYLOAD_DIR" -name '._*' -delete 2>/dev/null || true

echo "Payload assembled"

# ── 3. Sign all binaries in the payload ─────────────────────────────────────

echo ""
echo "=== Signing Binaries ==="

# Sign Sparkle's nested helper executables before signing the framework itself.
# The outer Maestro.app must be signed LAST and NEVER with --deep, because it
# contains the DriverKit dext.
# --deep re-signs nested code with the OUTER entitlements, which would strip the dext's
# DriverKit entitlements and make it silently fail to launch. Sign inside-out: the dext
# is already signed by build.sh/install-dext.sh; here we sign only the app shell.
#
# The app needs system-extension.install (to activate the dext) plus an embedded
# Developer ID profile granting it. Without the profile, AMFI kills the app at launch.
MAESTRO_ENTITLEMENTS="$BUILD_DIR/Maestro-app.entitlements"
cat > "$MAESTRO_ENTITLEMENTS" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.application-identifier</key>
    <string>95CX6P84C4.com.danielraffel.maestro</string>
    <key>com.apple.developer.team-identifier</key>
    <string>95CX6P84C4</string>
    <key>com.apple.developer.driverkit.userclient-access</key>
    <array>
        <string>com.danielraffel.maestro.thunderbridge</string>
    </array>
    <key>com.apple.developer.system-extension.install</key>
    <true/>
</dict>
</plist>
PLIST
# Claim the app's required subset of its approved profile. Never use --deep
# on the outer app, because it would overwrite the extension's entitlements.

codesign --sign "$SIGNING_IDENTITY" --force --deep --options runtime --timestamp \
    "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
codesign --verify --deep --strict "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
echo "  Sparkle.framework signed (hardened runtime)"

codesign --sign "$SIGNING_IDENTITY" --force --options runtime --timestamp \
    --entitlements "$MAESTRO_ENTITLEMENTS" \
    --generate-entitlement-der \
    "$PAYLOAD_DIR/Applications/Maestro.app"
rm -f "$MAESTRO_ENTITLEMENTS"
echo "  Maestro.app signed (hardened runtime, system-extension.install, dext embedded)"

codesign --sign "$SIGNING_IDENTITY" --force --deep --options runtime \
    "$PAYLOAD_DIR/Library/Audio/Plug-Ins/HAL/ApogeeSymIO.driver"
echo "  ApogeeSymIO.driver signed (hardened runtime)"

codesign --sign "$SIGNING_IDENTITY" --force --options runtime \
    "$PAYLOAD_DIR/usr/local/bin/MaestroVolumeProxy"
echo "  MaestroVolumeProxy signed (hardened runtime)"

# Verify all signatures
codesign -v "$PAYLOAD_DIR/Applications/Maestro.app"
codesign -v "$PAYLOAD_DIR/Library/Audio/Plug-Ins/HAL/ApogeeSymIO.driver"
codesign -v "$PAYLOAD_DIR/usr/local/bin/MaestroVolumeProxy"
echo "All signatures verified"

# ── 4. Build component .pkg ─────────────────────────────────────────────────

echo ""
echo "=== Building Package ==="

# Two components, so the installer can offer USB support as an opt-in:
#
#   core — /Applications/Maestro.app (embeds and activates the ThunderBridge dext).
#          Always installed.
#   usb  — AudioServerPlugin + MaestroVolumeProxy + its LaunchDaemon. On by default
#          (validated working); TB-only users can uncheck it in Customize.
#          Only a USB-connected Symphony I/O needs these; the Thunderbolt dext publishes
#          its own audio device via AudioDriverKit. The proxy runs as root, so it should
#          not land on machines that will never use it.
chmod +x "$SCRIPT_DIR/scripts-core/preinstall" "$SCRIPT_DIR/scripts-core/postinstall"
chmod +x "$SCRIPT_DIR/scripts-usb/postinstall"

CORE_ROOT="$BUILD_DIR/payload-core"
USB_ROOT="$BUILD_DIR/payload-usb"
python3 "$REPO_ROOT/Tools/clean-build-dir.py" "$SCRIPT_DIR" "$CORE_ROOT"
python3 "$REPO_ROOT/Tools/clean-build-dir.py" "$SCRIPT_DIR" "$USB_ROOT"
mkdir -p "$CORE_ROOT/Applications" "$USB_ROOT"

ditto "$PAYLOAD_DIR/Applications/Maestro.app" "$CORE_ROOT/Applications/Maestro.app"
for p in Library/Audio/Plug-Ins/HAL/ApogeeSymIO.driver usr/local/bin/MaestroVolumeProxy \
         Library/LaunchDaemons/com.danielraffel.Maestro.volumeproxy.plist; do
    mkdir -p "$USB_ROOT/$(dirname "$p")"
    ditto "$PAYLOAD_DIR/$p" "$USB_ROOT/$p"
done
echo "  core payload: Maestro.app (dext embedded)"
echo "  usb  payload: ApogeeSymIO.driver, MaestroVolumeProxy, LaunchDaemon"

# Disable bundle relocation on every TOP-LEVEL bundle. Without this, pkgbuild treats .app
# bundles as relocatable and macOS Installer moves Maestro.app to wherever LaunchServices
# last saw a copy with the same bundle ID, instead of /Applications.
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
    print(f"    non-relocatable: {c.get('RootRelativeBundlePath', '<no path>')}")
    for child in c.get('ChildBundles', []):
        print(f"        child: {child.get('RootRelativeBundlePath', '<no path>')}")
with open(path, 'wb') as f:
    plistlib.dump(comps, f)
PY
}

CORE_PKG="$BUILD_DIR/SymphonyMaestroCore.pkg"
USB_PKG="$BUILD_DIR/SymphonyMaestroUSB.pkg"

make_component_plist "$CORE_ROOT" "$BUILD_DIR/component-core.plist"
pkgbuild \
    --root "$CORE_ROOT" \
    --component-plist "$BUILD_DIR/component-core.plist" \
    --scripts "$SCRIPT_DIR/scripts-core" \
    --identifier "com.generouscorp.maestro.core" \
    --version "$VERSION" \
    --ownership recommended \
    "$CORE_PKG" >/dev/null
echo "Component package built: $CORE_PKG"

make_component_plist "$USB_ROOT" "$BUILD_DIR/component-usb.plist"
pkgbuild \
    --root "$USB_ROOT" \
    --component-plist "$BUILD_DIR/component-usb.plist" \
    --scripts "$SCRIPT_DIR/scripts-usb" \
    --identifier "com.generouscorp.maestro.usb" \
    --version "$VERSION" \
    --ownership recommended \
    "$USB_PKG" >/dev/null
echo "Component package built: $USB_PKG"

# ── 5. Build distribution .pkg (with installer screens) ────────────────────

# Update version in distribution.xml to match
DIST_XML="$BUILD_DIR/distribution.xml"
sed "s/version=\"[0-9]*\.[0-9]*\.[0-9]*\"/version=\"$VERSION\"/g" \
    "$SCRIPT_DIR/distribution.xml" > "$DIST_XML"

DIST_PKG="$OUTPUT_DIR/UnofficialSymphonyMaestro-${VERSION}-b${BUILD_NUM}.pkg"
productbuild \
    --distribution "$DIST_XML" \
    --resources "$SCRIPT_DIR/resources" \
    --package-path "$BUILD_DIR" \
    --version "$VERSION" \
    "$DIST_PKG"
echo "Distribution package built: $DIST_PKG"

# ── 6. Sign the .pkg ───────────────────────────────────────────────────────

SIGNED_PKG="$OUTPUT_DIR/UnofficialSymphonyMaestro-${VERSION}-b${BUILD_NUM}-signed.pkg"
productsign \
    --sign "$INSTALLER_IDENTITY" \
    "$DIST_PKG" \
    "$SIGNED_PKG"
rm "$DIST_PKG"
mv "$SIGNED_PKG" "$DIST_PKG"
echo "Package signed: $DIST_PKG"

# Verify package signature
pkgutil --check-signature "$DIST_PKG"

# ── 7. Notarize ─────────────────────────────────────────────────────────────

if [ "$SKIP_NOTARIZE" = true ]; then
    echo ""
    echo "=== Skipping notarization (--skip-notarize) ==="
    echo ""
    echo "Final package: $DIST_PKG"
    echo "To notarize manually:"
    echo "  xcrun notarytool submit '$DIST_PKG' --keychain-profile <profile> --wait"
    echo "  xcrun stapler staple '$DIST_PKG'"
    exit 0
fi

echo ""
echo "=== Notarizing Package ==="

# Notarization uses an external API key or a configured Keychain profile.
NOTARY_AUTH=()
if [ -n "${NOTARY_KEY_PATH:-}" ]; then
    [ -f "$NOTARY_KEY_PATH" ] && [ "$(stat -f '%Lp' "$NOTARY_KEY_PATH")" = 600 ] || { echo "Notary key must exist with mode 600" >&2; exit 1; }
    NOTARY_AUTH=(--key "$NOTARY_KEY_PATH" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER_ID:?}")
elif [ -n "${NOTARY_PROFILE:-}" ]; then
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
else
    echo "Set NOTARY_KEY_PATH/NOTARY_KEY_ID/NOTARY_ISSUER_ID or NOTARY_PROFILE" >&2
    exit 1
fi
NOTARY_CMD=(xcrun notarytool submit "$DIST_PKG" "${NOTARY_AUTH[@]}" --wait --output-format json)

# Run notarization and capture result
NOTARY_OUTPUT=$("${NOTARY_CMD[@]}" 2>&1) || true
echo "$NOTARY_OUTPUT"

# Extract submission ID and status
SUBMISSION_ID=$(echo "$NOTARY_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
NOTARY_STATUS=$(echo "$NOTARY_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || true)

if [ "$NOTARY_STATUS" != "Accepted" ]; then
    echo ""
    echo "ERROR: Notarization failed (status: $NOTARY_STATUS)"
    if [ -n "$SUBMISSION_ID" ]; then
        echo ""
        echo "=== Notarization Log ==="
        xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_AUTH[@]}" 2>&1 || true
    fi
    echo ""
    echo "Signed (but not notarized) package: $DIST_PKG"
    exit 1
fi

# ── 8. Staple the notarization ticket ───────────────────────────────────────

echo ""
echo "=== Stapling Notarization Ticket ==="
xcrun stapler staple "$DIST_PKG"

# Verify staple
xcrun stapler validate "$DIST_PKG"
echo "Notarization ticket stapled and validated"

# ── Done ────────────────────────────────────────────────────────────────────

echo ""
echo "============================================================"
echo "  Installer ready: $DIST_PKG"
echo "  Size: $(du -h "$DIST_PKG" | cut -f1)"
echo "  Signed: $INSTALLER_IDENTITY"
echo "  Notarized: Yes"
echo "============================================================"
echo ""
echo "Local artifact only. Publication is a separate, explicitly approved operation."
