# Unofficial Symphony Maestro for Apogee Symphony I/O MK I

Modern Apple Silicon support for the Apogee Symphony I/O MK I on **macOS 26**.

**Download:** <a href="https://github.com/danielraffel/unofficial-symphony-maestro-mk1/releases/download/0.7.2-b404/UnofficialSymphonyMaestro-0.7.2-b404.pkg">
Unofficial Symphony Maestro 0.7.2 Beta 404 (.pkg)
</a>

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

The installer includes a conservative license agreement stating that the software is provided **as-is**, without warranty. While I do not expect problems, I want to be transparent that this software has undergone very limited real-world testing.

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

## Acknowledgments

Many thanks to Apogee for their cooperation during development and for making it possible to explore restoring support for this hardware on modern versions of macOS.
