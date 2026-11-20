#include <DriverKit/IOLib.h>
#include <AudioDriverKit/IOUserAudioBooleanControl.h>
#include "SymphonyPhaseControl.h"
#include "SymphonyThunderbridge.h"
struct SymphonyPhaseControl_IVars { SymphonyThunderbridge *driver; uint32_t channel; };
bool SymphonyPhaseControl::init(IOUserAudioDriver *d, bool s, bool v, IOUserAudioObjectPropertyElement e, IOUserAudioObjectPropertyScope sc, IOUserAudioClassID c) {
    if (!super::init(d,s,v,e,sc,c)) return false;
    ivars = IONewZero(SymphonyPhaseControl_IVars,1); return ivars != nullptr;
}
void SymphonyPhaseControl::free() { if (ivars) { OSSafeReleaseNULL(ivars->driver); IODelete(ivars, SymphonyPhaseControl_IVars,1); ivars=nullptr; } super::free(); }
void SymphonyPhaseControl::SetDriver(SymphonyThunderbridge *d) { if (d) d->retain(); if (ivars->driver) ivars->driver->release(); ivars->driver=d; }
void SymphonyPhaseControl::SetChannel(uint32_t c) { ivars->channel=c; }
kern_return_t SymphonyPhaseControl::HandleChangeControlValue(bool v) { if (!ivars->driver) return kIOReturnNotReady; kern_return_t r=ivars->driver->RequestPhaseInvert(ivars->channel,v); if (r==kIOReturnSuccess) r=SetControlValue(v); return r; }
