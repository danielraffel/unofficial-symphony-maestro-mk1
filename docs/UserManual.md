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
  - **Trims can be typed.** Press **Show Trims** on the Input or Output tab, click the trim value under a channel's trim fader, type the value and press Return. Tab applies it and moves to the next channel's trim, Shift-Tab to the previous one, and Esc leaves it unchanged. A value outside the fader's range is set to the nearest value the fader allows. The box beside the trim value shows the meter level to a tenth of a dB, for calibrating against a tone.
- **Mixer:** hardware monitoring mixes. Input strips have level, pan, mute and solo; Software Return has a stereo fader, mute and solo. The value under each fader can be typed in the same way as a trim, and Tab moves along the strips to Software Return and Master.
  - **By default no mixer feeds an output.** Every hardware output plays the matching software output directly (1-2 → Line 1/2 and so on), so you hear your Mac's audio directly and your inputs only through your DAW, and the Mixer page does nothing until you route a mixer to an output.
  - **The Mixer only changes outputs that are fed from a mixer.** In Output Routing, route Mixer 1 or Mixer 2 to an output and that mixer's controls apply to it: your Mac's audio arrives through Software Return, and Master sets the level.
  - **You hear an input directly through the Symphony only when its strip is unmuted in a mixer that feeds an output in Output Routing.** There is no other setting for it.
  - **Mixer 1 and Mixer 2 are separate.** A control on Mixer 2 changes only outputs fed from Mixer 2.
  - **Over USB,** Software Return mute behaves slightly differently with "Symphony I/O : Maestro USB" and "Symphony I/O : USB Audio". Maestro's Help has the details under "The Mixer over USB".
- **Input Routing and Output Routing:** map available hardware and software channels. Verify routing at a low monitoring level before use.
  - **Reset Routing** puts the page you are on back to its default, after asking: each software input records the matching hardware input, and each software output goes to the matching hardware output.
  - **Identify** (Output Routing) lights every front-panel light on the Symphony I/O so you can find it; click again to turn them off. Quitting Maestro also turns them off. With two units there is one button for each.
- **Device Settings:** the Symphony I/O itself, in the sections **Clock** (sample rate, clock source, Loop Sync, Word Clock Output), **Connection** (device name and connection, the 32 or 64 channel **Ports** choice, **VBus**, Rescan), **Volume Keys** (see below), **Front Panel** (meter banks, Peak Hold, Over Hold), **Cards** (Optical Format, Insert Labels with an 8MicPre), **Naming** (Peripheral Prefix) and **Info** (Audio Interface Mode, firmware, cards, the ThunderBridge driver extension).
  - **Volume Keys › Audio Output** chooses what the Mac's volume and mute keys control: **Speaker** (the default), **Headphone 1** or **Headphone 2**, as in Apogee's software. The choice is kept for each Symphony I/O; on ThunderBridge and PCIe it takes effect when Maestro opens (after a restart, until then, the keys control the speaker, or Headphone 1 if the outputs are set to Line), and turning up or unmuting waits about five seconds after the Mac starts or wakes, the Symphony reconnects, the Ports setting or the VBus size changes, or macOS restarts its audio (turning down and muting work at once). Setting Analog Out Format to Line on the Output page changes Audio Output to **Headphone 1**, as in Apogee's software; it stays there when you leave Line, until you change it. With **Speaker (0ch)** chosen in Line mode the volume keys do not change a level (the mute key still mutes the speaker output). A unit without an analog output card offers the headphones only. With two units at 64 channels, **Peripheral** chooses the unit first. With converters only, the choices are **Mixer 1 level** (the keys turn Mixer 1 down and up, heard on outputs fed from Mixer 1) and **None**; that level control is our addition, Apogee's software had none for converters.
- **App Settings:** Maestro itself, in the sections **General** (appearance, tooltips, meter zone coloring, scroll positions), **When a Device Connects**, **Updates**, **Diagnostics & Feedback** and **About** (the Maestro and macOS versions).

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

## VBus

VBus adds virtual channels to the Symphony's audio device for sending audio from one application to another, or from one place to another in the same application: what is played to **VBout 1** is recorded from **VBin 1**, and so on. Nothing on these channels reaches the hardware. For example, in Logic set the output of several tracks to VBout 1-2 and record a new track from VBin 1-2 to print a submix.

Choose the number of channels under **VBus** in Device Settings › Connection: **None** (the default), or 2, 4, 8, 16, 32, 48 or 64 channels, as in Apogee's software. VBus is available on ThunderBridge and the Symphony 64 PCIe card, with a Symphony I/O or with converters alone, and not over USB. The VBus channels come after the hardware channels: from channel 33, or from 65 when 64 channels are selected under Ports (they move when you change Ports). The choice is kept for each card and set again when Maestro opens; after a restart of the Mac the VBus channels appear once Maestro is open.

After changing VBus, quit and reopen your audio applications; if they still do not show the VBus channels, restart the Mac.

## Appearance and updates

In **App Settings › General**, choose Auto, Light or Dark appearance; **Show tooltips** there controls the short explanations shown when you hold the pointer over a control; it is on by default. Software updates use Sparkle and the configured project update feed. An available update is not installed merely by opening this guide; follow the updater's prompts and save audio work before installing.

**Update channels.** Maestro normally offers stable versions only. In **App Settings › Updates** you can choose **Beta** to get versions that are still being tested. They may have bugs and can replace the ThunderBridge driver. Choose **Stable** again to stop getting them; Maestro then offers to reinstall the latest stable version. If you install a beta package yourself, Maestro sets that copy to Beta when it next reads the update feed, and it keeps getting betas until you choose Stable.

## Removing Apogee's original drivers

Maestro isn't supported alongside Apogee's original Symphony I/O drivers: the two can interfere with each other and cause problems, including crashes. The installer will not install Maestro for the first time while they are present (an update of Maestro goes ahead), and **Device Settings** shows a warning at the top while they are found.

To remove them:

1. Download Apogee's latest installer, [Symphony I/O Release 5.5](https://knowledge.apogeedigital.com/hubfs/Software%20Installers/Symphony%20IO/SymphonyIO_Release_5.5.dmg), open the disk image and choose **Uninstall**. Use this one even if you installed from an older release: older uninstallers leave parts behind.
2. Restart your Mac.
3. Reinstall Maestro, then restart once more.

Apogee's Uninstall also removes Maestro and Apogee Maestro 2, and resets macOS's audio device settings. If you use Apogee Maestro 2 with another Apogee interface, reinstall it from Apogee afterwards.

---

**You shouldn't need anything below this line.** The steps above are all most people ever do. What follows is future-proofing, for two situations: the warning is still there after you've followed those steps, or Apogee's uninstaller can't run on your Mac. It is an older Intel app, and a future macOS may no longer run it.

<details>
<summary>If the warning is still there after uninstalling and restarting</summary>

macOS can keep its own stored copy of Apogee's kernel extensions and load it again after a restart. No uninstaller from Apogee removes that copy. Maestro's warning says when it finds one (open **What was found**).

What follows is feedback from a user who had this problem and reported that these steps cleared it on their Mac. We have not tested them.

```
sudo kmutil clear-staging
```

```
sudo kmutil rebuild
```

1. Shut down your Mac and disconnect the ThunderBridge or PCIe chassis, then start up again. The user reported a crash when they tried to remove the old driver with it connected.
2. Open **Terminal** (in Applications › Utilities) and run the two commands above, one at a time, typing your Mac's password when asked. Approve the change if macOS asks you to.
3. Restart your Mac, then reconnect.

This is one user's experience on their own Mac, shared in case it helps. It is not a tested fix and Maestro can't do it for you. Leave System Integrity Protection on.

[Read the user's report](https://github.com/danielraffel/unofficial-symphony-maestro-mk1/issues/32#issuecomment-7050613371).

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
