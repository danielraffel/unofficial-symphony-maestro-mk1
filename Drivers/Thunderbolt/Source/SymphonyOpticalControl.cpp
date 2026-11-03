// SymphonyOpticalControl.cpp — push-model optical-format selector.
//
// coreaudiod delivers the user's Audio MIDI Setup selection (ADAT/SMUX vs S/PDIF)
// to HandleChangeSelectedValues (on the control's own work queue). We persist it —
// so the AMS checkmark sticks — and hand the (board, format) to the driver, which
// coalesces and async-sends OpticalFormat (0x34) on the serial XLink queue.
// Because we OVERRIDE (not extend) HandleChangeSelectedValues, the base default
// (which would call SetCurrentSelectedValues) never runs, so we must persist it
// ourselves — the same discipline as SymphonyClockSelectorControl, plus the
// phantom's per-board SetBoard()/ivar channel pattern.

#include <os/log.h>
#include <DriverKit/IOLib.h>
#include <AudioDriverKit/IOUserAudioSelectorControl.h>

#include "SymphonyOpticalControl.h"
#include "SymphonyThunderbridge.h"

#define OPLOG(fmt, ...) os_log(OS_LOG_DEFAULT, "SymphonyTB-OPT: " fmt, ##__VA_ARGS__)

// ── Instance Variables ──────────────────────────────────────────────────────

struct SymphonyOpticalControl_IVars {
    SymphonyThunderbridge *driver;   // retained back-pointer
    uint32_t               board;    // 0-based hw board index (nValue on the wire)
};

// ── Lifecycle ───────────────────────────────────────────────────────────────

bool SymphonyOpticalControl::init(
    IOUserAudioDriver* in_driver, bool in_is_settable,
    IOUserAudioObjectPropertyElement in_control_element,
    IOUserAudioObjectPropertyScope in_control_scope,
    IOUserAudioClassID in_control_class_id)
{
    if (!super::init(in_driver, in_is_settable, in_control_element,
                     in_control_scope, in_control_class_id))
        return false;
    ivars = IONewZero(SymphonyOpticalControl_IVars, 1);
    if (!ivars) return false;
    OPLOG("init");
    return true;
}

void SymphonyOpticalControl::free()
{
    if (ivars) {
        OSSafeReleaseNULL(ivars->driver);
        IODelete(ivars, SymphonyOpticalControl_IVars, 1);
        ivars = nullptr;
    }
    super::free();
}

// ── SetDriver / SetBoard ────────────────────────────────────────────────────

void SymphonyOpticalControl::SetDriver(SymphonyThunderbridge* in_driver)
{
    if (in_driver) in_driver->retain();
    if (ivars->driver) ivars->driver->release();
    ivars->driver = in_driver;
}

void SymphonyOpticalControl::SetBoard(uint32_t in_board)
{
    ivars->board = in_board;
}

// ── HandleChangeSelectedValues (the PUSH entry point) ────────────────────────

kern_return_t SymphonyOpticalControl::HandleChangeSelectedValues(
    const IOUserAudioSelectorValue* in_control_values, size_t in_num_values)
{
    if (!in_control_values || in_num_values == 0)
        return kIOReturnBadArgument;

    // 1. Persist so Audio MIDI Setup keeps the checkmark on the chosen row.
    //    (The base default would do this; our override replaces it, so we must.)
    kern_return_t r = SetCurrentSelectedValues(in_control_values, in_num_values);
    if (r != kIOReturnSuccess) {
        OPLOG("SetCurrentSelectedValues failed 0x%x", r);
        return r;
    }

    // 2. Push to hardware (non-blocking; driver coalesces + async-sends 0x34).
    uint32_t fmt = in_control_values[0];   // 0=ADAT/SMUX, 1=S/PDIF
    OPLOG("HandleChangeSelectedValues board=%u → fmt %u", ivars->board, fmt);
    if (ivars->driver)
        ivars->driver->RequestOpticalFormat(ivars->board, fmt);

    return kIOReturnSuccess;
}
