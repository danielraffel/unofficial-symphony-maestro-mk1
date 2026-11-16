#!/bin/bash
# Promote a tested beta to stable: same bytes, no rebuild.
#
#   Tools/promote-beta.sh [VERSION] --notes <stable-notes.md> --feed <appcast.xml> [--github] [--dry-run]
#
# With no VERSION it promotes the newest beta in the feed. One command:
#   1. download the release asset of vVERSION and verify it against the feed
#      item's edSignature and length (that signature was made over the tested
#      package, so this proves the bytes are the ones published as the beta);
#   2. Tools/feed.py promote: remove the channel element, write the stable
#      notes (required; they cover everything since the previous stable);
#   3. gh release edit vVERSION --prerelease=false --latest, with those notes;
#   4. download releases/latest/download/UnofficialSymphonyMaestro.pkg and
#      check it against the same signature;
#   5. print the feed diff and stop. It never commits or pushes.
#
# An item whose package is on this Mac (the rehearsal's local feed) is
# promoted in the feed only; GitHub is not called. An item whose package is a
# GitHub release asset needs --github, because promoting it edits that
# release: a rehearsal on a copy of the production feed cannot do so by
# accident. --github with a local item is refused.
set -euo pipefail
. "$(dirname "$0")/lib/release-common.sh"

VERSION="" NOTES="" FEED="" GITHUB=false DRY_RUN=false
while [ $# -gt 0 ]; do
    case "$1" in
        --notes) NOTES="${2:-}"; shift 2 ;;
        --feed) FEED="${2:-}"; shift 2 ;;
        --github) GITHUB=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
        -*) die "unknown argument: $1" ;;
        *) [ -z "$VERSION" ] || die "more than one version given"; VERSION="$1"; shift ;;
    esac
done
[ -n "$FEED" ] || die "--feed is required (there is no default)"
[ -f "$FEED" ] || die "no feed at $FEED"
[ -f "$NOTES" ] || die "--notes <stable notes> is required"
require_sparkle_key

WORK="$(mktemp -d "${TMPDIR:-/tmp}/maestro-promote.XXXXXX")"
trap 'remove_scratch "$WORK"' EXIT

[ -n "$VERSION" ] || VERSION="$(feed_py newest --feed "$FEED" --channel beta)" || die "no beta in $FEED"
ITEM="$(feed_py item "$VERSION" --feed "$FEED")"
SIGNATURE="$(sed -n 's/^edSignature=//p' <<<"$ITEM")"
LENGTH="$(sed -n 's/^length=//p' <<<"$ITEM")"
URL="$(sed -n 's/^url=//p' <<<"$ITEM")"
[ "$(sed -n 's/^channel=//p' <<<"$ITEM")" = beta ] || die "$VERSION is not a beta item"
STABLE="$(feed_py newest --feed "$FEED" --channel stable 2>/dev/null || true)"
if [ -n "$STABLE" ] && ! version_gt "$VERSION" "$STABLE"; then die "$VERSION is not above the newest stable ($STABLE)"; fi
KIND="$(enclosure_kind "$URL" "$VERSION")"
if [ "$KIND" = github ] && [ "$GITHUB" = false ]; then
    die "$VERSION's package is a GitHub release asset; promoting it edits release v$VERSION. Pass --github to do that."
fi
if [ "$KIND" = local ] && [ "$GITHUB" = true ]; then
    die "--github was given, but $VERSION's package is on this Mac ($URL)"
fi
echo "Promoting beta $VERSION to stable ($KIND package)"

# ── 1. The published beta bytes ─────────────────────────────────────────────
fetch "$URL" "$WORK/beta.pkg"
verify_package_bytes "$WORK/beta.pkg" "$SIGNATURE" "$LENGTH"
SHA256="$(shasum -a 256 "$WORK/beta.pkg" | cut -d' ' -f1)"
echo "  release asset matches the feed item (sha256 $SHA256)"

# ── 2. Feed ─────────────────────────────────────────────────────────────────
cp "$FEED" "$WORK/feed.xml"
feed_py promote "$VERSION" --feed "$WORK/feed.xml" --notes "$NOTES"
feed_py lint --feed "$WORK/feed.xml" --previous "$FEED" >/dev/null

# ── 3-4. Release ────────────────────────────────────────────────────────────
if [ "$KIND" = github ]; then
    EDIT=("$GH_BIN" release edit "v$VERSION" --repo "$RELEASE_SLUG" --prerelease=false --latest --notes-file "$NOTES")
    if [ "$DRY_RUN" = true ]; then
        printf 'dry run: would run:'; printf ' %q' "${EDIT[@]}"; echo
    else
        "${EDIT[@]}"
        LATEST="$("$GHAPP_BIN" api "repos/$RELEASE_SLUG/releases/latest" --jq .tag_name)"
        [ "$LATEST" = "v$VERSION" ] || die "GitHub's latest release is $LATEST, not v$VERSION"
        fetch "$RELEASES_BASE/latest/download/$RELEASE_ASSET" "$WORK/latest.pkg"
        verify_package_bytes "$WORK/latest.pkg" "$SIGNATURE" "$LENGTH"
        echo "  latest download is the promoted package (sha256 $(shasum -a 256 "$WORK/latest.pkg" | cut -d' ' -f1))"
    fi
else
    fetch "$URL" "$WORK/again.pkg"
    verify_package_bytes "$WORK/again.pkg" "$SIGNATURE" "$LENGTH"
    echo "  local package unchanged"
fi

# ── 5. Diff, then stop ──────────────────────────────────────────────────────
diff -u "$FEED" "$WORK/feed.xml" || true
if [ "$DRY_RUN" = true ]; then
    echo "dry run: $FEED not changed"
else
    cp "$WORK/feed.xml" "$FEED"
    echo "Feed updated: $FEED (not committed or pushed). Next: land it on main, merge dev into main,"
    echo "run Tools/verify-sparkle-feed.sh $VERSION <feed url> stable, and open the next minor line on dev."
fi
