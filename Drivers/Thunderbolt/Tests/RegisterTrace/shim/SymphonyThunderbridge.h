// Host-test stand-in for the header iig generates from SymphonyThunderbridge.iig.
// Keep the method list in step with the .iig; a method the driver source does
// not define is harmless as long as the test does not call it.
#pragma once
#include "HostDriverKit.h"
#define SYMPHONY_REGISTER_TRACE_HOST 1

struct SymphonyThunderbridge_IVars;

#define IMPL(cls, name) cls::name##_Impl(cls##_##name##_Args)
#define SymphonyThunderbridge_Start_Args IOService *provider
#define SymphonyThunderbridge_Stop_Args IOService *provider
#define SymphonyThunderbridge_SetPowerState_Args uint32_t powerFlags
#define SymphonyThunderbridge_NewUserClient_Args uint32_t type, IOUserClient **userClient
#define SymphonyThunderbridge_InterruptOccurred_Args OSAction *action, uint64_t count, uint64_t time
#define SymphonyThunderbridge_LinkWatchTimerOccurred_Args OSAction *action, uint64_t time

class SymphonyThunderbridge : public IOUserAudioDriver {
    using super = IOUserAudioDriver;
public:
    SymphonyThunderbridge_IVars *ivars = nullptr;

    bool init() override;
    void free() override;

    using IOService::Start;
    using IOService::Stop;
    using IOService::SetPowerState;
    using IOService::NewUserClient;
    kern_return_t Start(IOService *provider) { return Start_Impl(provider); }
    kern_return_t Stop(IOService *provider) { return Stop_Impl(provider); }
    kern_return_t SetPowerState(uint32_t powerFlags) { return SetPowerState_Impl(powerFlags); }
    kern_return_t NewUserClient(uint32_t type, IOUserClient **uc) { return NewUserClient_Impl(type, uc); }
    void InterruptOccurred(OSAction *a, uint64_t count, uint64_t time) { InterruptOccurred_Impl(a, count, time); }
    void LinkWatchTimerOccurred(OSAction *a, uint64_t time) { LinkWatchTimerOccurred_Impl(a, time); }

    kern_return_t Start_Impl(IOService *provider);
    kern_return_t Stop_Impl(IOService *provider);
    kern_return_t SetPowerState_Impl(uint32_t powerFlags);
    kern_return_t NewUserClient_Impl(uint32_t type, IOUserClient **userClient);
    void InterruptOccurred_Impl(OSAction *action, uint64_t count, uint64_t time);
    void LinkWatchTimerOccurred_Impl(OSAction *action, uint64_t time);

    kern_return_t CreateActionInterruptOccurred(size_t, OSAction **out) { *out = new OSAction; return kIOReturnSuccess; }
    kern_return_t CreateActionLinkWatchTimerOccurred(size_t, OSAction **out) { *out = new OSAction; return kIOReturnSuccess; }

    kern_return_t StartDevice(IOUserAudioObjectID in_object_id, IOUserAudioStartStopFlags in_flags) override;
    kern_return_t StopDevice(IOUserAudioObjectID in_object_id, IOUserAudioStartStopFlags in_flags) override;

    kern_return_t SendVendorCommand(uint8_t command, uint32_t value, const uint8_t *payload, uint16_t payloadLen, uint8_t port);
    kern_return_t SendVendorCommand(uint8_t command, uint32_t value, const uint8_t *payload, uint16_t payloadLen);
    kern_return_t ReadMeterBuffer(uint32_t *outWords);
    kern_return_t ReadBoardTypes(uint8_t *outTypes, uint8_t *outValid);
    kern_return_t ReadTimingHealth(uint32_t *outWords);
    kern_return_t ReadLinkState(uint32_t *outWords);
    kern_return_t RetireForUpgrade(uint32_t replacementBuild);
    kern_return_t ReadPort2State(uint32_t *outWords);   // experiment/64ch-port2 only
    kern_return_t LoopSyncConfig(uint32_t operation, uint32_t config, uint32_t *outWords);
    kern_return_t ReadUnitBState(uint32_t *outWords);
    kern_return_t SetMonitorDevice(uint32_t unit);
    kern_return_t ReadConverterState(uint32_t *outWords);
    kern_return_t SetConverterConfig(uint32_t config);
    kern_return_t RequestPortMode(uint32_t selectorValue);   // experiment, stage 2
    kern_return_t PerformPortModeChange();                   // experiment, stage 2
    kern_return_t ReadVendorCommand(uint8_t command, uint32_t value, uint8_t *outPayload, uint16_t responseLen, uint8_t port);
    kern_return_t ReadVendorCommand(uint8_t command, uint32_t value, uint8_t *outPayload, uint16_t responseLen);
    kern_return_t RequestClockSource(uint32_t source);
    kern_return_t RequestPhantom(uint32_t channel, bool on);
    kern_return_t RequestMicGain(uint32_t channel, float decibels);
    kern_return_t RequestOpticalFormat(uint32_t board, uint32_t fmt);
};
