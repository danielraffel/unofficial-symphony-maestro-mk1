# Changelog

## 0.9.10 (beta)

(Work in progress; not released. Intro to be written at release.)

### Changes that may affect your setup

- Symphony settings, input routes and channel labels now follow the identified physical unit when it moves between ports. Previously saved layout settings are preserved for their first identified owner; replacement units do not inherit them. Saved phantom power from an unverified migration cannot authorize preset recall.

- **Instrument gain on an 8MicPre now reaches the preamp's Instrument stage, with its own 0-65 dB range.** Before, Maestro sent Instrument gain as Mic gain. Mic and Instrument gains are now remembered separately for each channel, as in Apogee's software, so switching a channel between Mic and Instrument brings back the gain you last used for that type.
- **The connection in Device Info reads "Thunderbolt (Symphony 64 PCIe card)",** without the word "experimental".

### New

- With two Symphony I/Os at 64 channels, System Setup now offers Use Loop Sync and a choice of Loop Sync Master. Turning Loop Sync off puts unit B on Word Clock. Clock roles and measured lock are shown separately.
- **With two Symphony I/Os at 64 channels, System Setup lets you choose which unit receives the Mac's volume keys and Core Audio mute control.** It remembers the choice and returns to unit A if unit B is disconnected.
- **With two Symphony I/Os at 64 channels, Mixer and Output Routing use each unit's own prefix and board names, including optical format and `N.A.` channels; custom mixer labels stay with their unit.**
- **Input Routing on ThunderBridge and PCIe can map either Symphony I/O’s input streams to any software input.** Card input choices are remembered on reconnect, included in single-unit preset bundles, and cleared by Reset Routing.
- **With two Symphony I/Os at 64 channels, choosing Unit B on the Outputs page shows unit B's own speaker and headphone controls,** as Apogee's software did. The Mac's volume keys still control unit A.
- **Identify, on the Output Routing page, lights up all of the Symphony I/O's front-panel lights** so you can find the unit, as Apogee's software did; press it again to turn them off. With two units there is one for each.

### Fixes

- Keep each Symphony I/O’s speaker controls and front-panel changes on that unit when Mac volume keys target the other unit. Switching the keyboard-volume target, or losing unit B, restores the selected unit’s own level and mute without a volume jump. Monitor selection no longer waits for the hardware on the app’s main thread.

- **Reset Routing keeps working when an older driver is still serving after an app update.** The card-input grid requires driver build 132 or newer, and Reset Output Routing leaves card inputs unchanged.

- Restore both Symphony I/Os’ routing, mixers and headphone sources after returning to 64 channels, waking or recovering a link, even with the Mixer page closed.
- **With two Symphony I/Os at 64 channels, Reset Routing resets the selected routing direction across the whole card and both units.**
- **Settings bundles now save and restore both Symphony I/Os.** Older bundles restore unit A only. If unit B is absent or has different cards, Maestro restores unit A and reports that unit B was skipped.

- **Device Info now shows Unit B’s own firmware, board versions and hardware ID with two Symphony I/Os at 64 channels.** Unreadable fields say “Unknown”, and copied diagnostics include both units.
- **Unit B’s headphone sources now work on the Outputs page**, and stay routed after resetting or loading unit B’s output routing.

- **Input Routing now follows the Unit A / Unit B picker with two Symphony I/Os at 64 channels.** Unit B shows its own inputs and saves its routing choices separately.
- **Saving and loading a preset on ThunderBridge or PCIe now restores the Symphony I/O’s routing, mixer, monitor and channel settings.** Previously, loading a bundle restored only its channel names. Presets for a different card layout are refused before any settings change.
- **With two Symphony I/Os at 64 channels, Output Routing lets any of the 64 DAW channels and both mixers feed any output on either unit,** as Apogee's software did. Before, unit A's outputs could not play DAW channels 33-64.
- **The 8MicPre gain control in your DAW follows the channel's Mic or Instrument setting.** On an Instrument channel it stops at 65 dB (the slider still shows 0-85 dB).
- **Clear Meters clears peaks and overs on both units.**
- **Identify stays on when you leave Output Routing, and Maestro turns the lights off when it disconnects or quits.**
- **Turning the Symphony's knob on an 8MicPre Mic or Instrument channel now moves that channel's gain in Maestro too,** as Apogee's software did.
- **Choosing 64 channels with nothing on port 2 no longer flickers.** The Ports menu stays at 32 channels with a small spinner while Maestro looks for a unit on port 2, then shows 64 or the warning.

## 0.9.9 (beta)

Apogee's older converters and a second Symphony I/O now work the way they did with Apogee's software, on the ThunderBridge and the Symphony 64 PCIe card. It contains everything in 0.9.8. With one Symphony I/O, little changes for you; see "Changes that may affect your setup".

Thanks to the people who reported converters showing only four units, a tone repeating after quitting a DAW on the PCIe card, and input levels that looked reversed.

### Changes that may affect your setup

- **This beta updates the ThunderBridge and PCIe driver (0.11.5, build 131).** After installing, restart the Mac (or reconnect the ThunderBridge or PCIe chassis) so the new driver takes over.
- **Maestro sends each input and output channel's level, trim, Digital Ref and Soft Limit to the Symphony when it connects,** as Apogee's software did. Before, Maestro only showed what it had saved, so after using Apogee's software or switching the unit off and on, a page could show a level the unit was not at. Channels on an 8MicPre set to Mic or Instrument are left as they are.
- **The clock status reads "Ready" or "Clock Mismatch",** Apogee's wording, instead of "Locked" or "Unlocked".
- **The Sample Rate menu comes back sooner after a change:** once the Symphony has locked to the new rate (between 1.5 and 3 seconds) instead of after a fixed 5 seconds.
- **On the PCIe card and the ThunderBridge, audio stops cleanly when your DAW stops.** Before, the card could keep repeating the last fraction of a second it played.

### AD-16X, DA-16X, DD-16X and Rosetta converters

- **Up to four units on each port**, port 1 and, with 64 channels, port 2: eight in all. Maestro lists every unit with its X-Symphony firmware, and warns when one is older than 2.7.
- **The driver now sets the converters up as Apogee's driver did:** it addresses and checks each unit, sets the rate and word clock, lines up their timing after every rate change, and sends them none of the Symphony I/O's own messages.
- **Channels are placed and named as in Apogee's software.** Your DAW sees names such as "A Line 1" and "C Line 1", including the gaps Apogee's software left for some mixes of units (a Rosetta followed by an AD-16X, for example).
- **Input and Output Routing can be changed for converters**, both ways, on both ports. Reset Routing puts back the default layout.
- **Every DAW output now goes straight to its converter output,** as in Apogee's software, so nothing in the Mixer changes what your DAW plays. The Mac's volume keys still control Mixer 1; you hear them when Mixer 1 is routed to an output in Output Routing.
- **Clock Source offers Internal and External (word clock)** for converters, in Maestro and in Audio MIDI Setup.
- **Device Type**, as in Apogee's software, for the units that do not say what they are: choose DD-16X / AD-16X or DA-16X for a unit in Advanced Routing, and Rosetta 800 or Rosetta 200 for a Rosetta.
- **The driver keeps an eye on the units** about once a second and recovers if one drifts out of time, stops answering, or a unit is added or removed.
- **The latency your DAW compensates for** is the converters' own.
- None of this has been tried on real converters yet. If you have them, please send a Diagnostics report (see "Please test" below).

### Two Symphony I/O units (64 channels)

- **The second unit (on port 2) is now set up when 64 channels start,** as Apogee's software did: it follows the first unit's clock through Loop Sync, and its routing and optical format are set. Before, it ran on whatever it had stored.
- **Connect the two units' Loop Sync connectors with BNC cables,** as Apogee's guide shows, and choose the clock source on the first unit.
- **A Unit A / Unit B picker** appears in Maestro when the second unit is set up. Inputs, Outputs, Device Settings and System Setup show the chosen unit, with its own saved settings and meters.
- **The Mixer and Output Routing include the second unit's channels,** and your DAW sees its channel names for 33-64.
- **The ThunderBridge's port 2 light** is on while port 2 carries audio and flashes when it loses its clock.
- **64 channels comes back by itself** when the second unit is switched on after the Mac, or returns after a problem.
- This has not been tried with two units yet. Reports are welcome.

### 8MicPre

- **Phantom power and gain for the 8MicPre now appear in your DAW over ThunderBridge and PCIe.** The driver was looking for the Mic Pre in the wrong slot, so the controls never appeared.

### Please test

If you have any of these, a Diagnostics report helps a lot: in **Device Settings › Preferences**, turn on **Diagnostics**, switch your units off and on, use them for a few minutes, then press **Stop Diagnostics** and send the report.

- **AD-16X, DA-16X, DD-16X or Rosetta converters,** on port 1, port 2 or both: do all your units appear, with the right names and channels in your DAW, and do routing changes and rate changes work? Please say which units are on which port, in cable order.
- **Two Symphony I/Os at 64 channels:** does the second unit appear, follow the first unit's clock over Loop Sync, and play and record on channels 33-64?
- **An 8MicPre over ThunderBridge or PCIe:** do phantom power and gain appear in your DAW and work?
- **The Symphony 64 PCIe card:** does audio stop cleanly when you stop or quit your DAW?

### What's next

More is on the way in the following betas:

- **Second Symphony I/O:** editing its Input Routing, its headphone and monitor controls, its firmware and serial in Device Info, and Reset Routing and presets that cover its outputs.
- **8MicPre:** Mic and Instrument settings sent to the unit when Maestro connects, as line levels already are.
- Fixes for whatever the reports above turn up.

### Release notes

- The driver is 0.11.5, build 131.
- Some differences from Apogee's software remain on purpose: a converter that fails Apogee's authenticity check is reported, not refused; channels 33-64 start at 33 after a Symphony I/O on port 1; and editing routing for the second Symphony I/O's inputs is not available yet.

## 0.9.8 (beta)

Maestro opens straight away, even when macOS audio is slow. It contains everything in 0.9.7.

### Changes that may affect your setup

- **Maestro's window opens immediately at launch and then connects to your Symphony.** Before, Maestro asked macOS for its audio devices before showing anything, so when macOS audio was slow, as it is for a minute or two after installing any update, Maestro bounced in the Dock and looked stuck. Now the window appears at once, the status reads "Looking for your Symphony…" for a moment, and if macOS audio takes longer than a few seconds it reads "Waiting for macOS audio to respond…" until it connects. Your settings, routing and presets are restored as before.

### Release notes

- The ThunderBridge and PCIe driver is unchanged from 0.9.6 (0.11.4, build 130), so there is no need to reconnect anything after updating.

## 0.9.7 (beta)

Reset Routing now matches Apogee's software over ThunderBridge and PCIe. It contains everything in 0.9.6. Over USB nothing changes.

Thanks to the PCIe tester who confirmed audio now works on the Symphony 64 PCIe card, and who asked for this.

### Changes that may affect your setup

- **Over ThunderBridge and PCIe, Reset Routing on the Output Routing page now does what Apogee's software did.** Every software output goes to the matching hardware output, so Line 1/2 plays Software 1/2 directly, and no mixer is routed to an output. Before, Reset put Line 1/2 on Mixer 1. After a reset, the Mixer's Master, Software Return and input monitoring no longer change Line 1/2 until you route a mixer there. Easy to change back: choose Mixer 1 for Line 1/2 in Output Routing (Maestro remembers it), or save your layout as a routing preset and load it after a reset. Maestro's start-up default is unchanged: if you never press Reset, Line 1/2 stays on Mixer 1.

### Release notes

- The ThunderBridge and PCIe driver is unchanged from 0.9.6 (0.11.4, build 130), so there is no need to reconnect anything after updating.

### Known issue

- **Right after installing an update, Maestro can bounce in the Dock for a minute or two before its window opens.** The installer restarts macOS's audio system, and Maestro waits for it at launch. Give it a moment; if it is still bouncing after about five minutes, restart the Mac. A coming beta opens the window straight away and connects once macOS audio is ready.

## 0.9.6 (beta)

The next step for the Symphony 64 PCIe card, and a clearer diagnostics report. It contains everything in 0.9.5. If you use USB or a ThunderBridge, nothing changes for you.

Thanks to the PCIe tester whose diagnostics report showed exactly where audio stopped: 0.9.5 picked the right interrupt on the card, but the card's audio engine never started.

### Changes that may affect your setup

- **This beta updates the ThunderBridge and PCIe driver (0.11.4, build 130).** After installing, restart the Mac (or reconnect the ThunderBridge or PCIe chassis) so the new driver takes over.
- **On the Symphony 64 PCIe card, the driver now starts the card the way Apogee's driver did.** It tells the card it is the only card in the system, turns off the card's internal clock while the Symphony I/O provides the clock, aligns the card with the Symphony after each sample rate change, and starts the card's audio engine again when an app starts playing if it is not already running. Each of these is a step Apogee's driver takes that this driver skipped. On a ThunderBridge nothing changes.
- **On the PCIe card, the Speaker knob should follow the front panel again once audio runs.** The Mac's speaker volume reaches the Symphony with the audio, so it could not while the card's audio engine was stopped. Headphones were not affected.

### What's better

- **Diagnostics reports say more about the PCIe card and the volume controls.** The driver now records whether the card's audio engine started, whether the card reaches the Mac's memory, and the card's error state, and repeats this summary in every report even when the driver started long before. Each snapshot also shows the speaker and headphone levels in Maestro and in macOS, so a volume problem can be checked against both.

## 0.9.5 (beta)

A likely fix for the Symphony 64 PCIe card, a USB reconnect fix, and a new Diagnostics option for sending the developer a report. It contains everything in 0.9.4.

Thanks to the testers with Symphony 64 PCIe cards whose careful reports, and whose check on an Intel Mac with Apogee's software, pointed to the cause.

### Changes that may affect your setup

- **This beta updates the ThunderBridge and PCIe driver (0.11.3, build 129).** After installing, unplug the ThunderBridge or PCIe chassis cable and plug it back in (or restart) so the new driver takes over.
- **On the Symphony 64 PCIe card, the driver now picks the card's interrupt the way Apogee's driver did.** On Apple Silicon a card can only signal the Mac in one particular way, and Apogee's driver looked for it rather than assuming. This is the likely reason the PCIe card was detected and could change sample rate but gave no audio. On a ThunderBridge nothing changes: it picks the same one as before.
- **Over USB, unplugging, replugging or power-cycling the Symphony no longer leaves it silent.** Maestro could reconnect to the old connection, show meters and play nothing until a second replug. It now sets the Symphony up again every time it comes back.

### What's new

- **Diagnostics, for testers on the Beta channel.** Turn it on in Device Settings › Preferences, do what causes the problem, then press Stop Diagnostics. Maestro saves a file to your Desktop and offers to email it privately to the developer, with optional details about your setup and the problem. Nothing is sent until you press Agree and Send, and it is never posted publicly. Help › "When and how should I use diagnostics?" explains when it is useful.

### What's better

- **The Privacy Policy and Terms describe what Maestro sends and when:** update checks, and diagnostics only if you choose to send them.

### Release notes

- The driver's own log is easier to read in a diagnostics report, and it records which interrupt the card uses and whether audio starts. This changes nothing you hear.

## 0.9.4 (beta)

Small changes that make it easier to tell which version you are on. It contains everything in 0.9.3.

### What's new

- **About Maestro says whether you are on Stable or Beta.** The version reads, for example, "Version 0.9.4 (Beta)".
- **The copied details include your update channel.** The copy button in About Maestro and in Device Info now adds a line such as "Update channel: Beta", so a pasted report shows which channel you follow.

### What's better

- **Over USB, Maestro no longer sends an optical setting to an 8x8 card set to AES.** Apogee's software never sent it to an AES card, and the Symphony ignored it, so nothing you hear changes.

### Release notes

- The ThunderBridge driver is unchanged from 0.9.3, so there is no need to unplug and reconnect the ThunderBridge after updating.

## 0.9.3 (beta)

For people using Apogee's older converters (AD-16X, DA-16X, DD-16X or Rosetta 800) on a ThunderBridge or Symphony 64 PCIe card without a Symphony I/O. It contains everything in 0.9.2. If you have a Symphony I/O, nothing changes for you.

Thanks to the tester with a DA-16X on a ThunderBridge whose report showed that the Mac's volume keys did nothing on their setup.

### Changes that may affect your setup

- **This beta updates the ThunderBridge driver.** After installing, unplug the ThunderBridge cable and plug it back in (or turn the Maestro driver off and on in System Settings, or restart).
- **On converters, the Mac's volume and mute keys now work.** They turn Mixer 1 up and down, from full level to -64 dB, and the mute key silences it. Mixer 1 feeds outputs 1-2 unless you have changed Output Routing; outputs that are routed directly do not follow the keys. The Master fader in the Mixer still works as before and is separate. Apogee's own software did nothing with the volume keys on converters, so this is new. Nothing gets louder: the keys start from the level macOS already shows for the ThunderBridge.

### What's new

- **On converters, the speaker knob now works, in the toolbar and on the Output page.** On the Output page it is now called Volume. The knob, its mute button and the Mac's volume and mute keys are the same control and move together. The headphone controls and the speaker-only controls (Dim, Sum to mono, Analog Out Format and Speaker Select) are greyed out, because these converters have no speaker or headphone outputs; hold the pointer over them to see why.

### Release notes

- A DD-16X gets the new volume keys only if it answers the driver's extended identity question. If it does not, it keeps today's behaviour, because without that answer it cannot be told apart from a Symphony I/O.
- This has not been tried on a real converter yet. If you have one, please tell us whether the keys change the level and whether macOS remembers the level after a restart.
- With a Symphony I/O connected, the speaker knob, headphone knobs and volume keys work exactly as before.

## 0.9.2 (beta)

Over USB, the Mixer's Software Return and Master controls now work the way they did in Apogee's Maestro. It contains everything in 0.9.1.

Thanks to Minnietheandroid, whose [testing and report over USB](https://github.com/danielraffel/unofficial-symphony-maestro-mk1/issues/1#issuecomment-6887494993) showed that these controls had no effect, and led to them being rewired.

### Changes that may affect your setup

The first two apply over USB only. Turn your monitors down before the first playback after updating.

- **The Software Return fader and mute now affect only outputs fed from that mixer.** Before, on the "Maestro USB" device, they turned Mac output 1-2 down everywhere, even on an output that did not go through the mixer. If you had Software Return turned down or muted and you listen on an output that is not fed from the mixer in Output Routing, that output will be louder after updating.
- **The Master fader now works.** Over USB it was ignored. If a Master fader in the Mixer is not at 0 dB, outputs fed from that mixer change level to match it after updating.
- **The link buttons on Software Return and Master are gone.** Linking and unlinking was something we added ourselves. We assumed that two fader handles meant left and right could be set separately, and that was wrong: in Apogee's Maestro each of these is one stereo fader whose two handles always move together, and the Symphony's own mixer, used over USB, has no separate left and right level at all. This goes back to the original behaviour, over USB and ThunderBridge. If you had left and right set to different levels, both are set once, on the first launch after updating, to the lower of the two, so nothing gets louder. The faders show that level and move as normal from then on.

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

