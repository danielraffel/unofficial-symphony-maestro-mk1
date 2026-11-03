#!/bin/zsh
# Verify that the public Sparkle feed advertises the release being published.
# Usage: Tools/verify-sparkle-feed.sh 0.8.10 [feed-url]
set -euo pipefail
VERSION="${1:?usage: $0 VERSION [FEED_URL]}"
FEED_URL="${2:-https://raw.githubusercontent.com/danielraffel/unofficial-symphony-maestro-mk1/main/appcast.xml}"
SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-$PWD/Apps/Maestro/.build/artifacts/sparkle/Sparkle/bin/sign_update}"
: "${SPARKLE_ED_KEY_FILE:?Set SPARKLE_ED_KEY_FILE to your external mode-600 private key file}"
# Never fall back to an interactive login-keychain Sparkle key. A different
# ed25519 item can produce a perfectly valid signature that every existing
# Maestro install rejects. The file-backed key is the release authority and
# must be present with private permissions before this gate can run.
if [[ ! -f "$SPARKLE_ED_KEY_FILE" || ! -r "$SPARKLE_ED_KEY_FILE" ]]; then
    echo "ERROR: file-backed Sparkle signing key is missing or unreadable: $SPARKLE_ED_KEY_FILE" >&2
    echo "       Restore it from the protected backup before publishing." >&2
    exit 1
fi
KEY_MODE="$(stat -f '%Lp' "$SPARKLE_ED_KEY_FILE")"
if [[ "$KEY_MODE" != "600" ]]; then
    echo "ERROR: Sparkle signing key must be mode 600 (found $KEY_MODE): $SPARKLE_ED_KEY_FILE" >&2
    exit 1
fi
SIGN_ARGS=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
TMP="$(mktemp -t maestro-appcast).xml"
trap 'rm -f "$TMP"' EXIT
curl --fail --silent --show-error --location "$FEED_URL" -o "$TMP"
grep -Fq "<sparkle:version>$VERSION</sparkle:version>" "$TMP"
grep -Fq "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$TMP"
PACKAGE_URL="https://github.com/danielraffel/unofficial-symphony-maestro-mk1/releases/download/v${VERSION}/UnofficialSymphonyMaestro.pkg"
grep -Fq "$PACKAGE_URL" "$TMP"

# The enclosure signature is over the downloaded bytes.  Verify the exact
# versioned asset and its advertised length as well as the feed signature;
# a mutable `releases/latest/download` URL can otherwise race publication and
# make a valid update appear improperly signed.
PACKAGE_SIG="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$TMP" | head -1)"
PACKAGE_LENGTH="$(sed -n 's/.*length="\([0-9][0-9]*\)".*/\1/p' "$TMP" | head -1)"
PACKAGE_TMP="$(mktemp -t maestro-package).pkg"
trap 'rm -f "$TMP" "$PACKAGE_TMP"' EXIT
curl --fail --silent --show-error --location "$PACKAGE_URL" -o "$PACKAGE_TMP"
ACTUAL_LENGTH="$(stat -f '%z' "$PACKAGE_TMP")"
[[ "$ACTUAL_LENGTH" == "$PACKAGE_LENGTH" ]]
[[ -n "$PACKAGE_SIG" ]]
"$SIGN_UPDATE" "${SIGN_ARGS[@]}" --verify "$PACKAGE_TMP" "$PACKAGE_SIG"
"$SIGN_UPDATE" "${SIGN_ARGS[@]}" --verify "$TMP"

# A feed/package can be perfectly signed by the local keychain while the
# shipped app still embeds a different SUPublicEDKey. Sparkle validates a
# package with the *old app's* key before it can install it, so catch that
# release-breaking mismatch before publication. Compare against the
# checked-in app configuration rather than the login keychain: the
# file-backed key is the release source of truth, and a stale keychain item
# must not silently produce an unusable feed.
SOURCE_INFO="$PWD/Apps/Maestro/MaestroApp/Resources/Info.plist"
EXPECTED_PUBLIC_KEY="${SPARKLE_PUBLIC_ED_KEY:-$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$SOURCE_INFO") }"
EXPECTED_PUBLIC_KEY="${EXPECTED_PUBLIC_KEY% }"
if [[ -n "$EXPECTED_PUBLIC_KEY" ]]; then
    PACKAGE_EXPANDED="$(mktemp -d -t maestro-sparkle-package)-expanded"
    pkgutil --expand-full "$PACKAGE_TMP" "$PACKAGE_EXPANDED"
    APP_INFO="$PACKAGE_EXPANDED/SymphonyMaestroCore.pkg/Payload/Applications/Maestro.app/Contents/Info.plist"
    if [[ ! -f "$APP_INFO" ]]; then
        echo "ERROR: package does not contain Maestro.app Info.plist; cannot verify Sparkle key" >&2
        exit 1
    fi
    APP_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP_INFO")"
    if [[ "$APP_PUBLIC_KEY" != "$EXPECTED_PUBLIC_KEY" ]]; then
        echo "ERROR: package SUPublicEDKey ($APP_PUBLIC_KEY) does not match source SUPublicEDKey ($EXPECTED_PUBLIC_KEY)" >&2
        exit 1
    fi
    echo "Sparkle public key matches package and source configuration"
fi
printf 'Sparkle feed verified: %s (%s)\n' "$VERSION" "$FEED_URL"
