// SymphonyRetire.h — when the serving dext agrees to retire for an upgrade
// (kSelectorRetireForUpgrade). Kept free of DriverKit so the host test can
// compile it; SymphonyThunderbridge::RetireForUpgrade acts on the answer.
#pragma once

#include <stdint.h>

enum SymphonyRetireDecision : uint8_t {
    kSymphonyRetireTerminate = 0,      // call Terminate(0) now
    kSymphonyRetireAlreadyGoing,       // a request is pending or Stop() has begun: do nothing, report success
    kSymphonyRetireUnstamped,          // this binary has no build number: never retire
    kSymphonyRetireBadReplacement,     // replacement build is 0 or this binary's own build
};

// ownBuild: SYMPHONY_DEXT_BUILD of this binary. replacementBuild: what the app
// expects to take over (the build it carries). stopping / alreadyRequested: the
// driver's lifecycle flags at the time of the call.
static inline SymphonyRetireDecision SymphonyDecideRetire(uint32_t ownBuild,
                                                          uint32_t replacementBuild,
                                                          bool stopping,
                                                          bool alreadyRequested)
{
    if (ownBuild == 0) return kSymphonyRetireUnstamped;
    if (replacementBuild == 0 || replacementBuild == ownBuild) return kSymphonyRetireBadReplacement;
    if (stopping || alreadyRequested) return kSymphonyRetireAlreadyGoing;
    return kSymphonyRetireTerminate;
}
