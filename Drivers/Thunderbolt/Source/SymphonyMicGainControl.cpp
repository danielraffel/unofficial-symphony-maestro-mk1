// SymphonyMicGainControl.cpp — push-model mic-preamp gain level control.
//
// coreaudiod delivers the user's fader move to HandleChangeDecibelValue (on the
// control's own work queue). The driver coalesces and async-sends the selected
// gain stage on the serial XLink queue, then publishes the accepted value with
// SetDecibelValue (including the host property notification).

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
    // The driver clamps/quantizes for the active stage and publishes via
    // SetDecibelValue after a successful send. Never persist the raw request:
    // Instrument may clamp it, and unknown type/shutdown may refuse it.
    if (!ivars->driver) return kIOReturnNotReady;
    return ivars->driver->RequestMicGain(ivars->channel, in_decibel_value);
}

// No HandleChangeScalarValue override: a scalar change only updates the stored
// value, as before. coreaudiod's own store/recall must not move the preamp
// (the original refused coreaudiod's automatic recall of input gain,
// og_source/maestrolink/Software/SymphonyIOBoard_MicPre8ch.cpp:797-806).
