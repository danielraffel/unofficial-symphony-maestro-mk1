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

int main(void)
{
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
