// SymphonyPortSourceControl.cpp — EXPERIMENT (64ch, stage 2): the port selector.
// See the .iig. Two-port builds only.

#include <os/log.h>
#include <DriverKit/IOLib.h>
#include <AudioDriverKit/IOUserAudioSelectorControl.h>

#include "SymphonyPortSourceControl.h"
#include "SymphonyThunderbridge.h"
#include "SymphonyThunderbridgeShared.h"

#define PSLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "SymphonyTB-PORT: " fmt, ##__VA_ARGS__)

struct SymphonyPortSourceControl_IVars {
    SymphonyThunderbridge *driver;   // retained back-pointer
};

bool SymphonyPortSourceControl::init(
    IOUserAudioDriver* in_driver, bool in_is_settable,
    IOUserAudioObjectPropertyElement in_control_element,
    IOUserAudioObjectPropertyScope in_control_scope,
    IOUserAudioClassID in_control_class_id)
{
    if (!super::init(in_driver, in_is_settable, in_control_element,
                     in_control_scope, in_control_class_id))
        return false;
    ivars = IONewZero(SymphonyPortSourceControl_IVars, 1);
    return ivars != nullptr;
}

void SymphonyPortSourceControl::free()
{
    if (ivars) {
        OSSafeReleaseNULL(ivars->driver);
        IODelete(ivars, SymphonyPortSourceControl_IVars, 1);
        ivars = nullptr;
    }
    super::free();
}

void SymphonyPortSourceControl::SetDriver(SymphonyThunderbridge* in_driver)
{
    if (in_driver) in_driver->retain();
    if (ivars->driver) ivars->driver->release();
    ivars->driver = in_driver;
}

kern_return_t SymphonyPortSourceControl::HandleChangeSelectedValues(
    const IOUserAudioSelectorValue* in_control_values, size_t in_num_values)
{
    if (!in_control_values || in_num_values == 0)
        return kIOReturnBadArgument;
    const uint32_t value = in_control_values[0];
    if (value != kSymphonyPortSourcePort1 && value != kSymphonyPortSourcePorts1And2)
        return kIOReturnBadArgument;

    // Show the choice at once on this selector, as the original's did. The
    // driver sets both selectors to what the card is really doing once the
    // configuration change has been performed, so the other one follows there
    // and a refused request shows as the 32-channel entry again.
    kern_return_t r = SetCurrentSelectedValues(in_control_values, in_num_values);
    if (r != kIOReturnSuccess) {
        PSLOG("SetCurrentSelectedValues failed 0x%x", r);
        return r;
    }
    PSLOG("HandleChangeSelectedValues → %u", value);
    if (ivars->driver)
        ivars->driver->RequestPortMode(value);
    return kIOReturnSuccess;
}
