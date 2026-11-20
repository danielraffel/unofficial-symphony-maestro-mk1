#include <DriverKit/IOLib.h>
#include <AudioDriverKit/IOUserAudioSelectorControl.h>
#include "SymphonyInputTypeControl.h"
#include "SymphonyThunderbridge.h"
struct SymphonyInputTypeControl_IVars { SymphonyThunderbridge *driver; uint32_t channel; };
bool SymphonyInputTypeControl::init(IOUserAudioDriver*d,bool s,IOUserAudioObjectPropertyElement e,IOUserAudioObjectPropertyScope sc,IOUserAudioClassID c){if(!super::init(d,s,e,sc,c))return false;ivars=IONewZero(SymphonyInputTypeControl_IVars,1);return ivars!=nullptr;}
void SymphonyInputTypeControl::free(){if(ivars){OSSafeReleaseNULL(ivars->driver);IODelete(ivars,SymphonyInputTypeControl_IVars,1);ivars=nullptr;}super::free();}
void SymphonyInputTypeControl::SetDriver(SymphonyThunderbridge*d){if(d)d->retain();if(ivars->driver)ivars->driver->release();ivars->driver=d;} void SymphonyInputTypeControl::SetChannel(uint32_t c){ivars->channel=c;}
kern_return_t SymphonyInputTypeControl::HandleChangeSelectedValues(const IOUserAudioSelectorValue*v,size_t n){if(!v||!n||v[0]>4||!ivars->driver)return kIOReturnBadArgument;kern_return_t r=ivars->driver->RequestInputType(ivars->channel,v[0]);if(r==kIOReturnSuccess)r=SetCurrentSelectedValues(v,1);return r;}
