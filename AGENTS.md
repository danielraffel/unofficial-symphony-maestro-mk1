# Contributor guidance

This repository contains the Maestro macOS app, ThunderBridge DriverKit extension,
USB AudioServerPlugin and VolumeProxy, and their packaging tools.

## Preserve the shipping product

Keep the desktop app, both shipping transport paths, shared protocol code, helpers,
installer resources and install/uninstall scripts buildable together. Preserve
third-party license notices. Do not add original manufacturer source, private
reference documents, signing credentials or provisioning profiles to Git.

## Private reference material

The maintainer keeps the original manufacturer source and internal working
documents in a separate private checkout, expected as a sibling directory named
`symphony-maestro`. The `Evidence: og_source/...` comments in this source refer to
`og_source/` there, and plans and investigation notes are in its `Docs/` folder
(the current work plan is `Docs/2026-11-feedback-work-plan.md`, which also records
where the private build configuration lives). Read that material in place. Never
copy, symlink or vendor any of it into this checkout: its `Docs/` would also
collide with the tracked `docs/` on a case-insensitive volume.

## Build and test boundaries

The Swift package is in `Apps/Maestro`. Its unit tests and simulator do not establish
physical audio or driver installation success. Installer assembly is in
`Installer/build-installer.sh`; ThunderBridge uses
`Drivers/Thunderbolt/Scripts/build.sh`. Inspect their prerequisites before running
these scripts: packaging includes signing/notarization and install scripts affect
system audio. Keep build, install and publish operations separate.

Use explicit external signing inputs and never log secret values. Keep SIP enabled.
Do not alter driver activation ownership, hardware timing or bundle identifiers as
part of routine build cleanup. Verify the installed and loaded driver identity
against the built artifact after any deliberate installation.

## Release safeguards

Preserve established app, package, Sparkle and driver version sequences. Never derive
release numbering from a new checkout's commit count. A production appcast change
can deliver software to existing installations; source/site changes must not trigger
it. Do not replace published release assets. Test upgrades with a separate feed and
record the exact signed/stapled package hash before release approval.

## Release channels

There are two lines and one update feed.

- `main` is **stable**: the `0.8.x` versions until a beta is promoted. The
  README download and GitHub's "latest" release are always a stable version.
- `dev` is **beta**: the next minor line (`0.9.x`). A beta is a GitHub
  pre-release, and its feed item carries `<sparkle:channel>beta</sparkle:channel>`.
  Released builds ignore beta items unless the user chose Beta in Device
  Settings › Preferences, or installed a beta package by hand.
- The feed is `appcast.xml` on `main`, for both channels. A beta's feed item is
  a commit on `main` that changes only that file.

What goes where:

- Driver changes, and anything that could break a setup that works today, go
  to `dev` and ship as a beta first. `main` takes fixes and promoted betas.
- Merge `main` into `dev` after every change to `main`. Merge `dev` into `main`
  only when a beta is promoted.
- A beta user is never offered a lower-numbered stable version. After a stable
  fix release, release a beta that contains it, or beta users do not get the fix.
- Every release needs its own app version, higher than what it replaces:
  Sparkle compares app versions, not package build numbers. A beta must be above
  every feed item; a stable version must be above the newest stable item (so a
  stable fix may sit below an outstanding beta).
- 0.8.40 is the oldest version Maestro can go back to from a beta
  (`UpdateFloor.stable`). Do not publish a stable item below it.
- Publish the package that was tested; never rebuild after testing. Promoting a
  beta re-labels the same package as stable, with new notes.
- A release whose behaviour differs from the previous one says so at the top of
  its notes, under "Changes that may affect your setup".

Tools (each explains itself with `--help` or in its header):

- `Tools/check-versions.py --feed <feed> --channel stable|beta`: can this
  version be published on that channel?
- `Tools/publish-release.sh --channel stable|beta --pkg … --notes … --feed …`
  with `--github` (a real release) or `--local-base-url` (a rehearsal). There is
  no default destination.
- `Tools/promote-beta.sh [VERSION] --notes … --feed … [--github]`.
- `Tools/stable-notes.py [--out notes.md] [--apply]`: drafts the stable notes
  for a promotion from every `## X.Y.Z (beta)` section in CHANGELOG.md since
  the last stable one, merged under one heading each, and lists commits on
  `main` since the last stable tag that no beta describes.

Promoting ("merge dev/beta to main/stable"): run `Tools/stable-notes.py --out
<notes.md>` on `dev`; edit the draft into one release (remove duplicates such
as repeated driver-update lines, drop tester-only requests, write a short
introduction, cover any `main`-only commits it lists); run
`Tools/promote-beta.sh --notes <notes.md> --feed <main>/appcast.xml --github`;
add the same text to CHANGELOG.md as `## X.Y.Z` above the beta sections
(`--apply` does this; the beta sections stay as history); land the feed on
`main`, merge `dev` into `main`, verify with `stable`, and open the next minor
line on `dev`.
- `Tools/verify-sparkle-feed.sh <version> <feed> stable|beta`.
- `Tools/test-feed-tools.sh` and `Tools/test-installer-tools.sh` test the tools.

The tools print the feed diff and stop; they never commit or push. Landing the
feed change on `main` is the moment users are offered the update. To try a feed
without touching the live one, serve a copy locally and point one Mac at it with
the `SUFeedURL` user default of `com.danielraffel.maestro`; delete the default
afterwards.

Do not push, publish or promote without the maintainer's explicit go-ahead. The
step-by-step procedure, and where the private build inputs are, is in the
private checkout: `Docs/public-repo-release-runbook.md`.

Use one authoritative instruction file; avoid duplicating this guidance in a
separate CLAUDE.md.
