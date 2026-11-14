// SymphonyOptionBoard.h — option-board types and which of them take an optical format.
//
// Kept in a plain header (no DriverKit types) so Scripts/test-optical-format.sh
// can compile the same decisions on the host and check the 0x34 sends they
// produce for every board combination.
#pragma once

#include <stdint.h>

// SymphonyIOOptionBoardType (SymphonyIOVendorSpecific.h:805-812). MicPre8 == the
// 8-channel mic-preamp option board; every other value has ZERO mic-pre channels.
static constexpr uint8_t kSIOOptionBoard_None         = 0;
static constexpr uint8_t kSIOOptionBoard_MicPre8      = 1;
static constexpr uint8_t kSIOOptionBoard_AnalogAES    = 2;
static constexpr uint8_t kSIOOptionBoard_Optical      = 3;
static constexpr uint8_t kSIOOptionBoard_AnalogAD16   = 4;
static constexpr uint8_t kSIOOptionBoard_AnalogDA16   = 5;
static constexpr uint8_t kSIOOptionBoard_AnalogADDA16 = 6;
static constexpr uint8_t kSIOOptionBoard_TwoBySix     = 7;

// Option-board types with a selectable optical format (OpticalFormat 0x34).
// AD16/DA16 and 2x6 also expose optical I/O even though they are not reported
// as the legacy type-3 Optical board. The format command is direction-agnostic
// on the wire.
//
// AnalogAES is NOT one of them. The firmware acts on 0x34 only for 2x6, Optical,
// AD16 and DA16 and does nothing for an AES board
// (og_source/symphonymk1/ext/SymphonyIO/Software/XMOS/SymphonyIO/src/Bulldog/MAL/
// MainController/AudioManager/SymphonyIOAudioManager.cpp:257-290, the AnalogAES
// case is a bare `break`). Apogee's host software sent the format only for a
// board that has an optical stream (og_source/maestrolink/Software/
// SymphonyIO_IOBoard.cpp:940-981, setOpticalIsSPDIF inside the
// OpticalIn/OpticalOut dynamic_cast), and its Analog-AES board builds only
// analog and AES streams (og_source/maestrolink/Software/
// SymphonyIOBoard_AnalogAES.cpp:36-57).
// An 8x8 AES/OPT combo with DIG I/O on optical reports type 3 and still gets one.
static constexpr bool BoardHasOpticalFormat(uint8_t boardType)
{
    return boardType == kSIOOptionBoard_Optical ||
           boardType == kSIOOptionBoard_AnalogAD16 ||
           boardType == kSIOOptionBoard_AnalogDA16 ||
           boardType == kSIOOptionBoard_TwoBySix;
}

// Whether the link-configuration step sends its default OpticalFormat
// (ADAT/SMUX) to a slot. It used to go to both slots blindly. A slot that
// positively reads as an AES board is now skipped, for the reasons above.
// Every other case keeps the earlier behaviour, including a failed board-type
// read. The firmware acts on 0x34 for 2x6, Optical, AD16 and DA16 and ignores
// it on an empty, MicPre8, ADDA16 or AES slot, so the send stays harmless where
// it is ignored, and the traces for every card but AES do not change.
static constexpr bool BootSendsOpticalFormat(bool boardTypeReadOK, uint8_t boardType)
{
    return !(boardTypeReadOK && boardType == kSIOOptionBoard_AnalogAES);
}
