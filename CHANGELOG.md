# Changelog

## 0.8.35 (build 1031)

### Fixed

- Device settings no longer forget what you chose. Maestro now keeps these settings on your Mac and writes them back to the Symphony each time it connects, which is how the original Apogee software worked. They survive switching tabs, quitting Maestro, and power-cycling the unit.
  - Over ThunderBridge: Peak Hold, Over Hold, the front panel meter sources, the peripheral prefix, and the Output tab's speaker mode, speaker set, dim, mono and headphone source.
  - Over USB: Peak Hold, Over Hold and the peripheral prefix. The other USB settings were already read from the hardware.
- System Setup now shows the Clock Source in use when you return to the tab. Previously the picker went back to Internal while the hardware stayed on the source you had chosen. Over ThunderBridge it is read from the driver. Over USB it is remembered until Maestro quits.

### Known limits

- Only settings changed through Maestro are saved. A setting you have not touched in Maestro still shows its default until you set it once.
- Because Maestro writes its saved settings on connect, a change made on the unit's front panel while Maestro was closed is replaced by the saved value. Clock Source is the exception: it is never written on connect.
- The on-screen volume does not yet follow the front panel encoder over ThunderBridge.

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

