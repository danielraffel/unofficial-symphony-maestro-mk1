# Maestro user guide

Maestro is an independently maintained app and driver package for the original Apogee Symphony I/O MK I. Use the prebuilt signed and notarized installer unless you intend to develop or maintain the software.

## Install and connect

Use an Apple Silicon Mac running macOS 26 or later. Quit audio applications before installing: the installer replaces Maestro, stops its USB helper and, when USB support is selected, restarts the system audio service. Save your work first.

The required component installs Maestro and its embedded ThunderBridge extension. The optional USB component installs the Maestro USB audio device and its background hardware-control service. Keep USB support selected if you use that connection. If the installer reports conflicting original Apogee drivers, follow its removal instructions before retrying (see [Removing Apogee's original drivers](#removing-apogees-original-drivers)).

Open Maestro from Applications after installation. With a ThunderBridge connected, follow the system-extension approval prompt. Keep System Integrity Protection enabled; the distributed installer is intended for normal macOS security settings.

The Symphony front-panel mode selects the active transport: Symphony mode for ThunderBridge, or a USB mode for USB. In macOS Sound settings or your audio application's device settings, select the appropriate Symphony device. For the provided USB path use **Symphony I/O : Maestro USB**. USB supports 16 channels each way; ThunderBridge supports 32. Supported sample rates depend on the connection and hardware configuration.

## Find the controls

- **Input:** channel reference levels, trims and available input options. A compatible microphone-preamp module adds its corresponding controls.
- **Output:** output reference levels, trims and monitor controls.
- **Mixer:** hardware monitoring mixes, with channel levels, pan, mute and solo.
- **Input Routing and Output Routing:** map available hardware and software channels. Verify routing at a low monitoring level before use.
  - **Reset Routing** puts the page you are on back to its default, after asking: each software input records the matching hardware input, and each software output goes to the matching hardware output.
  - **Identify** (Output Routing) lights every front-panel light on the Symphony I/O so you can find it; click again to turn them off. Quitting Maestro also turns them off. With two units there is one button for each.
- **Device Settings:** the Symphony I/O itself, in the sections **Clock** (sample rate, clock source, Loop Sync, Word Clock Output), **Connection** (device name and connection, the 32 or 64 channel **Ports** choice, Rescan), **Input Monitoring** (DAW or Direct Monitor), **Volume Keys** (with two units), **Front Panel** (meter banks, Peak Hold, Over Hold), **Cards** (Optical Format, Insert Labels with an 8MicPre), **Naming** (Peripheral Prefix) and **Info** (Audio Interface Mode, firmware, cards, the ThunderBridge driver extension).
- **App Settings:** Maestro itself, in the sections **General** (appearance, tooltips, meter zone coloring, scroll positions, pop-ups), **When a Device Connects**, **Updates**, **Diagnostics & Feedback** and **About** (the Maestro and macOS versions).

Controls depend on installed modules and the selected transport. The app's built-in Help provides contextual guidance. A **Simulated** or **no hardware** indicator means the view represents a simulated configuration, not confirmation of connected hardware operation.

## Channel names

Optical channels are named after the card's optical format and the sample rate:

- **ADAT** at 44.1 and 48 kHz.
- **SMUX** at 88.2 and 96 kHz.
- **SPDIF Opt** when the optical format is set to S/PDIF.
- **N.A.** when a channel carries nothing at the current setting, for example optical channels at 176.4 and 192 kHz, or past the first pair in S/PDIF format.
- **SPDIF Cx** for an input pair that SPDIF Coax Replaces has handed to the coax input.

N.A. channels stay in place but are faded, as in Apogee's original Maestro.

Every name starts with the unit's peripheral prefix letter, set in Device Settings › Naming ("A Line 1"). The letter is stored in the Symphony.

Over ThunderBridge, Mac inputs follow the cards in slot order by default: the inputs of the card in slot 1 first, then those of slot 2. Slot 2 starts at Mac input 17, or at 13 behind a 2x6 card, which has 12 inputs. Each Mac input is named after what feeds it, so a change on Input Routing renames it.

Over ThunderBridge, Mac outputs 1-16 play through the card in slot 1 and 17-32 through the card in slot 2, in order, unless you route them elsewhere. Mac outputs keep fixed names based on their position: each is named after the output at the same position ("A Line 1", "A ADAT 9"), or "N.A." where the slot is empty, and the name does not change when you re-route it. This differs from the original, which renamed each output after the hardware it reached: an output that fed the mixer rather than a hardware output read "N.A.".

The optical format, the S/PDIF settings, the prefix letter and your routing choices are kept when the Symphony is turned off and on.

## Two units (64 channels)

This is a test build; two units have not been tried on hardware yet. Connect the first Symphony I/O to ThunderBridge port 1 and the second unit to port 2.

Audio MIDI Setup shows a **Source** menu for the ThunderBridge, on the Input and Output tabs, with two entries: **Symphony I/O: ThunderBridge** (32 channels, the default) and **Symphony I/O: ThunderBridge 64** (64 channels; 33-64 are the unit on port 2). The macOS Sound menu in the menu bar shows the selected entry's name in place of the device name, which is why the default entry reads like the device name. Apogee's software called these "Port 1: 32ch" and "Port 1-2: 64ch".

In Maestro the same setting is **Ports** in Device Settings › Connection, with the choices **32 channels** and **64 channels (two units)**. If no second unit is found on port 2, 64 channels is refused, the device stays at 32 and Device Settings › Connection says why. Your DAW should keep the device selected when you switch.

## Appearance and updates

In **App Settings › General**, choose Auto, Light or Dark appearance; **Show tooltips** there controls the short explanations shown when you hold the pointer over a control; it is on by default. Software updates use Sparkle and the configured project update feed. An available update is not installed merely by opening this guide; follow the updater's prompts and save audio work before installing.

**Update channels.** Maestro normally offers stable versions only. In **App Settings › Updates** you can choose **Beta** to get versions that are still being tested. They may have bugs and can replace the ThunderBridge driver. Choose **Stable** again to stop getting them; Maestro then offers to reinstall the latest stable version. If you install a beta package yourself, Maestro sets that copy to Beta when it next reads the update feed, and it keeps getting betas until you choose Stable.

## Removing Apogee's original drivers

Maestro isn't supported alongside Apogee's original Symphony I/O drivers: the two can interfere with each other and cause problems, including crashes. The installer will not install Maestro for the first time while they are present (an update of Maestro goes ahead), and **Device Settings** shows a warning at the top while they are found.

To remove them:

1. Download Apogee's latest installer, [Symphony I/O Release 5.5](https://22712264.fs1.hubspotusercontent-na1.net/hubfs/22712264/Software%20Installers/Symphony%20IO/SymphonyIO_Release_5.5.dmg), open the disk image and choose **Uninstall**. Use this one even if you installed from an older release: older uninstallers leave parts behind.
2. Restart your Mac.
3. Reinstall Maestro, then restart once more.

Apogee's Uninstall also removes Maestro and Apogee Maestro 2, and resets macOS's audio device settings. If you use Apogee Maestro 2 with another Apogee interface, reinstall it from Apogee afterwards.

<details>
<summary>If the warning is still there after uninstalling and restarting</summary>

macOS can keep its own stored copy of Apogee's kernel extensions in **/Library/StagedExtensions** and load it again after a restart. No uninstaller from Apogee removes that copy. Maestro's warning says when it finds one (open **What was found**).

This macOS command asks it to clear those stored copies, and may help:

```
sudo kmutil clear-staging
```

1. Open **Terminal** (in Applications › Utilities).
2. Paste the command, press Return, and type your Mac's password when asked.
3. Restart your Mac.

This is a suggestion, not a guaranteed fix: we haven't been able to test it on a Mac in this state, and Maestro can't do it for you. Leave System Integrity Protection on.

</details>

<details>
<summary>If you can't run Apogee's uninstaller</summary>

If Apogee's uninstaller won't run on your Mac, these are the parts of Apogee's original Symphony I/O software that need to be removed. We recommend the uninstaller whenever it runs. Restart afterwards.

- Kernel extensions in **/Library/Extensions**: **Symphony64Thunderbridge.kext**, **Symphony64.kext**, **SymphonyIOUSBOverideDriver.kext**, **SymphonyMobile.kext**
- Audio plug-ins: the **Symphony Systems** folder in **/Library/Audio/Plug-Ins/HAL/Apogee**
- Background helpers: **com.SymphonyDaemon.plist** and **com.SymphonyIOUSBDaemon.plist** in **/Library/LaunchDaemons**

For reference only, the complete list of what Apogee's Release 5.5 uninstaller deletes is [published here](https://gist.github.com/danielraffel/2c7d4f68adb562e7c94245907295320b). It is kept for education, in case a future macOS can no longer run Apogee's uninstaller. It is not a procedure, and we don't recommend removing those files by hand.

</details>

## Remove the software

The installed app includes an uninstall script at `/Applications/Maestro.app/Contents/Resources/uninstall.sh`. Review its instructions before running it with administrator privileges. Removing audio components interrupts audio; an active system extension may require an additional macOS removal step. Keep a known-good installer available before changing the installation.

## Help and feedback

Report issues through [the project repository](https://github.com/danielraffel/unofficial-symphony-maestro-mk1/issues). Include app/driver versions, macOS version, connected modules, transport and steps to reproduce. Review diagnostics before sharing them. Apogee does not maintain or provide support for this unofficial project.
