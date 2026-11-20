#include <DriverKit/IOLib.h>
#include <AudioDriverKit/IOUserAudioSelectorControl.h>
#include "SymphonyHighPassControl.h"
#include "SymphonyThunderbridge.h"
struct SymphonyHighPassControl_IVars { SymphonyThunderbridge *driver; uint32_t channel; };
bool SymphonyHighPassControl::init(IOUserAudioDriver *d,bool s,IOUserAudioObjectPropertyElement e,IOUserAudioObjectPropertyScope sc,IOUserAudioClassID c) { if(!super::init(d,s,e,sc,c)) return false; ivars=IONewZero(SymphonyHighPassControl_IVars,1); return ivars!=nullptr; }
void SymphonyHighPassControl::free(){if(ivars){OSSafeReleaseNULL(ivars->driver);IODelete(ivars,SymphonyHighPassControl_IVars,1);ivars=nullptr;}super::free();}
void SymphonyHighPassControl::SetDriver(SymphonyThunderbridge*d){if(d)d->retain();if(ivars->driver)ivars->driver->release();ivars->driver=d;} void SymphonyHighPassControl::SetChannel(uint32_t c){ivars->channel=c;}
kern_return_t SymphonyHighPassControl::HandleChangeSelectedValues(const IOUserAudioSelectorValue*v,size_t n){if(!v||!n||!ivars->driver)return kIOReturnBadArgument; bool on=v[0]!=0; kern_return_t r=ivars->driver->RequestHighPass(ivars->channel,on); if(r==kIOReturnSuccess) r=SetCurrentSelectedValues(v,1); return r;}
