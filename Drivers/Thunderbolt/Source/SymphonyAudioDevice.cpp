// SymphonyAudioDevice.cpp — rate publication hook for the ThunderBridge device.

#include <os/log.h>

#include <DriverKit/IOLib.h>

#include "SymphonyAudioDevice.h"
#include "SymphonyThunderbridge.h"
#include "SymphonyTimingProfile.h"

#define ADLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "SymphonyTB-AUDIO: " fmt, ##__VA_ARGS__)

// EXPERIMENT (64ch, stage 2). Allocated only when a two-port driver calls
// SetPortModeDriver; in a one-port build `ivars` stays null and nothing below
// that mentions it runs.
struct SymphonyAudioDevice_IVars {
    // Retained, set once before the device is published and released in
    // free(), like the selector controls' back-pointers: it is never cleared
    // while a configuration change could be reading it. The driver drops its
    // reference to this device in Stop(), so the pair does not keep itself alive.
    SymphonyThunderbridge *portModeDriver;
};

void SymphonyAudioDevice::SetPortModeDriver(SymphonyThunderbridge* in_driver)
{
    if (ivars || !in_driver) return;   // set once
    ivars = IONewZero(SymphonyAudioDevice_IVars, 1);
    if (!ivars) return;
    in_driver->retain();
    ivars->portModeDriver = in_driver;
}

void SymphonyAudioDevice::free()
{
    if (ivars) {
        OSSafeReleaseNULL(ivars->portModeDriver);
        IODelete(ivars, SymphonyAudioDevice_IVars, 1);
        ivars = nullptr;
    }
    super::free();
}

struct TimingTupleState {
    uint32_t inputSafety;
    uint32_t outputSafety;
    uint32_t inputLatency;
    uint32_t outputLatency;
};

static kern_return_t FirstFailure(kern_return_t a, kern_return_t b,
                                  kern_return_t c, kern_return_t d)
{
    if (a != kIOReturnSuccess) return a;
    if (b != kIOReturnSuccess) return b;
    if (c != kIOReturnSuccess) return c;
    return d;
}

static TimingTupleState ReadTimingTuple(IOUserAudioDevice* device)
{
    return {
        device->GetInputSafetyOffset(),
        device->GetOutputSafetyOffset(),
        device->GetInputLatency(),
        device->GetOutputLatency(),
    };
}

static bool TimingTuplesEqual(const TimingTupleState& lhs,
                              const TimingTupleState& rhs)
{
    return lhs.inputSafety == rhs.inputSafety &&
           lhs.outputSafety == rhs.outputSafety &&
           lhs.inputLatency == rhs.inputLatency &&
           lhs.outputLatency == rhs.outputLatency;
}

static kern_return_t SetTimingTuple(IOUserAudioDevice* device,
                                    const TimingTupleState& tuple)
{
    const kern_return_t inputSafety = device->SetInputSafetyOffset(tuple.inputSafety);
    const kern_return_t outputSafety = device->SetOutputSafetyOffset(tuple.outputSafety);
    const kern_return_t inputLatency = device->SetInputLatency(tuple.inputLatency);
    const kern_return_t outputLatency = device->SetOutputLatency(tuple.outputLatency);
    const kern_return_t setterResult =
        FirstFailure(inputSafety, outputSafety, inputLatency, outputLatency);
    if (setterResult != kIOReturnSuccess) return setterResult;

    // A successful setter is not enough for rollback: a framework or hardware
    // clamp can leave one member of the tuple unchanged. Verify all four
    // values before treating the previous rate as restored.
    const TimingTupleState readback = ReadTimingTuple(device);
    return TimingTuplesEqual(readback, tuple) ? kIOReturnSuccess : kIOReturnError;
}

// dext 131 (SymphonyThunderbridge.cpp): the converters' latency, 0/0 for a Symphony I/O.
void SymphonyConverterLatencyForDevice(IOUserAudioDevice *device, double rate,
                                       uint32_t *inLatency, uint32_t *outLatency);

static kern_return_t ApplyTimingTuple(IOUserAudioDevice* device, double rate,
                                      const TimingTupleState* rollback)
{
    if (!device) return kIOReturnBadArgument;
    TimingProfile profile = TimingProfileForRate(rate);
    uint32_t convIn = 0, convOut = 0;
    SymphonyConverterLatencyForDevice(device, rate, &convIn, &convOut);
    if (convIn || convOut) {
        profile.inputConverterLatency = convIn;
        profile.outputConverterLatency = convOut;
    }
    const kern_return_t inputSafety = device->SetInputSafetyOffset(profile.safetyOffset);
    const kern_return_t outputSafety = device->SetOutputSafetyOffset(profile.safetyOffset);
    const uint32_t inputLatencyFrames = profile.inputConverterLatency + profile.frameSize;
    const uint32_t outputLatencyFrames = profile.outputConverterLatency + profile.frameSize;
    const kern_return_t inputLatency = device->SetInputLatency(inputLatencyFrames);
    const kern_return_t outputLatency = device->SetOutputLatency(outputLatencyFrames);
    const TimingTupleState readback = ReadTimingTuple(device);
    const bool readbackMatches =
        readback.inputSafety == profile.safetyOffset &&
        readback.outputSafety == profile.safetyOffset &&
        readback.inputLatency == inputLatencyFrames &&
        readback.outputLatency == outputLatencyFrames;
    ADLOG("ApplyTimingTuple rate=%.0f frame=%u safety=(%u,%u) publishedLatency=(%u,%u) setters=(0x%x,0x%x,0x%x,0x%x) "
          "readback safety=(%u,%u) latency=(%u,%u)",
          rate, profile.frameSize, profile.safetyOffset, profile.safetyOffset,
          inputLatencyFrames, outputLatencyFrames,
          inputSafety, outputSafety, inputLatency, outputLatency,
          readback.inputSafety, readback.outputSafety,
          readback.inputLatency, readback.outputLatency);
    kern_return_t result = FirstFailure(inputSafety, outputSafety, inputLatency, outputLatency);
    if (result == kIOReturnSuccess && !readbackMatches) {
        ADLOG("ApplyTimingTuple rate=%.0f readback mismatch — refusing publication", rate);
        result = kIOReturnError;
    }
    if (result != kIOReturnSuccess && rollback) {
        const kern_return_t restore = SetTimingTuple(device, *rollback);
        ADLOG("ApplyTimingTuple rate=%.0f failed=0x%x rollback=0x%x", rate, result, restore);
        if (restore != kIOReturnSuccess) {
            ADLOG("ApplyTimingTuple rate=%.0f rollback readback mismatch — refusing mixed tuple",
                  rate);
            return kIOReturnError;
        }
    }
    return result;
}

kern_return_t SymphonyAudioDevice::PerformDeviceConfigurationChange(
    uint64_t in_change_action, OSObject* in_change_info)
{
    ADLOG("PerformDeviceConfigurationChange begin action=%llu rate=%.0f tuple=(%u,%u,%u,%u)",
          in_change_action, GetSampleRate(), GetInputLatency(), GetOutputLatency(),
          GetInputSafetyOffset(), GetOutputSafetyOffset());

    // EXPERIMENT (64ch, stage 2), two-port builds only: IO is stopped here, so
    // this is where a requested port selection is applied and the streams are
    // given their 32- or 64-channel formats (Apple's sample driver changes its
    // stream formats in this same callback). Its result does not fail the
    // configuration change: a refused request leaves the device at 32 channels.
    if (ivars && ivars->portModeDriver) {
        const kern_return_t portResult = ivars->portModeDriver->PerformPortModeChange();
        ADLOG("PerformDeviceConfigurationChange port selection applied: 0x%x", portResult);
    }

    const kern_return_t result = super::PerformDeviceConfigurationChange(
        in_change_action, in_change_info);
    if (result != kIOReturnSuccess) {
        ADLOG("PerformDeviceConfigurationChange super failed action=%llu: 0x%x",
              in_change_action, result);
        return result;
    }

    // Do not mutate the tuple here. This callback can observe the previous
    // nominal rate during a host transition; reapplying from GetSampleRate()
    // here can overwrite a newly staged 96 kHz safety value with 10.
    // HandleChangeSampleRate stages the target tuple before SetSampleRate's
    // host notification, and StartDevice applies it again for the hardware
    // restart.
    SymphonySyncHardwareRate(this, "configuration change");
    const double rate = GetSampleRate();
    ADLOG("PerformDeviceConfigurationChange end action=%llu rate=%.0f "
          "readback=(%u,%u,%u,%u)",
          in_change_action, rate,
          GetInputLatency(), GetOutputLatency(), GetInputSafetyOffset(),
          GetOutputSafetyOffset());
    return result;
}

// Defined in SymphonyThunderbridge.cpp: the channel names follow the nominal
// rate, which can change with no IO start (see there).
void SymphonyNoteNominalSampleRate(IOUserAudioDevice *device, double rate);
// Defined in SymphonyThunderbridge.cpp: the hardware takes the nominal rate
// now, as the original's performFormatChange did (see there).
void SymphonySyncHardwareRate(IOUserAudioDevice *device, const char *why);

kern_return_t SymphonyAudioDevice::HandleChangeSampleRate(double in_sample_rate)
{
    ADLOG("HandleChangeSampleRate begin rate=%.0f current=%.0f tuple=(%u,%u,%u,%u)",
          in_sample_rate, GetSampleRate(), GetInputLatency(), GetOutputLatency(),
          GetInputSafetyOffset(), GetOutputSafetyOffset());

    // Stage the complete target tuple before AudioDriverKit's nominal-rate
    // notification. Safety setters do not promise a separate notification, so
    // setting them after super::HandleChangeSampleRate can leave Core Audio
    // caching the previous rate's safety value (the observed 96 kHz 8/10 bug).
    const double previousRate = GetSampleRate();
    const TimingTupleState previousTuple = ReadTimingTuple(this);
    const kern_return_t preResult = ApplyTimingTuple(this, in_sample_rate, &previousTuple);
    if (preResult != kIOReturnSuccess) {
        ADLOG("HandleChangeSampleRate %.0f pre-apply failed: 0x%x",
              in_sample_rate, preResult);
        return preResult;
    }

    const kern_return_t result = super::HandleChangeSampleRate(in_sample_rate);
    if (result != kIOReturnSuccess) {
        ADLOG("HandleChangeSampleRate %.0f failed: 0x%x", in_sample_rate, result);
        // Restore the tuple for the still-active nominal rate if the host
        // rejected the requested rate.
        const kern_return_t restoreResult =
            ApplyTimingTuple(this, previousRate, &previousTuple);
        if (restoreResult != kIOReturnSuccess) {
            ADLOG("HandleChangeSampleRate %.0f rollback failed: 0x%x",
                  previousRate, restoreResult);
            return kIOReturnError;
        }
        return result;
    }

    // The rate is now the device's nominal rate: rename the optical channels.
    SymphonyNoteNominalSampleRate(this, in_sample_rate);

    // Re-read and reapply after the superclass transition as a defensive
    // check, while the pre-apply is what makes the host notification correct.
    const kern_return_t postResult = ApplyTimingTuple(this, in_sample_rate, &previousTuple);
    ADLOG("HandleChangeSampleRate %.0f completed result=0x%x post=0x%x",
          in_sample_rate, result, postResult);
    if (postResult == kIOReturnSuccess) SymphonySyncHardwareRate(this, "rate change");
    return postResult;
}
