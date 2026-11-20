// SymphonyPhaseControl.cpp — push-model MicPre polarity (phase invert) control.
//
// coreaudiod delivers the DAW's toggle to HandleChangeControlValue (on the
// control's own work queue). The driver checks the input type, coalesces and
// sends PhaseInverse (0xC5) on the serial XLink queue, then publishes the
// value the unit took with SetControlValue. Nothing is published here: a
// refused or dropped request must not leave a value the hardware never took.

#include <os/log.h>
#include <DriverKit/IOLib.h>
#include <AudioDriverKit/IOUserAudioBooleanControl.h>

#include "SymphonyPhaseControl.h"
#include "SymphonyThunderbridge.h"

#define PILOG(fmt, ...) os_log(OS_LOG_DEFAULT, "SymphonyTB-PHASE: " fmt, ##__VA_ARGS__)

// ── Instance Variables ──────────────────────────────────────────────────────

struct SymphonyPhaseControl_IVars {
    SymphonyThunderbridge *driver;   // retained back-pointer
    uint32_t               channel;  // 0-based host input (the driver resolves the route)
};

// ── Lifecycle ───────────────────────────────────────────────────────────────

bool SymphonyPhaseControl::init(
    IOUserAudioDriver* in_driver, bool in_is_settable, bool in_control_value,
    IOUserAudioObjectPropertyElement in_control_element,
    IOUserAudioObjectPropertyScope in_control_scope,
    IOUserAudioClassID in_control_class_id)
{
    if (!super::init(in_driver, in_is_settable, in_control_value,
                     in_control_element, in_control_scope, in_control_class_id))
        return false;
    ivars = IONewZero(SymphonyPhaseControl_IVars, 1);
    if (!ivars) return false;
    return true;
}

void SymphonyPhaseControl::free()
{
    if (ivars) {
        OSSafeReleaseNULL(ivars->driver);
        IODelete(ivars, SymphonyPhaseControl_IVars, 1);
        ivars = nullptr;
    }
    super::free();
}

// ── SetDriver / SetChannel ──────────────────────────────────────────────────

void SymphonyPhaseControl::SetDriver(SymphonyThunderbridge* in_driver)
{
    if (in_driver) in_driver->retain();
    if (ivars->driver) ivars->driver->release();
    ivars->driver = in_driver;
}

void SymphonyPhaseControl::SetChannel(uint32_t in_channel)
{
    ivars->channel = in_channel;
}

// ── HandleChangeControlValue (the PUSH entry point) ──────────────────────────

kern_return_t SymphonyPhaseControl::HandleChangeControlValue(bool in_control_value)
{
    // Like SymphonyMicGainControl: the driver publishes after a successful
    // send and republishes the real value when the request is dropped.
    PILOG("HandleChangeControlValue ch=%u -> %{public}s",
          ivars->channel, in_control_value ? "on" : "off");
    if (!ivars->driver) return kIOReturnNotReady;
    return ivars->driver->RequestPhaseInvert(ivars->channel, in_control_value);
}
