// SymphonyInputTypeControl.cpp — push-model MicPre input type control.
//
// A line-level control ('nlvl') on the Input scope, which the HAL serves as
// kAudioDevicePropertyChannelNominalLineLevel(s) and ...NameForIDCFString.
// IDs are CoreAudio's order: 0 +4 dBu, 1 -10 dBV, 2 Variable, 3 Mic,
// 4 Instrument (og_source/maestrolink/Software/mAEstro.h:353-357); the driver
// maps them to the 0x20 wire enum. coreaudiod delivers the DAW's choice to
// HandleChangeSelectedValues (on the control's own work queue). An accepted
// request shows the new type at once, as the original stored the type before
// the hardware write (og_source/maestrolink/Software/SymphonyIOBoard_MicPre8ch.cpp:401);
// the driver then turns phantom and the insert off first where needed, sends
// the type on the serial XLink queue and publishes the type the unit took. A
// request dropped or failed there republishes the real type
// (RepublishMicPreHost), so a client that read the new value is told again.

#include <os/log.h>
#include <DriverKit/IOLib.h>
#include <AudioDriverKit/IOUserAudioSelectorControl.h>

#include "SymphonyInputTypeControl.h"
#include "SymphonyThunderbridge.h"

#define ITLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "SymphonyTB-TYPE: " fmt, ##__VA_ARGS__)

// ── Instance Variables ──────────────────────────────────────────────────────

struct SymphonyInputTypeControl_IVars {
    SymphonyThunderbridge *driver;   // retained back-pointer
    uint32_t               channel;  // 0-based host input (the driver resolves the route)
};

// ── Lifecycle ───────────────────────────────────────────────────────────────

bool SymphonyInputTypeControl::init(
    IOUserAudioDriver* in_driver, bool in_is_settable,
    IOUserAudioObjectPropertyElement in_control_element,
    IOUserAudioObjectPropertyScope in_control_scope,
    IOUserAudioClassID in_control_class_id)
{
    if (!super::init(in_driver, in_is_settable, in_control_element,
                     in_control_scope, in_control_class_id))
        return false;
    ivars = IONewZero(SymphonyInputTypeControl_IVars, 1);
    if (!ivars) return false;
    return true;
}

void SymphonyInputTypeControl::free()
{
    if (ivars) {
        OSSafeReleaseNULL(ivars->driver);
        IODelete(ivars, SymphonyInputTypeControl_IVars, 1);
        ivars = nullptr;
    }
    super::free();
}

// ── SetDriver / SetChannel ──────────────────────────────────────────────────

void SymphonyInputTypeControl::SetDriver(SymphonyThunderbridge* in_driver)
{
    if (in_driver) in_driver->retain();
    if (ivars->driver) ivars->driver->release();
    ivars->driver = in_driver;
}

void SymphonyInputTypeControl::SetChannel(uint32_t in_channel)
{
    ivars->channel = in_channel;
}

// ── HandleChangeSelectedValues (the PUSH entry point) ────────────────────────

kern_return_t SymphonyInputTypeControl::HandleChangeSelectedValues(
    const IOUserAudioSelectorValue* in_selected_values, size_t in_selected_values_count)
{
    if (!in_selected_values || in_selected_values_count == 0 || in_selected_values[0] > 4)
        return kIOReturnBadArgument;
    if (!ivars->driver) return kIOReturnNotReady;
    ITLOG("HandleChangeSelectedValues ch=%u -> %u", ivars->channel, in_selected_values[0]);
    // Overriding HandleChange skips the base class's set: store the value
    // first (as the original did), so a client reading it back straight away
    // sees the type it chose, and the driver's publish after the send (or its
    // republish of the real type) always lands after it. Refused: put the
    // old value back (the driver also republishes the real type where it can).
    IOUserAudioSelectorValue previous = 0;
    const bool hadPrevious = GetCurrentSelectedValues(&previous, 1) == 1;
    SetCurrentSelectedValues(in_selected_values, 1);
    const kern_return_t r = ivars->driver->RequestInputType(ivars->channel, in_selected_values[0]);
    if (r != kIOReturnSuccess && hadPrevious) SetCurrentSelectedValues(&previous, 1);
    return r;
}
