# Local release candidate

This file records the state of the local public-source candidate. It is a
review aid, not a release announcement. No GitHub push, release upload,
Sparkle production-feed update, or Pages deployment has been performed.

## Candidate identity

- Worktree: `prepare/public-source-20261103`
- Source/package build commit: `8816dca8248112e21d21d935cb5c2db872fdcaed`
- Evidence-record commit: `4439aa6` (documentation only; package bytes are from the source/package commit above)
- App version: `0.8.34`
- Package build: `1030`
- ThunderBridge dext: `0.10.14/119`
- Local package: `Installer/build/output/UnofficialSymphonyMaestro-0.8.34-b1030.pkg`
- SHA-256 (stapled package): `f6e82cbf09a8671db8393ea1dfb533790a686cd8ee88c9ae3069ff3f595c302c`
- Sparkle package signature (private rehearsal): `NGXTyju504vTLKaFzx2rVevZpTPOMBsShZt2Rwx9VDKTaOxzkZdPsLulj9VAmTaElxy1hn1OHIB5pQCPs08HBw==`

The package was built with private Developer ID signing inputs from an
external environment file, notarized and stapled, installed locally, and the
ThunderBridge extension was observed as activated and enabled. The local
install restored the ability to select 192 kHz. The known 192 kHz secondary
input corruption remains an open hardware/driver issue and is not changed by
this release-preparation work.

## Checks completed

- `python3 Tools/check-public-source.py`
- `python3 Tools/check-versions.py`
- `git diff --check`
- Swift package tests: 559 tests across 32 suites
- Production DriverKit compile and link
- Signed package assembly
- Package notarization, stapling, and validation accepted
- Local install through the privileged package wrapper succeeded
- USB hardware validation: Card 2 optical format appears and remains selectable after ADAT/SMUX ↔ S/PDIF changes
- Local website assembly with `python3 Tools/build-website.py`
- Private Sparkle package-signature rehearsal and verification
- Production `appcast.xml` unchanged; checksum:
  `3d1962a748e43b8133a758ee7747928bed72e7ab34b38e6a04ad5c4ec94919fb`

## Package comparison

The source baseline is the private release-correlated `0.8.33` source commit
(`b1873c2882a18496dd93aa3453acec38545cb013`); this candidate only bumps the
app/package/dext versions and selects the external private production profile
needed for SIP-enabled DriverKit activation. It is not expected to be
byte-identical to an older signed package because signing timestamps, build
metadata and version changes differ. The USB optical-format mapper/readback
fix is an intentional source difference; fresh signing and notarization also
necessarily change package bytes.

Private keys, provisioning profiles, signing configuration, original
manufacturer source, private documentation, temporary inspection directories,
and the abandoned mobile/USB-DriverKit experiments are outside the tracked
public source boundary.

The current index and all reachable Git history were also checked for the
excluded private directory names and credential filenames; no matches were
found.

## Open engineering gates

### ThunderBridge 192 kHz / AD16

An older AD16 FPGA revision (`0x6`) can report a locked 192 kHz clock while
the secondary input bank delivers corrupt/full-scale samples. The source keeps
192 kHz available; it is not removed as a workaround. The explicit vendor
sample-rate command experiment was removed because it was unproven and did not
establish a fix. Root cause and a source-level fix remain open.

### 8MicPre

The reported issues (reference-level mapping, variable-gain/phase controls,
and software-return/master mixer behavior) remain open. They require targeted
hardware or signal-path verification before changing the implementation.

### Visual review

The website/gallery builds locally. Screenshots are simulator captures where
noted in the README. The gallery uses CSS `drop-shadow`, so transparent-window
captures render with natural corners; `output.png` is still an opaque capture
and should be replaced with a fresh simulator capture if Daniel wants every
gallery item to have the same silhouette.

## Publication gate

Do not publish this candidate until Daniel reviews the source audit, package,
screenshots, and the two hardware issue decisions. A Sparkle rehearsal must use
a private test feed and a separately generated signature; the production
appcast must remain unchanged.
