# Building Maestro (advanced)

**For everyday use, download the signed and notarized installer from
[Releases](https://github.com/danielraffel/unofficial-symphony-maestro-mk1/releases).**
Compiling the app is only one part of building this product. Installing a working
ThunderBridge driver with SIP enabled requires Apple-approved entitlements,
matching provisioning profiles, and the correct Developer ID certificates.
Obtaining and configuring these approvals can be complicated. This source is
available for learning, future maintenance, and developers willing to undertake
that setup. Keep SIP enabled; disabling platform protections is not the supported
build or installation workflow.

## Source layout

- `Apps/Maestro`: desktop app, device control, simulator and Swift tests.
- `Drivers/Thunderbolt`: shipping ThunderBridge DriverKit extension.
- `Drivers/AudioServerPlugin` and `Drivers/VolumeProxy`: shipping USB HAL support
  and hardware volume-key helper, using Apple's USB audio stack.
- `Shared`: shared protocols and utilities.
- `Installer`: package assembly, resources and installation scripts.
- `Tools`: build, verification and diagnostic helpers.
- `website`: landing-page source; `docs/screenshots`: gallery assets.

The abandoned USB DriverKit experiment and mobile app are not part of the shipped
product and are not included. Original manufacturer source and private reference
documents are excluded. Third-party notices are in `docs/third-party`.

## Tools and app-only checks

Use an Apple Silicon Mac, full Xcode with the DriverKit SDK selected through
`xcode-select`, Swift 6 or newer, CMake, Python 3 and the standard macOS signing
and packaging tools. The shipping product targets macOS 26 or later. Dependency
resolution downloads Sparkle and libASPL; their versions are pinned in the source.

```sh
swift test --package-path Apps/Maestro --jobs 4
swift build --package-path Apps/Maestro -c release --jobs 4
```

These commands do not install a driver. A successful app build or simulator test
does not establish that hardware audio, DriverKit activation or updates work.

The installed AD16 FPGA revision also matters. During development, revision `0x6`
produced corrupt secondary-board samples at 192 kHz even though the clock reported
locked; the archived updater identifies revision `0xF` as its normal target. The
shipping source keeps 192 kHz available, because the behavior is not universal and
removing the rate would hide the failure rather than fix it. Do not flash firmware
as part of a normal build: firmware updates are a separate, hardware-specific
recovery decision.

## Apple approvals and identities

Read Apple's [entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/)
and submit the [DriverKit/system-extension request](https://developer.apple.com/contact/request/system-extension/)
for your own team and registered identifiers. The shipped ThunderBridge path needs
DriverKit, DriverKit Family Audio and DriverKit PCI transport authorization,
including the approved PCI matching values. The client app needs system-extension
installation and DriverKit UserClient Access to the extension it opens. Inspect
the checked-in entitlement files and driver `Info.plist` for the exact values.

Hardware identifiers are public matching data: ThunderBridge PCI vendor **6594**,
device **8704**; Symphony I/O USB vendor **3168**. They are not signing secrets.
Apple approval is team-specific: copying these values or another developer's
bundle IDs does not grant permission to sign or install a driver.

Historical requests for this project selected Audio, PCI Transport, USB Transport
and UserClient Access, and included both `com.danielraffel.maestro.thunderbridge`
and `com.danielraffel.maestro.usb`. The latter belongs to the abandoned USB DriverKit
experiment; the shipping USB path uses Apple's USB audio stack. Do not request
USB DriverKit transport solely to build the currently shipped USB implementation.
Request the capabilities actually required by your targets and confirm them with
Apple if the portal or generated profiles disagree.

For UserClient Access, the array contains the **driver-extension bundle IDs** the
app opens, not the client application's own ID. For the shipping ThunderBridge
target that is `com.danielraffel.maestro.thunderbridge`. Compare the generated
Developer ID profile against the signed app's entitlements; portal checkboxes
alone are insufficient. `Tools/verify-profile.sh` provides profile checks.

Obtain Developer ID Application and Developer ID Installer certificates and the
appropriate Developer ID provisioning profiles. Their private keys must remain
in your own signing keychain. This checkout retains the project's shipping bundle
IDs in source, plists and installer scripts. Forks must consistently replace those
IDs, team values, application groups, helper paths and entitlement references;
setting a team variable alone does not convert this into a distributable fork.
Do not install a fork over the official app while testing identity changes.

## Private build configuration

Copy `.env.example` to a location **outside this checkout**, set its permissions
to `600`, and fill in the certificate identities, already-unlocked keychain,
external app/driver profiles and notarization configuration. Never commit private
keys, credentials or profiles. The file is sourced as shell configuration: use
only a file you trust. No private project directory is needed by the build.

```sh
MAESTRO_ENV_FILE=/absolute/path/to/private-build.env bash Installer/build-installer.sh
```

Standalone component build scripts compile without signing or installation. The
old direct-deploy helpers are excluded: they assumed private signing setup and
modified live system audio. Use the full package pipeline and its bundled install
and uninstall scripts to keep shipping components together.

The default pipeline builds the shipping components, signs them, assembles the
PKG, submits it to Apple's notarization service, and staples the accepted ticket.
It does not upload a GitHub release or change the Sparkle feed. `--skip-notarize`
builds a signed local test package; it is not a distribution-ready installer.
Avoid `--skip-build` for release validation because it reuses previous binaries.

Versions are recorded in `Tools/versions.json` and the app version in
`Apps/Maestro/MaestroCore/MaestroCore.swift`; keep them consistent. Preserve the
public app, package and dext version sequences. Build numbers cannot be derived
from commit counts after migrating repositories. Signing timestamps, build
metadata and version changes mean PKGs are not expected to be byte-identical.

## Sparkle and release validation

Sparkle verifies update packages using an Ed25519 signature. Its public key is
embedded in the app; the project's private signing key is **not shared**. Forks
must generate their own key with Sparkle's `generate_keys`, embed their public
key, and configure their own HTTPS appcast and release destinations. Never use
the production appcast to rehearse an update.

Freeze the final signed and stapled PKG before producing its Sparkle signature,
SHA-256 and byte length. Any later change requires regenerating those values.
Validate signature verification separately from an actual released-client update:
a locally generated signature alone does not prove the updater can download,
verify and install the package. Keep test feeds private and isolated.

Before release, verify package signature and notarization, compare payloads and
entitlements, and deliberately test installation, driver activation, audio and
updating on a suitable machine. Installation changes system audio components;
unit tests cannot replace these hardware checks. Source publication, website
deployment and release/appcast publication are separate operations.
