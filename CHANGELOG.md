# Changelog

## 0.8.36 (build 1032)

### Added

- Experimental: the ThunderBridge driver now also attaches to the original Symphony 64 PCIe card (`pci19c2,2100`) in a Thunderbolt chassis. Earlier builds contained support for the card but never matched it, so it was not detected. This has not been verified on that hardware; reports are welcome.

### Release notes

- This release updates the ThunderBridge driver to build 120 (0.10.15). macOS replaces the installed driver; close audio applications first, and disconnect and reconnect the ThunderBridge if Maestro asks you to.
- Nothing changes for ThunderBridge itself: the driver code is identical to build 119.

## 0.8.35 (build 1031)

### What's better

- **Your settings stay put.** Maestro used to forget some settings when you switched tabs or reopened the app, even though the Symphony itself still had them. It now remembers them on your Mac and sets them on the Symphony again each time it connects, which is how Apogee's original software worked. They survive switching tabs, quitting Maestro, and turning the Symphony off and on. This covers the speaker mode, speaker set, dim and mono on the Output tab; dim, mono and source for each headphone; the front panel meter sources; Peak Hold and Over Hold; and the peripheral prefix.
- **The knobs on the Symphony and the knobs in Maestro now agree (USB).** Turn the volume knob on the front of the Symphony and the speaker or headphone level in Maestro moves with it. Mute and unmute from the front panel show up in Maestro too. After you stop turning the speaker knob, your Mac's volume slider catches up. Clearing the meters on the front panel clears them in Maestro as well.
- **Headphone knobs match the Symphony.** The headphone knobs in Maestro went much lower than the Symphony can, so the Symphony's quietest setting sat in the middle of the knob. They now cover the same range, 0 to -64 dB.
- **No more clicking after turning the Symphony off and on (USB).** If you power-cycled the Symphony while Maestro was open, playback could come back with a digital clicking sound that only went away when you unplugged and replugged the USB cable. Maestro was talking to the Symphony while it was still starting up. It now waits until the Symphony is ready.
- **Clock Source shows what is in use.** In System Setup, the Clock Source menu used to snap back to Internal when you returned to the tab, even though the Symphony was still using the source you chose.
- **You can close the window.** File > Close Window (Command-W) now works. Closing the window does not quit Maestro: it keeps looking after the Symphony in the background, and clicking its Dock icon brings the window back. Use Quit to stop it.
- **Peak Hold and Over Hold show the Symphony's real setting (USB)** instead of the last thing Maestro sent.
- **Outputs no longer vanish with AD-16X and DA-16X converters.** With one of these connected through a ThunderBridge, Maestro could show every fader the first time and then none at all from then on. It now keeps showing the full set of channels.

- **Help has two new answers** near the end of Common questions: Maestro works with one Symphony I/O at a time, and what to expect with AD-16X, DA-16X and Rosetta converters.

### Good to know

- Maestro only remembers a setting once you have changed it in Maestro. Until then it shows the default.
- Volume, mute, headphone levels and Clock Source are never changed by Maestro when it connects, because you may have set them on the Symphony itself.
- Following the front panel knob works over USB. It does not yet work over ThunderBridge.

### Release notes

- The ThunderBridge driver is unchanged (build 119), so macOS will not ask you to approve it again.
- Installing briefly interrupts audio while the USB audio helper is replaced.

## 0.8.34 (build 1030)

### Fixed

- USB Device Settings now reads and writes the optical format for output-capable cards, so Card 2 correctly shows ADAT/SMUX and S/PDIF when using the 16 Analog In / 16 Digital Out configuration.
- USB optical-format changes now wait for a confirmed hardware readback, preventing the picker from reverting or showing a stale selection immediately after a change.

### Release notes

- This is the first release prepared and built from the source code shared in this public repository.
- This release keeps the existing 0.8.x version continuity and ThunderBridge driver build 119.
- The packaged installer is the recommended installation path. Building from source requires Apple DriverKit entitlements and private signing credentials; see [`docs/BUILDING.md`](docs/BUILDING.md).
- Sparkle update signing remains controlled by the project maintainer. The public source does not include the private signing key.

