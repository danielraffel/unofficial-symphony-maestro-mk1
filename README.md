# Unofficial Symphony Maestro for Apogee Symphony I/O MK I

Modern Apple Silicon support for the Apogee Symphony I/O MK I on **macOS 26**.

**Download:** <a href="https://github.com/danielraffel/unofficial-symphony-maestro-mk1/releases/download/0.7.2-b404/UnofficialSymphonyMaestro-0.7.2-b404.pkg">
Unofficial Symphony Maestro (.pkg)
</a>

_**Note:** Due to the limited testing of this software you should closely read the disclaimers in this read me and the license agreement before installing._

## Overview

This project restores support for the **Apogee Symphony I/O MK I** on Apple Silicon Macs running macOS 26.

It was developed with **Apogee's knowledge and blessing**, but it is **not affiliated with, supported by, or endorsed by Apogee** in any way. Apogee does not provide support for this software.

Due to the technical approach used, this software **requires an Apple Silicon Mac running macOS 26**. It will **never support Intel Macs or versions of macOS earlier than macOS 26**.

## What's Included

- Modern **Maestro** desktop application for basic device configuration
- Native **Thunderbolt DriverKit** driver
- Modern **USB** implementation using Apple's USB audio stack
- Hardware volume key support when using USB

## Requirements

- Apple Silicon Mac (M-series)
- macOS 26
- Apogee Symphony I/O MK I

_Intel Macs and earlier versions of macOS are not supported._

## Beta Status

This is an **early beta release**.

At the time of this release, the software has only been tested on a single system. I'm looking for a small number of technically experienced users who are comfortable testing pre-release software and providing feedback.

If your Mac is mission-critical, I strongly recommend testing on a secondary machine rather than your primary workstation.

## Tested Hardware

This release has only been tested with:

- Apple Silicon Mac running macOS 26
- Apogee Symphony I/O MK I
- 8×8 Analog-Optical I/O module
- 16×16 AD Optical I/O module

If your hardware configuration differs, it may work, but it has not yet been verified.

## Installation

The installer is:

- Apple signed
- Apple notarized

Installation should be straightforward without requiring any special security workarounds.

The installer includes a <a href="https://github.com/danielraffel/unofficial-symphony-maestro-mk1/blob/main/license.md">conservative license agreement</a> stating that the software is provided **as-is**, without warranty. While I do not expect problems, I want to be transparent that this software has undergone very limited real-world testing.

## Feedback

If you have a Symphony I/O MK I and an Apple Silicon Mac running macOS 26 and would like to help test, please include:

- Whether you're using USB or Thunderbolt
- Installed I/O modules
- Mac model
- Any other relevant hardware details

I'll reach out with additional information.

## Support

This is an independent community project.

Apogee does **not** provide support for this software. Please direct all feedback, bug reports, and questions to this project's GitHub Issues page.

Note: Assuming beta testing goes well and this works reliably for others, I’ll explore open sourcing the software. There are a few complexities to work through, so that’s a lower priority for now, and I can’t promise it will happen.

## Acknowledgments

Many thanks to Apogee for their cooperation during development, for trusting me and for making it possible to explore restoring support for this hardware on modern versions of macOS. “Apogee”, “Symphony” and "Maestro" are trademarks of their respective owners, used here only for identification and compatibility. 

During development I sent countless commands that could easily have bricked my device, while I did have to reboot my machine a lot I never encountered a single unrecoverable issue. That’s a real testament to the engineering and care that went into the Apogee firmware. The team clearly designed it to guard against invalid states, preventing me from ever putting the hardware into a bad or unrecoverable condition. Respect.

## Screenshots
<img width="1464" height="812" alt="image" src="https://github.com/user-attachments/assets/f344c351-df41-4615-9683-1f2fe9774a5d" />
<img width="1464" height="812" alt="image" src="https://github.com/user-attachments/assets/3731ecb7-40ea-4cac-8226-fc1f44840f90" />
<img width="1464" height="812" alt="image" src="https://github.com/user-attachments/assets/be7a7bf3-ce60-4ce5-8a76-dcb63856e0d5" />
<img width="1464" height="812" alt="image" src="https://github.com/user-attachments/assets/2fb878a8-389d-4a51-aee8-4d81eeb5389e" />
<img width="1464" height="812" alt="image" src="https://github.com/user-attachments/assets/d0b9099a-7bcb-4d0c-9ced-0489a0706764" />
<img width="1464" height="812" alt="image" src="https://github.com/user-attachments/assets/2ea26732-5838-45e6-a8a2-c62f007e5591" />
<img width="1464" height="812" alt="image" src="https://github.com/user-attachments/assets/2921c7d4-32be-43ca-9fdc-93251fe4c618" />


## Appendix
<a href="https://knowledge.apogeedigital.com/legacy-symphony-i/o-mk-i-guide-for-intel-and-apple-silicon-macs">About Apogee Symphony I/O MK I</a><br>
<a href="https://www.soundonsound.com/reviews/apogee-symphony-io">Sound on Sound Review of Apogee Symphony I/O MK I</a>
