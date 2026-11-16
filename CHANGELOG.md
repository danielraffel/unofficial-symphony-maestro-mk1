# Changelog

## 0.9.2 (beta)

Over USB, the Mixer's Software Return and Master controls now work the way they did in Apogee's Maestro. It contains everything in 0.9.1.

### Changes that may affect your setup

The first two apply over USB only. Turn your monitors down before the first playback after updating.

- **The Software Return fader and mute now affect only outputs fed from that mixer.** Before, on the "Maestro USB" device, they turned Mac output 1-2 down everywhere, even on an output that did not go through the mixer. If you had Software Return turned down or muted and you listen on an output that is not fed from the mixer in Output Routing, that output will be louder after updating.
- **The Master fader now works.** Over USB it was ignored. If a Master fader in the Mixer is not at 0 dB, outputs fed from that mixer change level to match it after updating.
- **The link buttons on Software Return and Master are gone.** Each of them is one stereo fader, drawn with a left and a right handle that always move together, as in Apogee's Maestro. This applies over ThunderBridge too. If you had a pair unlinked, the quieter side's level is used for both.

### What's fixed

- **Software Return fader, mute and solo, and the Master fader, now work over USB.** They did nothing when your DAW played through "Symphony I/O : USB Audio", and Master and Software Return solo did nothing on either device. They are now done by the Symphony's own mixer, so they work whichever of the two devices your DAW uses.
- **Your Master and Software Return settings are put back when the Symphony reconnects** or is turned off and on, for both mixers.
- **A sample rate choice is no longer ignored now and then.** The first time you went back to the rate Maestro started at, the choice showed for a moment and then jumped back without reaching the Symphony. Separately, a choice made while the Symphony was still switching could be dropped, so the Sample Rate menu is now greyed out for about five seconds after a change, until the Symphony has finished switching. Both apply over USB and ThunderBridge.

### Release notes

- The ThunderBridge driver is unchanged from 0.9.1. Over ThunderBridge the only changes are that Software Return and Master can no longer be unlinked, and the Sample Rate menu's short wait.
- Software Return pan still needs the "Maestro USB" device.
- If Maestro is not running when the Symphony is turned off and on, the Symphony's mixer stays at its own defaults (0 dB, not muted) until Maestro next connects.

## 0.9.1 (beta)

The first beta, for people helping to test two Symphony I/O units on one ThunderBridge (64 channels), or a Symphony I/O on a Symphony 64 PCIe card. It contains everything in 0.8.40. Betas may have bugs; if you rely on your setup, stay on Stable.

### Changes that may affect your setup

- **This beta updates the ThunderBridge driver.** After installing, unplug the ThunderBridge cable and plug it back in (or turn the Maestro driver off and on in System Settings, or restart). Until then the old driver keeps running and Maestro shows a banner.
- **The ThunderBridge now has a Source choice** in Audio MIDI Setup and the macOS Sound menu: "Symphony I/O: ThunderBridge" (the usual 32 channels) and "Symphony I/O: ThunderBridge 64". Leave it on the first unless you have two units. Your DAW keeps the same device either way.

### New

- **64 channels with two Symphony I/O units.** Connect the second unit to ThunderBridge port 2, then choose 64 channels (two units) under Ports in System Setup › Device Info, or pick "Symphony I/O: ThunderBridge 64" as the Source. Channels 33-64 are the unit on port 2. If no second unit is found, the driver stays at 32 channels and Device Info says why. This has not yet been confirmed on real hardware.
- **A Symphony I/O on a Symphony 64 PCIe card should now be recognised (experimental).** With the PCIe card in a Thunderbolt chassis, Maestro showed the Symphony I/O as an "Apogee DD-16X" and none of Maestro's settings reached it. It should now appear as a Symphony I/O with its option cards. This has not yet been confirmed on real hardware.

### For testers

- Please report whether 64 channels work with two units, and whether 32 channels still work as before with one.
- If you use the Symphony 64 PCIe card: please report whether Device Info now lists your option cards, whether Maestro's controls work, and whether audio plays and records. If it still shows a different unit, press Copy next to Device Info and send the text.
- If you have one of the 64-channel test builds (9004-9006), install this package by hand once. When Maestro next checks for updates it sets the update channel to Beta, and you keep getting betas.
- To leave the beta, choose Stable under Update channel in Device Settings › Preferences; Maestro offers to reinstall the latest stable version.

## 0.8.40

Every option card now behaves the way it did in Apogee's original Maestro: the optical format, the S/PDIF coax settings, the clock choices and the channel names.

### Changes that may affect your setup

These work differently from 0.8.39. Most match Apogee's original; check them after updating.

- **This release updates the ThunderBridge driver.** After installing, unplug the ThunderBridge cable and plug it back in (or turn the Maestro driver off and on in System Settings, or restart). Until then the old driver keeps running and Maestro shows a banner.
- **Input routing choices saved over ThunderBridge are cleared once.** The Symphony goes back to its default layout (each card's inputs in order). Choose them again on Input Routing; from now on they are kept and put back after reconnecting. Choices made over USB in 32-channel mode are cleared too.
- **2x6 card in slot 1 with a second card (ThunderBridge only):** the second card's inputs move from Mac inputs 17-32 to 13-28, as in the original. Check your DAW's input assignments.
- **Channel names in your DAW change over ThunderBridge.** Inputs and outputs now have names ("A Line 1", "A ADAT 3", "A N.A."...) instead of plain numbers. The channels themselves don't move.
- **Clock Source over ThunderBridge:** "Loop Sync" and the "IO Board 1" / "IO Board 2" entries are gone; each card's own inputs are listed instead. If you used one of those, choose the clock source again.
- **Headphones following an output of the slot 2 card** now play that output over ThunderBridge. Before, they played the matching output of the slot 1 card.
- **Reset Routing over ThunderBridge** puts back the layout the driver actually uses. With two 8x8 cards, or with slot 1 empty, this differs from what earlier versions wrote.
- **The Peripheral Prefix letter is now stored in the Symphony,** as the original did, and is written to it when Maestro connects.
- **Optical format and S/PDIF coax settings are now restored when the Symphony connects** (USB and ThunderBridge). Before, the Symphony started from ADAT and the defaults after every power cycle.

### New

- **Update channel: Stable or Beta.** Device Settings › Preferences has a new Update channel setting. Stable is the default and is what most people should use: nothing changes unless you choose Beta. Beta offers versions that are still being tested; they may have bugs and can replace the ThunderBridge driver. Switching back to Stable offers to download and reinstall the latest stable version.
- **Maestro reopens after an update is installed.**
- **An older Maestro package can be installed over a newer one.** From this version on, the installer replaces the app instead of leaving the newer one in place.

### What's fixed

- **S/PDIF settings for the card in slot 2 now take effect.** "SPDIF Coax 3-4 Replaces" and "SPDIF Coax 3-4 Mirrors" were sent in a form the Symphony ignores, and the Mirrors menu was not sent at all. Both now work, over USB and ThunderBridge.
- **S/PDIF settings show what the Symphony is set to over ThunderBridge.** The Replaces and Mirrors menus used to go back to their defaults whenever you left the tab.
- **Your optical format and S/PDIF settings are kept when the Symphony is turned off and on.** They used to go back to ADAT and the defaults. Maestro and the USB helper now put them back when the Symphony connects, as the original did. They go back only onto the card they were chosen for, so a card you swap in starts from its defaults.
- **Presets keep the optical format and S/PDIF settings of both cards.** They used to keep the first card's only.
- **Input Routing over ThunderBridge shows what the Symphony actually records.** The page drew the USB layout (all Line inputs first), but the ThunderBridge driver sends each card's inputs in order: Mac inputs 1-16 from the card in slot 1, 17-32 from slot 2. The page now shows that, and Reset Routing puts that layout back.
- **With a 2x6 card in slot 1, the card in slot 2 now starts at Mac input 13 over ThunderBridge,** right after the 2x6's 12 inputs, as in the original. It used to start at 17, leaving Mac inputs 13-16 empty. Every other setup keeps slot 2 on Mac inputs 17-32. This needs the driver in this release. If you record from a slot 2 card behind a 2x6, check your DAW's input assignments after updating.
- **Saved input routing choices are now put back when the Symphony reconnects** over ThunderBridge, including after the driver recovers the link. Until now the page kept showing your choices while the Symphony had gone back to the default.
- **Input routing choices saved by earlier versions are cleared once over ThunderBridge.** They were made on a page that showed the wrong layout, and the Symphony had not been using them since it last reconnected. Putting them back now could move your inputs without warning, so the first ThunderBridge connection after updating forgets them and the Symphony keeps its default layout. Choose them again on Input Routing if you want them; from now on they are kept. If you used Input Routing over USB in 32-channel mode, those choices are shared with ThunderBridge and are cleared too.
- **The software inputs on Input Routing are named after what is routed to them,** as in the original: "A SPDIF Opt 1/2" for a pair fed from the optical input, "N.A." for a pair with nothing behind it. They used to read "A Line" for every row.
- **Output Routing over ThunderBridge shows where each Mac output actually plays.** The driver sends Mac outputs 1-16 to the card in slot 1 and 17-32 to the card in slot 2, in order, but the page drew the USB layout, with every Line output first. With two cards that both have Line outputs, such as two 8x8 cards, Mac outputs 9-10 were labelled as slot 2's Line 9/10 while they played on slot 1's digital outputs. With slot 1 empty, the slot 2 card's outputs were labelled as Mac outputs 1-16 while they played on 17-32. The software rows are now named after the outputs they reach, the default the page shows matches what plays, and Reset Routing over ThunderBridge puts that default back. Saved routing choices are not changed. If you used Reset Routing over ThunderBridge with two such cards, or with slot 1 empty, the outputs keep that older layout until the driver restarts (for example when you restart the Mac); press Reset Routing again to get the default that matches the page.
- **"SPDIF Opt 1/2" fits on its Input and Output tab strip** instead of being cut short.
- **Input meters over ThunderBridge show the right channel.** Each strip used to read the meter at its position on the page, so with an 8x8 in slot 1 the slot 2 card's strips showed slot 1's digital inputs and the Mixer's digital strips showed the slot 2 card. Each strip now reads the input it belongs to, including after you change Input Routing, and the Input tab's digital strips move over ThunderBridge.
- **Device Info names the driver build that is actually running the ThunderBridge.** After a driver update macOS can keep the old driver on the card while it already lists the new one as active. Device Info used to show the new build. It now asks the running driver for its build. Drivers from before this release cannot answer, so they are reported as "a build before 123".
- **A driver update that macOS has not finished is now called that.** When the new driver is installed and enabled but the old one is still running the ThunderBridge, Maestro used to say the old copy was "finishing cleanup", or show nothing. It now shows a banner at the top of the window until the new driver is running. The banner has one instruction: "Unplug the ThunderBridge cable and plug it back in" (audio stops for a few seconds). A smaller line lists the other ways: turn the Maestro driver off and on in System Settings, or restart your Mac. An Open Driver Settings link opens that page. Device Info keeps the detail, including which driver build is still running.
- **Headphones set to follow an output of the card in slot 2 now play that output over ThunderBridge.** They played the matching output of the card in slot 1 instead (for example, slot 2's Line 1-2 played what goes to slot 1's Line 1-2). USB was not affected.

### What's better

- **Channel names follow the optical format and sample rate.** In the Mixer, the Input and Output tabs and both routing pages, optical channels are named ADAT at 44.1 and 48 kHz, SMUX at 88.2 and 96 kHz, and "N.A." where the optical ports carry nothing (at 176.4 and 192 kHz, or beyond the first pair in S/PDIF format, where they show SPDIF Opt). A pair replaced by the coax input is named "SPDIF Cx". The names change as soon as you change the rate or format.
- **Clock Source over ThunderBridge lists each card's own inputs,** as the original did: the S/PDIF coax input, then AES pairs or the optical input. An 8x8 Optical card shows "ADAT 1-8" (or SMUX, SPDIF Opt), an A16 IP or 16x16 card shows its coax input, an A16 OP its coax and optical inputs, and an empty or Mic Pre slot shows nothing. A second AES card continues the AES numbering (9-10 to 15-16). Loop Sync is no longer listed; the original offered it only in Pro Tools HD mode.
- **Menu names as in the original:** optical pairs are "Optical 1-2" in the S/PDIF and headphone menus, the input menu is "SPDIF Coax Replaces", and the optical format choices are "ADAT/SMUX" and "SPDIF".
- **Audio apps see channel names over ThunderBridge.** The driver now names each input and output channel ("A Line 1", "A ADAT 3", "A SPDIF Cx 1"...) for Audio MIDI Setup and DAWs, following the same rules. Each Mac output is named after the output it plays through by default: Mac outputs 1-16 after the card in slot 1, 17-32 after the card in slot 2, so with an 8x8 set to S/PDIF in slot 1 and an A16 IP in slot 2 they read "A Line 1" to "A Line 8", "A SPDIF Opt 1" and "2", "A N.A." for 11-16, then "A ADAT 9" to "A ADAT 24". The names on the Output Routing page are the same. The letter in front is the Peripheral Prefix from Device Settings, which Maestro now stores in the Symphony, as the original did.
- **Channels that carry nothing are greyed out.** "N.A." strips, routing columns and mixer names stay where they are, as in the original, but are faded.
- **The ThunderBridge driver no longer sends an optical format to an AES card.** An AES card has no optical format to set, and Apogee's software never sent one.

### Release notes

- This release includes a new ThunderBridge driver (0.10.17, build 123) carrying the driver changes above: input and output channel names with the prefix letter, names that follow the sample rate, no optical format for an AES card, keeping your settings after a link recovery, and Device Info's driver build report.
- Mac outputs keep fixed names based on their position, on purpose. They do not change when you re-route an output on Output Routing or send it through the mixer. The original renamed each output after the hardware it reached, so an output feeding the mixer read "N.A.". The user guide explains channel names.
- The USB helper changes with this release.

## 0.8.39 (build 1035)

Fixes for people using the AES port on an 8x8 card, following a user report.

### What's better

- **AES outputs are called AES.** On the Output Routing page, the software outputs that go to an 8x8 card's AES port were labelled "ADAT". They now follow the card.
- **The 8x8 AES/OPT card is named correctly.** System Setup > Device Info now shows "8x8 AES/OPT" for the combined AES and optical card, whichever way its DIG I/O button is set.
- **No optical format setting for an AES card.** With the card's DIG I/O button on AES, its digital channels use the AES connector, so Device Settings no longer offers an optical format for it. This matches Apogee's original Maestro.
- **Clock Source over USB offers Internal only,** as Apogee's software did. Over USB the Symphony runs on its own clock; the other choices did nothing. Over ThunderBridge all clock sources are still offered.

### Using the AES port on an 8x8 card

The 8x8 AES/OPT card sends its 8 digital channels to either the AES connector or the optical ports, chosen with the **DIG I/O** button on the card. After pressing it, turn the Symphony off and on again. Over USB the Symphony is the clock master, so set your AES device to follow the clock on its AES input.

### Release notes

- App-only update. The ThunderBridge driver is unchanged (build 121).
- Quit your audio apps before installing. The installer restarts macOS's audio system, which interrupts audio for a few seconds.

## 0.8.38 (build 1034)

Three small changes from user feedback, each matching Apogee's original Maestro.

### What's better

- **The Mixer remembers which mix you were on.** It used to go back to Mix 1 every time you left the Mixer tab, which made it easy to adjust the wrong mix. It now returns to the mix you were using, and the button for that mix is filled in so you can see at a glance which one is showing. A fresh launch still starts on Mix 1.
- **The polarity button shows the Ø symbol** on Mic Pre channels, as it did in the original.
- **The Analog Level menu is in the original order:** +4 dBu, -10 dBV, then Variable. Only the order changed; each choice does exactly what it did before.

### Release notes

- Nothing changes in what Maestro sends to your Symphony. The ThunderBridge driver is unchanged (build 121), so there is no driver swap if you already have 0.8.36 or 0.8.37.
- Quit your audio apps before installing. The installer restarts macOS's audio system, which interrupts audio for a few seconds.

## 0.8.37 (build 1033)

### Fixed

- **No sound through "Symphony I/O : Maestro USB" after updating to 0.8.36.** The 0.8.36 installer skipped a restart of macOS's audio system that the USB audio path depends on. If you updated to 0.8.36 and have no sound through Maestro USB, installing 0.8.37 fixes it; restarting your Mac also does.

### Release notes

- If you are on 0.8.36, quit your audio apps before installing. The installer restarts macOS's audio system again, which interrupts audio for a few seconds. With a ThunderBridge connected it can occasionally take a minute or two to come back.
- The ThunderBridge driver is unchanged from 0.8.36 (build 121).

## 0.8.36 (build 1032)

### What's new (experimental)

Both of these are written from Apogee's original source for hardware we do not own. We could not try them on the real thing, so testing and feedback are very welcome.

- **Symphony 64 PCIe card.** If you use the original Symphony 64 PCIe card in a Thunderbolt chassis, Maestro's driver now recognises it. Earlier versions contained support for the card but never actually connected to it, so it was not detected.
- **AD-16X, DA-16X, DD-16X and Rosetta 800 converters.** When the unit on the cable is not a Symphony I/O, the driver now asks it what it is, the way Apogee's software did, and does the same for up to four units chained together (an AD-16X and a DA-16X, for example). If they answer, Maestro adds up their inputs and outputs, shows that many channels, and names the units under System Setup > Device Info. If they do not answer, Maestro shows the generic 32-channel layout as before.
- **Device Info says what is connected.** The Connection row names the Symphony 64 PCIe card when that is what you are using, and a converter is described as a converter instead of as a Symphony with missing cards.

### What's better

- **Direct output routing is really direct (ThunderBridge).** With Software 1-2 routed to your main outputs, the Mixer's Master and Software Return faders still changed the level, because that route was quietly passing through Mixer 1. A software output now goes straight to the outputs, as it did with Apogee's software. Your main outputs default to Mixer 1, so Software Return, Master and input monitoring keep working out of the box, and Output Routing now shows that. If you had saved Software 1-2 on your main outputs, Maestro relabels it as Mixer 1 once, so nothing changes in what you hear. Choose Software 1-2 for those outputs when you want the mixer out of the path.
- **The front panel knob is followed over ThunderBridge too.** Turning the volume knob on the Symphony, or muting from the front panel, now updates Maestro over ThunderBridge as it does over USB. This also fixes a fault that had stopped Maestro reading anything back from the Symphony over ThunderBridge.

### Known limits with converters

- Maestro's pages are still laid out for a Symphony I/O. With a converter you will see controls that do nothing (per-channel input settings, the speaker and headphone knobs, most of Device Settings and System Setup), and the routing pages use generic channel names. We will tidy these once we hear from people using them.
- A Symphony I/O and converters on the same cable are not supported together.

### How to send feedback

Choose Maestro > About Maestro and click the copy button next to the version number. Paste that into your message. If you can, add screenshots of the Input, Output Routing and System Setup pages, and tell us which units you have, in what order they are cabled, and which inputs and outputs actually pass audio. See "Does Maestro work with AD-16X, DA-16X or Rosetta converters?" in Help.

### Release notes

- Version 0.8.35 was not released by itself. Everything listed under 0.8.35 below is part of this update.
- **This update replaces the ThunderBridge driver** (now build 121). macOS swaps the driver when you install. Close your audio apps first, and if Maestro asks, disconnect and reconnect the ThunderBridge.
- If you use a Symphony I/O over ThunderBridge, nothing should change for you. The new question is only asked when the connected unit does not answer as a Symphony I/O.
- USB is not affected by the driver change.
- Quit your audio apps before installing. The installer restarts macOS's audio system, and with a ThunderBridge connected that can take a minute or two, during which audio apps may freeze and Maestro may not open. It recovers by itself.

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

