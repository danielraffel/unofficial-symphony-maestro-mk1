#!/bin/bash
# Publish a tested Maestro package on the Stable or Beta channel.
#
#   Tools/publish-release.sh --channel stable|beta --pkg <tested.pkg> --notes <notes.md> \
#       --feed <appcast.xml> [--local-base-url http://127.0.0.1:8765] [--dry-run]
#
# Steps 2-6 of the runbook's Publish section, for one package:
#   1. read the version and source commit from the package, check it is
#      notarized and carries the app's Sparkle key, and check the version can
#      be published on the channel (Tools/check-versions.py --feed);
#   2. add the feed item (Tools/feed.py add) to a copy of the feed, re-sign
#      and lint it, so a feed problem stops before anything is created;
#   3. create GitHub release v<version> tagged at the commit the package was
#      built from, as a pre-release (beta) or the latest release (stable), with
#      the package as UnofficialSymphonyMaestro.pkg, and confirm "latest";
#   4. print the feed diff and stop. It never commits or pushes.
#
# With --local-base-url nothing goes to GitHub: the package (and the notes)
# are copied next to the feed as <version>.pkg and <version>.notes.md, for the
# rehearsal's local test feed. With --dry-run nothing is created or changed;
# the feed edit is made on a copy to show the diff.
set -euo pipefail
. "$(dirname "$0")/lib/release-common.sh"

CHANNEL="" PKG="" NOTES="" FEED="" LOCAL_BASE="" DRY_RUN=false
while [ $# -gt 0 ]; do
    case "$1" in
        --channel) CHANNEL="${2:-}"; shift 2 ;;
        --pkg) PKG="${2:-}"; shift 2 ;;
        --notes) NOTES="${2:-}"; shift 2 ;;
        --feed) FEED="${2:-}"; shift 2 ;;
        --local-base-url) LOCAL_BASE="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
case "$CHANNEL" in stable|beta) ;; *) die "--channel stable|beta is required" ;; esac
[ -n "$FEED" ] || die "--feed is required (there is no default)"
[ -f "$FEED" ] || die "no feed at $FEED"
[ -f "$PKG" ] || die "--pkg: no package at ${PKG:-<none>}"
[ -f "$NOTES" ] || die "--notes: no notes file at ${NOTES:-<none>}"
if [ -n "$LOCAL_BASE" ]; then
    case "$LOCAL_BASE" in http://127.0.0.1:*|http://localhost:*) ;; *) die "--local-base-url must be http://127.0.0.1:<port> or http://localhost:<port>" ;; esac
fi
require_sparkle_key

WORK="$(mktemp -d "${TMPDIR:-/tmp}/maestro-publish.XXXXXX")"
trap 'remove_scratch "$WORK"' EXIT

# ── 1. What is being published ──────────────────────────────────────────────
pkgutil --expand-full "$PKG" "$WORK/expanded" >/dev/null || die "cannot expand $PKG"
VERSION="$(expanded_app_info "$WORK/expanded" CFBundleShortVersionString)"
BUNDLE_VERSION="$(expanded_app_info "$WORK/expanded" CFBundleVersion)"
COMMIT="$(expanded_app_info "$WORK/expanded" MaestroSourceCommit)"
APP_KEY="$(expanded_app_info "$WORK/expanded" SUPublicEDKey)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "package version is '$VERSION'"
[ "$BUNDLE_VERSION" = "$VERSION" ] || die "package CFBundleVersion $BUNDLE_VERSION differs from $VERSION"
[ "$APP_KEY" = "$(source_public_key)" ] || die "package SUPublicEDKey ($APP_KEY) differs from the source key"
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "package was not built from a clean commit (MaestroSourceCommit '$COMMIT')"
verify_installer_signature "$PKG"
REPO_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["appVersion"])' "$RELEASE_REPO_ROOT/Tools/versions.json")"
[ "$REPO_VERSION" = "$VERSION" ] || die "Tools/versions.json is $REPO_VERSION; the package is $VERSION"
python3 "$RELEASE_REPO_ROOT/Tools/check-versions.py" --feed "$FEED" --channel "$CHANNEL"
SHA256="$(shasum -a 256 "$PKG" | cut -d' ' -f1)"
echo "Publishing $CHANNEL $VERSION from $COMMIT"
echo "  package $PKG ($(stat -f %z "$PKG") bytes, sha256 $SHA256)"

ADD_ARGS=(add --feed "$WORK/feed.xml" --channel "$CHANNEL" --version "$VERSION" --pkg "$PKG" --notes "$NOTES")
if [ -n "$LOCAL_BASE" ]; then
    FEED_DIR="$(cd "$(dirname "$FEED")" && pwd)"
    LOCAL_PKG="$FEED_DIR/$VERSION.pkg"
    if [ -e "$LOCAL_PKG" ] && ! cmp -s "$PKG" "$LOCAL_PKG"; then die "$LOCAL_PKG exists with other bytes"; fi
    ADD_ARGS+=(--enclosure-url "${LOCAL_BASE%/}/$VERSION.pkg" --notes-url "${LOCAL_BASE%/}/$VERSION.notes.md")
else
    ADD_ARGS+=(--base-url "$RELEASES_BASE/download")
fi

# ── 2. Feed item, on a copy, before anything is created ─────────────────────
# A feed that cannot be edited or does not lint stops here, so no release is
# left without its feed item.
cp "$FEED" "$WORK/feed.xml"
feed_py "${ADD_ARGS[@]}"
feed_py lint --feed "$WORK/feed.xml" --previous "$FEED" >/dev/null

# ── 3. Release ──────────────────────────────────────────────────────────────
if [ -n "$LOCAL_BASE" ]; then
    if [ "$DRY_RUN" = true ]; then
        echo "dry run: would copy the package to $LOCAL_PKG"
    else
        cp "$PKG" "$LOCAL_PKG"
        cp "$NOTES" "$FEED_DIR/$VERSION.notes.md"
        echo "Local: $LOCAL_PKG"
    fi
else
    git -C "$RELEASE_REPO_ROOT" cat-file -e "$COMMIT^{commit}" 2>/dev/null || die "commit $COMMIT is not in this repository"
    [ -n "$(git -C "$RELEASE_REPO_ROOT" branch -r --contains "$COMMIT" 2>/dev/null)" ] \
        || die "commit $COMMIT is not on any pushed branch; push it before tagging a release at it"
    if EXISTING="$("$GHAPP_BIN" api "repos/$RELEASE_SLUG/releases/tags/v$VERSION" 2>&1)"; then
        die "release v$VERSION already exists"
    elif ! grep -q 'Not Found' <<<"$EXISTING"; then
        die "could not check for an existing release v$VERSION: $EXISTING"
    fi
    mkdir "$WORK/asset"
    cp "$PKG" "$WORK/asset/$RELEASE_ASSET"
    CREATE=("$GH_BIN" release create "v$VERSION" "$WORK/asset/$RELEASE_ASSET" --repo "$RELEASE_SLUG"
            --title "Symphony Maestro $VERSION" --notes-file "$NOTES" --target "$COMMIT")
    if [ "$CHANNEL" = beta ]; then CREATE+=(--prerelease --latest=false); else CREATE+=(--latest); fi
    if [ "$DRY_RUN" = true ]; then
        printf 'dry run: would run:'; printf ' %q' "${CREATE[@]}"; echo
    else
        "${CREATE[@]}"
        LATEST="$("$GHAPP_BIN" api "repos/$RELEASE_SLUG/releases/latest" --jq .tag_name)"
        if [ "$CHANNEL" = stable ]; then
            [ "$LATEST" = "v$VERSION" ] || die "GitHub's latest release is $LATEST, not v$VERSION"
        else
            [ "$LATEST" != "v$VERSION" ] || die "the beta v$VERSION became GitHub's latest release"
        fi
        echo "GitHub latest release: $LATEST"
    fi
fi

# ── 4. Diff, then stop ──────────────────────────────────────────────────────
diff -u "$FEED" "$WORK/feed.xml" || true
if [ "$DRY_RUN" = true ]; then
    echo "dry run: $FEED not changed"
else
    cp "$WORK/feed.xml" "$FEED"
    echo "Feed updated: $FEED (not committed or pushed)"
fi
if [ "$CHANNEL" = stable ]; then
    NEWEST_BETA="$(feed_py newest --feed "$WORK/feed.xml" --channel beta 2>/dev/null || true)"
    if [ -n "$NEWEST_BETA" ] && version_gt "$NEWEST_BETA" "$VERSION"; then
        echo ""
        echo "Hotfix rule: beta $NEWEST_BETA is above $VERSION, so beta users will not be offered it."
        echo "Merge main into dev and publish a beta that contains this fix, the same day where possible."
    fi
fi
