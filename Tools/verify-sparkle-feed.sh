#!/bin/bash
# Verify that a Sparkle feed advertises a release correctly.
# Usage: Tools/verify-sparkle-feed.sh VERSION [FEED_URL] [stable|beta]
#
# The item is selected by version (not by position: a beta may be on top).
# With stable, the item must have no channel and be the newest stable; with
# beta, it must be tagged beta and be above the newest stable. The package is
# downloaded from the item's own enclosure, which must be this repository's
# vVERSION release asset or, for the rehearsal, a package on this Mac.
set -euo pipefail
. "$(dirname "$0")/lib/release-common.sh"
VERSION="${1:?usage: $0 VERSION [FEED_URL] [stable|beta]}"
FEED_URL="${2:-https://raw.githubusercontent.com/$RELEASE_SLUG/main/appcast.xml}"
CHANNEL="${3:-}"
case "$CHANNEL" in ''|stable|beta) ;; *) die "channel must be stable or beta" ;; esac
# Never fall back to an interactive login-keychain Sparkle key. A different
# ed25519 item can produce a perfectly valid signature that every existing
# Maestro install rejects. The file-backed key is the release authority and
# must be present with private permissions before this gate can run.
require_sparkle_key

WORK="$(mktemp -d "${TMPDIR:-/tmp}/maestro-verify-feed.XXXXXX")"
trap 'remove_scratch "$WORK"' EXIT
TMP="$WORK/appcast.xml"
fetch "$FEED_URL" "$TMP"

# feed_py checks the feed signature with the key before every read.
ITEM="$(feed_py item "$VERSION" --feed "$TMP")"
PACKAGE_SIG="$(sed -n 's/^edSignature=//p' <<<"$ITEM")"
PACKAGE_LENGTH="$(sed -n 's/^length=//p' <<<"$ITEM")"
PACKAGE_URL="$(sed -n 's/^url=//p' <<<"$ITEM")"
ITEM_CHANNEL="$(sed -n 's/^channel=//p' <<<"$ITEM")"
grep -Fq "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$TMP" \
    || die "no shortVersionString $VERSION in the feed"
enclosure_kind "$PACKAGE_URL" "$VERSION" >/dev/null
feed_py lint --feed "$TMP" >/dev/null

NEWEST_STABLE="$(feed_py newest --feed "$TMP" --channel stable 2>/dev/null || true)"
case "$CHANNEL" in
    stable)
        [ -z "$ITEM_CHANNEL" ] || die "$VERSION is tagged $ITEM_CHANNEL, not stable"
        [ "$NEWEST_STABLE" = "$VERSION" ] || die "the newest stable item is $NEWEST_STABLE, not $VERSION"
        ;;
    beta)
        [ "$ITEM_CHANNEL" = beta ] || die "$VERSION is not tagged beta"
        if [ -n "$NEWEST_STABLE" ] && ! version_gt "$VERSION" "$NEWEST_STABLE"; then
            die "beta $VERSION is not above the newest stable ($NEWEST_STABLE)"
        fi
        ;;
esac

# The enclosure signature is over the downloaded bytes.  Verify the exact
# versioned asset and its advertised length as well as the feed signature;
# a mutable `releases/latest/download` URL can otherwise race publication and
# make a valid update appear improperly signed.
PACKAGE_TMP="$WORK/package.pkg"
fetch "$PACKAGE_URL" "$PACKAGE_TMP"
verify_package_bytes "$PACKAGE_TMP" "$PACKAGE_SIG" "$PACKAGE_LENGTH"
"$SIGN_UPDATE" --ed-key-file "$SPARKLE_ED_KEY_FILE" --verify "$TMP" >/dev/null || die "feed signature"

# A feed/package can be perfectly signed by the local keychain while the
# shipped app still embeds a different SUPublicEDKey. Sparkle validates a
# package with the *old app's* key before it can install it, so catch that
# release-breaking mismatch before publication. Compare against the
# checked-in app configuration rather than the login keychain: the
# file-backed key is the release source of truth, and a stale keychain item
# must not silently produce an unusable feed.
EXPECTED_PUBLIC_KEY="$(source_public_key)"
pkgutil --expand-full "$PACKAGE_TMP" "$WORK/expanded" >/dev/null
APP_PUBLIC_KEY="$(expanded_app_info "$WORK/expanded" SUPublicEDKey)"
APP_VERSION="$(expanded_app_info "$WORK/expanded" CFBundleVersion)"
[ "$APP_PUBLIC_KEY" = "$EXPECTED_PUBLIC_KEY" ] \
    || die "package SUPublicEDKey ($APP_PUBLIC_KEY) does not match source SUPublicEDKey ($EXPECTED_PUBLIC_KEY)"
[ "$APP_VERSION" = "$VERSION" ] || die "the package is version $APP_VERSION, not $VERSION"
echo "Sparkle public key matches package and source configuration"
printf 'Sparkle feed verified: %s%s (%s)\n' "$VERSION" "${CHANNEL:+ ($CHANNEL)}" "$FEED_URL"
