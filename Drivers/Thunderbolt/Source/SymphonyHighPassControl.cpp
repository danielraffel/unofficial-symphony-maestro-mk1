// SymphonyHighPassControl.cpp — push-model MicPre 80 Hz high-pass control.
//
// A two-entry selector (Off, On) on the Input scope, the class the HAL serves
// as kAudioDevicePropertyHighPassFilterSetting(s). coreaudiod delivers the
// DAW's choice to HandleChangeSelectedValues (on the control's own work
// queue). The driver checks the input type, coalesces and sends
// HighPassFilter (0xCA) on the serial XLink queue, then publishes the value
// the unit took with SetCurrentSelectedValues. Nothing is published here.

#include <os/log.h>
#include <DriverKit/IOLib.h>
#include <AudioDriverKit/IOUserAudioSelectorControl.h>

#include "SymphonyHighPassControl.h"
#include "SymphonyThunderbridge.h"

#define HPLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "SymphonyTB-HPF: " fmt, ##__VA_ARGS__)

// ── Instance Variables ──────────────────────────────────────────────────────

struct SymphonyHighPassControl_IVars {
    SymphonyThunderbridge *driver;   // retained back-pointer
    uint32_t               channel;  // 0-based host input (the driver resolves the route)
};

// ── Lifecycle ───────────────────────────────────────────────────────────────

bool SymphonyHighPassControl::init(
    IOUserAudioDriver* in_driver, bool in_is_settable,
    IOUserAudioObjectPropertyElement in_control_element,
    IOUserAudioObjectPropertyScope in_control_scope,
    IOUserAudioClassID in_control_class_id)
{
    if (!super::init(in_driver, in_is_settable, in_control_element,
                     in_control_scope, in_control_class_id))
        return false;
    ivars = IONewZero(SymphonyHighPassControl_IVars, 1);
    if (!ivars) return false;
    return true;
}

void SymphonyHighPassControl::free()
{
    if (ivars) {
        OSSafeReleaseNULL(ivars->driver);
        IODelete(ivars, SymphonyHighPassControl_IVars, 1);
        ivars = nullptr;
    }
    super::free();
}

// ── SetDriver / SetChannel ──────────────────────────────────────────────────

void SymphonyHighPassControl::SetDriver(SymphonyThunderbridge* in_driver)
{
    if (in_driver) in_driver->retain();
    if (ivars->driver) ivars->driver->release();
    ivars->driver = in_driver;
}

void SymphonyHighPassControl::SetChannel(uint32_t in_channel)
{
    ivars->channel = in_channel;
}

// ── HandleChangeSelectedValues (the PUSH entry point) ────────────────────────

kern_return_t SymphonyHighPassControl::HandleChangeSelectedValues(
    const IOUserAudioSelectorValue* in_selected_values, size_t in_selected_values_count)
{
    if (!in_selected_values || in_selected_values_count == 0 || in_selected_values[0] > 1)
        return kIOReturnBadArgument;
    if (!ivars->driver) return kIOReturnNotReady;
    HPLOG("HandleChangeSelectedValues ch=%u -> %u", ivars->channel, in_selected_values[0]);
    return ivars->driver->RequestHighPass(ivars->channel, in_selected_values[0] != 0);
}
