/* Execute the real proxy render callback without starting its daemon or opening
   hardware. Synthetic shmem and output buffers cover both AudioUnit layouts. */
#define main maestro_proxy_daemon_main
#include "MaestroVolumeProxy.c"
#undef main
#include <assert.h>

static int failures;
#define CHECK(condition, message) do { \
    if (!(condition)) { fprintf(stderr, "FAIL: %s\n", message); ++failures; } \
} while (0)

static void check_render(int planar, float left, float right)
{
    enum { frames = 8, channels = MAESTRO_SHM_CHANNELS };
    MaestroAudioShm* shm = calloc(1, sizeof(*shm));
    assert(shm);
    float input[frames * channels];
    float output[frames * channels] = {0};
    /* Different signs and levels expose accidental mixing, channel swaps, and
       normalization, while each channel still has an exact known peak. */
    for (unsigned f = 0; f < frames; ++f)
        for (unsigned ch = 0; ch < channels; ++ch)
            input[f * channels + ch] = (f & 1 ? -1.f : 1.f) * (ch + 1) / 128.f;
    maestro_shm_write_at(shm, 0, input, frames);
    size_t bytes = offsetof(AudioBufferList, mBuffers) +
                   (planar ? channels : 1) * sizeof(AudioBuffer);
    AudioBufferList* buffers = calloc(1, bytes);
    assert(buffers);
    buffers->mNumberBuffers = planar ? channels : 1;
    for (unsigned ch = 0; ch < buffers->mNumberBuffers; ++ch) {
        buffers->mBuffers[ch].mNumberChannels = planar ? 1 : channels;
        buffers->mBuffers[ch].mDataByteSize = sizeof(float) * frames * (planar ? 1 : channels);
        buffers->mBuffers[ch].mData = planar ? output + ch * frames : output;
    }
    AudioTimeStamp timestamp = {0};
    timestamp.mFlags = kAudioTimeStampSampleTimeValid | kAudioTimeStampHostTimeValid;
    AudioUnitRenderActionFlags flags = 0;
    gSwReturnPeakL = gSwReturnPeakR = 0;
    memset(gSwPeak, 0, sizeof(gSwPeak));
    CHECK(render_callback(shm, &flags, &timestamp, 0, frames, buffers) == noErr,
          "render callback succeeds");
    for (unsigned f = 0; f < frames; ++f) {
        for (unsigned ch = 0; ch < channels; ++ch) {
            float actual = output[planar ? ch * frames + f : f * channels + ch];
            float expected = input[f * channels + ch] * (ch == 0 ? left : ch == 1 ? right : 1.f);
            CHECK(fabsf(actual - expected) < 1e-7f,
                  "only channels 1-2 are scaled, without mixing other channels");
        }
    }
    CHECK(fabsf(gSwReturnPeakL - left / 128.f) < 1e-7f &&
          fabsf(gSwReturnPeakR - 2.f * right / 128.f) < 1e-7f,
          "software output meters match rendered stereo samples");
    for (unsigned ch = 2; ch < channels; ++ch)
        CHECK(gSwPeak[ch] == (ch + 1) / 128.f, "channels 3-16 meter peaks unchanged");
    free(buffers);
    free(shm);
}

static UInt32 mock_transport;
static bool mock_transport_readable = true;

static bool mock_transport_query(AudioObjectID device, UInt32 *transportType)
{
    (void)device;
    if (!mock_transport_readable || !transportType) return false;
    *transportType = mock_transport;
    return true;
}

static void check_transport_filter(void)
{
    g_transport_query = mock_transport_query;

    mock_transport = kAudioDeviceTransportTypeUSB;
    mock_transport_readable = true;
    CHECK(device_is_usb(101), "USB transport is accepted");

    mock_transport = kAudioDeviceTransportTypeThunderbolt;
    CHECK(!device_is_usb(102), "Thunderbolt transport is rejected");

    mock_transport = kAudioDeviceTransportTypeVirtual;
    CHECK(!device_is_usb(103), "virtual transport is rejected");

    mock_transport_readable = false;
    CHECK(!device_is_usb(104), "unreadable transport is rejected closed");

    g_transport_query = query_device_transport;
}


/* A second configure of the same enumeration is skipped only inside the
   hold-off, and never for a handle that was not configured at all. */
static void check_reconfigure_holdoff(void)
{
    const uint64_t t = 1000ull * 1000000000ull;
    CHECK(!configured_recently(t, 0), "an unconfigured handle must be configured");
    CHECK(configured_recently(t + 200000000ull, t), "0.2 s after a configure is a repeat");
    CHECK(configured_recently(t + 1000000000ull, t), "1 s after a configure is a repeat");
    CHECK(!configured_recently(t + MAESTRO_RECONFIGURE_HOLDOFF_NS, t),
          "at the hold-off the unit is configured again");
    CHECK(!configured_recently(t - 1, t), "a clock that went backwards must not suppress a configure");
    gConfiguredAtNs = t;
    close_usb_device();
    CHECK(gConfiguredAtNs == 0, "closing the handle must forget the configure");
}

static void check_digital_settings(void)
{
    char path[] = "/tmp/maestro-proxy-digital-XXXXXX";
    int fd = mkstemp(path);
    assert(fd >= 0);
    close(fd);
    gDigitalStatePath = path;
    const uint8_t spdif = 1, replace = 6, mirror = 3, off = 0, bad = 9;
    /* SymphonyIOOptionBoardType: 8x8 AES 2, 8x8 Optical 3, A16 IP 4, 16x16 6. */
    enum { AES = 2, OPT = 3, AD16 = 4, ADDA16 = 6 };
    CHECK(!digital_has_replay(0) && !digital_has_replay(1),
          "first run: nothing to replay, so no board-type read");
    CHECK(note_digital_write(0x34, 1, &spdif, 1, AD16), "slot 2 S/PDIF format is remembered");
    CHECK(!note_digital_write(0x34, 1, &spdif, 1, AD16), "an unchanged value is not a change");
    CHECK(note_digital_write(0x35, 0, &replace, 1, OPT), "slot 1 Replaces is remembered");
    CHECK(note_digital_write(0x36, 1, &mirror, 1, AD16), "slot 2 Mirrors is remembered");
    CHECK(!note_digital_write(0x36, 0, &off, 1, OPT), "Mirrors Off is not a choice");
    CHECK(!note_digital_write(0x35, 0, &bad, 1, OPT), "out-of-range Replaces is ignored");
    CHECK(!note_digital_write(0x34, 0x10000, &spdif, 1, OPT), "board index must be the whole nValue");
    CHECK(!note_digital_write(0x31, 0, &spdif, 1, OPT), "other commands are not remembered");
    save_digital_state();
    for (int i = 0; i < 3; i++) gSavedDigital[i][0] = gSavedDigital[i][1] = -1;
    gSavedDigitalBoardType[0] = gSavedDigitalBoardType[1] = -1;
    load_digital_state();
    CHECK(gSavedDigital[0][0] == -1 && gSavedDigital[0][1] == 1, "format reloads per board");
    CHECK(gSavedDigital[1][0] == 6 && gSavedDigital[1][1] == -1, "Replaces reloads per board");
    CHECK(gSavedDigital[2][0] == -1 && gSavedDigital[2][1] == 3, "Mirrors reloads per board");
    CHECK(gSavedDigitalBoardType[0] == OPT && gSavedDigitalBoardType[1] == AD16,
          "the card each board's values belong to reloads");

    /* Replaces 6 is Optical 3-4 on the 8x8 it was chosen on and Analog 11-12
       on a 16x16: it goes back only on the same type of card. */
    CHECK(digital_has_replay(0) && digital_has_replay(1), "both boards have something to replay");
    CHECK(digital_replay_allowed(gSavedDigitalBoardType[0], OPT), "same card: replayed");
    CHECK(!digital_replay_allowed(gSavedDigitalBoardType[0], ADDA16), "card swapped: not replayed");
    CHECK(!digital_replay_allowed(gSavedDigitalBoardType[0], AES),
          "8x8 AES/OPT switched to AES: not replayed");
    CHECK(!digital_replay_allowed(gSavedDigitalBoardType[0], -1), "card type unreadable: not replayed");
    CHECK(!digital_replay_allowed(-1, OPT), "values with no known card: not replayed");
    /* The first write to a different card drops what the old one had. */
    CHECK(note_digital_write(0x36, 0, &mirror, 1, ADDA16), "a write to the new card is remembered");
    CHECK(gSavedDigital[1][0] == -1 && gSavedDigital[2][0] == 3 && gSavedDigitalBoardType[0] == ADDA16,
          "the old card's Replaces is forgotten, the new card's Mirrors kept");

    /* A file from before the card types were stored, or a damaged one, is
       ignored whole. */
    FILE *f = fopen(path, "w");
    assert(f);
    fputs("1 1 6 6 3 3\n", f);
    fclose(f);
    for (int i = 0; i < 3; i++) gSavedDigital[i][0] = gSavedDigital[i][1] = -1;
    gSavedDigitalBoardType[0] = gSavedDigitalBoardType[1] = -1;
    load_digital_state();
    CHECK(!digital_has_replay(0) && !digital_has_replay(1), "values without card types are not loaded");
    f = fopen(path, "w");
    assert(f);
    fputs("1 7 9 -1 0 3 3 99\n", f);
    fclose(f);
    load_digital_state();
    CHECK(gSavedDigital[0][0] == 1 && gSavedDigital[0][1] == -1, "an out-of-range format is dropped");
    CHECK(gSavedDigital[1][0] == -1 && gSavedDigital[2][0] == -1 && gSavedDigital[2][1] == 3,
          "out-of-range Replaces and Mirrors Off are dropped");
    CHECK(gSavedDigitalBoardType[0] == OPT && gSavedDigitalBoardType[1] == -1,
          "an unknown card type is dropped, so its board is never replayed");
    for (int i = 0; i < 3; i++) gSavedDigital[i][0] = gSavedDigital[i][1] = -1;
    gSavedDigitalBoardType[0] = gSavedDigitalBoardType[1] = -1;
    unlink(path);
}

static void check_optical_format_gate(void)
{
    /* SymphonyIOOptionBoardType: 0 none, 1 MicPre8, 2 AnalogAES, 3 Optical,
       4 AD16, 5 DA16, 6 ADDA16, 7 2x6; -1 = the read failed. */
    CHECK(!proxy_boot_sends_optical_format(2), "AES card: no optical format");
    for (int t = -1; t <= 7; t++)
        if (t != 2)
            CHECK(proxy_boot_sends_optical_format(t), "every other card, and a failed read, unchanged");
}

static void check_mixer_param_payload(void)
{
    const uint8_t on = 1, off = 0, odd = 7, fader = 48, pan = 64, top = 255;
    CHECK(mixer_param_payload(0xB3, &on, 1) == 1, "mute payload 1 is logged as 1");
    CHECK(mixer_param_payload(0xB3, &off, 1) == 0, "mute payload 0 is logged as 0");
    CHECK(mixer_param_payload(0xB2, &on, 1) == 1, "solo payload 1 is logged as 1");
    CHECK(mixer_param_payload(0xB2, &odd, 1) == 1, "any non-zero solo byte is on");
    CHECK(mixer_param_payload(0xB0, &fader, 1) == 48, "a fader write logs the byte sent");
    CHECK(mixer_param_payload(0xB0, &off, 1) == 0, "a fader at the bottom logs 0, not 'no value'");
    CHECK(mixer_param_payload(0xB1, &pan, 1) == 64, "a pan write logs the byte sent");
    CHECK(mixer_param_payload(0xB1, &top, 1) == 255, "the byte is logged unsigned");
    CHECK(mixer_param_payload(0xB4, &on, 1) == -1, "other requests keep the plain log line");
    CHECK(mixer_param_payload(0xAF, &on, 1) == -1, "other requests keep the plain log line");
    CHECK(mixer_param_payload(0xB3, NULL, 0) == -1, "empty mute payload is not logged as a state");
    CHECK(mixer_param_payload(0xB0, NULL, 0) == -1, "empty fader payload is not logged as a value");
}

/* What a configure leaves on the unit: every audible destination (both I/O
   boards and both headphones) on a USB playback channel, none on a mixer. */
static void check_direct_route_table(void)
{
    uint8_t table[DIRECT_ROUTE_COUNT][2];
    unsigned count = direct_route_table(table);
    CHECK(count == DIRECT_ROUTE_COUNT, "the table has every I/O board and headphone destination");
    bool seen[256] = { false };
    for (unsigned i = 0; i < count; i++) {
        seen[table[i][0]] = true;
        CHECK(!ROUTE_SRC_IS_MIXER(table[i][1]), "no destination is routed from a mixer");
        CHECK(table[i][1] >= 0xC0 && table[i][1] <= 0xCF, "every source is a USB playback channel");
    }
    for (unsigned d = 0x20; d <= 0x3F; d++) CHECK(seen[d], "every I/O board output is written");
    for (unsigned d = 224; d <= 227; d++) CHECK(seen[d], "both headphones' crosspoints are written");
    /* Headphones 1 and 2 play USB 1-2, as the firmware powers on. */
    for (unsigned i = 0; i < count; i++)
        if (table[i][0] >= 224)
            CHECK(table[i][1] == 0xC0 + (table[i][0] & 1), "a headphone plays USB 1-2, left and right");
    CHECK(ROUTE_SRC_IS_MIXER(64) && ROUTE_SRC_IS_MIXER(65) && ROUTE_SRC_IS_MIXER(96) && ROUTE_SRC_IS_MIXER(97)
          && !ROUTE_SRC_IS_MIXER(0xC0) && !ROUTE_SRC_IS_MIXER(0xEC), "the mixer outputs are 64/65 and 96/97");
    CHECK(MAESTRO_HELPER_VERSION >= 2, "the version Maestro asks for says headphones are direct after a configure");
}

/* The volume and mute keys of "Maestro USB": which vendor command and index
   each chosen output gets, the Line-mode no-op, and the kept state. */
static void check_monitor_output(void)
{
    MonitorKeyWrite w = monitor_key_write(MONITOR_OUTPUT_SPEAKERS, false, false);
    CHECK(w.send && w.request == 0x26 && w.nValue == 0, "speakers: a volume key is SpeakerVolume (0x26)");
    w = monitor_key_write(MONITOR_OUTPUT_SPEAKERS, false, true);
    CHECK(w.send && w.request == 0x27 && w.nValue == 0, "speakers: the mute key is SpeakerMute (0x27)");
    w = monitor_key_write(MONITOR_OUTPUT_HP1, false, false);
    CHECK(w.send && w.request == 0x23 && w.nValue == 0, "Headphone 1: a volume key is HeadphoneVolume (0x23) index 0");
    w = monitor_key_write(MONITOR_OUTPUT_HP1, false, true);
    CHECK(w.send && w.request == 0x24 && w.nValue == 0, "Headphone 1: the mute key is HeadphoneMute (0x24) index 0");
    w = monitor_key_write(MONITOR_OUTPUT_HP2, false, false);
    CHECK(w.send && w.request == 0x23 && w.nValue == 1, "Headphone 2: a volume key is HeadphoneVolume (0x23) index 1");
    w = monitor_key_write(MONITOR_OUTPUT_HP2, false, true);
    CHECK(w.send && w.request == 0x24 && w.nValue == 1, "Headphone 2: the mute key is HeadphoneMute (0x24) index 1");
    /* Line mode: the speakers are not moved, a chosen headphone is. */
    CHECK(!monitor_key_write(MONITOR_OUTPUT_SPEAKERS, true, false).send, "speakers in Line mode: a volume key writes nothing");
    CHECK(!monitor_key_write(MONITOR_OUTPUT_SPEAKERS, true, true).send, "speakers in Line mode: the mute key writes nothing");
    w = monitor_key_write(MONITOR_OUTPUT_HP1, true, false);
    CHECK(w.send && w.request == 0x23 && w.nValue == 0, "Headphone 1 in Line mode is still moved");
    w = monitor_key_write(MONITOR_OUTPUT_HP2, true, true);
    CHECK(w.send && w.request == 0x24 && w.nValue == 1, "Headphone 2 in Line mode is still muted");
    /* Anything else is the speakers (the default), never a headphone. */
    w = monitor_key_write(0, false, false);
    CHECK(w.send && w.request == 0x26, "an unknown output is the speakers");
    CHECK(!monitor_output_valid(0) && !monitor_output_valid(4) && monitor_output_valid(1) &&
          monitor_output_valid(2) && monitor_output_valid(3), "outputs 1-3 only");
    /* A configure or recovery puts the kept level on the chosen output; the
       speakers get theirs in Line mode too, as before. */
    w = monitor_restore_write(MONITOR_OUTPUT_SPEAKERS, false);
    CHECK(w.send && w.request == 0x26, "restore: speakers");
    w = monitor_restore_write(MONITOR_OUTPUT_HP2, true);
    CHECK(w.send && w.request == 0x24 && w.nValue == 1, "restore: Headphone 2 mute");

    /* The speaker mode Maestro writes through the helper. */
    uint8_t off = 0, stereo = 2;
    gSpeakerLineMode = false;
    CHECK(note_speaker_mode(0x25, 0, &off, 1) && gSpeakerLineMode, "speaker mode 0 is Line");
    CHECK(!note_speaker_mode(0x25, 0, &off, 1), "the same mode again changes nothing");
    CHECK(!note_speaker_mode(0x26, 0, &stereo, 1) && gSpeakerLineMode, "another command is not a speaker mode");
    CHECK(!note_speaker_mode(0x25, 0, &stereo, 0) && gSpeakerLineMode, "an empty write is not a speaker mode");
    CHECK(note_speaker_mode(0x25, 0, &stereo, 1) && !gSpeakerLineMode, "speaker mode 2 is not Line");

    /* The kept state: written with the output and Line, read back the same;
       a file from an older helper (two numbers) is the speakers. */
    char text[64];
    unsigned att = 0, output = 0; bool muted = false, line = false;
    format_volume_state(text, sizeof(text), 37, true, MONITOR_OUTPUT_HP2, true);
    CHECK(strcmp(text, "37 1 3 1\n") == 0, "state line format");
    CHECK(parse_volume_state(text, &att, &muted, &output, &line) && att == 37 && muted &&
          output == MONITOR_OUTPUT_HP2 && line, "state round trip");
    CHECK(parse_volume_state("12 0\n", &att, &muted, &output, &line) && att == 12 && !muted &&
          output == MONITOR_OUTPUT_SPEAKERS && !line, "an older helper's file is the speakers");
    CHECK(parse_volume_state("12 0 9 1\n", &att, &muted, &output, &line) && output == MONITOR_OUTPUT_SPEAKERS && !line,
          "an output that cannot be one is the speakers, not in Line mode");
    CHECK(!parse_volume_state("65 0 2 0\n", &att, &muted, &output, &line), "an attenuation above 64 is refused");
    CHECK(!parse_volume_state("garbage", &att, &muted, &output, &line), "a damaged file is refused");
    CHECK(MAESTRO_HELPER_VERSION >= 3, "the version Maestro asks for has setMonitorOutput");
}

int main(void)
{
    check_monitor_output();
    check_direct_route_table();
    check_mixer_param_payload();
    check_optical_format_gate();
    check_digital_settings();
    check_reconfigure_holdoff();
    check_transport_filter();
    /* As started: the software stage is out of the path (no mixer on USB 1-2
       feeds an output until Maestro says so), and all 16 channels pass. */
    CHECK(gSwReturnSoftwareProcessing == 0, "the software stage starts out of the path");
    check_render(0, 1.f, 1.f);
    check_render(1, 1.f, 1.f);
    /* Out of the path, neither a level nor a mute left in the helper acts:
       a direct output is never attenuated or silenced by Software Return. */
    gSwReturnGainL = 0.5f;
    gSwReturnGainR = 0.25f;
    gSwReturnMuted = 1;
    check_render(0, 1.f, 1.f);
    check_render(1, 1.f, 1.f);
    /* In the path, the mute silences channels 1-2 only and their meters. */
    gSwReturnSoftwareProcessing = 1;
    check_render(0, 0.f, 0.f);
    check_render(1, 0.f, 0.f);
    gSwReturnMuted = 0;
    /* The separate render gains must not alter channels 3-16 or collapse the
       pair back to one value. There is no balance: nothing but these scales
       channels 1-2. */
    check_render(0, 0.5f, 0.25f);
    check_render(1, 0.5f, 0.25f);
    gSwReturnGainL = gSwReturnGainR = 1.0f;
    check_render(0, 1.f, 1.f);
    check_render(1, 1.f, 1.f);
    gSwReturnSoftwareProcessing = 0;
    /* After an unplug the old handle answers "no device" while the unit that
       came back is published: that handle must be replaced, not the unit
       declared wedged or off the bus (2026-11-17 23:44). */
    CHECK(handle_is_from_before_replug(kIOReturnNoDevice, true),
          "a no-device answer with the unit published is a leftover handle");
    CHECK(!handle_is_from_before_replug(kIOReturnNoDevice, false),
          "a no-device answer with the unit gone is a unit off the bus");
    CHECK(!handle_is_from_before_replug(kIOReturnNotResponding, true),
          "a unit that does not answer on a live handle is still treated as wedged");
    CHECK(!handle_is_from_before_replug(kIOReturnSuccess, true),
          "a live handle is kept");
    printf("Proxy stereo render tests: %s (%d failures)\n", failures ? "FAIL" : "PASS", failures);
    return failures != 0;
}
