#!/bin/bash
# build.sh — Build the SymphonyThunderbridge DriverKit extension (.dext)
# Uses the DriverKit SDK directly via CLI (no Xcode project required).
#
# Usage:
#   ./Drivers/Thunderbolt/Scripts/build.sh                    # development build
#   ./Drivers/Thunderbolt/Scripts/build.sh --clean             # clean + development build
#   ./Drivers/Thunderbolt/Scripts/build.sh --production         # production build (Developer ID)
#   ./Drivers/Thunderbolt/Scripts/build.sh --clean --production # clean + production build
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRIVER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$DRIVER_DIR/build"
SOURCE_DIR="$DRIVER_DIR/Source"
IIG_DIR="$BUILD_DIR/iig"

CLEAN=false
PRODUCTION=false
for arg in "$@"; do
    case "$arg" in
        --clean) CLEAN=true ;;
        --production) PRODUCTION=true ;;
    esac
done

echo "[TB] SymphonyThunderbridge DriverKit build"
echo "[TB] Driver dir: $DRIVER_DIR"

# ── SDK and tools ────────────────────────────────────────────────────────────

SDK=$(xcrun --sdk driverkit --show-sdk-path)
IIG=$(xcrun --sdk driverkit -f iig)
CLANG=$(xcrun --sdk driverkit -f clang++)
FRAMEWORK_DIR="$SDK/System/DriverKit/System/Library/Frameworks"
INCLUDE_DIR="$SDK/System/DriverKit/usr/include"
LIB_DIR="$SDK/System/DriverKit/usr/lib"

echo "[TB] SDK: $SDK"
echo "[TB] iig: $IIG"

# ── Architecture selection ──────────────────────────────────────────────────
# Production builds use arm64 to avoid the kernel's "preview arm64e ABI"
# rejection (exec_mach_imgact) for non-platform binaries with SIP enabled.
# Development builds (SIP disabled + AMFI bypass) use arm64e which works fine.
# The DriverKit SDK supports both: targets = [ x86_64, arm64, arm64e ]-driverkit.
if [ "$PRODUCTION" = true ]; then
    ARCH_TARGET="arm64-apple-driverkit25.2"
    echo "[TB] Architecture: arm64 (production — avoids arm64e ABI kernel check)"
else
    ARCH_TARGET="arm64e-apple-driverkit25.2"
    echo "[TB] Architecture: arm64e (development)"
fi

# ── Clean if requested ───────────────────────────────────────────────────────

if [ "$CLEAN" = true ]; then
    echo "[TB] Cleaning..."
    python3 "$DRIVER_DIR/../../Tools/clean-build-dir.py" "$DRIVER_DIR" "$BUILD_DIR"
fi

mkdir -p "$BUILD_DIR" "$IIG_DIR"

# ── Step 1: Run iig (Interface Implementation Generator) ─────────────────────

echo "[TB] Running iig on SymphonyThunderbridge.iig..."
$IIG --def "$SOURCE_DIR/SymphonyThunderbridge.iig" \
     --header "$IIG_DIR/SymphonyThunderbridge.h" \
     --impl "$IIG_DIR/SymphonyThunderbridge.iig.cpp" \
     --deployment-target 25.2 \
     -- \
     -isysroot "$SDK" \
     -x c++ \
     -std=c++17 \
     -D__IIG=1 \
     -iframework "$FRAMEWORK_DIR"

echo "[TB] iig generated SymphonyThunderbridge.h and SymphonyThunderbridge.iig.cpp"

echo "[TB] Running iig on SymphonyAudioDevice.iig..."
$IIG --def "$SOURCE_DIR/SymphonyAudioDevice.iig" \
     --header "$IIG_DIR/SymphonyAudioDevice.h" \
     --impl "$IIG_DIR/SymphonyAudioDevice.iig.cpp" \
     --deployment-target 25.2 \
     -- \
     -isysroot "$SDK" \
     -x c++ \
     -std=c++17 \
     -D__IIG=1 \
     -iframework "$FRAMEWORK_DIR"

echo "[TB] iig generated SymphonyAudioDevice.h and SymphonyAudioDevice.iig.cpp"

echo "[TB] Running iig on SymphonyUserClient.iig..."
$IIG --def "$SOURCE_DIR/SymphonyUserClient.iig" \
     --header "$IIG_DIR/SymphonyUserClient.h" \
     --impl "$IIG_DIR/SymphonyUserClient.iig.cpp" \
     --deployment-target 25.2 \
     -- \
     -isysroot "$SDK" \
     -x c++ \
     -std=c++17 \
     -D__IIG=1 \
     -iframework "$FRAMEWORK_DIR"

echo "[TB] iig generated SymphonyUserClient.h and SymphonyUserClient.iig.cpp"

echo "[TB] Running iig on SymphonyClockSelectorControl.iig..."
$IIG --def "$SOURCE_DIR/SymphonyClockSelectorControl.iig" \
     --header "$IIG_DIR/SymphonyClockSelectorControl.h" \
     --impl "$IIG_DIR/SymphonyClockSelectorControl.iig.cpp" \
     --deployment-target 25.2 \
     -- \
     -isysroot "$SDK" \
     -x c++ \
     -std=c++17 \
     -D__IIG=1 \
     -iframework "$FRAMEWORK_DIR"

echo "[TB] iig generated SymphonyClockSelectorControl.h and SymphonyClockSelectorControl.iig.cpp"

echo "[TB] Running iig on SymphonyPhantomControl.iig..."
$IIG --def "$SOURCE_DIR/SymphonyPhantomControl.iig" \
     --header "$IIG_DIR/SymphonyPhantomControl.h" \
     --impl "$IIG_DIR/SymphonyPhantomControl.iig.cpp" \
     --deployment-target 25.2 \
     -- \
     -isysroot "$SDK" \
     -x c++ \
     -std=c++17 \
     -D__IIG=1 \
     -iframework "$FRAMEWORK_DIR"

echo "[TB] iig generated SymphonyPhantomControl.h and SymphonyPhantomControl.iig.cpp"

echo "[TB] Running iig on SymphonyMicGainControl.iig..."
$IIG --def "$SOURCE_DIR/SymphonyMicGainControl.iig" \
     --header "$IIG_DIR/SymphonyMicGainControl.h" \
     --impl "$IIG_DIR/SymphonyMicGainControl.iig.cpp" \
     --deployment-target 25.2 \
     -- \
     -isysroot "$SDK" \
     -x c++ \
     -std=c++17 \
     -D__IIG=1 \
     -iframework "$FRAMEWORK_DIR"

echo "[TB] iig generated SymphonyMicGainControl.h and SymphonyMicGainControl.iig.cpp"

echo "[TB] Running iig on SymphonyOpticalControl.iig..."
$IIG --def "$SOURCE_DIR/SymphonyOpticalControl.iig" \
     --header "$IIG_DIR/SymphonyOpticalControl.h" \
     --impl "$IIG_DIR/SymphonyOpticalControl.iig.cpp" \
     --deployment-target 25.2 \
     -- \
     -isysroot "$SDK" \
     -x c++ \
     -std=c++17 \
     -D__IIG=1 \
     -iframework "$FRAMEWORK_DIR"

echo "[TB] iig generated SymphonyOpticalControl.h and SymphonyOpticalControl.iig.cpp"

# ── Step 2: Compile ──────────────────────────────────────────────────────────

COMMON_FLAGS=(
    -target "$ARCH_TARGET"
    -isysroot "$SDK"
    -std=c++17
    -iframework "$FRAMEWORK_DIR"
    -I "$IIG_DIR"
    -I "$SOURCE_DIR"
    -O2
)

echo "[TB] Compiling SymphonyThunderbridge.iig.cpp..."
$CLANG -c "${COMMON_FLAGS[@]}" \
    -o "$BUILD_DIR/SymphonyThunderbridge.iig.o" \
    "$IIG_DIR/SymphonyThunderbridge.iig.cpp"

echo "[TB] Compiling SymphonyAudioDevice.iig.cpp..."
$CLANG -c "${COMMON_FLAGS[@]}" \
    -o "$BUILD_DIR/SymphonyAudioDevice.iig.o" \
    "$IIG_DIR/SymphonyAudioDevice.iig.cpp"

echo "[TB] Compiling SymphonyAudioDevice.cpp..."
$CLANG -c "${COMMON_FLAGS[@]}" \
    -o "$BUILD_DIR/SymphonyAudioDevice.o" \
    "$SOURCE_DIR/SymphonyAudioDevice.cpp"

echo "[TB] Compiling SymphonyThunderbridge.cpp..."
$CLANG -c "${COMMON_FLAGS[@]}" \
    -o "$BUILD_DIR/SymphonyThunderbridge.o" \
    "$SOURCE_DIR/SymphonyThunderbridge.cpp"

echo "[TB] Compiling SymphonyUserClient.iig.cpp..."
$CLANG -c "${COMMON_FLAGS[@]}" \
    -o "$BUILD_DIR/SymphonyUserClient.iig.o" \
    "$IIG_DIR/SymphonyUserClient.iig.cpp"

echo "[TB] Compiling SymphonyUserClient.cpp..."
$CLANG -c "${COMMON_FLAGS[@]}" \
    -o "$BUILD_DIR/SymphonyUserClient.o" \
    "$SOURCE_DIR/SymphonyUserClient.cpp"

echo "[TB] Compiling SymphonyClockSelectorControl.iig.cpp..."
$CLANG -c "${COMMON_FLAGS[@]}" \
    -o "$BUILD_DIR/SymphonyClockSelectorControl.iig.o" \
    "$IIG_DIR/SymphonyClockSelectorControl.iig.cpp"

echo "[TB] Compiling SymphonyClockSelectorControl.cpp..."
$CLANG -c "${COMMON_FLAGS[@]}" \
    -o "$BUILD_DIR/SymphonyClockSelectorControl.o" \
    "$SOURCE_DIR/SymphonyClockSelectorControl.cpp"

echo "[TB] Compiling SymphonyPhantomControl.iig.cpp..."
$CLANG -c "${COMMON_FLAGS[@]}" \
    -o "$BUILD_DIR/SymphonyPhantomControl.iig.o" \
    "$IIG_DIR/SymphonyPhantomControl.iig.cpp"

echo "[TB] Compiling SymphonyPhantomControl.cpp..."
$CLANG -c "${COMMON_FLAGS[@]}" \
    -o "$BUILD_DIR/SymphonyPhantomControl.o" \
    "$SOURCE_DIR/SymphonyPhantomControl.cpp"

echo "[TB] Compiling SymphonyMicGainControl.iig.cpp..."
$CLANG -c "${COMMON_FLAGS[@]}" \
    -o "$BUILD_DIR/SymphonyMicGainControl.iig.o" \
    "$IIG_DIR/SymphonyMicGainControl.iig.cpp"

echo "[TB] Compiling SymphonyMicGainControl.cpp..."
$CLANG -c "${COMMON_FLAGS[@]}" \
    -o "$BUILD_DIR/SymphonyMicGainControl.o" \
    "$SOURCE_DIR/SymphonyMicGainControl.cpp"

echo "[TB] Compiling SymphonyOpticalControl.iig.cpp..."
$CLANG -c "${COMMON_FLAGS[@]}" \
    -o "$BUILD_DIR/SymphonyOpticalControl.iig.o" \
    "$IIG_DIR/SymphonyOpticalControl.iig.cpp"

echo "[TB] Compiling SymphonyOpticalControl.cpp..."
$CLANG -c "${COMMON_FLAGS[@]}" \
    -o "$BUILD_DIR/SymphonyOpticalControl.o" \
    "$SOURCE_DIR/SymphonyOpticalControl.cpp"

# ── Step 3: Link ─────────────────────────────────────────────────────────────

echo "[TB] Linking..."
$CLANG \
    -target "$ARCH_TARGET" \
    -isysroot "$SDK" \
    -F "$FRAMEWORK_DIR" \
    -L "$LIB_DIR" \
    -framework DriverKit \
    -framework PCIDriverKit \
    -framework AudioDriverKit \
    -o "$BUILD_DIR/com.danielraffel.maestro.thunderbridge" \
    "$BUILD_DIR/SymphonyThunderbridge.o" \
    "$BUILD_DIR/SymphonyThunderbridge.iig.o" \
    "$BUILD_DIR/SymphonyAudioDevice.iig.o" \
    "$BUILD_DIR/SymphonyAudioDevice.o" \
    "$BUILD_DIR/SymphonyUserClient.o" \
    "$BUILD_DIR/SymphonyUserClient.iig.o" \
    "$BUILD_DIR/SymphonyClockSelectorControl.o" \
    "$BUILD_DIR/SymphonyClockSelectorControl.iig.o" \
    "$BUILD_DIR/SymphonyPhantomControl.o" \
    "$BUILD_DIR/SymphonyPhantomControl.iig.o" \
    "$BUILD_DIR/SymphonyMicGainControl.o" \
    "$BUILD_DIR/SymphonyMicGainControl.iig.o" \
    "$BUILD_DIR/SymphonyOpticalControl.o" \
    "$BUILD_DIR/SymphonyOpticalControl.iig.o"

echo "[TB] Linked: $(file "$BUILD_DIR/com.danielraffel.maestro.thunderbridge")"

# ── Step 4: Package .dext bundle (FLAT layout — matches Apple dexts) ──────────
# DriverKit dexts use a flat bundle: binary + Info.plist + _CodeSignature at root.
# NOT the nested Contents/MacOS/ layout used by macOS apps.
# CRITICAL: Directory name, CFBundleExecutable, and CFBundleIdentifier must ALL match.
# This is the pattern used by ALL Apple dexts and all working third-party extensions.

DEXT_DIR="$BUILD_DIR/com.danielraffel.maestro.thunderbridge.dext"
python3 "$DRIVER_DIR/../../Tools/clean-build-dir.py" "$DRIVER_DIR" "$DEXT_DIR"
mkdir -p "$DEXT_DIR"

cp "$BUILD_DIR/com.danielraffel.maestro.thunderbridge" "$DEXT_DIR/"
cp "$DRIVER_DIR/Info.plist" "$DEXT_DIR/"
if [ -n "${MAESTRO_DEXT_BUILD:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $MAESTRO_DEXT_BUILD" "$DEXT_DIR/Info.plist"
fi

# Embed provisioning profile (required for SIP-enabled operation)
if [ "$PRODUCTION" = true ]; then
    PROFILE="${MAESTRO_DEXT_PROFILE:?Set MAESTRO_DEXT_PROFILE to your external Developer ID profile}"
    echo "[TB] Production build — using production provisioning profile"
else
    PROFILE="${MAESTRO_DEXT_PROFILE:-}"
fi
if [ -f "$PROFILE" ]; then
    # Validate before embedding. A Development profile named like a production one,
    # or one bound to a certificate whose private key is gone, both sail through
    # codesign and notarization and only fail at dext load time.
    VERIFY="$DRIVER_DIR/../../Tools/verify-profile.sh"
    if [ -x "$VERIFY" ]; then
        "$VERIFY" "$PROFILE" com.danielraffel.maestro.thunderbridge \
            "$([ "$PRODUCTION" = true ] && echo developerid || echo development)" \
            || { echo "[TB] ERROR: profile validation failed — refusing to embed"; exit 1; }
    fi
    cp "$PROFILE" "$DEXT_DIR/embedded.provisionprofile"
    chmod 644 "$DEXT_DIR/embedded.provisionprofile"
    echo "[TB] Embedded provisioning profile: $(basename "$PROFILE")"
else
    echo "[TB] ERROR: required provisioning profile is missing" >&2
    exit 1
fi

echo ""
echo "[TB] Build complete. Mode: $([ "$PRODUCTION" = true ] && echo "PRODUCTION" || echo "DEVELOPMENT")"
echo "[TB] Driver extension: $DEXT_DIR"
echo "[TB] Bundle contents (flat layout):"
ls -la "$DEXT_DIR/"
echo ""
echo "[TB] Compile complete; package and sign using Installer/build-installer.sh."
