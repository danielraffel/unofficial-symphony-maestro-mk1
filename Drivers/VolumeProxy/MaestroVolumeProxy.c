/*
 * MaestroVolumeProxy — XPC bridge + audio forwarder for sandboxed AudioServerPlugin.
 *
 * The AudioServerPlugin runs in com.apple.audio.Core-Audio-Driver-Service.helper,
 * a sandboxed process that:
 *   - Cannot open UNIX domain sockets in /var/run/  (blocked)
 *   - Cannot run HAL AudioUnits targeting other devices (circular coreaudiod dependency)
 *   - CAN use XPC/Mach IPC  (explicitly allowed by sandbox)
 *
 * This daemon (running outside the sandbox) does three things:
 *   1. Accepts XPC connections from the ASP
 *   2. Forwards volume/mute → Apogee daemon UNIX socket (hardware control)
 *   3. Handles audio forwarding: allocates shared memory, sends it to the ASP,
 *      then reads audio out of that shared ring buffer via a HAL output AudioUnit
 *      targeting the real USB Symphony IO device.
 *
 * XPC protocol (ASP → proxy):
 *   { "command": "setAttenuation",    "attenuation": <uint64> }   0–64 dB
 *   { "command": "setMute",           "muted":       <bool>   }
 *   { "command": "requestAudioShmem"                           }   → proxy replies
 *
 * XPC protocol (proxy → ASP reply):
 *   { "command": "audioShmem", "shmem": <xpc_shmem> }
 *   { "command": "volumeState", "attenuation": <uint64>, "muted": <bool> }
 *
 * Audio shared memory (MaestroAudioShm — see Drivers/Shared/MaestroAudioShm.h):
 *   A clock anchor we publish from the render callback, plus a buffer INDEXED BY
 *   HARDWARE SAMPLE TIME rather than a head/tail FIFO. The plugin slaves its
 *   virtual clock to our anchor and writes each buffer at the slot its own
 *   timestamp maps to, so the added latency is a constant we choose.
 *
 * Install: /usr/local/bin/MaestroVolumeProxy  (see install.sh)
 * LaunchDaemon: com.danielraffel.Maestro.volumeproxy.plist
 */

#include <xpc/xpc.h>
#include <os/log.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <time.h>
#include <sys/stat.h>
#include <string.h>
#include <stdint.h>
#include <mach/mach_time.h>

#include "MaestroAudioShm.h"
#include <stdlib.h>
#include <signal.h>
#include <errno.h>
#include <stdatomic.h>
#include <stdio.h>
#include <math.h>
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <CoreAudio/CoreAudio.h>
#include <AudioToolbox/AudioToolbox.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOMessage.h>

/* Logging macros: write to both os_log AND stderr (→ /tmp/MaestroVolumeProxy.log).
   os_log alone doesn't appear in the log file because LaunchDaemons redirect
   stdout/stderr to the file, but os_log uses a separate logging subsystem.

   Every stderr line carries a wall-clock timestamp. os_log supplies its own, but
   the file is the copy anyone actually reads, and without a timestamp it cannot
   answer the only question that matters during a glitch report: WHEN. A 437 MB
   untimestamped log was unable to date a run of five AudioUnit rebuilds against
   anything the user did (2026-09-12) -- the events were all there and all
   useless. Timestamps are cheap; being unable to correlate is not. */

/* Wall-clock stamp for one log line, as "HH:MM:SS.mmm".
 *
 * Called from the realtime render thread (the render heartbeat below), so the
 * seconds field -- the only part that needs localtime_r, which takes a lock and
 * may touch the timezone file -- is computed once per second and reused. The
 * per-call work is then a clock_gettime and three digits of arithmetic. The
 * buffer is thread-local because the render thread and the daemon queue both
 * log, and a shared one would interleave halves of two stamps.
 */
static inline const char *log_stamp(void) {
    static _Thread_local char  buf[20];
    static _Thread_local time_t cachedSec = 0;
    static _Thread_local char  cachedHMS[9] = "00:00:00";
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    if (ts.tv_sec != cachedSec) {
        struct tm tmv;
        localtime_r(&ts.tv_sec, &tmv);
        strftime(cachedHMS, sizeof(cachedHMS), "%H:%M:%S", &tmv);
        cachedSec = ts.tv_sec;
    }
    snprintf(buf, sizeof(buf), "%s.%03d", cachedHMS, (int)(ts.tv_nsec / 1000000));
    return buf;
}

#define LOG(fmt, ...) do { \
    os_log_info(sLog, fmt, ##__VA_ARGS__); \
    fprintf(stderr, "%s [proxy] " fmt "\n", log_stamp(), ##__VA_ARGS__); \
    fflush(stderr); \
} while (0)

/* Verbose gate for recurring/periodic diagnostics (e.g. the per-render heartbeat).
   Off by default so a shipped release produces no steady-state log spam. Set the
   MAESTRO_PROXY_DEBUG environment variable (any value) to re-enable. Read once at
   startup in main() — never touched from the realtime audio render thread. */
static int sVerbose = 0;

/* Latency tuning: the IO buffer this process asks of the USB device, and the
   slack and floor of the ring delay D (maestro_shm_compute_delay_tuned). Zero
   means the built-in default. Set by "setLatencyTuning"; read when the audio
   output starts. */
static uint32_t gTuneBufferFrames = 0;
static uint32_t gTuneJitterMargin = 0;
static uint32_t gTuneMinDelay     = 0;
/* The defaults since 0.9.23: a 32-frame IO buffer on the USB device, slack 50
   and floor 64, so D = 2*32 + 14 - 64 + 50 = 64 frames (1.3 ms at 48 kHz).
   Measured with a DAW-like player at a 32-frame buffer and every core busy
   (Tools/latency-sweep.swift --player, 2026-11-22): no late write, worst
   headroom 106 frames at D = 64; with afplay's large buffer, 293. Measured on a Symphony I/O over USB at 48 kHz
   (2026-11-22, Tools/latency-sweep.swift): no late write and at least 417
   frames of headroom with every core busy; 64/64/64 also held (350). The
   reported latency of "Maestro USB" goes from 39.0 ms to 20.3 ms. Before:
   the device's own 512-frame buffer, 256 slack, 512 floor. */
#define DEFAULT_IO_BUFFER_FRAMES 32u
#define DEFAULT_JITTER_MARGIN    50u
#define DEFAULT_MIN_DELAY        64u
/* The defaults were measured at 48 kHz. Above it they are scaled with the
   rate, so the IO cycle, the slack and the floor keep the same time (64
   frames at 48 kHz, 128 at 96, 256 at 192: 1.3 ms at each). Values set
   with setLatencyTuning are used as given. */
static uint32_t default_scaled_for_rate(uint32_t frames48k, double rate)
{
    if (!(rate > 48000.0)) return frames48k;
    return (uint32_t)((double)frames48k * rate / 48000.0 + 0.5);
}
/* Worst headroom (frames the plugin had written beyond what we read) since the
   output last started or the tuning changed; negative = audio was read before
   it was written, i.e. a dropout. Written on the render thread only. */
static _Atomic int64_t gWorstHeadroom = INT64_MAX;

/* Second, louder tier: per-XPC-message tracing, off unless MAESTRO_PROXY_TRACE
 * is set. Read once at startup in main().
 *
 * Two gates rather than one because the two kinds of diagnostic differ by nearly
 * three orders of magnitude in rate, and lumping them together makes the useful
 * one unaffordable:
 *
 *   sVerbose (MAESTRO_PROXY_DEBUG)  the render heartbeat, ~1 line / 10 s.
 *                                   A health check. SHIPS ON, in the launchd
 *                                   plist, and should -- it is what identifies a
 *                                   starved ring, and it is how the AudioUnit
 *                                   rebuild storm of 2026-09-12 was read back.
 *
 *   sTrace   (MAESTRO_PROXY_TRACE)  one line per incoming XPC message, ~60 Hz
 *                                   for as long as the app's window is open.
 *                                   A trace. Ships OFF.
 *
 * Gating the 60 Hz sites behind MAESTRO_PROXY_DEBUG was therefore not a fix at
 * all: the plist sets that variable, so the firehose kept flowing on every
 * install. Errors use neither gate -- a failure that only appears when someone
 * thought to set an environment variable beforehand is a failure nobody sees.
 */
static int sTrace = 0;
#define LOG_V(fmt, ...) do { if (sTrace) { LOG(fmt, ##__VA_ARGS__); } } while (0)

#define LOG_ERR(fmt, ...) do { \
    os_log_error(sLog, fmt, ##__VA_ARGS__); \
    fprintf(stderr, "%s [proxy] ERROR: " fmt "\n", log_stamp(), ##__VA_ARGS__); \
    fflush(stderr); \
} while (0)

/* ── Constants ─────────────────────────────────────────────────────────── */

#define SOCKET_PATH  "/var/run/com.apogee.symphonyIOUSBDaemon/Socket"
#define MAGIC        0x4D4C4E4Bu  /* "MLNK" little-endian */
#define MAX_PACKET   4096u

/* MaestroLink object types */
#define OBJ_RESPONSE         2u
#define OBJ_REGISTRATION     3u
#define OBJ_GET_PROPERTY     4u
#define OBJ_SET_PROPERTY     5u
#define OBJ_PROP_CHANGED     6u

/* MaestroLink message types */
#define MSG_REGISTRATION     0x01u
#define MSG_SET_PROPERTY     0x03u
#define MSG_GET_PROPERTY     0x05u

/* Priority levels */
#define PRI_REGISTER         4u
#define PRI_SET              2u

/* Apogee property selectors (FourCC) */
#define PROP_OUTPUT_LEVEL    0x41456C33u  /* 'AEl3' */
#define PROP_OUTPUT_MUTE     0x41456D33u  /* 'AEm3' */

/* USB Symphony IO CoreAudio UID */
#define USB_DEVICE_UID \
    "AppleUSBAudioEngine:Apogee:Symphony I/O : USB Audio:2100000:1,2"

static const char kDeviceUID[] =
    "AppleUSBAudioEngine:Apogee:Symphony I/O : USB Audio:2100000:1,2";
static const char kBundleID[]  = "com.danielraffel.Maestro.volumeproxy";

/* ── Direct USB hardware control ───────────────────────────────────────── */
/*
 * On macOS 26, the Apogee daemon can't detect USB devices because usbaudiod
 * replaces AppleUSBAudio.kext and no AppleUSBAudioStream IOKit nodes exist.
 * We bypass the daemon entirely and send USB vendor EP0 commands directly.
 *
 * The Symphony IO has an FPGA routing matrix that must be configured before
 * audio reaches the DAC.  Without setAudioRoute() calls, USB audio frames
 * arrive at the XMOS controller but have no path to the DAC outputs.
 */

#define APOGEE_VID      0x0C60u
#define SYMPH_IO_PID    16u

/* Vendor command codes (from SymphonyIOVendorSpecific.h) */
#define VCMD_HEADPHONE_VOL   0x23u   /* nValue = headphone index (0 = HP1, 1 = HP2); 1 byte, attenuation in dB */
#define VCMD_HEADPHONE_MUTE  0x24u   /* nValue = headphone index; 1 byte, 0 = unmuted, 1 = muted */
#define VCMD_SPEAKER_MODE    0x25u
#define VCMD_SPEAKER_VOL     0x26u
#define VCMD_SPEAKER_MUTE    0x27u
#define VCMD_AUDIO_ROUTING   0x31u
#define VCMD_OPTICAL_FORMAT  0x34u   /* ADAT/SMUX (0) vs SPDIF (1) per IOBoard */
#define VCMD_CLOCK_MODE      0x50u
#define VCMD_RESET_ROUTING   0xC2u   /* ResetToDefaultRouting */
#define VCMD_PREF_LOAD_LOCK  0xDDu   /* PreferenceLoadLock — XMOS mute handshake */

/* Routing enums (from SymphonyIORouting.h / SymphonyIOMainFPGA.h) */
#define ROUTE_SRC_USB(n)     (0xC0u + (n))  /* eSymphonyIORoutingSource_FromP2Pch0..15 */
#define ROUTE_DST_IO0(ch)    (0x20u + (ch)) /* IOBoard0 ch0..15 (Line 1-8, ADAT 1-8); ch0/1 = DAC L/R */
#define ROUTE_DST_IO1(ch)    (0x30u + (ch)) /* IOBoard1 ch0..15 (ADAT 9-24) */
#define ROUTE_SRC_NONE       0xECu   /* Digital silence (null route) */
#define ROUTE_DST_HP(n)      (0xE0u + (n))  /* Headphone 1 L/R (224/225), Headphone 2 L/R (226/227) */
#define ROUTE_SRC_IS_MIXER(s) ((s) >= 0x40u && (s) < 0x80u) /* Mixer 1 out 64/65, Mixer 2 out 96/97 */

/* What Maestro asks with the "helperVersion" XPC command. 2: every configure
   leaves every audible destination (both I/O boards and both headphones) on a
   direct source, and no mixer strip is muted or unmuted by the helper. 3: the
   "setMonitorOutput" command (which output the volume and mute of
   "Maestro USB" move). A helper from before this constant does not answer the
   command at all, which is how Maestro recognises one. */
#define MAESTRO_HELPER_VERSION 3u

/* ── Which output the volume and mute of "Maestro USB" move ─────────────── */
/* The original's "Audio Output" choice for the keyboard volume
   (eSymphonyIO_MonitorOutput, og_source/symphonymk1/ext/SymphonyIO/generic/
   Products/SymphonyIO/SymphonyIOVendorSpecific.h:977-982): Speakers by default
   (og_source/symphonymk1/ext/maestrolink/Software/SymphonyIO.cpp:131). A
   volume set went to the chosen output's attenuation and a mute to its mute
   (SymphonyIO.cpp:2239-2276, :2345-2395); with Speakers chosen and the speaker
   mode Off (Line) the volume set was ignored (:2345-2351) and the mute still
   set the speaker mute. */
#define MONITOR_OUTPUT_SPEAKERS 1u
#define MONITOR_OUTPUT_HP1      2u
#define MONITOR_OUTPUT_HP2      3u

typedef struct {
    bool     send;      /* false: the key does nothing */
    uint8_t  request;   /* vendor command */
    uint32_t nValue;    /* headphone index for 0x23/0x24, else 0 */
} MonitorKeyWrite;

static bool monitor_output_valid(uint32_t output)
{
    return output >= MONITOR_OUTPUT_SPEAKERS && output <= MONITOR_OUTPUT_HP2;
}

/* What a volume key (mute = false) or the mute key (mute = true) writes. */
static MonitorKeyWrite monitor_key_write(uint32_t output, bool lineMode, bool mute)
{
    MonitorKeyWrite w = { false, 0, 0 };
    if (output == MONITOR_OUTPUT_HP1 || output == MONITOR_OUTPUT_HP2) {
        w.send = true;
        w.request = (uint8_t)(mute ? VCMD_HEADPHONE_MUTE : VCMD_HEADPHONE_VOL);
        w.nValue = output - MONITOR_OUTPUT_HP1;
    } else if (mute || !lineMode) {
        /* In Line mode the volume set is ignored (SymphonyIO.cpp:2345-2351);
           the mute is still the speaker's (:2239-2251 has no mode check). */
        w.send = true;
        w.request = (uint8_t)(mute ? VCMD_SPEAKER_MUTE : VCMD_SPEAKER_VOL);
    }
    return w;
}

/* What a configure or a recovery writes to put the kept level and mute back
   on the chosen output. The speakers get theirs in Line mode too, as every
   configure wrote it before there was a choice. */
static MonitorKeyWrite monitor_restore_write(uint32_t output, bool mute)
{
    return monitor_key_write(output, false, mute);
}


/* The routes every configure writes: each audible destination from a USB
   playback channel, none from a mixer.
     IOBoard0 ch0-15 and IOBoard1 ch0-15 <- USB 1-16 (see step 4 / 4b below);
     Headphone 1 and 2 <- USB 1-2, the firmware's own power-on default
     (og_source/symphonymk1/ext/SymphonyIO/Software/XMOS/SymphonyIO/src/XMOS/
     XCore/Core3/MainFPGAThread/SymphonyIOAudioRouteManager/
     SymphonyIOAudioRouteManager.cpp:389-397: "Software output 1&2 to
     headphone1 & headphone2").
   The unit keeps its routing until it is power-cycled, so a headphone an
   earlier Maestro pointed at a mixer would otherwise stay there while Maestro
   writes that mixer's strips. Maestro writes the saved headphone source after
   this, once the mixer it follows (if any) is set. */
#define DIRECT_ROUTE_COUNT 36u
static unsigned direct_route_table(uint8_t table[DIRECT_ROUTE_COUNT][2])
{
    unsigned n = 0;
    for (unsigned ch = 0; ch <= 15; ch++, n++) {
        table[n][0] = (uint8_t)ROUTE_DST_IO0(ch); table[n][1] = (uint8_t)ROUTE_SRC_USB(ch);
    }
    for (unsigned ch = 0; ch <= 15; ch++, n++) {
        table[n][0] = (uint8_t)ROUTE_DST_IO1(ch); table[n][1] = (uint8_t)ROUTE_SRC_USB(ch);
    }
    for (unsigned ch = 0; ch <= 3; ch++, n++) {
        table[n][0] = (uint8_t)ROUTE_DST_HP(ch); table[n][1] = (uint8_t)ROUTE_SRC_USB(ch & 1u);
    }
    return n;
}
static IOUSBDeviceInterface245 **gUSBDev = NULL;

static os_log_t sLog;

/* ── Volume/mute state cache ──────────────────────────────────────────── */
/* Cached so we can restore correct levels after USB recovery instead of
   falling back to configure_fpga_routing()'s hardcoded 20dB default.
   Persisted to disk so state survives proxy restarts. */
static uint8_t  gCachedAttenuation = 20;  /* safe default: -20 dB */
static bool     gCachedMuted       = false;
static bool     gHasReceivedVolume = false; /* true after first ASP setAttenuation */
/* The output the cached level and mute belong to (MONITOR_OUTPUT_*), set by
   Maestro with "setMonitorOutput", and whether the speaker mode Maestro last
   wrote is Off (Line). Both are kept with the volume. */
static uint32_t gMonitorOutput     = MONITOR_OUTPUT_SPEAKERS;
static bool     gSpeakerLineMode   = false;
/* The speaker's own level and mute, kept apart while a headphone is the
   chosen output: they stay the first two numbers of the state file, which is
   all an older helper reads (and writes to the speakers), and they are what
   a configure puts back on the speakers. gHasSpeakerLevel: they were set by a
   key, by Maestro, or read from a file; not the built-in 20 dB. */
static uint8_t  gSpeakerAttenuation = 20;
static bool     gSpeakerMuted       = false;
static bool     gHasSpeakerLevel    = false;
/* After "setMonitorOutput" the Mac's volume control still holds the level of
   the output chosen before, until Maestro has set it to the new output's.
   Until then (or until the wait runs out) a volume set louder than the new
   output's own level, or an unmute, is not kept and not sent: a key pressed
   in that moment would otherwise carry the old output's level to the new one. */
#define SLIDER_WAIT_NS (3ull * NSEC_PER_SEC)
static uint64_t gVolumeWaitUntilNs = 0;
static uint64_t gMuteWaitUntilNs   = 0;
/* The start-up guard is separate from the three-second output handoff wait.
   Apogee's first-set protection (SymphonyIO.cpp:1160-1163, :2310-2339)
   expires on its timer and must not be closed by the plug-in's echo. */
static uint64_t gStartupVolumeWaitUntilNs = 0;
static uint64_t gStartupMuteWaitUntilNs   = 0;

/* Whether a volume (or mute) set is taken. `value` and `expected` are an
   attenuation (more is quieter) or a mute (1 is muted). `waitUntil` is 0 when
   nothing is waited for; a set equal to the chosen output's own value, or the
   wait running out, ends the wait. While waiting, a change towards quiet
   (more attenuation, mute on) is still taken: it cannot make the output
   louder than it was, and a mute the user sees as on is never dropped. Only
   louder and unmute are refused. */
static bool slider_set_admitted(uint64_t nowNs, uint64_t *waitUntil, unsigned value, unsigned expected)
{
    if (*waitUntil == 0) return true;
    if (nowNs >= *waitUntil || value == expected) { *waitUntil = 0; return true; }
    return value > expected;
}

/* A refused louder start-up restore must put the ASP's virtual control back
   on the helper's kept level. */
static bool startup_volume_refusal_should_report(uint64_t nowNs, unsigned value)
{
    /* The start-up guard ends only when its timer expires. In particular, the
       plug-in's volumeState echo must not close it before a second restore. */
    if (gStartupVolumeWaitUntilNs == 0) return false;
    if (nowNs >= gStartupVolumeWaitUntilNs) {
        gStartupVolumeWaitUntilNs = 0;
        return false;
    }
    return value < gCachedAttenuation;
}

static bool startup_mute_refusal_should_report(uint64_t nowNs, bool muted)
{
    if (gStartupMuteWaitUntilNs == 0) return false;
    if (nowNs >= gStartupMuteWaitUntilNs) {
        gStartupMuteWaitUntilNs = 0;
        return false;
    }
    return !muted && gCachedMuted;
}

static void report_kept_volume(xpc_connection_t peer)
{
    xpc_object_t state = xpc_dictionary_create(NULL, NULL, 0);
    if (!state) return;
    xpc_dictionary_set_string(state, "command", "volumeState");
    xpc_dictionary_set_uint64(state, "attenuation", gCachedAttenuation);
    xpc_dictionary_set_bool(state, "muted", gCachedMuted);
    xpc_connection_send_message(peer, state);
    xpc_release(state);
}

/* After the helper puts its kept level on the unit (start-up, a replug, a
   recovery) and when the audio plug-in connects, coreaudiod may set the
   Mac's volume control from a value it saved earlier, possibly louder. The
   original dropped the first volume set after start-up in USB mode
   (SymphonyIO.cpp:1160-1163, :2310-2339). For a few seconds only a change
   towards quiet is taken, as the card driver does in its settle window. */
#define STARTUP_WAIT_NS (5ull * NSEC_PER_SEC)
static void arm_startup_volume_window(uint64_t nowNs)
{
    const uint64_t until = nowNs + STARTUP_WAIT_NS;
    if (gStartupVolumeWaitUntilNs < until) gStartupVolumeWaitUntilNs = until;
    if (gStartupMuteWaitUntilNs < until)   gStartupMuteWaitUntilNs = until;
}

/* The cached level belongs to the speakers while they are the chosen output. */
static void note_target_level(void)
{
    if (gMonitorOutput != MONITOR_OUTPUT_SPEAKERS) return;
    gSpeakerAttenuation = gCachedAttenuation;
    gSpeakerMuted = gCachedMuted;
    gHasSpeakerLevel = gHasReceivedVolume;
}

/* A speaker level or mute Maestro wrote through the helper (0x26 / 0x27, one
   byte). Returns true when the kept speaker state changed. */
static bool note_speaker_level(uint8_t bRequest, uint32_t nValue, const uint8_t *data, uint16_t len)
{
    if (nValue != 0 || !data || len < 1) return false;
    if (bRequest == VCMD_SPEAKER_VOL && data[0] <= 64) {
        if (gHasSpeakerLevel && gSpeakerAttenuation == data[0]) return false;
        gSpeakerAttenuation = data[0];
        gHasSpeakerLevel = true;
        return true;
    }
    if (bRequest == VCMD_SPEAKER_MUTE) {
        if (gSpeakerMuted == (data[0] != 0)) return false;
        gSpeakerMuted = data[0] != 0;
        return true;
    }
    return false;
}

/*
 * Where the volume survives a reboot.
 *
 * This used to be /var/run/maestro-volume-state, and /var/run does not survive a
 * reboot -- macOS 26 clears it at boot. Measured on this Mac rather than assumed:
 * with kern.boottime at 15:03:27, `ls -laT /var/run` showed every single entry
 * created at or after 15:03:27. So the file was always absent on the first launch
 * of a session, gHasReceivedVolume was false, and configure_fpga_routing()
 * programmed its hardcoded 20 dB unmuted default over whatever the user had set.
 * Every reboot silently reset the volume.
 *
 * /Library/Application Support is durable, root-writable, and the Apple-blessed
 * home for exactly this. The old path is still read once at startup so a proxy
 * upgrade mid-session does not lose the volume the user set ten seconds ago.
 */
#define VOLUME_STATE_DIR  "/Library/Application Support/Maestro"
#define VOLUME_STATE_PATH VOLUME_STATE_DIR "/volume-state"
#define VOLUME_STATE_LEGACY_PATH "/var/run/maestro-volume-state"

/* What the state file holds. */
typedef struct {
    unsigned speakerAttenuation;  /* 0-64 */
    bool     speakerMuted;
    bool     speakerKnown;        /* false: the two above are the built-in default */
    unsigned output;              /* MONITOR_OUTPUT_* */
    bool     line;                /* the speaker mode is Line */
    unsigned targetAttenuation;   /* the chosen output's level and mute */
    bool     targetMuted;
} VolumeState;

/* One line. The first two numbers are ALWAYS the speaker's attenuation and
   mute: a helper before version 3 reads only those and writes them to the
   speakers, so a headphone's level must never be there (a downgrade would
   put it on the speakers). Then, from version 3: the chosen output, whether
   the speaker mode is Line, the chosen output's attenuation and mute, and
   whether the speaker numbers are a level anyone set. */
static int format_volume_state(char *buf, size_t size, const VolumeState *st)
{
    return snprintf(buf, size, "%u %d %u %d %u %d %d\n", st->speakerAttenuation, st->speakerMuted ? 1 : 0,
                    st->output, st->line ? 1 : 0, st->targetAttenuation, st->targetMuted ? 1 : 0,
                    st->speakerKnown ? 1 : 0);
}

/* A file from an older helper has only the first two numbers: the output is
   then the speakers. A headphone without its own level is not taken either.
   Returns false for a line without a usable speaker attenuation and mute. */
static bool parse_volume_state(const char *text, VolumeState *st)
{
    unsigned a = 20, o = MONITOR_OUTPUT_SPEAKERS, t = 20;
    int m = 0, l = 0, tm = 0, known = 1;
    const int n = sscanf(text, "%u %d %u %d %u %d %d", &a, &m, &o, &l, &t, &tm, &known);
    if (n < 2 || a > 64) return false;
    st->speakerAttenuation = a;
    st->speakerMuted = m != 0;
    st->speakerKnown = n < 7 || known != 0;
    /* A choice that cannot be read is the speakers, not in Line mode. */
    bool chosen = n >= 3 && monitor_output_valid(o);
    if (chosen && o != MONITOR_OUTPUT_SPEAKERS && (n < 6 || t > 64)) chosen = false;
    st->output = chosen ? o : MONITOR_OUTPUT_SPEAKERS;
    st->line = chosen && n >= 4 && l != 0;
    const bool headphone = st->output != MONITOR_OUTPUT_SPEAKERS;
    st->targetAttenuation = headphone ? t : a;
    st->targetMuted = headphone ? tm != 0 : m != 0;
    return true;
}

/* A speaker mode write Maestro sent through the helper (0x25, one byte, 0 =
   Off, the mode the Output page calls Line). Returns true when the kept
   state changed. */
static bool note_speaker_mode(uint8_t bRequest, uint32_t nValue, const uint8_t *data, uint16_t len)
{
    if (bRequest != VCMD_SPEAKER_MODE || nValue != 0 || !data || len < 1) return false;
    const bool line = data[0] == 0;
    if (line == gSpeakerLineMode) return false;
    gSpeakerLineMode = line;
    return true;
}

/* Persist volume/mute to disk. Called on every setAttenuation/setMute. */
static void save_volume_state(void)
{
    /* Cheap and idempotent; the directory does not exist on a fresh install and
       there is no install step that would be a better place to create it. */
    mkdir(VOLUME_STATE_DIR, 0755);
    FILE *f = fopen(VOLUME_STATE_PATH, "w");
    if (!f) {
        LOG("Could not save volume state to %s: %s", VOLUME_STATE_PATH, strerror(errno));
        return;
    }
    char text[64];
    note_target_level();
    const VolumeState st = { gSpeakerAttenuation, gSpeakerMuted, gHasSpeakerLevel, gMonitorOutput,
                             gSpeakerLineMode, gCachedAttenuation, gCachedMuted };
    format_volume_state(text, sizeof(text), &st);
    fputs(text, f);
    fclose(f);
}

/* Read one state file. Returns true if it had a usable pair. */
static bool read_volume_state_file(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) return false;
    VolumeState st;
    char text[64] = "";
    bool ok = fgets(text, sizeof(text), f) != NULL && parse_volume_state(text, &st);
    fclose(f);
    if (!ok) return false;
    gSpeakerAttenuation = (uint8_t)st.speakerAttenuation;
    gSpeakerMuted = st.speakerMuted;
    gHasSpeakerLevel = st.speakerKnown;
    gMonitorOutput = st.output;
    gSpeakerLineMode = st.line;
    gCachedAttenuation = (uint8_t)st.targetAttenuation;
    gCachedMuted = st.targetMuted;
    gHasReceivedVolume = st.output != MONITOR_OUTPUT_SPEAKERS || st.speakerKnown;
    LOG("Loaded persisted volume state from %s: speaker %udB atten mute=%d, output=%u (%udB atten mute=%d), line=%d",
        path, st.speakerAttenuation, (int)st.speakerMuted, st.output, st.targetAttenuation,
        (int)st.targetMuted, (int)st.line);
    return true;
}

/* Load persisted volume/mute from disk on startup. */
static void load_volume_state(void)
{
    if (read_volume_state_file(VOLUME_STATE_PATH)) return;
    /* Pre-move file, still present for the rest of this boot. Adopt it and write
       it forward so this is the last boot that needs the fallback. */
    if (read_volume_state_file(VOLUME_STATE_LEGACY_PATH)) {
        save_volume_state();
        unlink(VOLUME_STATE_LEGACY_PATH);
    }
}

/* ── Per-board digital settings (optical format, S/PDIF Coax) ─────────── */
/*
 * Apogee's daemon kept each board's optical format, S/PDIF Coax Replaces and
 * Mirrors in its settings and applied them when the unit connected in the USB
 * mode (og_source/maestrolink/Software/SymphonyIO_IOBoard.cpp:527-566,
 * OpticalIn_SymphonyIO_Stream.cpp:387-437; SymphonyIO.cpp:1396-1412: in the
 * USB mode the computer, not the unit, holds them). The firmware starts at
 * ADAT/SMUX, Replaces Off, Mirrors Analog 1-2 (SymphonyIOStateData.cpp:127-151).
 * The proxy used to force ADAT/SMUX on both boards at every start, which threw
 * away a user's S/PDIF choice at each power cycle. It now remembers the last
 * value the app wrote for each board (0x34 / 0x35 / 0x36) and puts it back.
 *
 * Only on the type of card it was written to. Replaces and Mirrors are pair
 * numbers within one card's channels (SymphonyIOVendorSpecific.h:936-948):
 * 6 is Optical 3-4 on an 8x8 and Analog 11-12 on a 16x16. After a card swap,
 * or the 8x8 AES/OPT's DIG I/O switch moving, the remembered values are not
 * sent and the card keeps the firmware's defaults until the app writes again.
 */
#define DIGITAL_STATE_PATH VOLUME_STATE_DIR "/digital-settings"
static const char *gDigitalStatePath = DIGITAL_STATE_PATH;
/* [command 0x34, 0x35, 0x36][board]; -1 = never written. */
static int gSavedDigital[3][2] = { { -1, -1 }, { -1, -1 }, { -1, -1 } };
/* SymphonyIOOptionBoardType (0xA1) of the card each board's values were
   written to; -1 = not known. */
static int gSavedDigitalBoardType[2] = { -1, -1 };

/* Whether a board's remembered values go back on the card fitted now. */
static bool digital_replay_allowed(int savedType, int currentType)
{
    return savedType >= 0 && currentType == savedType;
}

/* Whether a board has anything remembered that differs from what the firmware
   and this proxy set anyway (ADAT/SMUX, nothing for Replaces and Mirrors). The
   board's type is read only then, so a unit that never had these set sees no
   extra control transfer. */
static bool digital_has_replay(uint32_t board)
{
    return board < 2 && (gSavedDigital[0][board] == 1 || gSavedDigital[1][board] >= 0
                         || gSavedDigital[2][board] >= 0);
}

static int digital_setting_index(uint8_t bRequest)
{
    switch (bRequest) {
    case 0x34: return 0;   /* OpticalFormat: 0 ADAT/SMUX, 1 S/PDIF */
    case 0x35: return 1;   /* SPDIFCoaxReplaceInput: 0 Off, 1-8 */
    case 0x36: return 2;   /* SPDIFCoaxMirrorOutput: 1-8 */
    default:   return -1;
    }
}

/* Record a successful vendor write. `boardType` is the type of the card on
   that board now (0xA1), -1 when it could not be read. Returns true when
   something remembered changed. */
static bool note_digital_write(uint8_t bRequest, uint32_t nValue, const uint8_t *data, uint16_t len,
                               int boardType)
{
    int idx = digital_setting_index(bRequest);
    if (idx < 0 || nValue > 1 || !data || len < 1) return false;
    int v = data[0];
    bool valid = (idx == 0) ? v <= 1 : (idx == 1) ? v <= 8 : (v >= 1 && v <= 8);
    if (!valid) return false;
    bool changed = false;
    if (gSavedDigitalBoardType[nValue] != boardType) {
        /* A different card (or one whose type is not known): what was
           remembered belonged to the other one. */
        for (int i = 0; i < 3; i++) gSavedDigital[i][nValue] = -1;
        gSavedDigitalBoardType[nValue] = boardType;
        changed = true;
    }
    if (gSavedDigital[idx][nValue] != v) {
        gSavedDigital[idx][nValue] = v;
        changed = true;
    }
    return changed;
}

static void save_digital_state(void)
{
    mkdir(VOLUME_STATE_DIR, 0755);
    FILE *f = fopen(gDigitalStatePath, "w");
    if (!f) {
        LOG("Could not save digital settings to %s: %s", gDigitalStatePath, strerror(errno));
        return;
    }
    fprintf(f, "%d %d %d %d %d %d %d %d\n", gSavedDigital[0][0], gSavedDigital[0][1],
            gSavedDigital[1][0], gSavedDigital[1][1], gSavedDigital[2][0], gSavedDigital[2][1],
            gSavedDigitalBoardType[0], gSavedDigitalBoardType[1]);
    fclose(f);
}

static void load_digital_state(void)
{
    FILE *f = fopen(gDigitalStatePath, "r");
    if (!f) return;
    int v[8];
    /* All eight or nothing: values without the card types they belong to are
       never replayed, so a short or damaged file is the same as no file. */
    if (fscanf(f, "%d %d %d %d %d %d %d %d", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5],
               &v[6], &v[7]) == 8) {
        for (int i = 0; i < 6; i++) {
            int idx = i / 2, board = i % 2;
            bool valid = v[i] == -1 ||
                ((idx == 0) ? (v[i] >= 0 && v[i] <= 1) : (idx == 1) ? (v[i] >= 0 && v[i] <= 8)
                                                                   : (v[i] >= 1 && v[i] <= 8));
            gSavedDigital[idx][board] = valid ? v[i] : -1;
        }
        for (int board = 0; board < 2; board++) {
            int type = v[6 + board];   /* SymphonyIOOptionBoardType 1-7 */
            gSavedDigitalBoardType[board] = (type >= 1 && type <= 7) ? type : -1;
        }
        LOG("Loaded digital settings: optical %d/%d, replaces %d/%d, mirrors %d/%d, card types %d/%d",
            gSavedDigital[0][0], gSavedDigital[0][1], gSavedDigital[1][0],
            gSavedDigital[1][1], gSavedDigital[2][0], gSavedDigital[2][1],
            gSavedDigitalBoardType[0], gSavedDigitalBoardType[1]);
    }
    fclose(f);
}

/* ── Audio shared buffer ────────────────────────────────────────────────── */
/*
 * Layout, semantics and the rationale for the v2 timeline-indexed design live
 * in Drivers/Shared/MaestroAudioShm.h, which the AudioServerPlugin compiles
 * too. Do not restate the layout here — that duplication is exactly what let
 * the old head/tail FIFO drift out of sync with reality.
 *
 * Our two jobs on this side:
 *   1. Publish the hardware clock anchor from the render callback, so the
 *      plugin can slave its virtual clock to the Symphony's crystal.
 *   2. Read audio from the slot our own timestamp names, and zero it behind us.
 */

/* Nominal sample rate of the real USB device, sampled when the AU is created. */
static double   gHwNominalRate = 48000.0;
/* Bumped every time the output AU is created: each one restarts the device
   sample-time origin, and the plugin must re-anchor when it changes. Starts at
   0, which the plugin reads as "never published". */
static uint32_t gClockGeneration = 0;
/* Device we have a nominal-rate listener registered on, or kAudioObjectUnknown. */
static AudioObjectID gRateListenerDev = kAudioObjectUnknown;
/* The device our AudioUnit is actually bound to. CoreAudio reassigns device IDs
   on re-enumeration, so "the Symphony" is not a stable identity -- we must
   notice when the ID behind it changes and rebind. */
static AudioObjectID gBoundDeviceID = kAudioObjectUnknown;
static void register_rate_listener(AudioObjectID devID);
static void unregister_rate_listener(void);
/* Defined below with the daemon state; the audio section needs it earlier. */
extern dispatch_queue_t gQueue;

/* ── Audio output (HAL AudioUnit → USB Symphony IO) ────────────────────── */

static MaestroAudioShm* gAudioRing = NULL;
static AudioUnit     gOutputUnit = NULL;
/* Set only by the render thread, consumed by the serial queue. */
static _Atomic int gProducerRecoveryPending = 0;
static uint64_t gLastProducerRecoveryHost = 0;
static uint64_t gLastRecoveryProducerWriteHost = 0;
static void start_audio_output(MaestroAudioShm* shm);
static void stop_audio_output(void);

static double host_ticks_per_second(void)
{
    static double cached = 0.0;
    if (cached == 0.0) {
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        cached = ((double)tb.numer / (double)tb.denom) * 1e9;
    }
    return cached;
}

/* Software return peak meters — measured in the render callback.
   Peak values (linear 0..1) are reset on each read via XPC. */
static float gSwReturnPeakL = 0.0f;
static float gSwReturnPeakR = 0.0f;
/* Per-USB-channel playback peaks for ch3-16 (index 2..15), same lifecycle as
   the L/R pair above. The FPGA routes USB ch n straight to IOBoard outputs, so
   these ARE the output levels for those channels. Needed because the firmware
   returns no output-group TDM meter data over USB EP0 (measured 2026-09-10:
   the 0x30 wValue=1 reply past byte 12 is XMOS stack residue -- see the
   METERDUMP "ECHO" flag below). */
static float gSwPeak[MAESTRO_SHM_CHANNELS];

/* Software mute for USB channels 1-2 rendered by this helper ("Maestro USB").
   It silences everything USB 1-2 feeds, a direct output included, so Maestro
   turns it on only while a mixer that takes USB 1-2 as its Software Return is
   routed to an output and every such mixer is muted (the rule lives in the
   app, USBHelperSoftwareReturn). With the default routing, where no mixer
   feeds an output, it stays off: Apogee's Software Return mute was the mixer's
   strip 32 and never touched a direct output
   (og_source/maestrolink/Software/SymphonyIOMixer.cpp:287-452). We zero
   ch 1-2 in the render callback when muted. Toggled via XPC command. */
static atomic_int gSwReturnMuted = 0;

/* Software gain for USB channels 1-2. The app now keeps this at unity: the
   unit's mixer owns the SW Return fader (0xB0). We scale samples in the
   render callback only if asked. Linear gain factor (1.0 = unity / 0dB).
   Range: 0.0 (-inf dB) to ~2.0 (+6dB). Set via XPC "setSwReturnLevel". */
static _Atomic float gSwReturnGain = 1.0f;
/* Independent L/R gains used when the stereo-link control is off. */
static _Atomic float gSwReturnGainL = 1.0f;
static _Atomic float gSwReturnGainR = 1.0f;

/* There is no Software Return balance: the original's Software Return had a
   stereo fader, solo and mute and no pan
   (og_source/maestrolink/Software/SymphonyIOMixer.cpp:262-290 pans input
   channels only), so channels 1-2 always pass centred.

   Whether the software gain/mute stage above is in the path at all. Maestro
   turns it on only while a mixer that takes USB 1-2 as its Software Return is
   routed to an output; off, channels 1-2 pass untouched like 3-16. Off until
   the app says otherwise, which is the default routing's state. */
static atomic_int gSwReturnSoftwareProcessing = 0;

/* The one-byte value of a mixer write, for the setProperty log line: the
   fader (0xB0) or pan (0xB1) byte as sent, or 0/1 for solo (0xB2) and mute
   (0xB3). -1 for every other request or an empty payload. EP0 "OK" alone does
   not say what a fader move or a click asked for. */
static int mixer_param_payload(uint8_t bReq, const uint8_t *data, uint32_t len)
{
    if (bReq < 0xB0 || bReq > 0xB3 || !data || len < 1) return -1;
    return (bReq == 0xB2 || bReq == 0xB3) ? (data[0] ? 1 : 0) : (int)data[0];
}

/* Render callback: called on the USB device's IO thread.
   Pulls interleaved 16-channel Float32 from the shared ring buffer.
   Channels 1-2 get the software gain/mute stage while Maestro has it on (a
   mixer on USB 1-2 feeds an output); otherwise they pass at unity.
   Channels 3-16 always pass through at unity. */
static OSStatus render_callback(
    void*                       inRefCon,
    AudioUnitRenderActionFlags* ioActionFlags,
    const AudioTimeStamp*       inTimeStamp,
    UInt32                      inBusNumber,
    UInt32                      inNumberFrames,
    AudioBufferList*            ioData)
{
    (void)ioActionFlags; (void)inBusNumber;

    MaestroAudioShm* shm = (MaestroAudioShm*)inRefCon;
    const uint32_t nChannels = MAESTRO_SHM_CHANNELS;
    const uint32_t totalBytes = inNumberFrames * nChannels * sizeof(float);

    /* This timestamp is the entire contract with the plugin: it says where to
       read, and it is the line the plugin slaves its virtual clock to. Publish
       it FIRST, ahead of any early return, so the plugin keeps its lock even on
       cycles we cannot service. */
    const int stampOK = (inTimeStamp->mFlags & kAudioTimeStampSampleTimeValid)
                     && (inTimeStamp->mFlags & kAudioTimeStampHostTimeValid);

    static uint64_t sRenderCount  = 0;
    static uint64_t sNonZeroCount = 0;   /* cycles where the plugin had written */
    static int64_t  sPrevLastWrite = 0;
    ++sRenderCount;

    if (shm && stampOK) {
        const double rateScalar = (inTimeStamp->mFlags & kAudioTimeStampRateScalarValid)
                                ? inTimeStamp->mRateScalar : 1.0;
        __atomic_store_n(&shm->readFrames, inNumberFrames, __ATOMIC_RELAXED);
        maestro_shm_publish_clock(shm, inTimeStamp->mSampleTime, inTimeStamp->mHostTime,
                                  rateScalar, gHwNominalRate, gClockGeneration);

        const int64_t lw = __atomic_load_n(&shm->lastWriteFrame, __ATOMIC_RELAXED);
        if (lw != sPrevLastWrite) { sNonZeroCount++; sPrevLastWrite = lw; }

        const uint64_t now = mach_absolute_time();
        const double hostHz = host_ticks_per_second();
        const int stalled = maestro_shm_producer_stalled(shm, now, hostHz);
        const int cooldown = gLastProducerRecoveryHost != 0 &&
            ((double)(now - gLastProducerRecoveryHost) / hostHz) < 2.0;
        /* A recovery itself must not become a reset loop while an app is
           paused but CoreAudio leaves I/O active. Require a new producer
           callback after each recovery before arming the next one. */
        const int newProducerActivity = maestro_shm_producer_activity_changed(
            shm, gLastRecoveryProducerWriteHost);
        if (stalled && newProducerActivity && !cooldown &&
            atomic_exchange_explicit(&gProducerRecoveryPending, 1, memory_order_acq_rel) == 0) {
            LOG("producer stall detected while I/O active — scheduling AudioUnit recovery");
            gLastProducerRecoveryHost = now;
            gLastRecoveryProducerWriteHost =
                __atomic_load_n(&shm->producerLastHostTime, __ATOMIC_ACQUIRE);
            dispatch_async(gQueue, ^{
                if (gOutputUnit && gAudioRing) {
                    LOG("producer stall recovery: rebuilding AudioUnit");
                    stop_audio_output();
                    start_audio_output(gAudioRing);
                }
                atomic_store_explicit(&gProducerRecoveryPending, 0, memory_order_release);
            });
        }
    }

    /* Periodic logging: ~1/s for the first 30 s, then every ~10 s.
       `depth` is the effective buffer depth — the plugin's write head minus our
       read point. Under the old head/tail FIFO this wandered across the entire
       32768-frame ring (0-683 ms, pegging full for over an hour at a stretch).
       It should now sit flat at ~delayFrames. If it drifts, the clock lock is
       NOT holding and that is the first thing to look at. */
    /* Track the WORST headroom over the interval, not the instantaneous depth.
       headroom = plugin's write head minus the last frame we needed this cycle.
       If it ever goes negative we read frames before they were written, which is
       precisely the failure D exists to prevent -- and the symptom is not
       silence but audio from a previous lap. `depth` alone hides this, because a
       late write still leaves a plausible-looking non-zero depth. */
    /* Reset across a hardware timeline restart. The plugin's write position is
       measured against the OLD timeline until it re-anchors, so carrying the
       tracker across the discontinuity reports an alarming number (-5956951 was
       observed on a replug) that describes nothing real. */
    static int64_t sMinHeadroom = INT64_MAX;
    static uint32_t sHeadroomGen = 0;
    if (sHeadroomGen != gClockGeneration) {
        sHeadroomGen = gClockGeneration;
        sMinHeadroom = INT64_MAX;
    }
    if (shm && stampOK) {
        const int64_t readEnd = (int64_t)llrint(inTimeStamp->mSampleTime) + (int64_t)inNumberFrames;
        const int64_t head    = __atomic_load_n(&shm->lastWriteFrame, __ATOMIC_RELAXED) - readEnd;
        if (head < sMinHeadroom) sMinHeadroom = head;
        /* Only while the plugin is writing: with nothing playing the write
           head stands still and the headroom means nothing. */
        if (head > -(int64_t)MAESTRO_SHM_RING_FRAMES / 4
            && head < atomic_load_explicit(&gWorstHeadroom, memory_order_relaxed))
            atomic_store_explicit(&gWorstHeadroom, head, memory_order_relaxed);
    }

    /* 94 render cycles is one second at 48 kHz and proportionally less above it
       -- a cadence in cycles, not seconds, now that the rate can be anything. */
    uint64_t interval = (sRenderCount <= 94u * 30u) ? 94u : 940u;
    if (sVerbose && sRenderCount % interval == 0) {
        const int64_t readFrame = stampOK ? (int64_t)llrint(inTimeStamp->mSampleTime) : 0;
        const int64_t lastWrite = shm ? __atomic_load_n(&shm->lastWriteFrame, __ATOMIC_RELAXED) : 0;
        const double  rs = (stampOK && (inTimeStamp->mFlags & kAudioTimeStampRateScalarValid))
                         ? inTimeStamp->mRateScalar : 0.0;
        LOG("render #%llu: frames=%u depth=%lld minHeadroom=%lld D=%u late=%u rateScalar=%.9f gen=%u data_cb=%llu",
            sRenderCount, inNumberFrames, (long long)(lastWrite - readFrame),
            (long long)(sMinHeadroom == INT64_MAX ? -1 : sMinHeadroom),
            shm ? __atomic_load_n(&shm->delayFrames, __ATOMIC_RELAXED) : 0u,
            shm ? __atomic_load_n(&shm->lateWrites, __ATOMIC_RELAXED) : 0u,
            rs, gClockGeneration, sNonZeroCount);
        sMinHeadroom = INT64_MAX;
    }

    /* No shmem, no usable position on the timeline, or an implausible request
       (16ch x 1024 frames x 4 bytes = 65536). Emit silence rather than guess a
       slot and splice unrelated audio into the output. */
    if (!shm || !stampOK || totalBytes > 65536u) {
        for (UInt32 i = 0; i < ioData->mNumberBuffers; i++)
            memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
        return noErr;
    }

    const int64_t readFrame = (int64_t)llrint(inTimeStamp->mSampleTime);

    if (ioData->mNumberBuffers == 1) {
        /* Interleaved output: read the slot our timestamp names */
        maestro_shm_read_at(shm, readFrame, ioData->mBuffers[0].mData, inNumberFrames);
        ioData->mBuffers[0].mDataByteSize = totalBytes;
        float* samp = (float*)ioData->mBuffers[0].mData;
        /* Software gain on channels 1-2 only, and only while processing is
           on. Channels 3-16 pass through at unity. */
        float gainL = atomic_load_explicit(&gSwReturnGainL, memory_order_relaxed);
        float gainR = atomic_load_explicit(&gSwReturnGainR, memory_order_relaxed);
        if (atomic_load_explicit(&gSwReturnSoftwareProcessing, memory_order_relaxed)) {
            for (UInt32 f = 0; f < inNumberFrames; f++) {
                samp[f * nChannels + 0] *= gainL;  /* USB ch1 */
                samp[f * nChannels + 1] *= gainR;  /* USB ch2 */
            }
        }
        /* Peak detection on ch1-2 post-gain so meters reflect actual output */
        float pkL = gSwReturnPeakL, pkR = gSwReturnPeakR;
        for (UInt32 f = 0; f < inNumberFrames; f++) {
            float aL = fabsf(samp[f * nChannels + 0]);
            float aR = fabsf(samp[f * nChannels + 1]);
            if (aL > pkL) pkL = aL;
            if (aR > pkR) pkR = aR;
        }
        gSwReturnPeakL = pkL;
        gSwReturnPeakR = pkR;
        /* Per-channel peaks for ch3-16 (direct IOBoard routes, unity). */
        for (UInt32 ch = 2; ch < nChannels; ch++) {
            float pk = gSwPeak[ch];
            for (UInt32 f = 0; f < inNumberFrames; f++) {
                float a = fabsf(samp[f * nChannels + ch]);
                if (a > pk) pk = a;
            }
            gSwPeak[ch] = pk;
        }
        /* Software mute zeros ch1-2 only, while processing is on. */
        if (atomic_load_explicit(&gSwReturnMuted, memory_order_relaxed)
            && atomic_load_explicit(&gSwReturnSoftwareProcessing, memory_order_relaxed)) {
            for (UInt32 f = 0; f < inNumberFrames; f++) {
                samp[f * nChannels + 0] = 0.0f;
                samp[f * nChannels + 1] = 0.0f;
            }
            gSwReturnPeakL = 0.0f;
            gSwReturnPeakR = 0.0f;
        }
    } else {
        /* Non-interleaved output: pop interleaved 16ch, then deinterleave */
        float tmp[16384]; /* 1024 frames × 16 ch max */
        uint32_t maxFrames = inNumberFrames < 1024u ? inNumberFrames : 1024u;
        maestro_shm_read_at(shm, readFrame, tmp, maxFrames);
        /* Software gain on ch1-2 only, while processing is on */
        float gainL = atomic_load_explicit(&gSwReturnGainL, memory_order_relaxed);
        float gainR = atomic_load_explicit(&gSwReturnGainR, memory_order_relaxed);
        if (atomic_load_explicit(&gSwReturnSoftwareProcessing, memory_order_relaxed)) {
            for (UInt32 f = 0; f < maxFrames; f++) {
                tmp[f * nChannels + 0] *= gainL;
                tmp[f * nChannels + 1] *= gainR;
            }
        }
        float pkL = gSwReturnPeakL, pkR = gSwReturnPeakR;
        for (UInt32 ch = 0; ch < ioData->mNumberBuffers && ch < nChannels; ch++) {
            float* dst = (float*)ioData->mBuffers[ch].mData;
            for (UInt32 f = 0; f < maxFrames; f++) {
                dst[f] = tmp[f * nChannels + ch];
            }
            if (ch == 0) {
                for (UInt32 f = 0; f < maxFrames; f++) {
                    float a = fabsf(dst[f]);
                    if (a > pkL) pkL = a;
                }
            } else if (ch == 1) {
                for (UInt32 f = 0; f < maxFrames; f++) {
                    float a = fabsf(dst[f]);
                    if (a > pkR) pkR = a;
                }
            } else {
                float pk = gSwPeak[ch];
                for (UInt32 f = 0; f < maxFrames; f++) {
                    float a = fabsf(dst[f]);
                    if (a > pk) pk = a;
                }
                gSwPeak[ch] = pk;
            }
            ioData->mBuffers[ch].mDataByteSize = maxFrames * sizeof(float);
        }
        /* Zero any extra buffers beyond our channel count */
        for (UInt32 ch = nChannels; ch < ioData->mNumberBuffers; ch++) {
            memset(ioData->mBuffers[ch].mData, 0, ioData->mBuffers[ch].mDataByteSize);
        }
        gSwReturnPeakL = pkL;
        gSwReturnPeakR = pkR;
        /* Software mute ch1-2 */
        if (atomic_load_explicit(&gSwReturnMuted, memory_order_relaxed)
            && atomic_load_explicit(&gSwReturnSoftwareProcessing, memory_order_relaxed)) {
            for (UInt32 ch = 0; ch < ioData->mNumberBuffers && ch < 2; ch++)
                memset(ioData->mBuffers[ch].mData, 0, ioData->mBuffers[ch].mDataByteSize);
            gSwReturnPeakL = 0.0f;
            gSwReturnPeakR = 0.0f;
        }
    }
    return noErr;
}

typedef bool (*MaestroTransportQuery)(AudioObjectID device, UInt32 *transportType);

static bool query_device_transport(AudioObjectID device, UInt32 *transportType);
static MaestroTransportQuery g_transport_query = query_device_transport;

static bool query_device_transport(AudioObjectID device, UInt32 *transportType)
{
    if (!transportType) return false;
    AudioObjectPropertyAddress prop = {
        kAudioDevicePropertyTransportType,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = sizeof(*transportType);
    return AudioObjectGetPropertyData(device, &prop, 0, NULL, &size, transportType) == noErr &&
           size == sizeof(*transportType);
}

static bool device_is_usb(AudioObjectID device)
{
    UInt32 transportType = 0;
    return g_transport_query(device, &transportType) &&
           transportType == kAudioDeviceTransportTypeUSB;
}

/* Find the USB Symphony IO CoreAudio device by UID (exact match). */
static AudioObjectID find_usb_device_by_uid(void)
{
    CFStringRef uid = CFStringCreateWithCString(
        NULL, USB_DEVICE_UID, kCFStringEncodingUTF8);
    AudioObjectID devID = kAudioObjectUnknown;
    AudioValueTranslation xlat = { &uid, sizeof(uid), &devID, sizeof(devID) };
    UInt32 xsz = sizeof(xlat);
    AudioObjectPropertyAddress prop = {
        kAudioHardwarePropertyDeviceForUID,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &prop, 0, NULL, &xsz, &xlat);
    CFRelease(uid);
    return devID != kAudioObjectUnknown && device_is_usb(devID)
        ? devID : kAudioObjectUnknown;
}

/* Fallback: find by device name containing "Symphony I/O" but not "Maestro"
   (our virtual device is "Symphony I/O : Maestro"). Handles UID changes across
   reboots or USB topology changes. */
static AudioObjectID find_usb_device_by_name(void)
{
    AudioObjectPropertyAddress devsProp = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 dataSize = 0;
    OSStatus err = AudioObjectGetPropertyDataSize(
        kAudioObjectSystemObject, &devsProp, 0, NULL, &dataSize);
    if (err != noErr || dataSize == 0) return kAudioObjectUnknown;

    UInt32 count = dataSize / sizeof(AudioObjectID);
    AudioObjectID *devices = (AudioObjectID *)malloc(dataSize);
    if (!devices) return kAudioObjectUnknown;

    err = AudioObjectGetPropertyData(
        kAudioObjectSystemObject, &devsProp, 0, NULL, &dataSize, devices);
    if (err != noErr) { free(devices); return kAudioObjectUnknown; }

    AudioObjectPropertyAddress nameProp = {
        kAudioObjectPropertyName,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectID found = kAudioObjectUnknown;
    for (UInt32 i = 0; i < count; i++) {
        CFStringRef name = NULL;
        UInt32 nameSize = sizeof(name);
        err = AudioObjectGetPropertyData(devices[i], &nameProp, 0, NULL, &nameSize, &name);
        if (err != noErr || !name) continue;

        /* Match "Symphony I/O" but exclude our virtual device ("Maestro") and
           require the actual USB transport. A ThunderBridge can share the name. */
        if (CFStringFind(name, CFSTR("Symphony I/O"), 0).location != kCFNotFound &&
            CFStringFind(name, CFSTR("Maestro"), 0).location == kCFNotFound &&
            device_is_usb(devices[i])) {
            found = devices[i];
            CFRelease(name);
            break;
        }
        CFRelease(name);
    }
    free(devices);
    return found;
}

/* Find USB Symphony IO — tries exact UID first, then name-based fallback. */
/// Resolve the real Symphony's CoreAudio device, port-independently.
///
/// NAME FIRST, deliberately. USB_DEVICE_UID embeds a USB *location ID* -- the
/// physical port the device happened to be plugged into on one particular Mac
/// (2100000 here). Move the cable and it becomes something else entirely
/// (1130000), and on anyone else's machine it never matches at all. Preferring
/// it meant the primary path was effectively dead code everywhere except one
/// port on one Mac, and when it went stale the AudioUnit silently bound to
/// whatever device CoreAudio defaulted to -- audio came out the Mac's built-in
/// speakers with everything else looking healthy.
///
/// The name match has no such dependency and already excludes our own virtual
/// device. The UID is kept only as a fallback for the case where the name has
/// been changed but the device sits on the original port.
///
/// NEVER cache the result across a device-list change: IDs are reassigned on
/// re-enumeration, and a stale ID is exactly the failure above.
static AudioObjectID find_usb_device(void)
{
    AudioObjectID devID = find_usb_device_by_name();
    if (devID != kAudioObjectUnknown) return devID;
    return find_usb_device_by_uid();
}

/* Create and start a HAL output AudioUnit targeting the USB device. */
static void start_audio_output(MaestroAudioShm* shm)
{
    AudioObjectID devID = find_usb_device();
    if (devID == kAudioObjectUnknown) {
        LOG("start_audio_output: USB device not yet available — listener will retry");
        return;
    }
    LOG("start_audio_output: USB device ID=%u", devID);
    gBoundDeviceID = devID;

    AudioComponentDescription desc = {
        .componentType         = kAudioUnitType_Output,
        .componentSubType      = kAudioUnitSubType_HALOutput,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentFlags        = 0,
        .componentFlagsMask    = 0
    };
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    if (!comp) { LOG_ERR("HAL output AudioComponent not found"); return; }

    OSStatus err = AudioComponentInstanceNew(comp, &gOutputUnit);
    if (err) { LOG_ERR("AudioComponentInstanceNew %d", (int)err); return; }

    /* Enable output bus 0, disable input capture */
    UInt32 one = 1, zero = 0;
    AudioUnitSetProperty(gOutputUnit, kAudioOutputUnitProperty_EnableIO,
                         kAudioUnitScope_Output, 0, &one,  sizeof(one));
    AudioUnitSetProperty(gOutputUnit, kAudioOutputUnitProperty_EnableIO,
                         kAudioUnitScope_Input,  1, &zero, sizeof(zero));

    /* Target USB device */
    err = AudioUnitSetProperty(gOutputUnit, kAudioOutputUnitProperty_CurrentDevice,
                               kAudioUnitScope_Global, 0, &devID, sizeof(devID));
    if (err) {
        LOG_ERR("Set CurrentDevice failed %d", (int)err);
        AudioComponentInstanceDispose(gOutputUnit); gOutputUnit = NULL; return;
    }

    /* Read the device's real nominal rate FIRST: everything below is derived from
       it. This used to run after a block that forced the device to 48 kHz,
       because the plugin was a 48 kHz-only device and the shared ring is indexed
       in HARDWARE frames -- one of our frames has to be one of the device's
       slots. The plugin now follows the rate instead (see MAESTRO_SHM_VERSION 4),
       so there is nothing left to coerce, and forcing the rate here would fight
       the very picker in Maestro that sets it.

       Nothing is programmed into the hardware here. The rate over USB belongs to
       UAC2 -- Apogee's own daemon sent no rate command in USB Audio mode, it just
       set m_fDisableRateCheck (og_source/maestrolink/Software/SymphonyIO.cpp:
       1897-1902) -- so this is purely a read. No optical/ADAT state is touched:
       only init_usb_hardware/configure_fpga_routing program the optical format
       and the IOBoard crosspoints, and the rate path never calls either. */
    {
        Float64 devRate = 0.0;
        UInt32  sz      = (UInt32)sizeof(devRate);
        AudioObjectPropertyAddress addr = {
            kAudioDevicePropertyNominalSampleRate,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        if (AudioObjectGetPropertyData(devID, &addr, 0, NULL, &sz, &devRate) != noErr
            || !(devRate > 0.0)) {
            /* Do NOT guess. Under v3 a wrong guess was harmless because the rate
               was pinned anyway; now it is published, and the plugin believes it.
               Guessing 48000 on a 96 kHz device would bind AUHAL at 48 k (so it
               resamples), tell the plugin the hardware is at 48 k (so it follows
               to the wrong rate), and then advance hwSampleTime at 96 k against a
               48 k slope -- which trips the discontinuity guard every tick
               (Drivers/Shared/MaestroClockSlave.h:170-176) and re-anchors forever.
               Leaving with no AudioUnit is the better failure: the reconcile timer
               retries every 2 s, and until then the plugin sees a stale anchor and
               flywheels, which is the case it is built for. */
            /* Tear the AudioUnit down on the way out. gOutputUnit is already
               non-NULL and already bound to the right device, and reconcile only
               starts audio when gOutputUnit is NULL -- so leaving it behind would
               convince reconcile that everything is fine while nothing was ever
               started, and the rate listener below never gets registered either.
               Silent until a replug, which is worse than the guess this replaced. */
            LOG_ERR("Could not read device nominal rate — not starting audio, "
                    "reconcile will retry");
            AudioComponentInstanceDispose(gOutputUnit);
            gOutputUnit    = NULL;
            gBoundDeviceID = kAudioObjectUnknown;
            return;
        }
        gHwNominalRate = devRate;
    }

    /* Interleaved Float32 16-channel on the input bus (what our callback provides),
       at the DEVICE's rate -- not a pinned 48 kHz. Matching it is what makes AUHAL
       pass frames through instead of resampling, and pass-through is the premise of
       the slot indexing: the ring is named in hardware frames, so one frame in must
       be one slot. 16 channels match the USB device's 16 output channels and the
       ASP's stream format. */
    AudioStreamBasicDescription fmt = {
        .mSampleRate       = gHwNominalRate,
        .mFormatID         = kAudioFormatLinearPCM,
        .mFormatFlags      = kAudioFormatFlagsNativeFloatPacked,
        .mBitsPerChannel   = 32,
        .mChannelsPerFrame = 16,
        .mBytesPerFrame    = 16 * (UInt32)sizeof(float),
        .mFramesPerPacket  = 1,
        .mBytesPerPacket   = 16 * (UInt32)sizeof(float)
    };
    err = AudioUnitSetProperty(gOutputUnit, kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Input, 0, &fmt, sizeof(fmt));
    if (err) {
        LOG_ERR("Set client StreamFormat at %.0f Hz failed %d — AUHAL will resample "
                "and the slot indexing will not hold", gHwNominalRate, (int)err);
    }

    /* Compute the presentation delay D from this device's actual geometry.
       A fixed constant cannot be correct: D must cover 2*N_proxy + S_usb minus
       what the plugin guarantees to have written, and N_proxy/S_usb belong to
       the USB device and are only visible from this process. See the derivation
       in MaestroAudioShm.h. */
    {
        UInt32 bufFrames = 512, safety = 0, sz;
        AudioObjectPropertyAddress a = {
            kAudioDevicePropertyBufferFrameSize,
            kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain
        };
        /* This process's IO buffer on the USB device: the IO buffer size is
           kept per process, so other apps playing to the device keep theirs.
           A smaller buffer is what lets D (the latency this bridge adds) be
           smaller, since D must cover two of our buffers. */
        {
            AudioValueRange range = { 0, 0 };
            AudioObjectPropertyAddress r = {
                kAudioDevicePropertyBufferFrameSizeRange,
                kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
            };
            UInt32 rsz = (UInt32)sizeof(range);
            UInt32 want = gTuneBufferFrames ? gTuneBufferFrames : default_scaled_for_rate(DEFAULT_IO_BUFFER_FRAMES, gHwNominalRate);
            if (AudioObjectGetPropertyData(devID, &r, 0, NULL, &rsz, &range) == noErr && range.mMaximum > 0) {
                if (want < (UInt32)range.mMinimum) want = (UInt32)range.mMinimum;
                if (want > (UInt32)range.mMaximum) want = (UInt32)range.mMaximum;
            }
            AudioObjectPropertyAddress g = a;
            g.mScope = kAudioObjectPropertyScopeGlobal;
            OSStatus serr = AudioObjectSetPropertyData(devID, &g, 0, NULL, (UInt32)sizeof(want), &want);
            if (serr) LOG_ERR("Set IO buffer %u frames failed %d", want, (int)serr);
        }
        sz = (UInt32)sizeof(bufFrames);
        if (AudioObjectGetPropertyData(devID, &a, 0, NULL, &sz, &bufFrames) != noErr || !bufFrames)
            bufFrames = 512;
        a.mSelector = kAudioDevicePropertySafetyOffset;
        sz = (UInt32)sizeof(safety);
        if (AudioObjectGetPropertyData(devID, &a, 0, NULL, &sz, &safety) != noErr)
            safety = 0;

        uint32_t D = maestro_shm_compute_delay_tuned(bufFrames, safety,
            gTuneJitterMargin ? gTuneJitterMargin : default_scaled_for_rate(DEFAULT_JITTER_MARGIN, gHwNominalRate),
            gTuneMinDelay ? gTuneMinDelay : default_scaled_for_rate(DEFAULT_MIN_DELAY, gHwNominalRate));
        if (D >= MAESTRO_SHM_RING_FRAMES / 2)
            LOG_ERR("D clamped at %u — device buffer %u is too large for the ring", D, bufFrames);
        if (shm) {
            /* Order matters. Bump the generation and park a deliberately stale
               anchor BEFORE clearing, so the plugin stops writing immediately.
               Otherwise it is still anchored to the OLD mapping (we are well
               inside the 250 ms staleness window) and keeps depositing buffers
               at old-mapping slots into the ring we just wiped -- which the new
               sweep then plays. hwHostTime = 0 fails the staleness check, so the
               plugin flywheels until the first real publish. */
            gClockGeneration++;
            maestro_shm_publish_clock(shm, 0.0, 0, 1.0, gHwNominalRate, gClockGeneration);

            __atomic_store_n(&shm->delayFrames, D, __ATOMIC_RELEASE);
            memset(shm->buf, 0, MAESTRO_SHM_RING_BYTES);
            __atomic_store_n(&shm->lateWrites, 0u, __ATOMIC_RELAXED);
        }
        atomic_store_explicit(&gWorstHeadroom, INT64_MAX, memory_order_relaxed);
        LOG("Presentation delay D=%u frames (%.1f ms) from device buffer=%u safety=%u margin=%u floor=%u",
            D, (double)D * 1000.0 / gHwNominalRate, bufFrames, safety, gTuneJitterMargin, gTuneMinDelay);
    }

    /* Watch for a nominal-rate change. gHwNominalRate is sampled once, here, and
       the plugin's slot arithmetic only holds while our rate matches its own --
       so a rate change we do not notice means permanent silence, not a glitch. */
    register_rate_listener(devID);

    LOG("Audio clock generation %u (device nominal rate %.1f Hz)",
        gClockGeneration, gHwNominalRate);

    /* Render callback reads the slot named by the hardware timestamp */
    AURenderCallbackStruct cb = { render_callback, shm };
    AudioUnitSetProperty(gOutputUnit, kAudioUnitProperty_SetRenderCallback,
                         kAudioUnitScope_Input, 0, &cb, sizeof(cb));

    err = AudioUnitInitialize(gOutputUnit);
    if (err) {
        LOG_ERR("AudioUnitInitialize %d", (int)err);
        AudioComponentInstanceDispose(gOutputUnit); gOutputUnit = NULL; return;
    }

    err = AudioOutputUnitStart(gOutputUnit);
    if (err) {
        LOG_ERR("AudioOutputUnitStart %d", (int)err);
        AudioComponentInstanceDispose(gOutputUnit); gOutputUnit = NULL; return;
    }

    /* Check if the USB device is actually streaming */
    UInt32 isRunning = 0;
    UInt32 runSz = sizeof(isRunning);
    AudioObjectPropertyAddress runProp = {
        kAudioDevicePropertyDeviceIsRunning,
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    AudioObjectGetPropertyData(devID, &runProp, 0, NULL, &runSz, &isRunning);

    LOG("Audio output STARTED → USB device %u (interleaved 16ch f32 %.0f Hz, running=%u)",
        devID, gHwNominalRate, isRunning);
}

/* Stop and dispose the HAL output AudioUnit.

   Says nothing about WHY, because this function cannot know and four of its five
   callers are not a removal: a sample-rate change rebuilding the unit, the device
   id changing, the reconcile timer's rebuild, and resetAudioOutput over XPC all
   come through here, and every caller already logs its own reason on the line
   before. Claiming "USB device removed or unavailable" on a routine rate change
   sent whoever read this log looking for a cable fault. */
static void stop_audio_output(void)
{
    if (!gOutputUnit) return;
    AudioOutputUnitStop(gOutputUnit);
    AudioComponentInstanceDispose(gOutputUnit);
    gOutputUnit = NULL;
    LOG("Audio output STOPPED");
}

/* The USB device's nominal sample rate changed under us.
   Tear the AudioUnit down and rebuild it: that re-reads gHwNominalRate, bumps
   the clock generation so the plugin re-anchors instead of extrapolating across
   the discontinuity, recomputes D, and clears the ring. Doing nothing here
   leaves a stale rate, which the plugin correctly refuses to map -- silence
   until something else happens to restart us. */
static OSStatus rate_changed_callback(
    AudioObjectID                     inObjectID,
    UInt32                            inNumberAddresses,
    const AudioObjectPropertyAddress* inAddresses,
    void*                             inClientData)
{
    (void)inObjectID; (void)inNumberAddresses; (void)inAddresses; (void)inClientData;
    dispatch_async(gQueue, ^{
        if (!gOutputUnit || !gAudioRing) return;
        LOG("USB device nominal rate changed — rebuilding AudioUnit");
        stop_audio_output();
        start_audio_output(gAudioRing);
    });
    return noErr;
}

static void register_rate_listener(AudioObjectID devID)
{
    if (gRateListenerDev == devID) return;
    unregister_rate_listener();

    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    if (AudioObjectAddPropertyListener(devID, &addr, rate_changed_callback, NULL) == noErr) {
        gRateListenerDev = devID;
        LOG("Registered nominal-rate listener on device %u", devID);
    } else {
        LOG_ERR("Could not register nominal-rate listener on device %u", devID);
    }
}

static void unregister_rate_listener(void)
{
    if (gRateListenerDev == kAudioObjectUnknown) return;
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectRemovePropertyListener(gRateListenerDev, &addr, rate_changed_callback, NULL);
    gRateListenerDev = kAudioObjectUnknown;
}

/* ── Device binding reconciliation ──────────────────────────────────────── */
/*
 * CoreAudio device IDs are NOT durable. They are reassigned on every
 * re-enumeration -- replug, port change, coreaudiod restart -- and our
 * AudioUnit holds whichever id it was given at creation. When that id goes
 * stale, AudioUnitSetProperty(CurrentDevice) has long since succeeded and
 * nothing reports an error: CoreAudio simply falls back to the system default
 * output. Audio then plays out of the Mac's speakers while every bridge metric
 * (minHeadroom, depth, late, data_cb) stays perfectly healthy, because the
 * bridge IS healthy -- it is faithfully delivering to the wrong device.
 *
 * Worse, it can appear to work: if the user's default output happens to be our
 * own virtual device, the audio loops back round and reaches the hardware
 * anyway. Observed exactly that on the dev unit -- bound to id 571, which did
 * not exist, while the Symphony was 390.
 *
 * The device-list listener is necessary but not sufficient: it did not fire for
 * every transition, and a listener that must fire is a single point of failure.
 * So we also RECONCILE: periodically ask what the AudioUnit is actually
 * attached to and compare it against a freshly resolved Symphony. This is
 * self-healing regardless of which notifications arrive.
 */
/// Allocate the shared audio buffer. Idempotent.
///
/// Called unconditionally at startup rather than only when the plugin asks.
/// On-demand allocation made a live proxy that had never been asked for a
/// buffer permanently unable to play: every path that starts the AudioUnit is
/// gated on gAudioRing, so no ring meant no audio, forever, with the hardware
/// present and initialised. That is reachable whenever the plugin's request
/// does not arrive -- a dead XPC connection, or simply a proxy that outlived
/// the request. Owning a ring costs 2 MB and removes the whole class.
static int ensure_audio_ring(void)
{
    if (gAudioRing) return 1;

    mach_vm_address_t addr = 0;
    kern_return_t kr = mach_vm_allocate(
        mach_task_self(), &addr, sizeof(MaestroAudioShm), VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        LOG_ERR("mach_vm_allocate failed %d", kr);
        return 0;
    }
    gAudioRing = (MaestroAudioShm*)addr;
    memset(gAudioRing, 0, sizeof(MaestroAudioShm));
    gAudioRing->magic         = MAESTRO_SHM_MAGIC;
    gAudioRing->version       = MAESTRO_SHM_VERSION;
    gAudioRing->ringFrames    = MAESTRO_SHM_RING_FRAMES;
    gAudioRing->bytesPerFrame = MAESTRO_SHM_BYTES_PER_FRAME;
    gAudioRing->delayFrames   = MAESTRO_SHM_MIN_DELAY_FRAMES;
    LOG("Audio shmem allocated at %p (%zu bytes)", (void*)gAudioRing, sizeof(MaestroAudioShm));
    return 1;
}

static dispatch_source_t gReconcileTimer = NULL;
static int      sMismatchTicks  = 0;
static uint64_t sLastRebindHost = 0;

static double host_ticks_to_sec(uint64_t ticks)
{
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)ticks * (double)tb.numer / (double)tb.denom / 1e9;
}
static void init_usb_hardware(void);
static void close_usb_device(void);
static int ensure_audio_ring(void);

static void reconcile_audio_binding(void)
{
    if (!gAudioRing) return;                 /* nothing to play into yet */

    AudioObjectID want = find_usb_device();

    /* Say whether the hardware is there, every tick, whatever else we decide.
       This is the plugin's only way to know: it talks to us, not to IOKit, and a
       virtual device that stays selectable with the Symphony unplugged is a
       device the user can pick and then hear nothing from. Published before the
       early return below, because "absent" is exactly the case that returns. */
    maestro_shm_set_presence(gAudioRing,
        want == kAudioObjectUnknown ? MAESTRO_DEVICE_ABSENT : MAESTRO_DEVICE_PRESENT);

    if (want == kAudioObjectUnknown) return; /* genuinely absent; listener stops us */

    if (!gOutputUnit) {
        LOG("reconcile: device %u present but no AudioUnit — starting", want);
        /* Only touch USB/FPGA if we genuinely have no control handle. Rebinding
           an AudioUnit is a CoreAudio concern and must NOT rewrite routing --
           init_usb_hardware reprograms the optical format and the IOBoard
           crosspoints, and doing that on a timer would disturb ADAT. */
        if (!gUSBDev) init_usb_hardware();
        start_audio_output(gAudioRing);
        return;
    }

    /* Ask the AudioUnit itself rather than trusting what we set. */
    AudioObjectID have = kAudioObjectUnknown;
    UInt32 sz = (UInt32)sizeof(have);
    if (AudioUnitGetProperty(gOutputUnit, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &have, &sz) != noErr)
        return;

    if (have == want) { sMismatchTicks = 0; return; }

    /* Debounce. Device ids churn in bursts during re-enumeration, and acting on
       the first disagreement would rebind repeatedly mid-storm. Require the
       mismatch to persist, and rate-limit rebinds. */
    if (++sMismatchTicks < 2) return;

    const uint64_t now = mach_absolute_time();
    if (sLastRebindHost && host_ticks_to_sec(now - sLastRebindHost) < 10.0) return;
    sLastRebindHost = now;
    sMismatchTicks  = 0;

    LOG("reconcile: AudioUnit bound to %u but Symphony is %u — rebinding",
        have, want);
    /* Rebuild the AudioUnit ONLY. Deliberately does not call close_usb_device /
       init_usb_hardware: the USB control handle is independent of the CoreAudio
       binding, and re-running hardware init would reprogram the optical format
       and IOBoard crosspoints. Rewriting ADAT routing from a timer is exactly
       the kind of collateral damage a recovery path must not cause. */
    unregister_rate_listener();
    stop_audio_output();
    start_audio_output(gAudioRing);
}

static void start_reconcile_timer(void)
{
    if (gReconcileTimer) return;
    gReconcileTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
    if (!gReconcileTimer) return;
    dispatch_source_set_timer(gReconcileTimer,
        dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
        2 * NSEC_PER_SEC, (uint64_t)(500 * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(gReconcileTimer, ^{ reconcile_audio_binding(); });
    dispatch_resume(gReconcileTimer);
    LOG("Device binding reconciliation active (every 2s)");
}

/* ── Direct USB hardware access ────────────────────────────────────────── */

/* Send a vendor control request to the Symphony IO USB device.
   bmRequestType = 0x40 (vendor, host-to-device) for writes.
   bRequest = vendor command code (0x25, 0x26, 0x27, 0x31, 0x50, etc.).
   nValue is split: wValue = nValue >> 16, wIndex = nValue & 0xFFFF. */
/* Forward declarations for USB recovery */
static int open_usb_device(void);
static void close_usb_device(void);
static int configure_fpga_routing(void);
static int usb_vendor_read(uint8_t bRequest, uint16_t wValue, uint16_t wIndex,
                           void *outBuf, uint16_t len);
static void restore_cached_volume(void);
static int usb_vendor_read(uint8_t bRequest, uint16_t wValue, uint16_t wIndex, void *outBuf, uint16_t len);
static void save_volume_state(void);
static int set_hw_volume(uint32_t output, uint8_t attenuation);
static int set_hw_mute(uint32_t output, bool muted);

/* Check if an IOReturn code indicates a stale/dead USB handle */
static int is_stale_handle_error(IOReturn kr)
{
    return kr == kIOReturnNotResponding  /* 0xE00002ED */
        || kr == kIOReturnNoDevice       /* 0xE00002C0 */
        || kr == kIOReturnAborted        /* 0xE00002EB */
        || kr == (IOReturn)0xE00002D8;   /* kIOReturnTimeout */
}

/* ── 0x30 meter-read backoff ──────────────────────────────────────────────────
   The app polls TDM meters at ~12 reads/s. When EP0 starts failing, continuing
   to poll it at that rate helps nobody: it cannot succeed, it floods the log,
   and every failed transfer carries a 1s usb_vendor_read timeout that stalls the
   serial gQueue -- so volume, mute and routing commands queue up behind reads
   that are already known to be failing.

   So after a failed 0x30, stop issuing 0x30 transfers for a short window and
   fail the reads outright instead. Deliberately NOT answered from a cache: a
   cached payload with status 0 tells the app a transfer succeeded when none
   happened, which is exactly the lie removed in 6586c7b. A meter read that
   cannot run must report that it could not run.

   This is a politeness fix, not the wedge fix. The wedge was a malformed request
   (bank/group in wValue instead of wIndex) and is fixed in 95668ac; see
   Docs/Learnings.md 2026-09-11 (resolved). */
#define METER_BACKOFF_SEC 2.0
static uint64_t gMeterBackoffSince = 0;   /* mach_absolute_time; 0 = not backing off */

static int meter_is_backed_off(void)
{
    if (!gMeterBackoffSince) return 0;
    if (host_ticks_to_sec(mach_absolute_time() - gMeterBackoffSince) < METER_BACKOFF_SEC)
        return 1;
    gMeterBackoffSince = 0;
    return 0;
}

/* Saying "the USB device is not open" at the rate a client asks is not logging,
   it is a denial of service against the log.

   MEASURED 2026-09-13: with the Symphony powered off for four minutes, the app's
   meter loop kept asking at 20 Hz and this one line was written 4,647 times,
   burying the presence and reconnect lines that actually explain what happened.
   The client-side half of this is a 1 Hz backoff in the app's meter loop, but the
   proxy must not depend on every client being well behaved -- the log has to stay
   readable no matter who is asking.

   So: say it once when the refusals start, then at most once every
   GETPROP_QUIET_SEC with a count of what was swallowed, and say it once more when
   reads start working again. No refusal is hidden, only the repetition is.

   Called only from the getProperty handler's dispatch_async onto gQueue, which is
   serial, so the counters need no synchronisation. */
#define GETPROP_QUIET_SEC 5.0
static uint64_t gGetPropDeniedLast = 0;   /* mach ticks of the last line printed */
static uint32_t gGetPropDeniedSince = 0;  /* refusals swallowed since that line */

static void note_getproperty_denied(void)
{
    const uint64_t now = mach_absolute_time();
    if (gGetPropDeniedLast &&
        host_ticks_to_sec(now - gGetPropDeniedLast) < GETPROP_QUIET_SEC) {
        gGetPropDeniedSince++;
        return;
    }
    if (gGetPropDeniedSince) {
        LOG_ERR("getProperty: USB device not open (and %u more since the last line)",
                gGetPropDeniedSince);
    } else {
        LOG_ERR("getProperty: USB device not open");
    }
    gGetPropDeniedSince = 0;
    gGetPropDeniedLast = now;
}

/* One read got through. Close the books on the quiet period so the next outage
   announces itself immediately instead of inheriting this one's timestamp. */
static void note_getproperty_succeeded(void)
{
    if (!gGetPropDeniedLast) return;
    LOG("getProperty: USB device answering again%s",
        gGetPropDeniedSince ? " (refusals in between were not all logged)" : "");
    gGetPropDeniedLast = 0;
    gGetPropDeniedSince = 0;
}

/* Rate-limit recovery: don't attempt more than once per 10 seconds */
static time_t gLastRecoveryAttempt = 0;
/* When the open handle was last fully configured, so the same enumeration is not
   configured twice.

   A power cycle with Maestro open is seen by two observers. The app's meter
   polling hits the dead handle first and try_recover_usb() reopens and
   configures the unit the moment it is back on the bus. Up to a second later
   CoreAudio publishes the audio device and devices_changed_callback() calls
   init_usb_hardware(), which used to run the whole sequence again: preference
   lock back ON, clock source, some seventy routing and mixer writes, unlock --
   on a unit that had just been unlocked and was about to start streaming.

   Seen 2026-11-13, twice out of two: 11:58:42 then 11:58:43 (3,392 late frames
   and audible clicking afterwards), and 12:02:26.27 then 12:02:26.47 (control
   endpoint wedged six seconds later). Two reconnects that same session with
   Maestro closed -- one observer, one init -- were clean. That is a small
   sample and other things differed, so it is a correlation, not a proven
   cause; but the second pass does nothing the first did not.

   Cleared whenever the handle closes, so a new enumeration is always
   configured. */
static uint64_t gConfiguredAtNs = 0;   /* CLOCK_MONOTONIC; 0 = this handle is unconfigured */
#define MAESTRO_RECONFIGURE_HOLDOFF_NS (5ull * 1000000000ull)

static int configured_recently(uint64_t nowNs, uint64_t configuredAtNs)
{
    return configuredAtNs != 0 && nowNs >= configuredAtNs
        && nowNs - configuredAtNs < MAESTRO_RECONFIGURE_HOLDOFF_NS;
}

/* Re-entrancy guard: configure_fpga_routing() calls usb_vendor_write() which
   can fail and call try_recover_usb() again — must prevent that loop. */
static int gRecoveryInProgress = 0;
static int gRecoveryFailures  = 0;   /* consecutive failed recoveries */
static int gRecoveryDisarmed  = 0;   /* set after MAX_RECOVERY_FAILURES; stops thrash */
#define MAX_RECOVERY_FAILURES 3

/* Does endpoint 0 actually answer?

   This is the ONLY way to tell a recovered device from a wedged one, and skipping
   it is what made recovery thrash. The failure this proxy actually sees is a
   DEVICE-SIDE EP0 wedge, not an invalid host handle: at both 2026-09-11 failures
   ResetDevice() returned kIOReturnSuccess while the very next transfer still
   returned 0xE00002ED. The IOService and the port were alive; the unit was not
   answering. open_usb_device() cannot detect that — it only does
   IOServiceGetMatchingService on VID/PID plus USBDeviceOpen/OpenSeize, so it
   SUCCEEDS against a wedged unit, and recovery would then report success and fire
   configure_fpga_routing() (~10 EP0 writes) plus restore_cached_volume() at a
   device answering nothing, every cooldown period, forever.

   0x26 (speaker volume) is the probe because the device demonstrably answers it
   when healthy — 5 successful `getProperty cmd=0x26` reads in the reference log —
   while both wedges failed it. One probe read is strictly less EP0 traffic than
   the dozen blind writes it gates. */
static IOReturn ep0_probe(void)
{
    if (!gUSBDev) return kIOReturnNotOpen;
    uint8_t test = 0;
    IOUSBDevRequest req = {
        .bmRequestType = USBmakebmRequestType(kUSBIn, kUSBVendor, kUSBDevice),
        .bRequest = VCMD_SPEAKER_VOL, .wValue = 0, .wIndex = 0,
        .wLength = 1, .pData = &test, .wLenDone = 0
    };
    IOReturn kr = (*gUSBDev)->DeviceRequest(gUSBDev, &req);
    if (kr != kIOReturnSuccess)
        LOG("EP0 liveness probe (0x%02X) failed: 0x%08X", VCMD_SPEAKER_VOL, kr);
    return kr;
}

static int ep0_is_live(void) { return ep0_probe() == kIOReturnSuccess; }

/* Whether the open handle is left over from before an unplug or power cycle.
   open_usb_device() keeps an existing handle, so after a replug the handle can
   still point at the device instance that was destroyed. Asking it anything
   then answers "no device" (0xE00002C0) while the unit that came back is on
   the bus and published. That is not a wedged unit and not a unit that is off
   the bus: close the handle and open the device that is there.
   Seen 2026-11-17 23:44 (diagnostics capture): the replugged unit was treated
   as wedged, hardware init was skipped (no routing, XMOS left locked: meters
   but no sound), and recovery then waited for an arrival that had already
   happened. */
static bool handle_is_from_before_replug(IOReturn kr, bool unitPublished)
{
    return kr == kIOReturnNoDevice && unitPublished;
}

/* Try to recover a stale USB handle by closing and reopening the device.
   Returns 0 on success (device reopened + FPGA reconfigured + volume restored).
   Strategy:
     1. Try ResetDevice() first — lightweight USB port reset
     2. Close and retry open with increasing backoff delays

   DO NOT re-add an unconditional USBDeviceReEnumerate() escalation here. It reads
   like a harmless "software unplug/replug", but on a Symphony IO MKI it is a
   one-way door: the unit leaves the USB bus and does NOT come back, so the only
   remaining recovery is a physical Apogee power cycle. That cost two power cycles
   while a front-panel meter write (0x10) was wrongly blamed for the departure —
   the write had succeeded; a 0x30 meter read timed out with
   kIOUSBTransactionTimeout (0xE0004051), the follow-on 0xE00002ED was classified
   as a dead handle, and this function pushed the device off the bus.
   The authority for this is Apple's, not Apogee's. IOUSBLib.h:1459-1480 says
   USBDeviceReEnumerate "will send a terminate message to all clients ... emulating
   an unplug" and "should be used by clients wishing to take advantage of the Device
   Firmware Update Class specification" — i.e. it is a DFU tool by design.
   IOUSBLib.h:1200-1216 confirms ResetDevice "will not reenumerate the device",
   which is why step 1 below is safe to keep.

   Do NOT cite og_source for this, and do not repeat the earlier claim that every
   USBDeviceReEnumerate in og_source is a DFU path — that is false.
   og_source/generic/USB/ApoUSB.cpp:1009-1015 is ApoUSB::ResetDevice(), a
   general-purpose helper whose body is ResetDevice() followed immediately by
   USBDeviceReEnumerate(...,0), and it is reached from a NON-DFU path at
   og_source/generic/USB/ApoUSB.cpp:325-329 ("Reopen and reset the device for
   normal use"). Apogee's generic reset was exactly the pattern removed here.
   Likewise ApoUSB.cpp:1369 is a case label in ApoUSB::PrintUSBErr(), an error-code
   to string table that ApoUSB.cpp never calls — it is not evidence of any policy
   toward kIOUSBTransactionTimeout. (Note og_source has 8 copies of ApoUSB.cpp at
   two different line offsets, so cite the full path, never a bare filename.)
   Full write-up: Docs/Learnings.md 2026-09-11 (night).

   To opt back in for a deliberate experiment, launchd gives this daemon only the
   EnvironmentVariables in its plist, so `launchctl setenv` will NOT work (that
   writes the GUI domain). Add the variable to
   /Library/LaunchDaemons/com.danielraffel.Maestro.volumeproxy.plist and
   `sudo launchctl kickstart -k system/com.danielraffel.Maestro.volumeproxy`. */
/* Recovery must not configure a unit that is still starting up.

   When the Symphony is power-cycled with Maestro open, the app's meter polling
   hits the dead handle and lands here. The old code then retried the open until
   the unit was back on the bus and immediately sent the whole configuration --
   preference lock, clock source, routing, mixer, unlock -- half a second to
   three quarters of a second BEFORE macOS had finished bringing up the unit's
   audio interface (2026-11-13: configured 11:58:42.48, device published
   11:58:43.23; configured 12:18:21.28, published 12:18:21.94). Those reconnects
   were followed by digital clicking that lasted until a USB replug. With Maestro
   closed nothing polls, recovery never runs, and the unit is configured once by
   the "USB device appeared" path after macOS has published it; every one of
   those reconnects was clean.

   So: if CoreAudio does not currently list the audio device, the unit is off the
   bus or still coming up. Close the control handle, send nothing, and let the
   device-list listener do the single configuration at the right time. This is
   not a failed recovery and does not count toward disarming. It also means
   recovery no longer blocks gQueue for seconds waiting for a unit to boot. */
static int defer_to_device_listener(const char *why)
{
    LOG("USB recovery: %s — closing the control handle and waiting for the "
        "audio device to appear (nothing is sent to a unit that is starting up)", why);
    close_usb_device();
    gRecoveryInProgress = 0;
    return -1;
}

static int try_recover_usb(void)
{
    /* Prevent re-entrant recovery from writes inside configure_fpga_routing() */
    if (gRecoveryInProgress) return -1;

    /* Give up permanently after repeated failures. Without this the 10s cooldown
       is the ONLY brake, and a device-side wedge means a real USB port reset plus
       a dozen EP0 writes at a unit that answers nothing, every 10s, forever — on
       the same serial gQueue that serves the volume/mute XPC path. Fail-fast is
       correct here: the fix for a wedged unit is Tools/unwedge.sh or a power
       cycle, neither of which this daemon can do. */
    if (gRecoveryDisarmed) return -1;

    /* Rate limit — avoid thrashing if USB is truly gone */
    time_t now = time(NULL);
    if (now - gLastRecoveryAttempt < 10) {
        LOG("USB recovery skipped — last attempt %lds ago (cooldown 10s)",
            (long)(now - gLastRecoveryAttempt));
        return -1;
    }
    gLastRecoveryAttempt = now;
    gRecoveryInProgress = 1;

    LOG("USB handle stale — attempting recovery...");

    if (find_usb_device() == kAudioObjectUnknown)
        return defer_to_device_listener("the audio device is not present");

    /* Step 1: Try ResetDevice on the current handle (lightweight port reset) */
    if (gUSBDev) {
        IOReturn kr = (*gUSBDev)->ResetDevice(gUSBDev);
        LOG("ResetDevice: 0x%08X (%s)", kr, kr == kIOReturnSuccess ? "OK" : "failed");
        /* CoreAudio can lag the bus by a moment; the port saying "no device" is
           the same fact from the other side. */
        if (kr == kIOReturnNoDevice) {
            /* Checked just above: Core Audio publishes the unit. Then the handle is
               from before a replug and the listener will not fire again; one
               reopen tells that apart from Core Audio lagging an unplug. */
            if (handle_is_from_before_replug(kr, find_usb_device() != kAudioObjectUnknown)) {
                close_usb_device();
                if (open_usb_device() == 0 && ep0_is_live()) {
                    LOG("USB recovery: the handle was from before a replug — reopened the unit that is here");
                    configure_fpga_routing();
                    restore_cached_volume();
                    gRecoveryFailures  = 0;
                    gRecoveryInProgress = 0;
                    return 0;
                }
            }
            return defer_to_device_listener("the unit is off the bus");
        }
        if (kr == kIOReturnSuccess) {
            usleep(500000);  /* 500ms for device to stabilize after reset */
            if (ep0_is_live()) {
                LOG("ResetDevice succeeded — EP0 answers");
                configure_fpga_routing();
                restore_cached_volume();
                gRecoveryFailures  = 0;
                gRecoveryInProgress = 0;
                return 0;
            }
            LOG("ResetDevice succeeded but EP0 still does not answer, reopening");
        }
    }

    /* Step 2: NOT a re-enumerate. See the header comment — on this device
       USBDeviceReEnumerate() is unrecoverable without a physical power cycle, so
       it is opt-in only. A genuinely stale handle is cleared by close + reopen
       below, which leaves the unit on the bus either way. */
    /* Exact "1" match, not truthiness: a bare getenv() test makes
       MAESTRO_ALLOW_USB_REENUMERATE=0 ENABLE re-enumeration, which is the
       opposite of what anyone setting it to 0 intends. Matches the Swift gate in
       Apps/Maestro/MaestroDevice/SymphonyIOPropertyMapper.swift:57-58. */
    const char *reenum = getenv("MAESTRO_ALLOW_USB_REENUMERATE");
    if (gUSBDev && reenum && strcmp(reenum, "1") == 0) {
        LOG("MAESTRO_ALLOW_USB_REENUMERATE set — forcing re-enumeration.");
        LOG("  WARNING: the Symphony typically does NOT return from this; expect");
        LOG("  to power-cycle the Apogee to get it back.");
        IOReturn kr = (*gUSBDev)->USBDeviceReEnumerate(gUSBDev, 0);
        LOG("USBDeviceReEnumerate: 0x%08X (%s)", kr,
            kr == kIOReturnSuccess ? "OK — device will re-enumerate" : "failed");
    }

    close_usb_device();

    /* Step 3: Retry open with increasing delays (the port reset needs time to settle) */
    int delays_ms[] = { 1000, 2000, 3000, 4000, 5000 };
    for (int i = 0; i < 5; i++) {
        usleep(delays_ms[i] * 1000);
        if (open_usb_device() == 0) {
            /* Reopening proves nothing on its own — see ep0_is_live(). Only
               reconfigure a device that is actually answering. */
            if (ep0_is_live()) {
                /* Back on the bus and answering, but if macOS has not published
                   the audio device yet the unit is mid start-up (a reset
                   re-enumerates it too). Leave the configuration to the
                   listener. */
                if (find_usb_device() == kAudioObjectUnknown) {
                    gRecoveryFailures = 0;
                    return defer_to_device_listener(
                        "the unit answers but its audio device is not published yet");
                }
                configure_fpga_routing();
                restore_cached_volume();
                gRecoveryFailures  = 0;
                gRecoveryInProgress = 0;
                LOG("USB recovery succeeded on attempt %d (reopen, EP0 answers)", i + 1);
                return 0;
            }
            LOG("USB recovery attempt %d: reopened but EP0 does not answer "
                "(device-side wedge, not a stale handle) — not reconfiguring", i + 1);
            close_usb_device();
            continue;
        }
        LOG("USB recovery attempt %d failed, retrying...", i + 1);
    }
    gRecoveryInProgress = 0;
    if (++gRecoveryFailures >= MAX_RECOVERY_FAILURES) {
        gRecoveryDisarmed = 1;
        LOG_ERR("USB recovery failed %d times consecutively — DISARMING recovery.",
                gRecoveryFailures);
        LOG_ERR("  The unit is wedged device-side; more EP0 traffic cannot fix it.");
        LOG_ERR("  Unplug and replug the Apogee's USB cable to force a real");
        LOG_ERR("  re-enumeration; power-cycle the unit only if that fails. Then");
        LOG_ERR("  restart this daemon (sudo Tools/deploy-proxy.sh --no-build).");
        LOG_ERR("  (Tools/unwedge.sh is for the ThunderBridge dext, not this USB path.)");
    } else {
        LOG_ERR("USB recovery failed after 5 attempts (%d/%d before disarming)",
                gRecoveryFailures, MAX_RECOVERY_FAILURES);
    }
    return -1;
}

static int usb_vendor_write(uint8_t bRequest, uint32_t nValue,
                            void *data, uint16_t len)
{
    if (!gUSBDev) return -1;

    IOUSBDevRequest req;
    req.bmRequestType = USBmakebmRequestType(kUSBOut, kUSBVendor, kUSBDevice);
    req.bRequest      = bRequest;
    req.wValue        = (uint16_t)(nValue >> 16);
    req.wIndex        = (uint16_t)(nValue & 0xFFFF);
    req.wLength       = len;
    req.pData         = data;
    req.wLenDone      = 0;

    IOReturn kr = (*gUSBDev)->DeviceRequest(gUSBDev, &req);
    if (kr == kIOReturnSuccess) return 0;

    if (is_stale_handle_error(kr)) {
        LOG_ERR("USB vendor write cmd=0x%02X failed: 0x%08X (stale handle)", bRequest, kr);
        if (try_recover_usb() == 0) {
            /* Retry the write on the new handle */
            req.wLenDone = 0;
            kr = (*gUSBDev)->DeviceRequest(gUSBDev, &req);
            if (kr == kIOReturnSuccess) return 0;
        }
    }

    LOG_ERR("USB vendor write cmd=0x%02X failed: 0x%08X", bRequest, kr);
    return -1;
}

/* Open the Symphony IO USB device by VID/PID.  Returns 0 on success. */
static int open_usb_device(void)
{
    if (gUSBDev) return 0;  /* already open */

    /* Match IOUSBHostDevice by vendor + product ID */
    CFMutableDictionaryRef matchDict = IOServiceMatching("IOUSBHostDevice");
    if (!matchDict) {
        /* Fallback to legacy class name */
        matchDict = IOServiceMatching(kIOUSBDeviceClassName);
    }
    if (!matchDict) { LOG_ERR("IOServiceMatching failed"); return -1; }

    CFNumberRef vid = CFNumberCreate(NULL, kCFNumberIntType,
                                     &(int){APOGEE_VID});
    CFNumberRef pid = CFNumberCreate(NULL, kCFNumberIntType,
                                     &(int){SYMPH_IO_PID});
    CFDictionarySetValue(matchDict, CFSTR(kUSBVendorID),  vid);
    CFDictionarySetValue(matchDict, CFSTR(kUSBProductID), pid);
    CFRelease(vid);
    CFRelease(pid);

    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, matchDict);
    /* matchDict consumed by IOServiceGetMatchingService */
    if (!svc) {
        LOG("USB device not found (VID=0x%04X PID=%u)", APOGEE_VID, SYMPH_IO_PID);
        return -1;
    }

    /* Create plugin interface → USB device interface */
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn kr = IOCreatePlugInInterfaceForService(
        svc, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID,
        &plugin, &score);
    IOObjectRelease(svc);

    if (kr != kIOReturnSuccess || !plugin) {
        LOG_ERR("IOCreatePlugInInterface failed: 0x%08X", kr);
        return -1;
    }

    IOUSBDeviceInterface245 **dev = NULL;
    HRESULT hr = (*plugin)->QueryInterface(
        plugin,
        CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID245),
        (LPVOID *)&dev);
    IODestroyPlugInInterface(plugin);

    if (hr != S_OK || !dev) {
        LOG_ERR("QueryInterface for USB device failed");
        return -1;
    }

    /* Open the device (non-exclusive — we only need EP0 vendor requests) */
    kr = (*dev)->USBDeviceOpen(dev);
    if (kr == kIOReturnExclusiveAccess) {
        /* Another process has exclusive access — seize it (we're root) */
        kr = (*dev)->USBDeviceOpenSeize(dev);
    }
    if (kr != kIOReturnSuccess) {
        LOG_ERR("USBDeviceOpen failed: 0x%08X", kr);
        (*dev)->Release(dev);
        return -1;
    }

    gUSBDev = dev;
    LOG("USB device opened (VID=0x%04X PID=%u)", APOGEE_VID, SYMPH_IO_PID);
    return 0;
}

static void close_usb_device(void)
{
    gConfiguredAtNs = 0;   /* whatever is opened next is a new enumeration */
    if (!gUSBDev) return;
    (*gUSBDev)->USBDeviceClose(gUSBDev);
    (*gUSBDev)->Release(gUSBDev);
    gUSBDev = NULL;
    LOG("USB device closed");
}

/* Bring the unit up for USB playback. The original's ApplySettingsToHardware
   (og_source/maestrolink/Software/SymphonyIO.cpp:4660-4708) wrote the saved
   settings under one PreferenceLoadLock; this helper holds none of the
   user's settings, so it writes only what audio needs and leaves the rest to
   Maestro, which restores the saved state after every connect and recovery:
     1. PreferenceLoadLock(true)  — mute XMOS while configuring
     2. Speaker volume/mute (the cached values; the speaker MODE is the
        user's setting and is not touched here)
     3. Clock source → Internal/Master (the USB mode's only clock)
     4. Routing: every USB playback channel straight to the matching output,
        no mixer routed to any output (the original's default)
     5. PreferenceLoadLock(false) — unlock XMOS, audio can flow
   The PreferenceLoadLock handshake is CRITICAL — without step 5 the XMOS
   stays muted and no audio reaches the DAC even though USB frames arrive. */
/* Whether bring-up sends the default OpticalFormat (0x34) to a slot, given its
   OptionBoardType (0xA1) or -1 when the read failed. Only a slot that reads as
   AnalogAES (2) is skipped. Mirrors the dext's BootSendsOpticalFormat. */
static bool proxy_boot_sends_optical_format(int boardType)
{
    return boardType != 2;
}

/* The option board fitted on a slot (OptionBoardType 0xA1, board in wIndex),
   -1 when the read fails. */
static int current_board_type(uint32_t board)
{
    uint8_t type = 0;
    if (usb_vendor_read(0xA1, 0, (uint16_t)board, &type, 1) != 1) return -1;
    return (type >= 1 && type <= 7) ? type : -1;
}

static int configure_fpga_routing(void)
{
    if (!gUSBDev) return -1;

    int err;

    /* ── Step 1: Lock/mute XMOS while we configure ─────────────────────── */
    uint8_t lock = 1;
    err = usb_vendor_write(VCMD_PREF_LOAD_LOCK, 0, &lock, 1);
    LOG("PreferenceLoadLock(true): %s", err ? "FAILED" : "OK");

    /* ── Step 2: Speaker volume and mute ───────────────────────────────── */
    /* The speaker output mode (0x25) is not written here. It used to be
       forced to stereo on every configure, which undid the user's choice
       (Output page, Speaker mode) on each connect and recovery. It is one of
       the settings the Mac owns: Maestro writes the saved one back after
       every connect and recovery, as the original did first thing in
       ApplySettingsToHardware (og_source/maestrolink/Software/SymphonyIO.cpp:4669),
       and a unit nobody set a mode for keeps its own. */

    /* Set volume and mute using cached state if available, otherwise safe defaults.
       This avoids a momentary jump to the hardcoded 20dB before restore_cached_volume()
       overwrites it — the hardware hears only one volume value. */
    uint8_t vol = gHasReceivedVolume ? gCachedAttenuation : 20;
    uint8_t muteVal = gHasReceivedVolume ? (gCachedMuted ? 1 : 0) : 0;
    if (gMonitorOutput == MONITOR_OUTPUT_SPEAKERS) {
        err = usb_vendor_write(VCMD_SPEAKER_VOL, 0, &vol, 1);
        LOG("SpeakerVolume(%ddB atten%s): %s", vol,
            gHasReceivedVolume ? " [cached]" : " [default]",
            err ? "FAILED" : "OK");

        err = usb_vendor_write(VCMD_SPEAKER_MUTE, 0, &muteVal, 1);
        LOG("SpeakerMute(%s%s): %s",
            muteVal ? "muted" : "unmuted",
            gHasReceivedVolume ? " [cached]" : " [default]",
            err ? "FAILED" : "OK");
    } else {
        /* A headphone is the chosen output. The speakers get their own kept
           level, as every configure did (never the headphone's), and only
           when one was ever set. */
        if (gHasSpeakerLevel) {
            uint8_t spk = gSpeakerAttenuation, spkMute = gSpeakerMuted ? 1 : 0;
            err = usb_vendor_write(VCMD_SPEAKER_VOL, 0, &spk, 1);
            LOG("SpeakerVolume(%ddB atten [kept]): %s", spk, err ? "FAILED" : "OK");
            err = usb_vendor_write(VCMD_SPEAKER_MUTE, 0, &spkMute, 1);
            LOG("SpeakerMute(%s [kept]): %s", spkMute ? "muted" : "unmuted", err ? "FAILED" : "OK");
        }
        /* The headphone is not written: the unit keeps its level, which may
           have been changed on the front panel since. It is read instead, so
           that the level the Mac's control is given belongs to it. */
        MonitorKeyWrite v = monitor_restore_write(gMonitorOutput, false);
        MonitorKeyWrite m = monitor_restore_write(gMonitorOutput, true);
        uint8_t level = 0, mute = 0;
        if (usb_vendor_read(v.request, 0, (uint16_t)v.nValue, &level, 1) == 1 &&
            usb_vendor_read(m.request, 0, (uint16_t)m.nValue, &mute, 1) == 1 && level <= 64) {
            gCachedAttenuation = level;
            gCachedMuted = mute != 0;
            gHasReceivedVolume = true;
            save_volume_state();
            LOG("Headphone %u level read from the unit: %udB atten, mute=%d", v.nValue + 1, level, (int)gCachedMuted);
        } else {
            LOG_ERR("Headphone %u level could not be read; the kept one stays", v.nValue + 1);
        }
        vol = gCachedAttenuation;
        muteVal = gCachedMuted ? 1 : 0;
    }

    /* ── Step 3: Clock source → Internal, Master mode ──────────────────── */
    /* Over USB the clock is always Internal: Apogee's user guide says of
       Clock Source "Only available in Symphony & Standalone AIMs ... USB AIM
       is always Internal", and Maestro offers only Internal over USB
       (ClockSourceMenu.usb). So this is not a user setting being overridden,
       and a source saved under ThunderBridge must never be applied here.
       ClockMode command 0x50, payload 4 bytes — [source, master, loopSync, boardClockSrc]
       Source enum (1-based): 1=Internal, 2=WordClock, 3=LoopSync, 4=IOBoard1, 5=IOBoard2
       Master flag: 0=Slave, 1=Master
       LoopSync: 0=off, 1=on
       boardClockSrc: 0=SPDIFCoax, 1=Optical1-2, etc. */
    uint8_t clock_data[4] = { 0x01, 0x01, 0x00, 0x00 };  /* Internal, Master, no LoopSync */
    err = usb_vendor_write(VCMD_CLOCK_MODE, 0, clock_data, 4);
    LOG("ClockSource(Internal, Master): %s", err ? "FAILED" : "OK");

    /* ── Step 3a: Set optical format to ADAT/SMUX on both IOBoards ───── */
    /* OpticalFormat command 0x34: configures IOBoard Analog FPGA register 0x24
       ("Option Major Mode") which controls the ADAT transmitter/receiver.
       Without this, the ADAT optical port doesn't generate frames.
       nValue = board index (0 or 1), pData[0] = 0 for ADAT/SMUX, 1 for SPDIF.
       Board-agnostic: harmless if board doesn't exist.
       Evidence: og_source SymphonyIOControl.cpp:1301-1320 setOpticalIsSPDIF(),
       SymphonyIOAnalogFPGA.cpp:82-99 writes FPGA register 0x24. */
    /* The format is the one last chosen for each board (ADAT/SMUX, 0, until
       one is), and the remembered S/PDIF Coax Replaces / Mirrors go back too;
       see "Per-board digital settings" above. */
    {
        for (uint32_t b = 0; b < 2; b++) {
            /* Remembered values go back only on the type of card they were
               written to; see "Per-board digital settings". */
            bool replay = false;
            /* Read once: the type decides both the replay and whether the
               optical format goes out at all. */
            int type = current_board_type(b);
            if (digital_has_replay(b)) {
                replay = digital_replay_allowed(gSavedDigitalBoardType[b], type);
                if (!replay)
                    LOG("Digital settings board%u not replayed: card type %d, remembered for %d",
                        b, type, gSavedDigitalBoardType[b]);
            }
            uint8_t format = (replay && gSavedDigital[0][b] == 1) ? 1 : 0;
            /* An AES card (8x8 AES, type 2) has no optical format: Apogee's
               software never sent one (SymphonyIO_IOBoard.cpp:940-981) and the
               firmware ignores it (SymphonyIOAudioManager.cpp:257-290). Same
               rule as the ThunderBridge driver's BootSendsOpticalFormat: skip
               only a slot that positively reads as AES; a failed read keeps
               the old behaviour. */
            if (proxy_boot_sends_optical_format(type)) {
                int e = usb_vendor_write(VCMD_OPTICAL_FORMAT, b, &format, 1);
                LOG("OpticalFormat board%u = %s: %s", b, format ? "SPDIF" : "ADAT/SMUX",
                    e ? "FAILED" : "OK");
            } else {
                LOG("OpticalFormat board%u: not sent (AES card has no optical port)", b);
            }
            for (int idx = 1; replay && idx <= 2; idx++) {
                if (gSavedDigital[idx][b] < 0) continue;
                uint8_t value = (uint8_t)gSavedDigital[idx][b];
                int err = usb_vendor_write(idx == 1 ? 0x35 : 0x36, b, &value, 1);
                LOG("S/PDIF Coax %s board%u = %u: %s", idx == 1 ? "Replaces" : "Mirrors",
                    b, value, err ? "FAILED" : "OK");
            }
        }
    }

    /* ── Step 4: Output routing — every output direct ─────────────────── */
    /* USB ch0-15 straight to IOBoard0 ch0-15, Line 1/2 included, and no
       mixer routed to any output. This is the original's default: its reset
       routes every hardware output from a USB playback channel and no mixer
       output anywhere (og_source/maestrolink/Software/
       SymphonyIOUSBAudioRoutingController.cpp:623-712), and the firmware powers
       on the same way (SymphonyIOAudioRouteManager.cpp:226-439). Line 1/2 used
       to be sent through Mixer 1 here (USB → Mixer0 → DAC), with the mixer's
       hardware inputs then muted to hide them; that was ours, not Apogee's.
       A mixer reaches an output only when the user routes it there in Output
       Routing, and Maestro writes those saved routes (and each mixer's
       Software Return source) after this runs, on connect and on recovery.
       Each route sent individually (2 bytes) matching the original daemon's
       ResetOutputRouting() pattern.
       Evidence: og_source SymphonyIORouting.h IOBoard0Ch0=0x20 .. Ch15=0x2F */
    {
        uint8_t table[DIRECT_ROUTE_COUNT][2];
        unsigned count = direct_route_table(table);
        int ok[3] = {0, 0, 0}, fail[3] = {0, 0, 0};
        for (unsigned i = 0; i < count; i++) {
            int group = i < 16 ? 0 : i < 32 ? 1 : 2;
            int rerr = usb_vendor_write(VCMD_AUDIO_ROUTING, 0, table[i], 2);
            if (rerr) fail[group]++; else ok[group]++;
        }
        LOG("IOBoard0 direct routes (USB 1-16 → outputs 1-16): %d OK, %d failed", ok[0], fail[0]);
        /* Step 4b: the same USB channels feed IOBoard1 ch0-15 (ADAT 9-24);
           the FPGA crosspoint allows several destinations per source, as the
           original's two-X-per-row pattern
           (og_source SymphonyIOUSBAudioRoutingController.cpp:681-689).
           Harmless if the slot is empty. */
        LOG("IOBoard1 dual routes (ADAT 9-24): %d OK, %d failed", ok[1], fail[1]);
        /* Step 4c: both headphones direct (USB 1-2), never left on a mixer. */
        LOG("Headphone direct routes (USB 1-2 → headphones 1 and 2): %d OK, %d failed", ok[2], fail[2]);
    }

    /* No mixer strip is muted here. All 32 hardware inputs of Mixer 1 used to
       be muted (or unmuted) on every configure for the removed Input
       Monitoring setting; a strip now only ever holds what Maestro shows for
       it, and Maestro restores both mixers after every connect and recovery. */

    /* NOTE: SW Return meter taps (destinations 0xB0-0xB3) cannot be set via
       command 0x31 — the firmware only accepts audio routing destinations
       (0x20+) through this command. Meter tap routing requires direct FPGA
       register writes via XLink, which the legacy daemon did but we cannot
       replicate over USB vendor EP0. SW Return meters will remain inactive
       until a different approach is found (e.g., reading mixer input levels
       from a different TDM group, or implementing XLink register access). */

    /* ── Step 5: Unlock XMOS — audio can now flow ──────────────────────── */
    uint8_t unlock = 0;
    err = usb_vendor_write(VCMD_PREF_LOAD_LOCK, 0, &unlock, 1);
    LOG("PreferenceLoadLock(false): %s — XMOS %s",
        err ? "FAILED" : "OK",
        err ? "STILL MUTED" : "UNLOCKED, audio should flow");

    LOG("Hardware init complete — %s, vol=%ddB, clock=Internal/Master, outputs direct",
        muteVal ? "muted" : "unmuted", vol);
    /* Only a unit that took the final unlock counts as configured. */
    gConfiguredAtNs = err ? 0 : clock_gettime_nsec_np(CLOCK_MONOTONIC);
    return err;
}

/* Restore cached volume/mute state after FPGA reconfiguration.
   configure_fpga_routing() always writes hardcoded defaults (20dB, unmuted).
   If we've received volume commands from the ASP, overwrite with cached state
   so hardware matches what the ASP expects — prevents loud volume jumps. */
static void restore_cached_volume(void)
{
    arm_startup_volume_window(clock_gettime_nsec_np(CLOCK_MONOTONIC));
    /* Only the speakers: a headphone's level is the unit's own, read at
       configure and never written back from a kept copy. */
    if (gHasReceivedVolume && gMonitorOutput == MONITOR_OUTPUT_SPEAKERS) {
        set_hw_volume(gMonitorOutput, gCachedAttenuation);
        set_hw_mute(gMonitorOutput, gCachedMuted);
        LOG("Restored cached volume: %udB atten, mute=%d",
            gCachedAttenuation, (int)gCachedMuted);
    }
    /* else: first boot, keep configure_fpga_routing() defaults (20dB, unmuted) */
}

/* Send a vendor control read request to the Symphony IO USB device.
   bmRequestType = 0xC0 (vendor, device-to-host) for reads.
   Returns bytes read, or -1 on error.  Data written to `outBuf`. */
static int usb_vendor_read(uint8_t bRequest, uint16_t wValue, uint16_t wIndex,
                           void *outBuf, uint16_t len)
{
    if (!gUSBDev) return -1;

    IOUSBDevRequest req;
    req.bmRequestType = USBmakebmRequestType(kUSBIn, kUSBVendor, kUSBDevice);
    req.bRequest      = bRequest;
    req.wValue        = wValue;
    req.wIndex        = wIndex;
    req.wLength       = len;
    req.pData         = outBuf;
    req.wLenDone      = 0;

    IOReturn kr = (*gUSBDev)->DeviceRequest(gUSBDev, &req);
    if (kr == kIOReturnSuccess) return (int)req.wLenDone;

    if (is_stale_handle_error(kr)) {
        LOG_ERR("USB vendor read cmd=0x%02X failed: 0x%08X (stale handle)", bRequest, kr);
        if (try_recover_usb() == 0) {
            /* Retry the read on the new handle */
            req.wLenDone = 0;
            kr = (*gUSBDev)->DeviceRequest(gUSBDev, &req);
            if (kr == kIOReturnSuccess) return (int)req.wLenDone;
        }
    }

    LOG_ERR("USB vendor read cmd=0x%02X failed: 0x%08X", bRequest, kr);
    return -1;
}

/* Set the chosen output's level directly via USB (the speakers, or a
   headphone; see monitor_restore_write).
   attenuation: 0 = 0dB (full), 64 = -64dB (silent). */
static int set_hw_volume(uint32_t output, uint8_t attenuation)
{
    if (attenuation > 64) attenuation = 64;
    MonitorKeyWrite w = monitor_restore_write(output, false);
    return usb_vendor_write(w.request, w.nValue, &attenuation, 1);
}

/* Set the chosen output's mute directly via USB. */
static int set_hw_mute(uint32_t output, bool muted)
{
    uint8_t val = muted ? 1 : 0;
    MonitorKeyWrite w = monitor_restore_write(output, true);
    return usb_vendor_write(w.request, w.nValue, &val, 1);
}

/* Open USB device and configure FPGA routing.
   Called when USB device appears (from CoreAudio device listener). */
static void init_usb_hardware(void)
{
    if (open_usb_device() != 0) return;

    IOReturn probe = ep0_probe();
    if (handle_is_from_before_replug(probe, find_usb_device() != kAudioObjectUnknown)) {
        LOG("EP0 probe went to the device from before the replug — reopening the one that appeared");
        close_usb_device();
        if (open_usb_device() != 0) return;
        probe = ep0_probe();
    }

    /* open_usb_device() SUCCEEDS against a wedged unit -- it only does
       IOServiceGetMatchingService on VID/PID plus USBDeviceOpen, and a
       device-side EP0 wedge leaves the IOService and the port perfectly alive.
       So "opened" is not evidence of anything.  Ask EP0 directly.

       Getting this wrong cost a live thrash loop: clearing the recovery counters
       on open alone pinned gRecoveryFailures at 1/3 forever, because this
       function runs on every reconcile, so the disarm could never fire and the
       proxy retried a dead unit every ~15s indefinitely. */
    if (probe != kIOReturnSuccess) {
        LOG_ERR("USB device opened but EP0 does not answer — skipping hardware init.");
        LOG_ERR("  Not re-arming recovery and not sending 30 doomed EP0 writes.");
        LOG_ERR("  The unit is wedged device-side. Unplug and replug its USB cable");
        LOG_ERR("  (forces a real re-enumeration); power-cycle the Apogee only if that");
        LOG_ERR("  fails. Then: sudo Tools/deploy-proxy.sh --no-build");
        return;
    }

    /* EP0 answers, so this is a genuinely healthy unit -- a fresh enumeration
       after a replug or power cycle is exactly the event that invalidates an
       earlier "this unit is wedged" conclusion.  Re-arm recovery here, or the
       first real wedge disables it for the daemon's whole lifetime, including
       after the power cycle that fixed the hardware. */
    gRecoveryFailures = 0;
    gRecoveryDisarmed = 0;
    const uint64_t nowNs = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    if (configured_recently(nowNs, gConfiguredAtNs)) {
        LOG("Hardware already configured %llu ms ago on this handle (USB recovery) — not repeating",
            (unsigned long long)((nowNs - gConfiguredAtNs) / 1000000ull));
        return;
    }
    configure_fpga_routing();
    restore_cached_volume();
}

/* ── CoreAudio device list listener ────────────────────────────────────── */
/*
 * Replaces the old retry timer with an event-driven approach.  Instead of
 * polling 15×2s and then giving up, we permanently listen for device list
 * changes on the system AudioObject.  This handles:
 *   - USB replug at any time (not just a 30s window at startup)
 *   - Sleep/wake cycles where USB re-enumerates
 *   - coreaudiod restarts
 */

dispatch_queue_t gQueue;  /* serial queue for all daemon + audio work */
static int gListenerRegistered = 0;

static OSStatus devices_changed_callback(
    AudioObjectID                inObjectID,
    UInt32                       inNumberAddresses,
    const AudioObjectPropertyAddress* inAddresses,
    void*                        inClientData)
{
    (void)inObjectID; (void)inNumberAddresses; (void)inAddresses; (void)inClientData;

    dispatch_async(gQueue, ^{
        AudioObjectID devID = find_usb_device();

        /* Tell the plugin immediately. The 2s reconcile tick would get there on
           its own, but this callback is the moment the hardware actually left,
           and the gap between the two is a window where the user can still pick
           a device that is not there. */
        maestro_shm_set_presence(gAudioRing,
            devID == kAudioObjectUnknown ? MAESTRO_DEVICE_ABSENT : MAESTRO_DEVICE_PRESENT);

        /* The Symphony is present but under a DIFFERENT id than the one our
           AudioUnit is bound to. This happens on a replug or a port change: the
           device never "disappears" from our point of view, it is simply
           reassigned, so neither the appeared nor the disappeared branch below
           fires and we stay bound to an id that no longer resolves. CoreAudio
           then falls back to the default output and audio comes out of the Mac's
           speakers while every bridge metric still looks healthy. Rebind. */
        if (devID != kAudioObjectUnknown && gOutputUnit
            && gBoundDeviceID != kAudioObjectUnknown && devID != gBoundDeviceID) {
            LOG("USB device id changed %u -> %u — rebinding audio output",
                gBoundDeviceID, devID);
            unregister_rate_listener();
            stop_audio_output();
            close_usb_device();
            init_usb_hardware();
            if (gAudioRing) start_audio_output(gAudioRing);
            return;
        }

        if (devID != kAudioObjectUnknown && !gOutputUnit && gAudioRing) {
            /* USB device appeared and we have shmem — init hardware + start audio */
            LOG("USB device appeared (ID=%u), initializing hardware", devID);
            init_usb_hardware();
            start_audio_output(gAudioRing);
        } else if (devID != kAudioObjectUnknown && !gUSBDev) {
            /* USB device appeared but no USB handle yet — open and configure */
            LOG("USB device appeared (ID=%u), opening USB for hardware control", devID);
            init_usb_hardware();
        } else if (devID == kAudioObjectUnknown && gOutputUnit) {
            /* USB device disappeared — stop audio and close USB.
               Ring buffer stays allocated so ASP side keeps writing
               (data is silently dropped until the device returns). */
            LOG("USB device disappeared, stopping audio output");
            unregister_rate_listener();
            stop_audio_output();
            gBoundDeviceID = kAudioObjectUnknown;
            close_usb_device();
        }
    });
    return noErr;
}

static void register_device_listener(void)
{
    if (gListenerRegistered) return;

    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    OSStatus err = AudioObjectAddPropertyListener(
        kAudioObjectSystemObject, &addr, devices_changed_callback, NULL);
    if (err == noErr) {
        gListenerRegistered = 1;
        LOG("Registered CoreAudio device list listener");
    } else {
        LOG_ERR("AudioObjectAddPropertyListener failed: %d", (int)err);
    }
}

/* Allocate shared memory, send it to ASP via XPC, start audio output.
   Must be called on gQueue (serial) so gAudioRing is set atomically. */
static void setup_audio_shmem(xpc_connection_t peer)
{
    dispatch_async(gQueue, ^{ arm_startup_volume_window(clock_gettime_nsec_np(CLOCK_MONOTONIC)); });
    LOG("setup_audio_shmem: called (gAudioRing=%p, gOutputUnit=%p)",
        (void*)gAudioRing, (void*)gOutputUnit);

    /* Already set up — resend the shmem object to this peer */
    if (gAudioRing) {
        xpc_object_t shm = xpc_shmem_create(gAudioRing, sizeof(MaestroAudioShm));
        if (shm) {
            xpc_object_t reply = xpc_dictionary_create(NULL, NULL, 0);
            xpc_dictionary_set_string(reply, "command", "audioShmem");
            xpc_dictionary_set_value(reply, "shmem", shm);
            xpc_dictionary_set_uint64(reply, "attenuation", gCachedAttenuation);
            xpc_dictionary_set_bool(reply, "muted", gCachedMuted);
            xpc_connection_send_message(peer, reply);
            xpc_release(reply);
            xpc_release(shm);
            LOG("Resent existing audio shmem to reconnecting ASP");
        }
        /* Defer AudioUnit start to avoid coreaudiod deadlock (same reason as below) */
        if (!gOutputUnit) {
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                gQueue,
                ^{
                    if (!gOutputUnit && gAudioRing) {
                        LOG("Deferred audio start (resend path)");
                        start_audio_output(gAudioRing);
                    }
                });
        }
        return;
    }

    if (!ensure_audio_ring()) return;
    /* mach_vm_allocate hands back zeroed pages, so the audio buffer and the
       clock slot both start clean. Fill in the contract the plugin validates;
       clockGen stays 0 until the render callback first publishes, which is how
       the plugin knows the hardware clock is not live yet. */
    memset(gAudioRing, 0, sizeof(MaestroAudioShm));
    gAudioRing->magic         = MAESTRO_SHM_MAGIC;
    gAudioRing->version       = MAESTRO_SHM_VERSION;
    gAudioRing->ringFrames    = MAESTRO_SHM_RING_FRAMES;
    gAudioRing->bytesPerFrame = MAESTRO_SHM_BYTES_PER_FRAME;
    /* Provisional. The real value needs the USB device's buffer size and safety
       offset, which are only known once we have the device -- start_audio_output
       computes it and overwrites this before the plugin can act on it. */
    gAudioRing->delayFrames   = MAESTRO_SHM_MIN_DELAY_FRAMES;
    LOG("Audio shmem allocated at %p (%zu bytes)", (void*)gAudioRing, sizeof(MaestroAudioShm));

    /* Create XPC shmem object and send to ASP */
    xpc_object_t shm = xpc_shmem_create(gAudioRing, sizeof(MaestroAudioShm));
    if (!shm) {
        LOG_ERR("xpc_shmem_create failed");
        return;
    }
    xpc_object_t reply = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(reply, "command", "audioShmem");
    xpc_dictionary_set_value(reply, "shmem", shm);
    xpc_dictionary_set_uint64(reply, "attenuation", gCachedAttenuation);
    xpc_dictionary_set_bool(reply, "muted", gCachedMuted);
    xpc_connection_send_message(peer, reply);
    xpc_release(reply);
    xpc_release(shm);

    LOG("Audio shmem sent to ASP (shm=%p, v%u, ring=%u frames, D=%u frames)",
        (void*)gAudioRing, gAudioRing->version,
        gAudioRing->ringFrames, gAudioRing->delayFrames);

    /* Start a periodic shmem diagnostic to verify sharing works */
    dispatch_source_t timer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
    dispatch_source_set_timer(timer,
        dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
        5 * NSEC_PER_SEC, NSEC_PER_SEC);
    __block int diagCount = 0;
    dispatch_source_set_event_handler(timer, ^{
        if (gAudioRing && diagCount < 10) {
            LOG("SHMEM DIAG #%d: shm=%p clockGen=%u lastWrite=%lld rateScalar=%.9f",
                diagCount, (void*)gAudioRing,
                __atomic_load_n(&gAudioRing->clockGen, __ATOMIC_RELAXED),
                (long long)__atomic_load_n(&gAudioRing->lastWriteFrame, __ATOMIC_RELAXED),
                gAudioRing->rateScalar);
            diagCount++;
        }
    });
    dispatch_resume(timer);

    /* Ensure device listener is registered so we catch USB plug/unplug */
    register_device_listener();

    /* Ensure USB hardware is initialized (FPGA routing configured) */
    if (!gUSBDev) init_usb_hardware();

    /* IMPORTANT: Do NOT start the AudioUnit synchronously here.
       This function runs during the ASP's XPC "requestAudioShmem" handler.
       Creating a HAL AudioUnit calls back into coreaudiod, but coreaudiod is
       still loading our ASP — circular IPC → deadlock.
       Delay by 3s so the ASP finishes initializing in coreaudiod first. */
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
        gQueue,
        ^{
            if (!gOutputUnit && gAudioRing) {
                LOG("Deferred audio start: creating AudioUnit (ASP should be ready)");
                start_audio_output(gAudioRing);
            }
        });
}

/* ── MaestroLink helpers ────────────────────────────────────────────────── */

typedef struct {
    int      fd;
    uint32_t msgCounter;
    uint32_t deviceControllerID;
    int      connected;
} DaemonConn;

static void write_le32(uint8_t *buf, uint32_t v) {
    buf[0] = (uint8_t)(v);
    buf[1] = (uint8_t)(v >> 8);
    buf[2] = (uint8_t)(v >> 16);
    buf[3] = (uint8_t)(v >> 24);
}

static uint32_t read_le32(const uint8_t *buf) {
    return (uint32_t)buf[0]
         | ((uint32_t)buf[1] << 8)
         | ((uint32_t)buf[2] << 16)
         | ((uint32_t)buf[3] << 24);
}

/* Send all bytes, handling partial writes. Returns 0 on success. */
static int send_all(int fd, const uint8_t *data, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = write(fd, data + sent, len - sent);
        if (n <= 0) return -1;
        sent += (size_t)n;
    }
    return 0;
}

/* Read one framed message (8-byte header + payload). Caller frees result.
   timeout_sec: socket receive timeout. Legacy uses 10s for registration, 1s for ops. */
static uint8_t *read_message(int fd, uint32_t *out_size, int timeout_sec) {
    uint8_t hdr[8];
    struct timeval tv = { .tv_sec = timeout_sec, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    size_t got = 0;
    while (got < 8) {
        ssize_t n = read(fd, hdr + got, 8 - got);
        if (n <= 0) return NULL;
        got += (size_t)n;
    }

    uint32_t magic = read_le32(hdr);
    uint32_t psize = read_le32(hdr + 4);
    if (magic != MAGIC || psize == 0 || psize > 65536) return NULL;

    uint8_t *buf = malloc(8 + psize);
    if (!buf) return NULL;
    memcpy(buf, hdr, 8);

    size_t read_got = 0;
    while (read_got < psize) {
        ssize_t n = read(fd, buf + 8 + read_got, psize - read_got);
        if (n <= 0) { free(buf); return NULL; }
        read_got += (size_t)n;
    }
    *out_size = 8 + psize;
    return buf;
}

/* Skip PropertyChanged notifications, return first Response message. */
static uint8_t *read_response(int fd, uint32_t *out_size, int timeout_sec) {
    for (int i = 0; i < 16; i++) {
        uint8_t *msg = read_message(fd, out_size, timeout_sec);
        if (!msg) return NULL;
        /* objectType is at offset 8+4 = 12 */
        if (*out_size >= 16) {
            uint32_t obj_type = read_le32(msg + 12);
            if (obj_type == OBJ_RESPONSE)    return msg;
            if (obj_type == OBJ_PROP_CHANGED) { free(msg); continue; }
        }
        free(msg);
    }
    return NULL;
}

/* Connect and register with the Apogee daemon. Returns 0 on success. */
static int daemon_connect(DaemonConn *c) {
    if (c->connected) return 0;

    c->fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (c->fd < 0) {
        LOG_ERR("socket() failed: %d", errno);
        return -1;
    }

    signal(SIGPIPE, SIG_IGN);

    struct sockaddr_un addr = {0};
    addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, SOCKET_PATH, sizeof(addr.sun_path));

    if (connect(c->fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        LOG_ERR("connect() to daemon failed: %d", errno);
        close(c->fd);
        c->fd = -1;
        return -1;
    }

    /* Build registration frame */
    size_t uid_len    = strlen(kDeviceUID) + 1;
    size_t bundle_len = strlen(kBundleID)  + 1;
    size_t payload    = 12 + 16 + 12 + uid_len + bundle_len;
    uint8_t *frame    = calloc(1, 8 + payload);
    if (!frame) { close(c->fd); c->fd = -1; return -1; }

    uint8_t *p = frame;
    /* Frame header */
    write_le32(p,   MAGIC);           p += 4;
    write_le32(p,   (uint32_t)payload); p += 4;
    /* Transportable (12 bytes) */
    write_le32(p,   (uint32_t)payload); p += 4;
    write_le32(p,   OBJ_REGISTRATION);  p += 4;
    *p++ = 0x4C;                                  /* byteOrder 'L' */
    p += 3;                                       /* padding */
    /* MessageContent (16 bytes) */
    write_le32(p, ++c->msgCounter);   p += 4;
    write_le32(p, PRI_REGISTER);      p += 4;
    write_le32(p, (uint32_t)getpid());p += 4;
    *p++ = MSG_REGISTRATION;                      /* msgType */
    p += 3;                                       /* padding */
    /* RegistrationContent (12 bytes) */
    write_le32(p, 0);                 p += 4;
    write_le32(p, (uint32_t)uid_len); p += 4;
    write_le32(p, (uint32_t)bundle_len); p += 4;
    /* Strings */
    memcpy(p, kDeviceUID,  uid_len);    p += uid_len;
    memcpy(p, kBundleID,   bundle_len);

    int err = send_all(c->fd, frame, 8 + payload);
    free(frame);
    if (err < 0) {
        LOG_ERR("send registration failed");
        close(c->fd); c->fd = -1; return -1;
    }

    /* Read registration response — legacy uses 10× timeout for registration
       because the daemon may take several seconds to initialize USB devices. */
    uint32_t rsize = 0;
    uint8_t *resp = read_response(c->fd, &rsize, 10);
    if (!resp) {
        LOG_ERR("no registration response (10s timeout)");
        close(c->fd); c->fd = -1; return -1;
    }

    if (rsize >= 48 + 4) {
        uint32_t ret_status = read_le32(resp + 36);
        uint32_t data_size  = read_le32(resp + 44);
        if (ret_status == 0 && data_size >= 4)
            c->deviceControllerID = read_le32(resp + 48);
    }
    free(resp);

    c->connected = 1;
    LOG("Connected to daemon (devCtrlID=%u)", c->deviceControllerID);
    return 0;
}

/* Set a UInt32 property on the Apogee daemon. Returns 0 on success. */
static int daemon_set_uint32(DaemonConn *c, uint32_t prop_id,
                              uint32_t channel, int is_input,
                              uint32_t value)
{
    if (!c->connected && daemon_connect(c) < 0) return -1;

#define SET_PROP_PAYLOAD (12 + 16 + 28 + 4)
    const size_t payload = SET_PROP_PAYLOAD;
    uint8_t frame[8 + SET_PROP_PAYLOAD];
    memset(frame, 0, sizeof(frame));
    uint8_t *p = frame;

    write_le32(p, MAGIC);             p += 4;
    write_le32(p, (uint32_t)payload); p += 4;
    write_le32(p, (uint32_t)payload); p += 4;
    write_le32(p, OBJ_SET_PROPERTY);  p += 4;
    *p++ = 0x4C; p += 3;
    write_le32(p, ++c->msgCounter);           p += 4;
    write_le32(p, PRI_SET);                   p += 4;
    write_le32(p, (uint32_t)getpid());        p += 4;
    *p++ = MSG_SET_PROPERTY; p += 3;
    write_le32(p, c->deviceControllerID);     p += 4;
    write_le32(p, 0);                         p += 4;
    write_le32(p, prop_id);                   p += 4;
    write_le32(p, channel);                   p += 4;
    write_le32(p, 0);                         p += 4;
    write_le32(p, 4);                         p += 4;
    *p++ = (uint8_t)(is_input ? 1 : 0); p += 3;
    write_le32(p, value); p += 4;

    if (send_all(c->fd, frame, sizeof(frame)) < 0) {
        LOG_ERR("send SetProperty failed, marking disconnected");
        close(c->fd); c->fd = -1; c->connected = 0;
        return -1;
    }

    uint32_t rsize = 0;
    uint8_t *resp = read_response(c->fd, &rsize, 2);
    if (!resp) {
        LOG_ERR("no SetProperty response");
        close(c->fd); c->fd = -1; c->connected = 0;
        return -1;
    }
    uint32_t status = (rsize >= 40) ? read_le32(resp + 36) : 1;
    free(resp);

    if (status != 0) {
        LOG_ERR("SetProperty 0x%08X status=%u", prop_id, status);
        return -1;
    }
    return 0;
}

/* ── XPC service ────────────────────────────────────────────────────────── */

static DaemonConn gDaemon = { .fd = -1 };

static void handle_peer(xpc_connection_t peer) {
    LOG("New XPC peer connected");
    xpc_connection_set_event_handler(peer, ^(xpc_object_t msg) {
        if (xpc_get_type(msg) == XPC_TYPE_ERROR) {
            LOG("XPC peer disconnected");
            return;
        }

        /* Raw diagnostic — every non-error event, trace tier only.
           xpc_copy_description allocates and formats the entire dictionary, and
           its output is multi-line, so an always-on copy of this was ~95% of the
           log file by volume at metering rate. */
        if (sTrace) {
            char *desc = xpc_copy_description(msg);
            LOG("XPC raw event: type=%s desc=%.200s",
                xpc_get_type(msg) == XPC_TYPE_DICTIONARY ? "dict" : "other",
                desc ? desc : "(null)");
            if (desc) free(desc);
        }

        if (xpc_get_type(msg) != XPC_TYPE_DICTIONARY) return;

        const char *cmd = xpc_dictionary_get_string(msg, "command");
        if (!cmd) return;

        LOG_V("XPC command: %s", cmd);

        if (strcmp(cmd, "setAttenuation") == 0) {
            uint32_t att = (uint32_t)xpc_dictionary_get_uint64(msg, "attenuation");
            if (att > 64) att = 64;

            /* Reply immediately — fire-and-forget silently dropped on macOS 26. */
            xpc_object_t reply = xpc_dictionary_create_reply(msg);
            if (reply) {
                xpc_dictionary_set_int64(reply, "status", 0);
                xpc_connection_send_message(peer, reply);
                xpc_release(reply);
            }

            xpc_retain(peer);
            dispatch_async(gQueue, ^{
                /* Speakers chosen in Line mode: the set is ignored, as the
                   original did (SymphonyIO.cpp:2345-2351). Nothing is kept
                   either, so the speaker level is what it was. */
                uint64_t nowNs = clock_gettime_nsec_np(CLOCK_MONOTONIC);
                if (startup_volume_refusal_should_report(nowNs, att) ||
                    (gVolumeWaitUntilNs != 0 &&
                     !slider_set_admitted(nowNs, &gVolumeWaitUntilNs, att, gCachedAttenuation))) {
                    LOG("setAttenuation %u ignored: the Mac's volume has not been given output %u's level yet",
                        att, gMonitorOutput);
                    report_kept_volume(peer);
                    xpc_release(peer);
                    return;
                }
                MonitorKeyWrite w = monitor_key_write(gMonitorOutput, gSpeakerLineMode, false);
                if (!w.send) {
                    LOG("setAttenuation %u ignored: Speaker is the output and the speaker mode is Line", att);
                    xpc_release(peer);
                    return;
                }
                /* Cache before writing — used by restore_cached_volume() after recovery */
                gCachedAttenuation = (uint8_t)att;
                gHasReceivedVolume = true;
                save_volume_state();
                if (gUSBDev) {
                    set_hw_volume(gMonitorOutput, (uint8_t)att);
                    LOG("setAttenuation %u → USB direct (output %u)", att, gMonitorOutput);
                } else if (gMonitorOutput == MONITOR_OUTPUT_SPEAKERS) {
                    /* Fallback to daemon if USB not open */
                    daemon_set_uint32(&gDaemon, PROP_OUTPUT_LEVEL, 0, 0, att);
                    LOG("setAttenuation %u → daemon (fallback)", att);
                }
                xpc_release(peer);
            });

        } else if (strcmp(cmd, "setMute") == 0) {
            bool muted = xpc_dictionary_get_bool(msg, "muted");

            /* Reply immediately — fire-and-forget silently dropped on macOS 26. */
            xpc_object_t reply = xpc_dictionary_create_reply(msg);
            if (reply) {
                xpc_dictionary_set_int64(reply, "status", 0);
                xpc_connection_send_message(peer, reply);
                xpc_release(reply);
            }

            xpc_retain(peer);
            dispatch_async(gQueue, ^{
                uint64_t nowNs = clock_gettime_nsec_np(CLOCK_MONOTONIC);
                if (startup_mute_refusal_should_report(nowNs, muted) ||
                    (gMuteWaitUntilNs != 0 &&
                     !slider_set_admitted(nowNs, &gMuteWaitUntilNs,
                                          muted ? 1u : 0u, gCachedMuted ? 1u : 0u))) {
                    LOG("setMute %d ignored: the Mac's mute has not been given output %u's yet",
                        (int)muted, gMonitorOutput);
                    xpc_release(peer);
                    return;
                }
                MonitorKeyWrite w = monitor_key_write(gMonitorOutput, gSpeakerLineMode, true);
                if (!w.send) {
                    LOG("setMute %d ignored: Speaker is the output and the speaker mode is Line", (int)muted);
                    xpc_release(peer);
                    return;
                }
                /* Cache before writing — used by restore_cached_volume() after recovery */
                gCachedMuted = muted;
                save_volume_state();
                if (gUSBDev) {
                    set_hw_mute(gMonitorOutput, muted);
                    LOG("setMute %d → USB direct (output %u)", (int)muted, gMonitorOutput);
                } else if (gMonitorOutput == MONITOR_OUTPUT_SPEAKERS) {
                    daemon_set_uint32(&gDaemon, PROP_OUTPUT_MUTE, 0, 0, muted ? 1 : 0);
                    LOG("setMute %d → daemon (fallback)", (int)muted);
                }
                xpc_release(peer);
            });

        } else if (strcmp(cmd, "setMonitorOutput") == 0) {
            /* Maestro's "Audio Output" choice: which output the volume and
               mute of "Maestro USB" move from now on, with that output's
               current level and mute (read from the unit by Maestro), which
               become the kept ones. Nothing is written to the unit.
               XPC dict: { command, output (1 speakers, 2 HP1, 3 HP2),
               attenuation (0-64), muted }. Refused without all three. */
            uint64_t output = xpc_dictionary_get_uint64(msg, "output");
            uint64_t att = xpc_dictionary_get_uint64(msg, "attenuation");
            bool muted = xpc_dictionary_get_bool(msg, "muted");
            bool complete = xpc_dictionary_get_value(msg, "attenuation") != NULL &&
                            xpc_dictionary_get_value(msg, "muted") != NULL &&
                            monitor_output_valid((uint32_t)output) && att <= 64;
            xpc_object_t reply = xpc_dictionary_create_reply(msg);
            xpc_retain(peer);
            dispatch_async(gQueue, ^{
                if (complete) {
                    gMonitorOutput = (uint32_t)output;
                    gCachedAttenuation = (uint8_t)att;
                    gCachedMuted = muted;
                    gHasReceivedVolume = true;
                    /* Until the Mac's control holds this output's values. */
                    gVolumeWaitUntilNs = gMuteWaitUntilNs = clock_gettime_nsec_np(CLOCK_MONOTONIC) + SLIDER_WAIT_NS;
                    save_volume_state();
                    LOG("setMonitorOutput %u (level %udB atten, mute=%d)", gMonitorOutput,
                        gCachedAttenuation, (int)gCachedMuted);
                } else {
                    LOG_ERR("setMonitorOutput refused: output=%llu attenuation=%llu", output, att);
                }
                if (reply) {
                    xpc_dictionary_set_int64(reply, "status", complete ? 0 : -1);
                    xpc_connection_send_message(peer, reply);
                    xpc_release(reply);
                }
                xpc_release(peer);
            });

        } else if (strcmp(cmd, "setProperty") == 0) {
            /* Generic USB vendor write — the Swift side owns property→USB mapping.
               XPC dict: { command, bRequest, wValue, wIndex, data } */
            uint8_t bReq  = (uint8_t)xpc_dictionary_get_uint64(msg, "bRequest");
            uint16_t wVal = (uint16_t)xpc_dictionary_get_uint64(msg, "wValue");
            uint16_t wIdx = (uint16_t)xpc_dictionary_get_uint64(msg, "wIndex");

            size_t dataLen = 0;
            const void *dataPtr = xpc_dictionary_get_data(msg, "data", &dataLen);
            /* Copy data for async block (XPC message may be released) */
            uint8_t *dataCopy = NULL;
            uint16_t copyLen = 0;
            if (dataPtr && dataLen > 0 && dataLen <= 64) {
                dataCopy = malloc(dataLen);
                if (dataCopy) {
                    memcpy(dataCopy, dataPtr, dataLen);
                    copyLen = (uint16_t)dataLen;
                }
            }

            /* S5: reply AFTER the write completes with the real result, so a failed
               USB vendor write surfaces as a non-zero status the Swift side throws on
               (matching the request-reply model getProperty already uses). */
            xpc_object_t setReply = xpc_dictionary_create_reply(msg);

            xpc_retain(peer);
            dispatch_async(gQueue, ^{
                if (!gUSBDev) {
                    LOG_ERR("setProperty: USB device not open");
                    if (setReply) {
                        xpc_dictionary_set_int64(setReply, "status", -1);
                        xpc_connection_send_message(peer, setReply);
                        xpc_release(setReply);
                    }
                    free(dataCopy);
                    xpc_release(peer);
                    return;
                }
                /* NOTHING takes the preference load lock on a per-command basis.
                   We used to; it was wrong twice over, for 0x10 and for 0x50.

                   In the legacy stack 0xDD is not a per-write mutex at all -- it is a
                   coarse "this device is not ready, do not load preferences" lifecycle
                   flag. Every caller confirms it: set on sleep, shutdown and restart,
                   cleared on wake (SymphonyIOSymphonyPeripheralDevice.cpp:260,279,298,320
                   and the identical block in SymphonyIOUSBAudioDeviceController.cpp:
                   233,253,273,295), and taken ONCE around a whole
                   ApplySettingsToHardware() batch, released once via SetPeripheralReady()
                   (SymphonyIO.cpp:4708, body :4712-4733).

                   Two further callers exist and neither weakens that, but both were
                   described wrongly here before, so state them exactly:
                     - SymphonyIO.cpp:1142 sets the lock for a firmware version mismatch,
                       but it is dead code: the whole block :1104-:1152 is inside
                       "#if 0 // Version mis-match handling". It never runs.
                     - SymphonyIO.cpp:6329-6337 (GetChangesFromHW) is a READER, not a
                       setter: it reads the lock, usleep(200000)s and returns early so it
                       does not poll hardware mid-batch. It is inside
                       "#ifndef DAEMON_IS_SYMPHONYIOUSB", i.e. excluded from the USB
                       daemon build this proxy replaces.
                   So: no live caller takes the lock per command.

                   0x10 (frontPanelMeterShow) is not in this set. Apogee's
                   runtime path for a meter-source change sends ONE bare 0x10 and takes
                   no lock at all (og_source/maestrolink/Software/SymphonyIO.cpp:2578-2628,
                   the kmAEstroPropertyMetersShowInput handler). Their 0xDD is a coarse
                   batch gate, taken once around a whole ApplySettingsToHardware() run and
                   released once via SetPeripheralReady() -- which reads the lock back and
                   retries 10x/5ms because it can fail (SymphonyIO.cpp:4708, :4712-4733).
                   Wrapping each meter write turned one EP0 transfer into three plus an
                   XMOS mute/unmute cycle, fired blind with both 0xDD results ignored, and
                   a 0x30 meter read timed out immediately afterwards in both hardware
                   failures. The positive claim -- that changing which bank the front-panel
                   LEDs display needs no FPGA reconfigure and no output mute -- is NOT
                   established by our logs; what is established is that Apogee did not
                   take the lock for it, which is the only reason we stopped doing so.
                   See Docs/Learnings.md 2026-09-11 (night).

                   0x50 (clockMode) is not in it either. Note the claim is NOT that only
                   one path emits 0x50 -- setClockMode has at least seven callers
                   (SymphonyIO_IOBoard.cpp:68, OpticalIn_SymphonyIO_Stream.cpp:121,
                   AESIn_SymphonyIO_Stream.cpp:83, DA16AESIn_SymphonyIO_Stream.cpp:57,
                   DA16OpticalIn_SymphonyIO_Stream.cpp:41, five sites inside
                   SymphonyIO::SetClockSource itself (SymphonyIO.cpp:4764,4766,4777,4783,
                   4788, reached from reconfigClock at :4741), and SymphonyIO.cpp:4691 in
                   ApplySettingsToHardware, which IS under the coarse batch lock). The
                   claim is narrower and holds: no path asserts the lock FOR a 0x50.
                   setClockMode itself does NOT set it -- it READS
                   it (SymphonyIOControl.cpp:960-961), sends one bare 0x50
                   (SendRequest(true, SymphonyIOCommands_ClockMode, ...), :1012-1017), then
                   polls getPreferenceLoadLock up to 10x/1000us until the lock returns to
                   the value it had BEFORE the write, failing the call if it never settles
                   (:1019-1035). The firmware perturbs the lock while applying a clock
                   change; the daemon waits for it to come back. It is a settle BARRIER the
                   daemon observes, not a mute the daemon asserts -- so clamping it around
                   our own 0x50 inverted the mechanism.

                   TODO: implement that read-back barrier after a 0x50. Deliberately not
                   done here: it adds EP0 reads, and an EP0 read timing out
                   (0xE0004051 on 0x30) is the unexplained failure we are still chasing.
                   Adding more EP0 reads before understanding that would be backwards.
                   The accepted cost of deferring, stated plainly: legacy returns -1 from
                   setClockMode when the lock never settles within 10x1000us, so the
                   firmware genuinely can fail to apply a clock change. We do not check,
                   so a clock change can report status 0 to the app without having been
                   applied. Symptom to expect: the UI shows the new clock source while the
                   hardware stays on the old one. */
                /* Reconstruct nValue from wValue/wIndex for usb_vendor_write */
                uint32_t nValue = ((uint32_t)wVal << 16) | (uint32_t)wIdx;
                int err = usb_vendor_write(bReq, nValue, dataCopy, copyLen);
                int mixerVal = mixer_param_payload(bReq, dataCopy, copyLen);
                if (mixerVal >= 0)
                    LOG("setProperty cmd=0x%02X wVal=%u wIdx=%u len=%u val=%d: %s",
                        bReq, wVal, wIdx, copyLen, mixerVal, err ? "FAILED" : "OK");
                else
                    LOG("setProperty cmd=0x%02X wVal=%u wIdx=%u len=%u: %s",
                        bReq, wVal, wIdx, copyLen, err ? "FAILED" : "OK");
                /* The speaker mode decides whether the speakers can be moved
                   by the keys (Off, i.e. Line: they cannot). */
                if (!err && (note_speaker_mode(bReq, nValue, dataCopy, copyLen) ||
                             note_speaker_level(bReq, nValue, dataCopy, copyLen)))
                    save_volume_state();
                if (!err && digital_setting_index(bReq) >= 0 && nValue <= 1 &&
                    note_digital_write(bReq, nValue, dataCopy, copyLen,
                                       current_board_type(nValue)))
                    save_digital_state();
                if (setReply) {
                    xpc_dictionary_set_int64(setReply, "status", err ? -1 : 0);
                    xpc_connection_send_message(peer, setReply);
                    xpc_release(setReply);
                }
                free(dataCopy);
                xpc_release(peer);
            });

        } else if (strcmp(cmd, "getProperty") == 0) {
            /* Generic USB vendor read — request-reply.
               XPC dict: { command, bRequest, wValue, wIndex, dataLength }
               Reply: { status, data } */
            uint8_t bReq  = (uint8_t)xpc_dictionary_get_uint64(msg, "bRequest");
            uint16_t wVal = (uint16_t)xpc_dictionary_get_uint64(msg, "wValue");
            uint16_t wIdx = (uint16_t)xpc_dictionary_get_uint64(msg, "wIndex");
            uint16_t dLen = (uint16_t)xpc_dictionary_get_uint64(msg, "dataLength");
            if (dLen > 64) dLen = 64;

            /* Need to send reply — retain connection info from the message */
            xpc_object_t replyMsg = xpc_dictionary_create_reply(msg);
            if (!replyMsg) {
                LOG_ERR("getProperty: cannot create reply (fire-and-forget message?)");
                return;
            }

            xpc_retain(peer);
            dispatch_async(gQueue, ^{
                if (!gUSBDev) {
                    xpc_dictionary_set_int64(replyMsg, "status", -1);
                    xpc_connection_send_message(peer, replyMsg);
                    xpc_release(replyMsg);
                    note_getproperty_denied();
                    xpc_release(peer);
                    return;
                }
                note_getproperty_succeeded();

                /* Meter reads only: skip the transfer while backed off, and say so.
                   Other commands (volume, clock, routing) still go through --
                   they are user-initiated and rare, and the caller needs a real
                   answer even on a sick bus. */
                if (bReq == 0x30 && meter_is_backed_off()) {
                    xpc_dictionary_set_int64(replyMsg, "status", -1);
                    xpc_connection_send_message(peer, replyMsg);
                    xpc_release(replyMsg);
                    xpc_release(peer);
                    return;
                }

                uint8_t buf[64];
                memset(buf, 0, sizeof(buf));
                int bytesRead = usb_vendor_read(bReq, wVal, wIdx, buf, dLen);

                if (bytesRead < 0) {
                    xpc_dictionary_set_int64(replyMsg, "status", -1);
                    LOG_ERR("getProperty cmd=0x%02X wVal=%u wIdx=%u: FAILED", bReq, wVal, wIdx);
                    if (bReq == 0x30 && !gMeterBackoffSince) {
                        gMeterBackoffSince = mach_absolute_time();
                        LOG("0x30 read failed — pausing meter polling for %.1fs",
                            METER_BACKOFF_SEC);
                    }
                } else {
                    /* One good read clears the backoff immediately; there is no
                       reason to keep meters dark once EP0 is answering again. */
                    if (bReq == 0x30) gMeterBackoffSince = 0;
                    xpc_dictionary_set_int64(replyMsg, "status", 0);
                    xpc_dictionary_set_data(replyMsg, "data", buf, (size_t)bytesRead);

                    /* TDM meter payload dump, throttled. Prints index=value for
                       every word above the silence threshold (0x40); 14-bit
                       level, bit 15 is the over flag.

                       ECHO flag (measured 2026-09-10): the XMOS EP0 handler
                       answers from an uninitialised stack buffer and always
                       ships the host's full wLength, however few bytes the Core3
                       supplied (SymphonyIOVendorSpecifics.xc:15,60,109-113).
                       When bytes 32-39 of the reply are this very request's
                       setup packet {C0 30 wValue 00 00 40 00} the payload is
                       stack residue, not meter data -- every read command on
                       the dev unit returns the same bytes at 12-31. The app
                       detects the same fingerprint and stops trusting the
                       output/mixer groups. Correct behaviour in this log is
                       values that CHANGE between dumps and no ECHO tag. */
                    if (sVerbose && bReq == 0x30) {   /* SymphonyIOCommands_TDMMeterData */
                        static uint64_t sDumpCount = 0;
                        if (++sDumpCount % 40 == 0) {
                            char line[512]; int n = 0;
                            for (int w = 0; w * 2 + 1 < bytesRead && n < (int)sizeof(line) - 24; w++) {
                                uint16_t raw = (uint16_t)buf[w * 2] | ((uint16_t)buf[w * 2 + 1] << 8);
                                uint16_t lvl = raw & 0x3FFF;
                                if (lvl > 0x40)
                                    n += snprintf(line + n, sizeof(line) - n, "[%d]=%u%s ",
                                                  w, lvl, (raw & 0x8000) ? "!" : "");
                            }
                            bool echo = bytesRead >= 40
                                     && buf[32] == 0xC0 && buf[33] == 0x30
                                     && buf[34] == (uint8_t)(wVal & 0xFF)
                                     && buf[35] == (uint8_t)(wVal >> 8)
                                     && buf[36] == 0 && buf[37] == 0
                                     && buf[38] == (uint8_t)(dLen & 0xFF)
                                     && buf[39] == (uint8_t)(dLen >> 8);
                            LOG("METERDUMP grp=%u: %s%s", wVal, n ? line : "(all silent)",
                                echo ? " [ECHO: bytes 32-39 are this request's setup packet -- "
                                       "XMOS EP0 stack residue, firmware returned no meter data]" : "");
                        }
                    }

                    LOG_V("getProperty cmd=0x%02X wVal=%u wIdx=%u → %d bytes",
                          bReq, wVal, wIdx, bytesRead);
                }

                xpc_connection_send_message(peer, replyMsg);
                xpc_release(replyMsg);
                xpc_release(peer);
            });

        } else if (strcmp(cmd, "getSoftwareMeterLevels") == 0) {
            /* Return peak levels measured in the render callback, then reset.
               Response: "levels"   = 8 bytes = 2 × float32 (L, R), linear 0..1
                         "levels16" = MAESTRO_SHM_CHANNELS × float32, one per USB
                                      playback channel ([0]/[1] == L/R). */
            float peaks[2] = { gSwReturnPeakL, gSwReturnPeakR };
            float peaks16[MAESTRO_SHM_CHANNELS];
            peaks16[0] = gSwReturnPeakL;
            peaks16[1] = gSwReturnPeakR;
            for (unsigned ch = 2; ch < MAESTRO_SHM_CHANNELS; ch++) {
                peaks16[ch] = gSwPeak[ch];
                gSwPeak[ch] = 0.0f;
            }
            gSwReturnPeakL = 0.0f;
            gSwReturnPeakR = 0.0f;
            xpc_object_t reply = xpc_dictionary_create_reply(msg);
            if (reply) {
                xpc_dictionary_set_data(reply, "levels", peaks, sizeof(peaks));
                xpc_dictionary_set_data(reply, "levels16", peaks16, sizeof(peaks16));
                xpc_connection_send_message(peer, reply);
            }
        } else if (strcmp(cmd, "helperVersion") == 0) {
            /* Which helper this is (see MAESTRO_HELPER_VERSION). */
            xpc_object_t reply = xpc_dictionary_create_reply(msg);
            if (reply) {
                xpc_dictionary_set_uint64(reply, "helperVersion", MAESTRO_HELPER_VERSION);
                /* The output the volume and mute move now, so that Maestro
                   only sends "setMonitorOutput" when it differs. Read without
                   the queue: a stale answer costs one repeated command. */
                xpc_dictionary_set_uint64(reply, "monitorOutput", gMonitorOutput);
                xpc_connection_send_message(peer, reply);
                xpc_release(reply);
            }
        } else if (strcmp(cmd, "setMixerParam") == 0) {
            /* Dedicated mixer parameter command — bypasses generic setProperty.
               Covers fader (0xB0), pan (0xB1), solo (0xB2), mute (0xB3).
               nValue = (mixer << 16) | channel, data = 1 byte. */
            uint8_t usbCmd   = (uint8_t)xpc_dictionary_get_uint64(msg, "usbCmd");
            uint16_t mixer   = (uint16_t)xpc_dictionary_get_uint64(msg, "mixer");
            uint16_t channel = (uint16_t)xpc_dictionary_get_uint64(msg, "channel");
            uint8_t value    = (uint8_t)xpc_dictionary_get_uint64(msg, "value");

            /* Reply immediately — fire-and-forget messages from user processes
               to LaunchDaemons are silently dropped on macOS 26. */
            xpc_object_t reply = xpc_dictionary_create_reply(msg);
            if (reply) {
                xpc_dictionary_set_int64(reply, "status", 0);
                xpc_connection_send_message(peer, reply);
                xpc_release(reply);
            }

            dispatch_async(gQueue, ^{
                if (!gUSBDev) {
                    LOG_ERR("setMixerParam: USB device not open");
                    return;
                }
                uint32_t nValue = ((uint32_t)mixer << 16) | (uint32_t)channel;
                uint8_t val = value;
                int err = usb_vendor_write(usbCmd, nValue, &val, 1);
                LOG("setMixerParam cmd=0x%02X mixer=%u ch=%u val=%u: %s",
                    usbCmd, mixer, channel, value, err ? "FAILED" : "OK");
            });

        } else if (strcmp(cmd, "setSwReturnMute") == 0) {
            /* Software mute — zeros ch1-2 of the "Maestro USB" render while
               software processing is on. Maestro decides when: only while a
               mixer on USB 1-2 feeds an output (see gSwReturnMuted). */
            int muted = (int)xpc_dictionary_get_int64(msg, "muted");
            atomic_store_explicit(&gSwReturnMuted, muted, memory_order_relaxed);
            LOG("SW Return software mute: %s", muted ? "MUTED" : "unmuted");

            /* Reply — fire-and-forget silently dropped on macOS 26. */
            xpc_object_t reply = xpc_dictionary_create_reply(msg);
            if (reply) {
                xpc_dictionary_set_int64(reply, "status", 0);
                xpc_connection_send_message(peer, reply);
                xpc_release(reply);
            }
        } else if (strcmp(cmd, "setSwReturnLevel") == 0) {
            /* Software level for USB channels 1-2, applied only while software
               processing is on. Maestro keeps it at 0 dB: the unit's mixer owns
               the Software Return fader (0xB0, strip 32).
               Input: dB value (double). -48 to +6 range, or <= -96 for silence. */
            double dB = xpc_dictionary_get_double(msg, "dB");
            float gain;
            if (dB <= -96.0) {
                gain = 0.0f;
            } else {
                gain = powf(10.0f, (float)dB / 20.0f);
            }
            atomic_store_explicit(&gSwReturnGain, gain, memory_order_relaxed);
            atomic_store_explicit(&gSwReturnGainL, gain, memory_order_relaxed);
            atomic_store_explicit(&gSwReturnGainR, gain, memory_order_relaxed);
            LOG("SW Return software level: %.1f dB → gain %.4f", dB, gain);

            xpc_object_t reply = xpc_dictionary_create_reply(msg);
            if (reply) {
                xpc_dictionary_set_int64(reply, "status", 0);
                xpc_connection_send_message(peer, reply);
                xpc_release(reply);
            }

        } else if (strcmp(cmd, "setSwReturnChannelLevel") == 0) {
            int channel = xpc_dictionary_get_int64(msg, "channel") == 0 ? 0 : 1;
            double dB = xpc_dictionary_get_double(msg, "dB");
            float gain = dB <= -96.0 ? 0.0f : powf(10.0f, (float)dB / 20.0f);
            if (channel == 0) {
                atomic_store_explicit(&gSwReturnGainL, gain, memory_order_relaxed);
            } else {
                atomic_store_explicit(&gSwReturnGainR, gain, memory_order_relaxed);
            }
            LOG("SW Return independent level ch%d: %.1f dB -> gain %.4f", channel + 1, dB, gain);
            xpc_object_t reply = xpc_dictionary_create_reply(msg);
            if (reply) {
                xpc_dictionary_set_int64(reply, "status", 0);
                xpc_connection_send_message(peer, reply);
                xpc_release(reply);
            }

        } else if (strcmp(cmd, "setSwReturnProcessing") == 0) {
            /* Whether the software gain/mute stage processes USB 1-2: on only
               while a mixer on USB 1-2 feeds an output (the app's rule). */
            int enabled = xpc_dictionary_get_int64(msg, "enabled") != 0;
            atomic_store_explicit(&gSwReturnSoftwareProcessing, enabled, memory_order_relaxed);
            LOG("SW Return software processing: %s", enabled ? "enabled" : "disabled");

            xpc_object_t reply = xpc_dictionary_create_reply(msg);
            if (reply) {
                xpc_dictionary_set_int64(reply, "status", 0);
                xpc_connection_send_message(peer, reply);
                xpc_release(reply);
            }

        } else if (strcmp(cmd, "setLatencyTuning") == 0) {
            /* Measurement aid: the IO buffer, slack and floor the ring delay is
               computed from (0 = default), then the output is rebuilt with them.
               Clamped so no value can lap the ring. Not saved: a helper restart
               goes back to the defaults. */
            uint64_t buf = xpc_dictionary_get_uint64(msg, "bufferFrames");
            uint64_t margin = xpc_dictionary_get_uint64(msg, "jitterMargin");
            uint64_t floor = xpc_dictionary_get_uint64(msg, "minDelay");
            gTuneBufferFrames = buf > 4096 ? 4096 : (uint32_t)buf;
            gTuneJitterMargin = margin > 4096 ? 4096 : (uint32_t)margin;
            gTuneMinDelay     = floor > 8192 ? 8192 : (uint32_t)floor;
            LOG("setLatencyTuning: buffer=%u margin=%u floor=%u", gTuneBufferFrames, gTuneJitterMargin, gTuneMinDelay);
            xpc_object_t reply = xpc_dictionary_create_reply(msg);
            if (reply) {
                xpc_dictionary_set_int64(reply, "status", 0);
                xpc_connection_send_message(peer, reply);
                xpc_release(reply);
            }
            dispatch_async(gQueue, ^{
                stop_audio_output();
                if (gAudioRing) start_audio_output(gAudioRing);
            });
        } else if (strcmp(cmd, "getLatencyStats") == 0) {
            /* Measurement aid: the ring delay now, dropouts (late writes) and
               the worst headroom since the output started or was retuned. */
            MaestroAudioShm* shm = gAudioRing;
            xpc_object_t reply = xpc_dictionary_create_reply(msg);
            if (reply) {
                xpc_dictionary_set_uint64(reply, "delayFrames", shm ? __atomic_load_n(&shm->delayFrames, __ATOMIC_RELAXED) : 0);
                xpc_dictionary_set_uint64(reply, "lateWrites", shm ? __atomic_load_n(&shm->lateWrites, __ATOMIC_RELAXED) : 0);
                int64_t worst = atomic_load_explicit(&gWorstHeadroom, memory_order_relaxed);
                xpc_dictionary_set_int64(reply, "worstHeadroom", worst == INT64_MAX ? 0 : worst);
                xpc_dictionary_set_bool(reply, "headroomSeen", worst != INT64_MAX);
                xpc_dictionary_set_double(reply, "rate", gHwNominalRate);
                xpc_dictionary_set_uint64(reply, "bufferFrames", gTuneBufferFrames);
                xpc_connection_send_message(peer, reply);
                xpc_release(reply);
            }
        } else if (strcmp(cmd, "resetAudioOutput") == 0) {
            /* Tear down and recreate the HAL AudioUnit targeting the USB device.
               Fixes stale AudioUnit sessions after FPGA reconfiguration commands
               that disrupt the audio chain without requiring a Mac reboot. */
            LOG("resetAudioOutput: tearing down AudioUnit...");

            /* Reply immediately — fire-and-forget silently dropped on macOS 26. */
            xpc_object_t reply = xpc_dictionary_create_reply(msg);
            if (reply) {
                xpc_dictionary_set_int64(reply, "status", 0);
                xpc_connection_send_message(peer, reply);
                xpc_release(reply);
            }

            dispatch_async(gQueue, ^{
                stop_audio_output();
                if (gAudioRing) {
                    LOG("resetAudioOutput: recreating AudioUnit...");
                    start_audio_output(gAudioRing);
                } else {
                    LOG("resetAudioOutput: no ring buffer — skipping recreate");
                }
            });
        } else if (strcmp(cmd, "setHardwareRate") == 0) {
            /* Move the REAL USB device's sample rate.
             *
             * The virtual device cannot change its own rate: slots in the shared
             * ring are named in hardware frames, so the hardware has to move
             * first and the virtual device follows. That is correct, and it is
             * also why the Format popup in Audio MIDI Setup did nothing when it
             * was pointed at Maestro USB -- the plugin refused, and had no way to
             * pass the request on to anything that could say yes.
             *
             * This is that way. We are already the process that owns the HAL
             * AudioUnit on the real device, so we can set its rate directly. The
             * nominal-rate listener then fires, the AudioUnit is rebuilt at the
             * new rate, the new rate is published in shared memory, and the
             * plugin follows it -- the same path a rate change made on
             * "Symphony I/O (USB Audio)" already takes.
             */
            double rate = xpc_dictionary_get_double(msg, "rate");

            xpc_object_t reply = xpc_dictionary_create_reply(msg);
            if (reply) {
                xpc_dictionary_set_int64(reply, "status", 0);
                xpc_connection_send_message(peer, reply);
                xpc_release(reply);
            }

            dispatch_async(gQueue, ^{
                /* A rate outside anything this hardware runs is a bug upstream,
                   not a request to honour: setting one would strand the virtual
                   device at a rate it can never match. */
                if (!(rate >= 44100.0 && rate <= 192000.0)) {
                    LOG_ERR("setHardwareRate: refusing %.0f Hz — outside the range "
                            "this hardware runs", rate);
                    return;
                }
                AudioObjectID devID = find_usb_device();
                if (devID == kAudioObjectUnknown) {
                    LOG_ERR("setHardwareRate: USB device not available — cannot set %.0f Hz",
                            rate);
                    return;
                }
                if (fabs(rate - gHwNominalRate) < 1.0) {
                    LOG("setHardwareRate: already at %.0f Hz — nothing to do", rate);
                    return;
                }
                AudioObjectPropertyAddress addr = {
                    kAudioDevicePropertyNominalSampleRate,
                    kAudioObjectPropertyScopeGlobal,
                    kAudioObjectPropertyElementMain
                };
                Float64 want = (Float64)rate;
                OSStatus err = AudioObjectSetPropertyData(devID, &addr, 0, NULL,
                                                          sizeof(want), &want);
                if (err != noErr) {
                    LOG_ERR("setHardwareRate: device %u refused %.0f Hz (err %d)",
                            devID, rate, (int)err);
                    return;
                }
                LOG("setHardwareRate: asked device %u to move %.0f Hz -> %.0f Hz",
                    devID, gHwNominalRate, rate);
                /* Deliberately not touching gHwNominalRate here. The listener
                   rebuilds the AudioUnit and re-reads the device, so the rate we
                   publish is the one the hardware actually reached, not the one
                   we asked for. */
            });

        } else if (strcmp(cmd, "requestAudioShmem") == 0) {
            /* ASP is asking for the shared audio ring buffer.
               We allocate it (once), send it back, and start the HAL AudioUnit. */
            xpc_retain(peer);
            dispatch_async(gQueue, ^{
                setup_audio_shmem(peer);
                xpc_release(peer);
            });
        }
    });
    xpc_connection_resume(peer);
}

/* Hard ceiling on /tmp/MaestroVolumeProxy.log, enforced by the proxy itself.
 *
 * launchd points both StandardOutPath and StandardErrorPath at one file and
 * never rotates it, and this daemon runs from boot to shutdown with KeepAlive,
 * so the file only ever grows. It reached 437 MB on the development machine
 * (2026-09-12) at roughly 1 MB/min. Nobody is going to notice that, which is
 * exactly why it has to bound itself rather than rely on being tailed.
 *
 * Truncation rather than rotation because launchd owns the descriptor: it opened
 * this path once at spawn and will not reopen it, so renaming the file would
 * leave every subsequent line going to an unlinked inode and the visible log
 * permanently empty. ftruncate keeps writing to the same descriptor. The lseek
 * afterwards is belt-and-braces for the case where launchd did not pass
 * O_APPEND -- with O_APPEND each write already seeks to the (now zero) end, and
 * without it the offset would stay high and leave a multi-hundred-MB sparse
 * hole that looks exactly like the problem being fixed.
 *
 * Runs on gQueue, never on the render thread: it stats a file.
 */
#define LOG_SIZE_CAP_BYTES   (64ull * 1024ull * 1024ull)
#define LOG_SIZE_CHECK_SECS  60ull

static dispatch_source_t sLogCapTimer;

static void start_log_cap_timer(void) {
    sLogCapTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
    if (!sLogCapTimer) {
        LOG_ERR("Could not create the log size timer — the log will grow unbounded");
        return;
    }
    dispatch_source_set_timer(sLogCapTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(LOG_SIZE_CHECK_SECS * NSEC_PER_SEC)),
                              LOG_SIZE_CHECK_SECS * NSEC_PER_SEC,
                              10ull * NSEC_PER_SEC);
    dispatch_source_set_event_handler(sLogCapTimer, ^{
        struct stat st;
        if (fstat(fileno(stderr), &st) != 0) return;
        if (!S_ISREG(st.st_mode)) return;          /* piped or to a tty: not ours to trim */
        if ((unsigned long long)st.st_size < LOG_SIZE_CAP_BYTES) return;
        fflush(stderr);
        if (ftruncate(fileno(stderr), 0) != 0) {
            LOG_ERR("Log hit %llu MB but could not be truncated: %s",
                    (unsigned long long)(st.st_size / (1024 * 1024)), strerror(errno));
            return;
        }
        lseek(fileno(stderr), 0, SEEK_SET);
        /* First line of the fresh file says what happened, so a truncated log is
           never mistaken for a proxy that just started. */
        LOG("Log reached %llu MB and was truncated (cap %llu MB) — earlier history is gone",
            (unsigned long long)(st.st_size / (1024 * 1024)),
            (unsigned long long)(LOG_SIZE_CAP_BYTES / (1024 * 1024)));
    });
    dispatch_resume(sLogCapTimer);
}

/* ── Sleep, shutdown and restart (A3 / J7) ───────────────────────────────
   As the original's root daemon did (og main.cpp:161-182;
   SymphonyIOUSBAudioDeviceController.cpp:219-301): before the Mac sleeps,
   shuts down or restarts, the unit is locked (PreferenceLoadLock = 1, which
   mutes it) so it makes no noise as USB goes away; when the Mac has woken, it
   is unlocked. A re-enumeration at wake also unlocks (init_usb_hardware). No
   lock on SIGTERM: an update restarts this helper and must leave audio on. */
typedef enum { POWER_NONE, POWER_LOCK, POWER_UNLOCK } PowerAction;

static PowerAction power_action(natural_t message)
{
    switch (message) {
    case kIOMessageSystemWillSleep:
    case kIOMessageSystemWillPowerOff:
    case kIOMessageSystemWillRestart:
        return POWER_LOCK;
    case kIOMessageSystemHasPoweredOn:
        return POWER_UNLOCK;
    default:
        return POWER_NONE;
    }
}

static io_connect_t gPowerRoot = MACH_PORT_NULL;
/* True from the moment a lock is attempted until an unlock succeeds. A lock
   that reached the unit but returned an error (USB going down) still counts,
   so the unlock at wake is always tried. */
static bool gLockedForPower = false;
/* Bumped by every lock or unlock request, so a pending unlock retry from an
   earlier wake never unlocks a later sleep's lock. */
static unsigned gPowerLockGeneration = 0;

/* Whether the unit may still be locked after a lock (lock true) or unlock
   attempt that returned err. */
static bool power_lock_held_after(bool lock, int err)
{
    return lock || err != 0;
}

static void power_unlock_retry(unsigned generation);

static void set_power_lock(bool lock)
{
    gPowerLockGeneration++;
    if (!gUSBDev) { gLockedForPower = false; return; }   /* re-enumeration unlocks in configure_fpga_routing */
    uint8_t value = lock ? 1 : 0;
    int err = -1;
    for (int attempt = 0; attempt < 3 && err != 0; attempt++) {
        err = usb_vendor_write(VCMD_PREF_LOAD_LOCK, 0, &value, 1);
        if (err && !lock) usleep(200 * 1000);
        if (lock) break;   /* going to sleep: one try, never delay the Mac */
    }
    gLockedForPower = power_lock_held_after(lock, err);
    LOG("Power: PreferenceLoadLock(%s) %s", lock ? "true" : "false", err ? "FAILED" : "OK");
    if (!lock && err) power_unlock_retry(gPowerLockGeneration);
}

/* An unlock that failed is tried again every five seconds until it succeeds,
   the unit goes away, or the Mac locks it again for another sleep. */
static void power_unlock_retry(unsigned generation)
{
    if (!gQueue) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), gQueue, ^{
        if (generation != gPowerLockGeneration || !gLockedForPower) return;
        LOG("Power: retrying the unlock after wake");
        set_power_lock(false);
    });
}

static void power_callback(void *refcon, io_service_t service, natural_t message, void *argument)
{
    (void)refcon; (void)service;
    const PowerAction action = power_action(message);
    if (action == POWER_LOCK) set_power_lock(true);
    /* A shutdown or restart that does not happen (cancelled after this
       message) must not leave the unit muted: unlock if the Mac is still up
       a minute later. */
    if (message == kIOMessageSystemWillPowerOff || message == kIOMessageSystemWillRestart) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), gQueue, ^{
            if (gLockedForPower) { LOG("Power: still running a minute after shutdown/restart was announced; unlocking"); set_power_lock(false); }
        });
    }
    else if (action == POWER_UNLOCK && gLockedForPower) set_power_lock(false);   /* always tried after an attempted lock */
    if (message == kIOMessageCanSystemSleep || message == kIOMessageSystemWillSleep)
        IOAllowPowerChange(gPowerRoot, (long)argument);
}

static void register_power_notifications(void)
{
    static IONotificationPortRef port = NULL;
    io_object_t notifier = 0;
    gPowerRoot = IORegisterForSystemPower(NULL, &port, power_callback, &notifier);
    if (gPowerRoot == MACH_PORT_NULL) { LOG_ERR("Power: IORegisterForSystemPower failed"); return; }
    IONotificationPortSetDispatchQueue(port, gQueue);
    LOG("Power: watching sleep, shutdown and restart");
}

int main(void) {
    sLog  = os_log_create("com.danielraffel.Maestro.volumeproxy", "main");
    sVerbose = (getenv("MAESTRO_PROXY_DEBUG") != NULL) ? 1 : 0;
    sTrace   = (getenv("MAESTRO_PROXY_TRACE") != NULL) ? 1 : 0;
    gQueue = dispatch_queue_create("com.danielraffel.Maestro.volumeproxy.daemon",
                                   DISPATCH_QUEUE_SERIAL);

    LOG("MaestroVolumeProxy starting (pid %d)", getpid());

    /* Load persisted volume/mute state from previous run (survives proxy restarts) */
    load_volume_state();
    load_digital_state();

    /* Open USB device directly and configure FPGA routing.
       This bypasses the Apogee daemon which can't detect devices on macOS 26. */
    dispatch_async(gQueue, ^{ init_usb_hardware(); });

    /* Also try daemon connection as fallback (may not work on macOS 26) */
    dispatch_async(gQueue, ^{ daemon_connect(&gDaemon); });

    /* Register CoreAudio device listener — handles USB plug/unplug/sleep/wake */
    dispatch_async(gQueue, ^{
        ensure_audio_ring();
        register_device_listener();
        start_reconcile_timer();
        start_log_cap_timer();
    });

    xpc_connection_t listener = xpc_connection_create_mach_service(
        "com.danielraffel.Maestro.volumeproxy",
        NULL,
        XPC_CONNECTION_MACH_SERVICE_LISTENER);

    if (!listener) {
        LOG_ERR("Failed to create XPC listener — not running as LaunchDaemon?");
        return 1;
    }

    xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) == XPC_TYPE_CONNECTION) {
            handle_peer((xpc_connection_t)peer);
        }
    });
    xpc_connection_resume(listener);

    register_power_notifications();

    LOG("Listening on com.danielraffel.Maestro.volumeproxy");
    dispatch_main();
    return 0;
}
