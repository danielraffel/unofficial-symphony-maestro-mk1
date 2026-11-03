// Opt-in hardware regression: creates audible, quiet (-36 dBFS peak) test tones.
// Measures the installed proxy's post-render peaks, not physical analog outputs.
// Does not change default device, routing, gain, rate, or persisted HAL layout.
// clang -std=c11 -fblocks LivePlaybackTests.c -framework AudioToolbox \
//   -framework CoreAudio -framework CoreFoundation -o live-playback-tests
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <xpc/xpc.h>
#include <math.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define CHANNELS 16
#define PEAK 0.015848931924611134f // -36 dBFS
#define SILENCE 0.00001f          // -100 dBFS
#define DURATION 2.0
#define PI 3.14159265358979323846
static const char *service = "com.danielraffel.Maestro.volumeproxy";
static volatile sig_atomic_t interrupted;
static AudioDeviceID device;
static double rate;
static xpc_connection_t connection;
static atomic_bool queueFinished, invalidBuffers;
static UInt64 framePosition; // Written only by the active IOProc.

static void on_signal(int signalNumber) { (void)signalNumber; interrupted = 1; }
static double seconds(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static bool status_ok(OSStatus status, const char *operation) {
    if (!status) return true;
    fprintf(stderr, "%s failed: OSStatus %d\n", operation, (int)status);
    return false;
}
static bool property(AudioObjectID object, UInt32 selector, UInt32 scope,
                     UInt32 bytes, void *out) {
    AudioObjectPropertyAddress a = {selector, scope, kAudioObjectPropertyElementMain};
    UInt32 actual = bytes;
    return status_ok(AudioObjectGetPropertyData(object, &a, 0, NULL, &actual, out),
                     "Read CoreAudio property") && actual == bytes;
}
static bool nominal_rate(double *value) {
    return property(device, kAudioDevicePropertyNominalSampleRate,
                    kAudioObjectPropertyScopeGlobal, sizeof(*value), value)
        && isfinite(*value) && *value >= 8000 && *value <= 384000;
}
static bool find_device(void) {
    CFStringRef uid = CFSTR("com.apogee.audio.symphonyio-asp:usb");
    AudioValueTranslation translation = {&uid, sizeof(uid), &device, sizeof(device)};
    if (!property(kAudioObjectSystemObject, kAudioHardwarePropertyDeviceForUID,
                  kAudioObjectPropertyScopeGlobal, sizeof(translation), &translation)
        || device == kAudioObjectUnknown) {
        fprintf(stderr, "Maestro USB UID absent; no playback.\n"); return false;
    }
    CFStringRef name = NULL;
    if (!property(device, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
                  sizeof(name), &name)) return false;
    bool match = name && CFEqual(name, CFSTR("Symphony I/O : Maestro USB"));
    if (name) CFRelease(name);
    if (!match) fprintf(stderr, "Unexpected device name for Maestro USB UID.\n");
    return match;
}
static bool preflight(void) {
    UInt32 stereo[2] = {0};
    if (!property(device, kAudioDevicePropertyPreferredChannelsForStereo,
                  kAudioObjectPropertyScopeOutput, sizeof(stereo), stereo)
        || stereo[0] != 1 || stereo[1] != 2) {
        fprintf(stderr, "Expected preferred stereo pair [1,2].\n"); return false;
    }
    AudioObjectPropertyAddress a = {kAudioDevicePropertyPreferredChannelLayout,
        kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
    UInt32 bytes = 0;
    const UInt32 expectedBytes = offsetof(AudioChannelLayout, mChannelDescriptions)
        + CHANNELS * sizeof(AudioChannelDescription);
    if (!status_ok(AudioObjectGetPropertyDataSize(device, &a, 0, NULL, &bytes),
                   "Read layout size") || bytes != expectedBytes) return false;
    AudioChannelLayout *layout = calloc(1, bytes);
    if (!layout) return false;
    bool valid = property(device, a.mSelector, a.mScope, bytes, layout);
    valid = valid && layout->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions
        && layout->mChannelBitmap == 0 && layout->mNumberChannelDescriptions == CHANNELS;
    if (valid) for (unsigned ch = 0; ch < CHANNELS; ch++) {
        AudioChannelDescription d = layout->mChannelDescriptions[ch];
        UInt32 expected = ch == 0 ? kAudioChannelLabel_Left
            : ch == 1 ? kAudioChannelLabel_Right : kAudioChannelLabel_Discrete_0 + ch;
        if (d.mChannelLabel != expected || d.mChannelFlags
            || d.mCoordinates[0] || d.mCoordinates[1] || d.mCoordinates[2]) valid = false;
    }
    free(layout);
    if (!valid) {
        fprintf(stderr, "Unexpected live channel layout. A saved HAL speaker-layout override "
                "can mask the installed driver default. Diagnose it separately; this test "
                "never changes the layout.\n"); return false;
    }
    double current = 0;
    if (!nominal_rate(&current)) return false;
    if (rate && current != rate) {
        fprintf(stderr, "Sample rate changed during the test; result invalid.\n"); return false;
    }
    if (!rate) rate = current;
    return true;
}

// Reply state lives in a copied block, not the caller's stack. A late reply after
// timeout cannot write into a dead stack frame or release an expired semaphore.
static bool read_peaks(float out[CHANNELS]) {
    typedef struct { bool valid; float levels[CHANNELS]; } Reply;
    __block Reply response = {0};
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    dispatch_retain(semaphore); // Reply owns one reference, including on timeout.
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "command", "getSoftwareMeterLevels");
    xpc_connection_send_message_with_reply(connection, message,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(xpc_object_t reply) {
            if (xpc_get_type(reply) == XPC_TYPE_DICTIONARY) {
                size_t length = 0;
                const void *data = xpc_dictionary_get_data(reply, "levels16", &length);
                if (data && length == sizeof(response.levels)) {
                    memcpy(response.levels, data, length); response.valid = true;
                }
            }
            dispatch_semaphore_signal(semaphore);
            dispatch_release(semaphore);
        });
    xpc_release(message);
    bool received = dispatch_semaphore_wait(semaphore,
        dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0;
    dispatch_release(semaphore);
    if (!received || !response.valid) {
        fprintf(stderr, "Missing/invalid proxy meter reply (2-second timeout).\n"); return false;
    }
    for (unsigned ch = 0; ch < CHANNELS; ch++) {
        if (!isfinite(response.levels[ch]) || response.levels[ch] < 0) {
            fprintf(stderr, "Invalid proxy peak on channel %u.\n", ch + 1); return false;
        }
    }
    memcpy(out, response.levels, sizeof(response.levels)); return true;
}
static bool capture(float maximum[CHANNELS], double duration) {
    double end = seconds() + duration;
    do {
        float levels[CHANNELS];
        if (interrupted || !read_peaks(levels)) return false;
        for (unsigned ch = 0; ch < CHANNELS; ch++) maximum[ch] = fmaxf(maximum[ch], levels[ch]);
        usleep(50000);
    } while (seconds() < end);
    return true;
}
static bool silent_baseline(void) {
    float discard[CHANNELS], maximum[CHANNELS] = {0};
    // Reading resets peak-hold; discard only the historical sample, then require
    // a full fresh half-second of silence before every individual playback.
    if (!read_peaks(discard) || !capture(maximum, 0.5)) return false;
    for (unsigned ch = 0; ch < CHANNELS; ch++) if (maximum[ch] > SILENCE) {
        fprintf(stderr, "Other audio active on channel %u (%.2f dBFS); no playback.\n",
                ch + 1, 20 * log10f(maximum[ch])); return false;
    }
    return true;
}
static float tone(UInt64 frame) {
    double t = frame / rate;
    double envelope = fmax(0, fmin(1, fmin(t / .020, (DURATION - t) / .020)));
    return PEAK * envelope * sin(2 * PI * 1000 * t);
}
static float expected_peak(unsigned kind, unsigned ch) {
    return kind == 16 ? PEAK * (ch + 1) / CHANNELS
        : ch >= 2 ? 0 : kind == 1 ? PEAK / sqrtf(2) : PEAK;
}
static bool peaks_match(const float actual[CHANNELS], unsigned kind) {
    if (kind != 1 && kind != 2 && kind != 16) return false;
    for (unsigned ch = 0; ch < CHANNELS; ch++) {
        float expected = expected_peak(kind, ch);
        // 2% allows sampled sine peaks and small resampler variation, while a
        // 3 dB level defect, missing channel, or wrong channel cannot pass.
        if (!isfinite(actual[ch]) || actual[ch] < 0
            || (expected ? fabsf(actual[ch] - expected) > expected * .02f : actual[ch] > SILENCE))
            return false;
    }
    return true;
}
static bool assert_peaks(const char *name, const float actual[CHANNELS], unsigned kind) {
    bool pass = peaks_match(actual, kind);
    printf("%s post-proxy dBFS:", name);
    for (unsigned ch = 0; ch < CHANNELS; ch++)
        printf(" %u=%.3f", ch + 1, actual[ch] > 0 ? 20 * log10f(actual[ch]) : -INFINITY);
    printf("\n%s: %s\n", pass ? "PASS" : "FAIL", name);
    return pass;
}
// These exercise exactly the acceptance predicate used by live playback, with
// both passing fixtures and historical regressions. They never enter CoreAudio.
static int self_test(void) {
    unsigned failures = 0, checks = 0;
    float actual[CHANNELS];
#define CHECK_RESULT(label, kind, wanted) do { \
    bool accepted = peaks_match(actual, kind); checks++; \
    if (accepted != (wanted)) { fprintf(stderr, "FAIL self-test: %s\n", label); failures++; } \
} while (0)
    const unsigned kinds[] = {1, 2, 16};
    for (unsigned k = 0; k < 3; k++) {
        for (unsigned ch = 0; ch < CHANNELS; ch++) actual[ch] = expected_peak(kinds[k], ch);
        CHECK_RESULT("expected mono/stereo/indexed peaks", kinds[k], true);
    }
    memset(actual, 0, sizeof(actual)); actual[0] = PEAK / sqrtf(2);
    CHECK_RESULT("mono only on output 1", 1, false);
    actual[0] = 0; actual[2] = PEAK;
    CHECK_RESULT("mono incorrectly on output 3", 1, false);
    memset(actual, 0, sizeof(actual)); actual[0] = actual[1] = PEAK / sqrtf(2);
    CHECK_RESULT("stereo first pair loses 3 dB", 2, false);
    for (unsigned ch = 0; ch < CHANNELS; ch++) actual[ch] = expected_peak(16, ch);
    float swap = actual[0]; actual[0] = actual[1]; actual[1] = swap;
    CHECK_RESULT("indexed channels swapped", 16, false);
    for (unsigned ch = 0; ch < CHANNELS; ch++) actual[ch] = expected_peak(2, ch);
    actual[0] = NAN; CHECK_RESULT("NaN cannot pass", 2, false);
    actual[0] = INFINITY; CHECK_RESULT("infinity cannot pass", 2, false);
    actual[0] = -PEAK; CHECK_RESULT("negative peak cannot pass", 2, false);
    actual[0] = PEAK; actual[15] = SILENCE * 2;
    CHECK_RESULT("unexpected output leakage", 2, false);
    printf("%s: %u offline live-test assertion checks; no hardware accessed.\n",
           failures ? "FAIL" : "PASS", checks);
#undef CHECK_RESULT
    return failures ? 1 : 0;
}
static void queue_complete(void *context, AudioQueueRef queue, AudioQueueBufferRef buffer) {
    (void)context; (void)queue; (void)buffer; atomic_store(&queueFinished, true);
}
static bool queue_test(unsigned channels) {
    AudioQueueRef queue = NULL;
    AudioQueueBufferRef buffer = NULL;
    bool success = false;
    atomic_store(&queueFinished, false);
    AudioStreamBasicDescription format = {0};
    format.mSampleRate = rate; format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
    format.mBytesPerPacket = format.mBytesPerFrame = channels * sizeof(float);
    format.mFramesPerPacket = 1; format.mChannelsPerFrame = channels; format.mBitsPerChannel = 32;
    if (!status_ok(AudioQueueNewOutput(&format, queue_complete, NULL, NULL, NULL, 0, &queue),
                   "Create AudioQueue")) goto cleanup;
    CFStringRef uid = CFSTR("com.apogee.audio.symphonyio-asp:usb");
    if (!status_ok(AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice,
                                         &uid, sizeof(uid)), "Select Maestro USB")) goto cleanup;
    // Explicit standard file semantics: mono Center maps to the stereo pair;
    // stereo Left/Right must remain unity. No device layout is written.
    AudioChannelLayout layout = {0};
    layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo;
    if (!status_ok(AudioQueueSetProperty(queue, kAudioQueueProperty_ChannelLayout,
                                         &layout, sizeof(layout)), "Set source channel semantics")) goto cleanup;
    UInt32 frames = (UInt32)(DURATION * rate), bytes = frames * channels * sizeof(float);
    if (!status_ok(AudioQueueAllocateBuffer(queue, bytes, &buffer), "Allocate audio")) goto cleanup;
    float *samples = buffer->mAudioData;
    for (UInt32 f = 0; f < frames; f++) for (unsigned ch = 0; ch < channels; ch++)
        samples[f * channels + ch] = tone(f);
    buffer->mAudioDataByteSize = bytes;
    if (!status_ok(AudioQueueEnqueueBuffer(queue, buffer, 0, NULL), "Enqueue audio")) goto cleanup;
    if (!preflight() || !silent_baseline() || interrupted) goto cleanup;
    if (!status_ok(AudioQueueStart(queue, NULL), "Start AudioQueue")) goto cleanup;
    float maximum[CHANNELS] = {0};
    success = capture(maximum, DURATION + .6);
    if (!atomic_load(&queueFinished)) { fprintf(stderr, "AudioQueue buffer did not complete.\n"); success = false; }
    if (success) success = preflight() && assert_peaks(channels == 1 ? "Mono to outputs 1/2" : "Stereo unity", maximum, channels);
cleanup:
    if (queue) {
        if (!status_ok(AudioQueueStop(queue, true), "Stop AudioQueue")) success = false;
        if (!status_ok(AudioQueueDispose(queue, true), "Dispose AudioQueue")) success = false;
    }
    return success;
}

static OSStatus render_indexed(AudioObjectID object, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inputTime,
    AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    (void)object; (void)now; (void)input; (void)inputTime; (void)outputTime; (void)context;
    unsigned channels = 0, frames = 0;
    if (!output) { atomic_store(&invalidBuffers, true); return noErr; }
    // Silence every buffer first: even malformed layouts must never emit garbage.
    for (unsigned b = 0; b < output->mNumberBuffers; b++)
        if (output->mBuffers[b].mData) memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
    for (unsigned b = 0; b < output->mNumberBuffers; b++) {
        AudioBuffer *buffer = &output->mBuffers[b];
        if (!buffer->mData || !buffer->mNumberChannels || buffer->mNumberChannels > CHANNELS
            || buffer->mDataByteSize % (buffer->mNumberChannels * sizeof(float))) goto invalid;
        unsigned count = buffer->mDataByteSize / (buffer->mNumberChannels * sizeof(float));
        if (b && count != frames) goto invalid;
        frames = count; channels += buffer->mNumberChannels;
    }
    if (channels != CHANNELS || !frames) goto invalid;
    unsigned base = 0;
    for (unsigned b = 0; b < output->mNumberBuffers; b++) {
        AudioBuffer *buffer = &output->mBuffers[b]; float *data = buffer->mData;
        for (unsigned f = 0; f < frames; f++) {
            float sample = tone(framePosition + f);
            for (unsigned ch = 0; ch < buffer->mNumberChannels; ch++)
                data[f * buffer->mNumberChannels + ch] = sample * (base + ch + 1) / CHANNELS;
        }
        base += buffer->mNumberChannels;
    }
    framePosition += frames; return noErr;
invalid:
    atomic_store(&invalidBuffers, true); return noErr;
}
static bool indexed_format(void) {
    AudioObjectPropertyAddress a = {kAudioDevicePropertyStreams,
        kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain};
    UInt32 bytes = 0;
    if (!status_ok(AudioObjectGetPropertyDataSize(device, &a, 0, NULL, &bytes), "Read streams")
        || !bytes || bytes > CHANNELS * sizeof(AudioStreamID) || bytes % sizeof(AudioStreamID)) return false;
    AudioStreamID streams[CHANNELS];
    if (!property(device, a.mSelector, a.mScope, bytes, streams)) return false;
    unsigned channels = 0;
    for (unsigned i = 0; i < bytes / sizeof(AudioStreamID); i++) {
        AudioStreamBasicDescription f = {0};
        if (!property(streams[i], kAudioStreamPropertyVirtualFormat, kAudioObjectPropertyScopeGlobal, sizeof(f), &f)) return false;
        unsigned sampleChannels = (f.mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 1 : f.mChannelsPerFrame;
        if (f.mFormatID != kAudioFormatLinearPCM || !(f.mFormatFlags & kAudioFormatFlagIsFloat)
            || !(f.mFormatFlags & kAudioFormatFlagIsPacked) || (f.mFormatFlags & kAudioFormatFlagIsBigEndian)
            || f.mBitsPerChannel != 32 || f.mSampleRate != rate || !f.mChannelsPerFrame
            || f.mChannelsPerFrame > CHANNELS || f.mBytesPerFrame != sampleChannels * sizeof(float)
            || f.mFramesPerPacket != 1 || f.mBytesPerPacket != f.mBytesPerFrame) {
            fprintf(stderr, "Indexed test needs native packed Float32 at the current rate.\n"); return false;
        }
        channels += f.mChannelsPerFrame;
    }
    return channels == CHANNELS;
}
static bool indexed_test(void) {
    AudioDeviceIOProcID proc = NULL;
    bool started = false, success = false;
    framePosition = 0; atomic_store(&invalidBuffers, false);
    if (!preflight() || !indexed_format()) return false;
    if (!status_ok(AudioDeviceCreateIOProcID(device, render_indexed, NULL, &proc), "Create indexed IOProc")) goto cleanup;
    if (!silent_baseline() || interrupted) goto cleanup;
    if (!status_ok(AudioDeviceStart(device, proc), "Start indexed IOProc")) goto cleanup;
    started = true;
    float maximum[CHANNELS] = {0};
    success = capture(maximum, DURATION + .6);
    if (atomic_load(&invalidBuffers)) { fprintf(stderr, "Unexpected indexed buffer format.\n"); success = false; }
    if (success) success = preflight() && assert_peaks("All 16 indexed channels", maximum, 16);
cleanup:
    if (started && !status_ok(AudioDeviceStop(device, proc), "Stop indexed IOProc")) success = false;
    if (proc && !status_ok(AudioDeviceDestroyIOProcID(device, proc), "Destroy indexed IOProc")) success = false;
    return success;
}
int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--self-test")) return self_test();
    if (argc != 2 || strcmp(argv[1], "--run-live")) {
        fprintf(stderr, "Usage: %s --self-test | --run-live | --help\n"
                "--self-test checks assertions offline. --run-live emits quiet tones on all 16 "
                "Maestro USB outputs. Stop other playback first. No device settings are changed.\n", argv[0]);
        return argc == 2 && !strcmp(argv[1], "--help") ? 0 : 2;
    }
    signal(SIGINT, on_signal); signal(SIGTERM, on_signal);
    if (!find_device() || !preflight()) return 1;
    printf("Maestro USB device=%u rate=%.0f Hz; peak=-36 dBFS; 2-second ramped tones.\n", device, rate);
    connection = xpc_connection_create_mach_service(service,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), 0);
    if (!connection) return 1;
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) { (void)event; });
    xpc_connection_resume(connection);
    bool success = queue_test(1) && queue_test(2) && indexed_test();
    xpc_connection_cancel(connection); xpc_release(connection);
    if (interrupted) { fprintf(stderr, "Interrupted; playback stopped.\n"); return 130; }
    if (success) puts("PASS: installed mono, stereo-level, and indexed-output regressions.");
    return success ? 0 : 1;
}
