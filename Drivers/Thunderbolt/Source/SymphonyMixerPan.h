// Pan law used by the ThunderBridge card mixer.
#pragma once

#include <stdint.h>

// `side` is the 0...128 attenuation-table index for one output side.
// SW Return is a stereo balance control: center preserves both channels at
// unity, while the opposite side fades to a -48 dB floor.
static constexpr int8_t SymphonyMixerPanAttenuation(uint8_t side)
{
    if (side >= 64) return 0;
    return static_cast<int8_t>(-((48 * (64 - static_cast<int>(side)) + 32) / 64));
}
