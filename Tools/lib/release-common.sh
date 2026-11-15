# shellcheck shell=bash
# Shared by Tools/publish-release.sh, Tools/promote-beta.sh and
# Tools/verify-sparkle-feed.sh. Sourced, never run.
#
# Overridable for tests only: GH_BIN (release writes), GHAPP_BIN (GitHub
# reads), SPCTL_BIN, MAESTRO_RELEASES_BASE, SPARKLE_SIGN_UPDATE,
# SPARKLE_PUBLIC_ED_KEY.

RELEASE_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RELEASE_SLUG="danielraffel/unofficial-symphony-maestro-mk1"
RELEASES_BASE="${MAESTRO_RELEASES_BASE:-https://github.com/$RELEASE_SLUG/releases}"
RELEASE_ASSET="UnofficialSymphonyMaestro.pkg"
# ghapp refuses release writes on this repo and the shell's gh is a function
# that reroutes to it; release writes use Homebrew's gh, reads use ghapp.
GH_BIN="${GH_BIN:-/opt/homebrew/bin/gh}"
GHAPP_BIN="${GHAPP_BIN:-ghapp}"
SPCTL_BIN="${SPCTL_BIN:-/usr/sbin/spctl}"
SIGN_UPDATE="${SPARKLE_SIGN_UPDATE:-$RELEASE_REPO_ROOT/Apps/Maestro/.build/artifacts/sparkle/Sparkle/bin/sign_update}"
export SPARKLE_SIGN_UPDATE="$SIGN_UPDATE"

die() { echo "ERROR: $*" >&2; exit 1; }

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

feed_py() { python3 "$RELEASE_REPO_ROOT/Tools/feed.py" "$@"; }

# The Sparkle key: a file, mode 600. Never a keychain item (a different
# ed25519 item can make a valid signature every installed copy rejects).
require_sparkle_key() {
    [ -n "${SPARKLE_ED_KEY_FILE:-}" ] || die "set SPARKLE_ED_KEY_FILE to the file-backed Sparkle key (mode 600)"
    [ -f "$SPARKLE_ED_KEY_FILE" ] && [ -r "$SPARKLE_ED_KEY_FILE" ] || die "Sparkle key missing or unreadable: $SPARKLE_ED_KEY_FILE"
    [ "$(stat -f '%Lp' "$SPARKLE_ED_KEY_FILE")" = 600 ] || die "Sparkle key must be mode 600: $SPARKLE_ED_KEY_FILE"
    [ -x "$SIGN_UPDATE" ] || die "sign_update not found at $SIGN_UPDATE"
}

source_public_key() {
    if [ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
        echo "$SPARKLE_PUBLIC_ED_KEY"
    else
        /usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$RELEASE_REPO_ROOT/Apps/Maestro/MaestroApp/Resources/Info.plist"
    fi
}

# Reads a value from Maestro.app's Info.plist inside a package expanded with
# `pkgutil --expand-full`.
expanded_app_info() {  # $1 = expanded dir, $2 = key
    local info="$1/SymphonyMaestroCore.pkg/Payload/Applications/Maestro.app/Contents/Info.plist"
    [ -f "$info" ] || die "the package has no Maestro.app Info.plist"
    /usr/libexec/PlistBuddy -c "Print :$2" "$info" 2>/dev/null || true
}

# Downloads a URL to a file, failing on HTTP errors.
fetch() {  # $1 = url, $2 = destination
    curl --fail --silent --show-error --location "$1" -o "$2"
}

# Checks a downloaded package against the feed item's length and signature.
verify_package_bytes() {  # $1 = file, $2 = edSignature, $3 = length
    [ -n "$2" ] || die "the feed item has no edSignature"
    local actual
    actual="$(stat -f '%z' "$1")"
    [ "$actual" = "$3" ] || die "$1 is $actual bytes; the feed says $3"
    "$SIGN_UPDATE" --ed-key-file "$SPARKLE_ED_KEY_FILE" --verify "$1" "$2" >/dev/null \
        || die "$1 does not match the feed item's edSignature"
}

# The package must be notarized and signed by Developer ID Installer with the team ID.
verify_installer_signature() {  # $1 = pkg
    local out
    out="$("$SPCTL_BIN" --assess --type install -vv "$1" 2>&1)" || die "spctl rejected $1: $out"
    grep -q '^source=Notarized Developer ID$' <<<"$out" || die "$1 is not notarized: $out"
    grep -Eq '^origin=Developer ID Installer: .*\(95CX6P84C4\)$' <<<"$out" || die "$1 is not signed by Maestro's Developer ID Installer: $out"
}

# Where a feed item's package lives: "github" for this repo's release
# downloads, "local" for this Mac (the rehearsal feed). Anything else fails.
enclosure_kind() {  # $1 = url, $2 = version
    case "$1" in
        "$RELEASES_BASE/download/v$2/$RELEASE_ASSET") echo github ;;
        http://127.0.0.1:*|http://127.0.0.1/*|http://localhost:*|http://localhost/*) echo local ;;
        *) die "unexpected package URL for $2: $1" ;;
    esac
}

version_gt() {  # $1 > $2 (numeric x.y.z)
    python3 -c 'import sys
k=lambda s: tuple(int(p) for p in s.split("."))
sys.exit(0 if k(sys.argv[1]) > k(sys.argv[2]) else 1)' "$1" "$2"
}
