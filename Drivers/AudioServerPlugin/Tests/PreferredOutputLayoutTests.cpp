// Verify the production factory contract used by CoreAudio channel mapping.
// This does not start audio I/O; live playback remains the acceptance check.
#include "../ApogeeDriver.cpp"
#include <cstdio>
#include <cstdlib>
int main() {
    auto driver = CreateDriver();
    const std::array<AudioChannelLabel, 16> expected {
        kAudioChannelLabel_Left, kAudioChannelLabel_Right,
        kAudioChannelLabel_Discrete_2, kAudioChannelLabel_Discrete_3,
        kAudioChannelLabel_Discrete_4, kAudioChannelLabel_Discrete_5,
        kAudioChannelLabel_Discrete_6, kAudioChannelLabel_Discrete_7,
        kAudioChannelLabel_Discrete_8, kAudioChannelLabel_Discrete_9,
        kAudioChannelLabel_Discrete_10, kAudioChannelLabel_Discrete_11,
        kAudioChannelLabel_Discrete_12, kAudioChannelLabel_Discrete_13,
        kAudioChannelLabel_Discrete_14, kAudioChannelLabel_Discrete_15 };
    const auto channels = sDeviceRaw->GetPreferredChannels();
    if (channels.size() != 16) return 1;
    for (size_t n = 0; n < channels.size(); ++n) {
        if (channels[n].mChannelLabel != expected[n]) return 2;
        if (channels[n].mChannelFlags != 0) return 3;
        for (float coordinate : channels[n].mCoordinates) if (coordinate != 0) return 4;
    }
    const auto stereo = sDeviceRaw->GetPreferredChannelsForStereo();
    if (stereo != std::array<UInt32, 2>{1, 2}) return 5;
    const auto bytes = sDeviceRaw->GetPreferredChannelLayout();
    const auto* layout = reinterpret_cast<const AudioChannelLayout*>(bytes.data());
    if (layout->mChannelLayoutTag != kAudioChannelLayoutTag_UseChannelDescriptions || layout->mNumberChannelDescriptions != 16) return 6;
    for (size_t n = 0; n < 16; ++n) if (layout->mChannelDescriptions[n].mChannelLabel != expected[n]) return 7;
    std::puts("PASS: actual CreateDriver exposes Left/Right plus 14 discrete channels, zero coordinates/flags, stereo [1,2], and matching preferred layout.");
    std::fflush(stdout);
    // The production factory starts process-lifetime XPC/timer callbacks.
    std::_Exit(0);
}
