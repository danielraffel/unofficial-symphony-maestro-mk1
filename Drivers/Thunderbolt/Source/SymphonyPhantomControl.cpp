// SymphonyPhantomControl.cpp — push-model phantom-power boolean control.
//
// coreaudiod delivers the user's on/off toggle to HandleChangeControlValue (on
// the control's own work queue). We persist it — so the toggle sticks in the
// UI — and hand the (channel, value) to the driver, which coalesces and
// async-sends PhantomPower (0xC6) on the serial XLink queue. Because we OVERRIDE
// (not extend) HandleChangeControlValue, the base default (which would call
// SetControlValue) never runs, so we must persist it ourselves.

#include <os/log.h>
#include <DriverKit/IOLib.h>
#include <AudioDriverKit/IOUserAudioBooleanControl.h>

#include "SymphonyPhantomControl.h"
#include "SymphonyThunderbridge.h"

#define PHLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "SymphonyTB-PHAN: " fmt, ##__VA_ARGS__)

// ── Instance Variables ──────────────────────────────────────────────────────

struct SymphonyPhantomControl_IVars {
    SymphonyThunderbridge *driver;   // retained back-pointer
    uint32_t               channel;  // 0-based hw mic channel
};

// ── Lifecycle ───────────────────────────────────────────────────────────────

bool SymphonyPhantomControl::init(
    IOUserAudioDriver* in_driver, bool in_is_settable, bool in_control_value,
    IOUserAudioObjectPropertyElement in_control_element,
    IOUserAudioObjectPropertyScope in_control_scope,
    IOUserAudioClassID in_control_class_id)
{
    if (!super::init(in_driver, in_is_settable, in_control_value,
                     in_control_element, in_control_scope, in_control_class_id))
        return false;
    ivars = IONewZero(SymphonyPhantomControl_IVars, 1);
    if (!ivars) return false;
    PHLOG("init");
    return true;
}

void SymphonyPhantomControl::free()
{
    if (ivars) {
        OSSafeReleaseNULL(ivars->driver);
        IODelete(ivars, SymphonyPhantomControl_IVars, 1);
        ivars = nullptr;
    }
    super::free();
}

// ── SetDriver / SetChannel ──────────────────────────────────────────────────

void SymphonyPhantomControl::SetDriver(SymphonyThunderbridge* in_driver)
{
    if (in_driver) in_driver->retain();
    if (ivars->driver) ivars->driver->release();
    ivars->driver = in_driver;
}

void SymphonyPhantomControl::SetChannel(uint32_t in_channel)
{
    ivars->channel = in_channel;
}

// ── HandleChangeControlValue (the PUSH entry point) ──────────────────────────

kern_return_t SymphonyPhantomControl::HandleChangeControlValue(bool in_control_value)
{
    // 1. Persist so the toggle sticks. (The base default would do this; our
    //    override replaces it, so we must.)
    kern_return_t r = SetControlValue(in_control_value);
    if (r != kIOReturnSuccess) {
        PHLOG("SetControlValue failed 0x%x", r);
        return r;
    }

    // 2. Push to hardware (non-blocking; driver coalesces + async-sends 0xC6).
    PHLOG("HandleChangeControlValue ch=%u → %s",
          ivars->channel, in_control_value ? "on" : "off");
    if (ivars->driver)
        ivars->driver->RequestPhantom(ivars->channel, in_control_value);

    return kIOReturnSuccess;
}
