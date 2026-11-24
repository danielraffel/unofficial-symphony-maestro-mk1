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
    w = monitor_key_write(MONITOR_OUTPUT_SPEAKERS, true, true);
    CHECK(w.send && w.request == 0x27 && w.nValue == 0, "speakers in Line mode: the mute key is still SpeakerMute (0x27)");
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

    /* The state file. Its first two numbers are always the speaker's, so a
       helper before version 3 reading it after a downgrade writes the
       speakers their own level and never a headphone's. */
    char text[64];
    VolumeState st = { 12, false, true, MONITOR_OUTPUT_HP2, true, 37, true };
    format_volume_state(text, sizeof(text), &st);
    CHECK(strcmp(text, "12 0 3 1 37 1 1\n") == 0, "state line: speaker first, then output, Line, the output's level");
    {
        unsigned oldAtt = 99; int oldMuted = 9;   /* what a version-2 helper reads */
        CHECK(sscanf(text, "%u %d", &oldAtt, &oldMuted) == 2 && oldAtt == 12 && oldMuted == 0,
              "an older helper reads the speaker's level from a file written with a headphone chosen");
    }
    VolumeState back;
    memset(&back, 0, sizeof(back));
    CHECK(parse_volume_state(text, &back) && back.speakerAttenuation == 12 && !back.speakerMuted && back.speakerKnown &&
          back.output == MONITOR_OUTPUT_HP2 && back.line && back.targetAttenuation == 37 && back.targetMuted,
          "state round trip");
    CHECK(parse_volume_state("12 0\n", &back) && back.speakerAttenuation == 12 && back.speakerKnown &&
          back.output == MONITOR_OUTPUT_SPEAKERS && !back.line && back.targetAttenuation == 12 && !back.targetMuted,
          "an older helper's two-number file is the speakers");
    CHECK(parse_volume_state("12 1 1 1 40 0 1\n", &back) && back.output == MONITOR_OUTPUT_SPEAKERS && back.line &&
          back.targetAttenuation == 12 && back.targetMuted, "with the speakers chosen their own level is the output's");
    CHECK(parse_volume_state("12 0 9 1\n", &back) && back.output == MONITOR_OUTPUT_SPEAKERS && !back.line,
          "an output that cannot be one is the speakers, not in Line mode");
    CHECK(parse_volume_state("12 0 2 0\n", &back) && back.output == MONITOR_OUTPUT_SPEAKERS && back.targetAttenuation == 12,
          "a headphone without its own level is not taken: the speakers");
    CHECK(parse_volume_state("12 0 2 0 70 0 1\n", &back) && back.output == MONITOR_OUTPUT_SPEAKERS,
          "a headphone level above 64 is not taken");
    CHECK(parse_volume_state("20 0 2 0 33 0 0\n", &back) && !back.speakerKnown && back.output == MONITOR_OUTPUT_HP1 &&
          back.targetAttenuation == 33, "a speaker level nobody set is marked as such");
    CHECK(!parse_volume_state("65 0 2 0 10 0 1\n", &back), "a speaker attenuation above 64 is refused");
    CHECK(!parse_volume_state("garbage", &back), "a damaged file is refused");

    /* The speaker's level is kept apart while a headphone is chosen. */
    gMonitorOutput = MONITOR_OUTPUT_SPEAKERS; gCachedAttenuation = 15; gCachedMuted = true; gHasReceivedVolume = true;
    note_target_level();
    CHECK(gSpeakerAttenuation == 15 && gSpeakerMuted && gHasSpeakerLevel, "with the speakers chosen the kept level is theirs");
    gMonitorOutput = MONITOR_OUTPUT_HP1; gCachedAttenuation = 44; gCachedMuted = false;
    note_target_level();
    CHECK(gSpeakerAttenuation == 15 && gSpeakerMuted, "a headphone's level never becomes the speaker's");
    uint8_t nine = 9, zero = 0, tooMuch = 70;
    CHECK(note_speaker_level(0x26, 0, &nine, 1) && gSpeakerAttenuation == 9, "a speaker level Maestro writes is kept");
    CHECK(note_speaker_level(0x27, 0, &zero, 1) && !gSpeakerMuted, "a speaker mute Maestro writes is kept");
    CHECK(!note_speaker_level(0x23, 0, &nine, 1) && !note_speaker_level(0x26, 1, &nine, 1) &&
          !note_speaker_level(0x26, 0, &tooMuch, 1) && gSpeakerAttenuation == 9 && gCachedAttenuation == 44,
          "nothing else is taken for the speaker level");
    gMonitorOutput = MONITOR_OUTPUT_SPEAKERS; gCachedAttenuation = 20; gCachedMuted = false; gHasReceivedVolume = false;
    gSpeakerAttenuation = 20; gSpeakerMuted = false; gHasSpeakerLevel = false;

    /* After the output changed, a volume or mute set is taken only when it is
       the new output's own value, until Maestro has set the Mac's control or
       the wait ran out. */
    uint64_t wait = 0;
    CHECK(slider_set_admitted(100, &wait, 8, 40), "nothing waited for: every set is taken");
    wait = 1000;
    CHECK(!slider_set_admitted(100, &wait, 8, 40) && wait == 1000, "the old output's louder level is not taken for the new output");
    CHECK(!slider_set_admitted(999, &wait, 39, 40) && wait == 1000, "nor one step louder");
    CHECK(slider_set_admitted(200, &wait, 41, 40) && wait == 1000, "turning down is taken at once, and the wait goes on");
    CHECK(slider_set_admitted(200, &wait, 64, 40) && wait == 1000, "down to silence too");
    /* Mute: 1 is muted. */
    CHECK(slider_set_admitted(200, &wait, 1, 0) && wait == 1000, "mute on is taken at once");
    CHECK(!slider_set_admitted(200, &wait, 0, 1) && wait == 1000, "an unmute is not");
    CHECK(slider_set_admitted(500, &wait, 40, 40) && wait == 0, "the new output's own level ends the wait");
    CHECK(slider_set_admitted(501, &wait, 8, 40), "after that a key is taken");
    wait = 1000;
    CHECK(slider_set_admitted(1000, &wait, 8, 40) && wait == 0, "the wait runs out");
    CHECK(MAESTRO_HELPER_VERSION >= 3, "the version Maestro asks for has setMonitorOutput");
}

static void test_startup_volume_window(void)
{
    gVolumeWaitUntilNs = gMuteWaitUntilNs = 0;
    gStartupVolumeWaitUntilNs = gStartupMuteWaitUntilNs = 0;
    gCachedAttenuation = 30;
    arm_startup_volume_window(1000);
    CHECK(gStartupVolumeWaitUntilNs == 1000 + STARTUP_WAIT_NS &&
          gStartupMuteWaitUntilNs == 1000 + STARTUP_WAIT_NS,
          "start-up arms both windows for five seconds");
    gVolumeWaitUntilNs = 1000 + STARTUP_WAIT_NS;
    CHECK(!slider_set_admitted(2000, &gVolumeWaitUntilNs, 10, gCachedAttenuation),
          "inside the window a louder restored volume is refused");
    CHECK(startup_volume_refusal_should_report(2000, 10),
          "a refused louder restore is reported back to the plug-in");
    CHECK(startup_volume_refusal_should_report(3000, 5),
          "a second louder restore is still refused during the start-up window");
    gCachedMuted = true;
    CHECK(startup_mute_refusal_should_report(3000, false),
          "a refused start-up unmute is reported back to the plug-in");
    CHECK(!startup_mute_refusal_should_report(3000, true),
          "a start-up mute is not reported as a refusal");
    CHECK(gStartupVolumeWaitUntilNs == 1000 + STARTUP_WAIT_NS,
          "reporting the kept volume does not end the start-up window");
    CHECK(!startup_volume_refusal_should_report(1000 + STARTUP_WAIT_NS, 5) &&
          gStartupVolumeWaitUntilNs == 0,
          "the start-up window ends when its timer expires");
    CHECK(slider_set_admitted(2000, &gVolumeWaitUntilNs, 40, gCachedAttenuation),
          "turning down is taken");
    gMuteWaitUntilNs = 1000 + STARTUP_WAIT_NS;
    CHECK(!slider_set_admitted(2000, &gMuteWaitUntilNs, 0, 1), "an unmute is refused");
    CHECK(slider_set_admitted(1000 + STARTUP_WAIT_NS, &gVolumeWaitUntilNs, 10, gCachedAttenuation),
          "after the window a louder set is taken");
    gVolumeWaitUntilNs = 9000000000ull;
    arm_startup_volume_window(1000);
    CHECK(gVolumeWaitUntilNs == 9000000000ull, "a longer wait already armed is not shortened");
    gVolumeWaitUntilNs = gMuteWaitUntilNs = 0;
    gStartupVolumeWaitUntilNs = gStartupMuteWaitUntilNs = 0;
}

static void test_power_actions(void)
{
    CHECK(power_action(kIOMessageSystemWillSleep) == POWER_LOCK, "sleep locks the unit");
    CHECK(power_action(kIOMessageSystemWillPowerOff) == POWER_LOCK, "shutdown locks the unit");
    CHECK(power_action(kIOMessageSystemWillRestart) == POWER_LOCK, "restart locks the unit");
    CHECK(power_action(kIOMessageSystemHasPoweredOn) == POWER_UNLOCK, "wake unlocks it");
    CHECK(power_action(kIOMessageCanSystemSleep) == POWER_NONE, "a sleep query does nothing");
    CHECK(power_action(kIOMessageSystemWillNotSleep) == POWER_NONE, "a cancelled sleep does nothing");
    gUSBDev = NULL; gLockedForPower = true;
    set_power_lock(true);
    CHECK(!gLockedForPower, "with no unit on USB nothing is locked");
    CHECK(power_lock_held_after(true, 0), "a lock that was written holds");
    CHECK(power_lock_held_after(true, -1), "a lock that returned an error may still have landed: unlock at wake");
    CHECK(power_lock_held_after(false, -1), "a failed unlock leaves it held, so it is retried");
    CHECK(!power_lock_held_after(false, 0), "a written unlock releases it");
}

static void test_latency_defaults_scale_with_rate(void)
{
    CHECK(default_scaled_for_rate(64, 44100.0) == 64, "44.1 kHz keeps the 48 kHz frames");
    CHECK(default_scaled_for_rate(64, 48000.0) == 64, "48 kHz as measured");
    CHECK(default_scaled_for_rate(64, 96000.0) == 128, "96 kHz doubles the frames");
    CHECK(default_scaled_for_rate(32, 192000.0) == 128, "192 kHz quadruples the helper buffer");
    CHECK(default_scaled_for_rate(50, 88200.0) == 92, "88.2 kHz scales by 1.8375");
    CHECK(default_scaled_for_rate(64, 0.0) == 64, "an unknown rate keeps the 48 kHz frames");
}

static void check_write_shadow(void)
{
    shadow_reset();
    CHECK(gRouteShadow[32] == -1 && gDigitalShadow[0][1] == -1, "nothing is known before a write");
    /* configure's direct table, one route per transfer */
    uint8_t table[DIRECT_ROUTE_COUNT][2];
    unsigned n = direct_route_table(table);
    for (unsigned i = 0; i < n; i++) shadow_note_write(0x31, 0, table[i], 2, 1);
    CHECK(gRouteShadow[32] == 192 && gRouteShadow[63] == 192 + 15, "both I/O boards on USB 1-16");
    CHECK(gRouteShadow[224] == 192 && gRouteShadow[225] == 193, "headphone 1 on USB 1-2");
    /* a two-route transfer, then one that failed */
    uint8_t pair[4] = { 32, 64, 33, 65 };
    shadow_note_write(0x31, 0, pair, 4, 1);
    CHECK(gRouteShadow[32] == 64 && gRouteShadow[33] == 65, "a batch sets each destination");
    shadow_note_write(0x31, 0, pair, 2, 0);
    CHECK(gRouteShadow[32] == -1 && gRouteShadow[33] == 65, "a failed write leaves it unknown");
    uint8_t spdif = 1;
    shadow_note_write(0x34, 1, &spdif, 1, 1);
    CHECK(gDigitalShadow[0][1] == 1 && gDigitalShadow[0][0] == -1, "optical format per board");
    shadow_note_write(0x34, 7, &spdif, 1, 1);   /* not a board: ignored */
    uint8_t level = 3;
    shadow_note_write(0x20, 0, &level, 1, 1);   /* not tracked */
    close_usb_device();
    CHECK(gRouteShadow[33] == -1 && gDigitalShadow[0][1] == -1, "a closed handle forgets it all");
    const uint64_t configures = gConfigureCount;
    CHECK(configure_fpga_routing() == -1 && gConfigureCount == configures,
          "no unit open: nothing configured, nothing counted");
}

int main(void)
{
    check_write_shadow();
    test_latency_defaults_scale_with_rate();
    test_power_actions();
    test_startup_volume_window();
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
