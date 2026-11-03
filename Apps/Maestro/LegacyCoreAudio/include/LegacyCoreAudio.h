#ifndef LegacyCoreAudio_h
#define LegacyCoreAudio_h

#include <CoreAudio/CoreAudio.h>

/// Wrappers for deprecated CoreAudio APIs that are unavailable in Swift on macOS 26.
/// These map directly to AudioDriverPlugInDeviceGetProperty/Info in old-style HAL plugins.

OSStatus LegacyAudioDeviceGetPropertyInfo(
    AudioDeviceID inDevice,
    UInt32 inChannel,
    Boolean isInput,
    AudioObjectPropertySelector inPropertyID,
    UInt32 *outSize,
    Boolean *outWritable
);

OSStatus LegacyAudioDeviceGetProperty(
    AudioDeviceID inDevice,
    UInt32 inChannel,
    Boolean isInput,
    AudioObjectPropertySelector inPropertyID,
    UInt32 *ioPropertyDataSize,
    void *outPropertyData
);

OSStatus LegacyAudioDeviceSetProperty(
    AudioDeviceID inDevice,
    const AudioTimeStamp *inWhen,
    UInt32 inChannel,
    Boolean isInput,
    AudioObjectPropertySelector inPropertyID,
    UInt32 inPropertyDataSize,
    const void *inPropertyData
);

#endif /* LegacyCoreAudio_h */
