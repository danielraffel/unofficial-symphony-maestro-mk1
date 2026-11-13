# Changelog

## 0.8.36 (build 1032)

### Added

- Experimental: the ThunderBridge driver now also attaches to the original Symphony 64 PCIe card (`pci19c2,2100`) in a Thunderbolt chassis. Earlier builds contained support for the card but never matched it, so it was not detected. This has not been verified on that hardware; reports are welcome.

### Release notes

- This release updates the ThunderBridge driver to build 120 (0.10.15). macOS replaces the installed driver; close audio applications first, and disconnect and reconnect the ThunderBridge if Maestro asks you to.
- Nothing changes for ThunderBridge itself: the driver code is identical to build 119.

## 0.8.35 (build 1031)

### Fixed

- System Setup now shows the Clock Source you selected when you return to the tab. Previously the picker went back to Internal while the hardware stayed on the source you had chosen. Over ThunderBridge the value is read from the driver; over USB it is remembered until Maestro quits.
- Over ThunderBridge, Peak Hold, Over Hold, the front panel meter sources, the peripheral prefix, and the Output tab's speaker mode, dim, mono and headphone source no longer return to their defaults on screen after you switch tabs. These are remembered until Maestro quits; they are not yet read from the hardware, so they show their defaults again after a relaunch.

### Release notes

- App-only update. The ThunderBridge driver stays at build 119, so no driver re-approval is needed.

## 0.8.34 (build 1030)

### Fixed

- USB Device Settings now reads and writes the optical format for output-capable cards, so Card 2 correctly shows ADAT/SMUX and S/PDIF when using the 16 Analog In / 16 Digital Out configuration.
- USB optical-format changes now wait for a confirmed hardware readback, preventing the picker from reverting or showing a stale selection immediately after a change.

### Release notes

- This is the first release prepared and built from the source code shared in this public repository.
- This release keeps the existing 0.8.x version continuity and ThunderBridge driver build 119.
- The packaged installer is the recommended installation path. Building from source requires Apple DriverKit entitlements and private signing credentials; see [`docs/BUILDING.md`](docs/BUILDING.md).
- Sparkle update signing remains controlled by the project maintainer. The public source does not include the private signing key.

