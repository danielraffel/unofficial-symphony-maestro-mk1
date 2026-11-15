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
                  "stereo balance scales only the selected pair without mixing other channels");
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

int main(void)
{
    check_digital_settings();
    check_reconfigure_holdoff();
    check_transport_filter();
    printf("Production startup gains: L=%.8f R=%.8f (%.5f dB)\n",
           (double)gSwReturnPanL, (double)gSwReturnPanR, 20.0 * log10(gSwReturnPanL));
    check_render(0, 1.f, 1.f);
    check_render(1, 1.f, 1.f);
    const int startupFailures = failures;
    // Positive control: the same renderer and assertions at known unity gains.
    failures = 0;
    gSwReturnPanL = gSwReturnPanR = 1.0f;
    check_render(0, 1.f, 1.f);
    check_render(1, 1.f, 1.f);
    printf("Unity control: %s (%d failures)\n", failures ? "FAIL" : "PASS", failures);
    failures += startupFailures;
    // Exercise the same setter used by XPC, including saved-state reapplication.
    const double positions[] = {-1, -0.5, 0, 0.5, 1, -2, 2, NAN};
    const float expectedL[] = {1, 1, 1, 0.70710678f, 0, 1, 0, 1};
    const float expectedR[] = {0, 0.70710678f, 1, 1, 1, 0, 1, 1};
    for (unsigned i = 0; i < sizeof(positions) / sizeof(positions[0]); ++i) {
        set_sw_return_pan(positions[i]);
        CHECK(fabsf(gSwReturnPanL - expectedL[i]) < 1e-6f, "left balance coefficient");
        CHECK(fabsf(gSwReturnPanR - expectedR[i]) < 1e-6f, "right balance coefficient");
        check_render(0, expectedL[i], expectedR[i]);
        check_render(1, expectedL[i], expectedR[i]);
    }
    float previousL = 1.f, previousR = 0.f;
    for (int step = -100; step <= 100; ++step) {
        set_sw_return_pan(step / 100.0);
        CHECK(gSwReturnPanL >= 0 && gSwReturnPanL <= 1 &&
              gSwReturnPanR >= 0 && gSwReturnPanR <= 1, "balance never boosts or inverts");
        CHECK(gSwReturnPanL <= previousL && gSwReturnPanR >= previousR, "balance sweep is monotonic");
        previousL = gSwReturnPanL; previousR = gSwReturnPanR;
    }
    set_sw_return_pan(0);
    check_render(0, 1.f, 1.f);
    check_render(1, 1.f, 1.f);
    /* The unlink path uses separate render gains and must not alter channels
       3-16 or accidentally collapse the pair back to one value. */
    gSwReturnGainL = 0.5f;
    gSwReturnGainR = 0.25f;
    check_render(0, 0.5f, 0.25f);
    check_render(1, 0.5f, 0.25f);
    gSwReturnGainL = gSwReturnGainR = 1.0f;
    printf("Proxy stereo render tests: %s (%d failures)\n", failures ? "FAIL" : "PASS", failures);
    return failures != 0;
}
