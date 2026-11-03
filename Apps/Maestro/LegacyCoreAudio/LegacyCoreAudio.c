#include "include/LegacyCoreAudio.h"
#include <dlfcn.h>

// The deprecated APIs still exist in the CoreAudio binary but are unavailable from Swift.
// We load them dynamically via dlsym.

typedef OSStatus (*AudioDeviceGetPropertyInfoProc)(
    AudioDeviceID, UInt32, Boolean, AudioObjectPropertySelector, UInt32 *, Boolean *
);

typedef OSStatus (*AudioDeviceGetPropertyProc)(
    AudioDeviceID, UInt32, Boolean, AudioObjectPropertySelector, UInt32 *, void *
);

typedef OSStatus (*AudioDeviceSetPropertyProc)(
    AudioDeviceID, const AudioTimeStamp *, UInt32, Boolean, AudioObjectPropertySelector, UInt32, const void *
);

static void *getCoreAudioHandle(void) {
    static void *handle = NULL;
    if (!handle) {
        handle = dlopen("/System/Library/Frameworks/CoreAudio.framework/CoreAudio", RTLD_LAZY);
    }
    return handle;
}

OSStatus LegacyAudioDeviceGetPropertyInfo(
    AudioDeviceID inDevice,
    UInt32 inChannel,
    Boolean isInput,
    AudioObjectPropertySelector inPropertyID,
    UInt32 *outSize,
    Boolean *outWritable
) {
    void *h = getCoreAudioHandle();
    if (!h) return -1;
    AudioDeviceGetPropertyInfoProc fn = (AudioDeviceGetPropertyInfoProc)dlsym(h, "AudioDeviceGetPropertyInfo");
    if (!fn) return -1;
    return fn(inDevice, inChannel, isInput, inPropertyID, outSize, outWritable);
}

OSStatus LegacyAudioDeviceGetProperty(
    AudioDeviceID inDevice,
    UInt32 inChannel,
    Boolean isInput,
    AudioObjectPropertySelector inPropertyID,
    UInt32 *ioPropertyDataSize,
    void *outPropertyData
) {
    void *h = getCoreAudioHandle();
    if (!h) return -1;
    AudioDeviceGetPropertyProc fn = (AudioDeviceGetPropertyProc)dlsym(h, "AudioDeviceGetProperty");
    if (!fn) return -1;
    return fn(inDevice, inChannel, isInput, inPropertyID, ioPropertyDataSize, outPropertyData);
}

OSStatus LegacyAudioDeviceSetProperty(
    AudioDeviceID inDevice,
    const AudioTimeStamp *inWhen,
    UInt32 inChannel,
    Boolean isInput,
    AudioObjectPropertySelector inPropertyID,
    UInt32 inPropertyDataSize,
    const void *inPropertyData
) {
    void *h = getCoreAudioHandle();
    if (!h) return -1;
    AudioDeviceSetPropertyProc fn = (AudioDeviceSetPropertyProc)dlsym(h, "AudioDeviceSetProperty");
    if (!fn) return -1;
    return fn(inDevice, inWhen, inChannel, isInput, inPropertyID, inPropertyDataSize, inPropertyData);
}
