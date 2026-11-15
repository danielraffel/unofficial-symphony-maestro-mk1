# Maestro user guide

Maestro is an independently maintained app and driver package for the original Apogee Symphony I/O MK I. Use the prebuilt signed and notarized installer unless you intend to develop or maintain the software.

## Install and connect

Use an Apple Silicon Mac running macOS 26 or later. Quit audio applications before installing: the installer replaces Maestro, stops its USB helper and, when USB support is selected, restarts the system audio service. Save your work first.

The required component installs Maestro and its embedded ThunderBridge extension. The optional USB component installs the Maestro USB audio device and its background hardware-control service. Keep USB support selected if you use that connection. If the installer reports conflicting original Apogee drivers, follow its removal instructions before retrying.

Open Maestro from Applications after installation. With a ThunderBridge connected, follow the system-extension approval prompt. Keep System Integrity Protection enabled; the distributed installer is intended for normal macOS security settings.

The Symphony front-panel mode selects the active transport: Symphony mode for ThunderBridge, or a USB mode for USB. In macOS Sound settings or your audio application's device settings, select the appropriate Symphony device. For the provided USB path use **Symphony I/O : Maestro USB**. USB supports 16 channels each way; ThunderBridge supports 32. Supported sample rates depend on the connection and hardware configuration.

## Find the controls

- **Input:** channel reference levels, trims and available input options. A compatible microphone-preamp module adds its corresponding controls.
- **Output:** output reference levels, trims and monitor controls.
- **Mixer:** hardware monitoring mixes, with channel levels, pan, mute and solo.
- **Input Routing and Output Routing:** map available hardware and software channels. Verify routing at a low monitoring level before use.
- **Device Settings:** device preferences and available hardware options.
- **System Setup:** clock and sample-rate configuration and system information.

Controls depend on installed modules and the selected transport. The app's built-in Help provides contextual guidance. A **Simulated** or **no hardware** indicator means the view represents a simulated configuration, not confirmation of connected hardware operation.

## Channel names

Optical channels are named after the card's optical format and the sample rate:

- **ADAT** at 44.1 and 48 kHz.
- **SMUX** at 88.2 and 96 kHz.
- **SPDIF Opt** when the optical format is set to S/PDIF.
- **N.A.** when a channel carries nothing at the current setting, for example optical channels at 176.4 and 192 kHz, or past the first pair in S/PDIF format.
- **SPDIF Cx** for an input pair that SPDIF Coax Replaces has handed to the coax input.

N.A. channels stay in place but are faded, as in Apogee's original Maestro.

Every name starts with the unit's peripheral prefix letter, set in Device Settings ("A Line 1"). The letter is stored in the Symphony.

Over ThunderBridge, Mac inputs follow the cards in slot order by default: the inputs of the card in slot 1 first, then those of slot 2. Slot 2 starts at Mac input 17, or at 13 behind a 2x6 card, which has 12 inputs. Each Mac input is named after what feeds it, so a change on Input Routing renames it.

Over ThunderBridge, Mac outputs 1-16 play through the card in slot 1 and 17-32 through the card in slot 2, in order, unless you route them elsewhere. Mac outputs keep fixed names based on their position: each is named after the output at the same position ("A Line 1", "A ADAT 9"), or "N.A." where the slot is empty, and the name does not change when you re-route it. This differs from the original, which renamed each output after the hardware it reached: an output that fed the mixer rather than a hardware output read "N.A.".

The optical format, the S/PDIF settings, the prefix letter and your routing choices are kept when the Symphony is turned off and on.

## Two units (64 channels)

This is a test build; two units have not been tried on hardware yet. Connect the first Symphony I/O to ThunderBridge port 1 and the second unit to port 2.

Audio MIDI Setup shows a **Source** menu for the ThunderBridge, on the Input and Output tabs, with two entries: **Symphony I/O: ThunderBridge** (32 channels, the default) and **Symphony I/O: ThunderBridge 64** (64 channels; 33-64 are the unit on port 2). The macOS Sound menu in the menu bar shows the selected entry's name in place of the device name, which is why the default entry reads like the device name. Apogee's software called these "Port 1: 32ch" and "Port 1-2: 64ch".

In Maestro the same setting is **Ports** in System Setup › Device Info, with the choices **32 channels** and **64 channels (two units)**. If no second unit is found on port 2, 64 channels is refused, the device stays at 32 and Device Info says why. Your DAW should keep the device selected when you switch.

## Appearance and updates

Choose Auto, Light or Dark appearance in Device Settings. Software updates use Sparkle and the configured project update feed. An available update is not installed merely by opening this guide; follow the updater's prompts and save audio work before installing.

**Update channels.** Maestro normally offers stable versions only. In **Device Settings › Preferences** you can choose **Beta** to get versions that are still being tested. They may have bugs and can replace the ThunderBridge driver. Choose **Stable** again to stop getting them; Maestro then offers to reinstall the latest stable version. If you install a beta package yourself, Maestro sets that copy to Beta when it next reads the update feed, and it keeps getting betas until you choose Stable.

## Remove the software

The installed app includes an uninstall script at `/Applications/Maestro.app/Contents/Resources/uninstall.sh`. Review its instructions before running it with administrator privileges. Removing audio components interrupts audio; an active system extension may require an additional macOS removal step. Keep a known-good installer available before changing the installation.

## Help and feedback

Report issues through [the project repository](https://github.com/danielraffel/unofficial-symphony-maestro-mk1/issues). Include app/driver versions, macOS version, connected modules, transport and steps to reproduce. Review diagnostics before sharing them. Apogee does not maintain or provide support for this unofficial project.
