// SymphonyClockSelectorControl.cpp — push-model clock-source selector.
//
// coreaudiod delivers the user's Audio MIDI Setup selection to
// HandleChangeSelectedValues (on the control's own work queue). We persist it —
// so the AMS checkmark sticks — and hand the source to the driver, which
// coalesces and async-sends ClockMode on the serial XLink queue. Because we
// OVERRIDE (not extend) HandleChangeSelectedValues, the base default (which would
// call SetCurrentSelectedValues) never runs, so we must persist it ourselves.

#include <os/log.h>
#include <DriverKit/IOLib.h>
#include <AudioDriverKit/IOUserAudioSelectorControl.h>

#include "SymphonyClockSelectorControl.h"
#include "SymphonyThunderbridge.h"

#define CKLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "SymphonyTB-CLK: " fmt, ##__VA_ARGS__)

// ── Instance Variables ──────────────────────────────────────────────────────

struct SymphonyClockSelectorControl_IVars {
    SymphonyThunderbridge *driver;   // retained back-pointer
};

// ── Lifecycle ───────────────────────────────────────────────────────────────

bool SymphonyClockSelectorControl::init(
    IOUserAudioDriver* in_driver, bool in_is_settable,
    IOUserAudioObjectPropertyElement in_control_element,
    IOUserAudioObjectPropertyScope in_control_scope,
    IOUserAudioClassID in_control_class_id)
{
    if (!super::init(in_driver, in_is_settable, in_control_element,
                     in_control_scope, in_control_class_id))
        return false;
    ivars = IONewZero(SymphonyClockSelectorControl_IVars, 1);
    if (!ivars) return false;
    CKLOG("init");
    return true;
}

void SymphonyClockSelectorControl::free()
{
    if (ivars) {
        OSSafeReleaseNULL(ivars->driver);
        IODelete(ivars, SymphonyClockSelectorControl_IVars, 1);
        ivars = nullptr;
    }
    super::free();
}

// ── SetDriver ───────────────────────────────────────────────────────────────

void SymphonyClockSelectorControl::SetDriver(SymphonyThunderbridge* in_driver)
{
    if (in_driver) in_driver->retain();
    if (ivars->driver) ivars->driver->release();
    ivars->driver = in_driver;
}

// ── HandleChangeSelectedValues (the PUSH entry point) ────────────────────────

kern_return_t SymphonyClockSelectorControl::HandleChangeSelectedValues(
    const IOUserAudioSelectorValue* in_control_values, size_t in_num_values)
{
    if (!in_control_values || in_num_values == 0)
        return kIOReturnBadArgument;

    // 1. Persist so Audio MIDI Setup keeps the checkmark on the chosen row.
    //    (The base default would do this; our override replaces it, so we must.)
    kern_return_t r = SetCurrentSelectedValues(in_control_values, in_num_values);
    if (r != kIOReturnSuccess) {
        CKLOG("SetCurrentSelectedValues failed 0x%x", r);
        return r;
    }

    // 2. Push to hardware (non-blocking; driver coalesces + async-sends ClockMode).
    uint32_t sel = in_control_values[0];   // 1..5 = clock source
    CKLOG("HandleChangeSelectedValues → source %u", sel);
    if (ivars->driver)
        ivars->driver->RequestClockSource(sel);

    return kIOReturnSuccess;
}
