// SymphonyTimingProfile.h — shared High Performance timing table.
//
// The table is intentionally kept independent of the AudioDriverKit object so
// both the device subclass and the ThunderBridge transaction can publish the
// same rate-specific tuple.
#pragma once

#include <stdint.h>

#include "Sym64Registers.h"

struct TimingProfile {
    uint32_t frameSize;
    uint32_t safetyOffset;
    // Converter/channel latency reported by the legacy Symphony I/O
    // peripheral. Core Audio latency is this term plus the FPGA period.
    uint32_t inputConverterLatency;
    uint32_t outputConverterLatency;
};

static inline TimingProfile TimingProfileForRate(double rate)
{
    if (!kUseHighPerformanceProfile) {
        if (rate <= 48000.0) return { kStandardFPGAFrameSize, kStandardSafetyOffset, 29, 29 };
        if (rate <= 96000.0) return { kStandardFPGAFrameSize, kStandardSafetyOffset, 28, 28 };
        return { kStandardFPGAFrameSize, kStandardSafetyOffset, 26, 27 };
    }
    if (rate <= 48000.0) {
        return { kHighPerformanceFrameLow, kHighPerformanceSafetyLow, 29, 29 };
    }
    if (rate <= 96000.0) {
        return { kHighPerformanceFrameMid, kHighPerformanceSafetyMid, 28, 28 };
    }
    return { kHighPerformanceFrameHigh, kHighPerformanceSafetyHigh, 26, 27 };
}

static inline uint32_t FPGAFrameSizeForRate(double rate)
{
    return TimingProfileForRate(rate).frameSize;
}

static inline uint32_t SafetyOffsetForRate(double rate)
{
    return TimingProfileForRate(rate).safetyOffset;
}
