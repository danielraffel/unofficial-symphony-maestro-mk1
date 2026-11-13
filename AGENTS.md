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

Use one authoritative instruction file; avoid duplicating this guidance in a
separate CLAUDE.md.
