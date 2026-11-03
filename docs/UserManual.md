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

## Appearance and updates

Choose Auto, Light or Dark appearance in Device Settings. Software updates use Sparkle and the configured project update feed. An available update is not installed merely by opening this guide; follow the updater's prompts and save audio work before installing.

## Remove the software

The installed app includes an uninstall script at `/Applications/Maestro.app/Contents/Resources/uninstall.sh`. Review its instructions before running it with administrator privileges. Removing audio components interrupts audio; an active system extension may require an additional macOS removal step. Keep a known-good installer available before changing the installation.

## Help and feedback

Report issues through [the project repository](https://github.com/danielraffel/unofficial-symphony-maestro-mk1/issues). Include app/driver versions, macOS version, connected modules, transport and steps to reproduce. Review diagnostics before sharing them. Apogee does not maintain or provide support for this unofficial project.
