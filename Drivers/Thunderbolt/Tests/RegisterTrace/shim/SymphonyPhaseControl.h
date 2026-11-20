#pragma once
#include "HostDriverKit.h"
class SymphonyThunderbridge;
class SymphonyPhaseControl : public IOUserAudioBooleanControl {
public:
    void SetDriver(SymphonyThunderbridge *) {}
    void SetChannel(uint32_t) {}
};
