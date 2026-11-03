// SymphonyMicGainControl.cpp — push-model mic-preamp gain level control.
//
// coreaudiod delivers the user's fader move to HandleChangeDecibelValue (on the
// control's own work queue). We persist it — so the fader sticks in the UI —
// and hand the (channel, dB) to the driver, which coalesces and async-sends
// MicGain (0xC3) on the serial XLink queue. Because we OVERRIDE (not extend)
// HandleChangeDecibelValue, the base default (which would call SetDecibelValue)
// never runs, so we must persist it ourselves.

#include <os/log.h>
#include <DriverKit/IOLib.h>
#include <AudioDriverKit/IOUserAudioLevelControl.h>

#include "SymphonyMicGainControl.h"
#include "SymphonyThunderbridge.h"

#define MGLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "SymphonyTB-MGAIN: " fmt, ##__VA_ARGS__)

// ── Instance Variables ──────────────────────────────────────────────────────

struct SymphonyMicGainControl_IVars {
    SymphonyThunderbridge *driver;   // retained back-pointer
    uint32_t               channel;  // 0-based hw mic channel
};

// ── Lifecycle ───────────────────────────────────────────────────────────────

bool SymphonyMicGainControl::init(
    IOUserAudioDriver* in_driver, bool in_is_settable, float in_decibel_value,
    IOUserAudioLevelControlRange in_decibel_range,
    IOUserAudioObjectPropertyElement in_control_element,
    IOUserAudioObjectPropertyScope in_control_scope,
    IOUserAudioClassID in_control_class_id)
{
    if (!super::init(in_driver, in_is_settable, in_decibel_value, in_decibel_range,
                     in_control_element, in_control_scope, in_control_class_id))
        return false;
    ivars = IONewZero(SymphonyMicGainControl_IVars, 1);
    if (!ivars) return false;
    MGLOG("init");
    return true;
}

void SymphonyMicGainControl::free()
{
    if (ivars) {
        OSSafeReleaseNULL(ivars->driver);
        IODelete(ivars, SymphonyMicGainControl_IVars, 1);
        ivars = nullptr;
    }
    super::free();
}

// ── SetDriver / SetChannel ──────────────────────────────────────────────────

void SymphonyMicGainControl::SetDriver(SymphonyThunderbridge* in_driver)
{
    if (in_driver) in_driver->retain();
    if (ivars->driver) ivars->driver->release();
    ivars->driver = in_driver;
}

void SymphonyMicGainControl::SetChannel(uint32_t in_channel)
{
    ivars->channel = in_channel;
}

// ── HandleChangeDecibelValue (the PUSH entry point) ──────────────────────────

kern_return_t SymphonyMicGainControl::HandleChangeDecibelValue(float in_decibel_value)
{
    // 1. Persist so the fader sticks. (The base default would do this; our
    //    override replaces it, so we must.)
    kern_return_t r = SetDecibelValue(in_decibel_value);
    if (r != kIOReturnSuccess) {
        MGLOG("SetDecibelValue failed 0x%x", r);
        return r;
    }

    // 2. Push to hardware (non-blocking; driver coalesces + async-sends 0xC3).
    MGLOG("HandleChangeDecibelValue ch=%u → %d dB",
          ivars->channel, (int)in_decibel_value);
    if (ivars->driver)
        ivars->driver->RequestMicGain(ivars->channel, in_decibel_value);

    return kIOReturnSuccess;
}
