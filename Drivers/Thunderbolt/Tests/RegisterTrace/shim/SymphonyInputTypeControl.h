#pragma once
#include "HostDriverKit.h"
class SymphonyThunderbridge;
class SymphonyInputTypeControl : public IOUserAudioSelectorControl {
public:
    void SetDriver(SymphonyThunderbridge *) {}
    void SetChannel(uint32_t) {}
};
