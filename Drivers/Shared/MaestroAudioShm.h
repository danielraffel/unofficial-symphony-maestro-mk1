/// MaestroAudioShm.h — shared-memory contract between the AudioServerPlugin
/// (Drivers/AudioServerPlugin/ApogeeDriver.cpp, C++) and MaestroVolumeProxy
/// (Drivers/VolumeProxy/MaestroVolumeProxy.c, C).
///
/// Both processes compile this header, so the layout cannot drift.
///
/// ── Why v2 replaced the v1 FIFO ──────────────────────────────────────────
///
/// v1 was a head/tail FIFO. The plugin and the proxy ran on two unrelated
/// clocks — the plugin's virtual clock came from mach_absolute_time() at
/// exactly the nominal rate, the proxy's from the Symphony's crystal — and
/// nothing reconciled them. The FIFO silently integrated the difference:
/// ring fill (== real added latency) wandered between 0 ms and 682 ms in an
/// 8.4 h production trace, spending ~70 min pegged full and dropping samples,
/// while the device advertised a constant 11.3 ms. Video players schedule
/// against the advertised number, so A/V drifted by up to ~2/3 s.
///
/// v2 fixes it in two halves, and BOTH are required:
///
///   1. Rate. The plugin slaves its clock to the hardware by overriding
///      GetZeroTimeStampImpl() and deriving its timeline from the anchor
///      published here by the proxy's render callback. Same crystal on both
///      ends, so the rate error goes to zero.
///
///   2. Offset. Clock-slaving alone does NOT make the buffer depth constant —
///      it fixes the slope, not the intercept. Any disturbance (a skipped IO
///      cycle on either side) permanently displaces a FIFO's fill level. So
///      this is no longer a FIFO: the buffer is *indexed by hardware sample
///      time*. The plugin writes each buffer at the slot its timestamp maps
///      to; the proxy reads the slot its own timestamp names. Latency is then
///      `delayFrames` by construction — not history-dependent, not disturbed
///      by overloads, and self-correcting after any re-anchor. A dropped
///      cycle becomes one buffer of silence instead of a permanent offset.
///
/// This is the model Apple describes for zero timestamps: a ring buffer whose
/// position is derived from the device timeline rather than from a write
/// pointer chasing a read pointer.
///
/// The reader ZEROES what it consumes. Without that, audio replays out of the
/// ring when the plugin stops writing (no head/tail means no empty signal).

#ifndef MAESTRO_AUDIO_SHM_H
#define MAESTRO_AUDIO_SHM_H

#include <stdint.h>
#include <string.h>
#include <stddef.h>

#if defined(__cplusplus)
#define MAESTRO_SHM_STATIC_ASSERT(cond, msg) static_assert(cond, msg)
#else
#define MAESTRO_SHM_STATIC_ASSERT(cond, msg) _Static_assert(cond, msg)
#endif

#define MAESTRO_SHM_MAGIC    0x4D414553u  /* 'MAES' */
/* 4: hwNominalRate became variable. Through v3 the proxy held the device at
   48 kHz, so both sides could assume that number; from v4 the proxy binds
   AUHAL at whatever rate the device is at and the plugin follows. A v3 proxy
   paired with a v4 plugin would coerce the rate the plugin is trying to follow,
   so refuse the pair rather than let them fight. */
#define MAESTRO_SHM_VERSION  4u

#define MAESTRO_SHM_CHANNELS        16u
#define MAESTRO_SHM_BYTES_PER_FRAME (MAESTRO_SHM_CHANNELS * 4u)   /* interleaved f32 */
#define MAESTRO_SHM_RING_FRAMES     32768u                        /* power of two: 0.68 s @ 48 kHz */
#define MAESTRO_SHM_RING_MASK       (MAESTRO_SHM_RING_FRAMES - 1u)
#define MAESTRO_SHM_RING_BYTES      (MAESTRO_SHM_RING_FRAMES * MAESTRO_SHM_BYTES_PER_FRAME)

/// Presentation delay D, in hardware frames — computed at runtime, not fixed.
///
/// The plugin stores a buffer destined for hardware frame H at slot H + D, and
/// the proxy reads slot H when the hardware asks for H. So D is exactly the
/// latency this bridge adds.
///
/// D must cover the wallclock gap between the two IO threads, and the first
/// draft of this got the derivation wrong by forgetting that the proxy reads a
/// WHOLE BLOCK UP FRONT. At its wake time t the AUHAL callback is handed
/// X = t + N_proxy + S_usb and reads [X, X + N_proxy), so it needs frames
/// through t + 2*N_proxy + S_usb - 1. The plugin, in the worst case, has only
/// written through t + S_plugin + D - 1 (a cycle that writes near its deadline).
/// Hence:
///
///     D >= 2*N_proxy + S_usb - S_plugin + margin
///
/// N_proxy and S_usb belong to the real USB device and are only knowable in the
/// proxy's own process, so the proxy computes D in start_audio_output() and
/// publishes it in delayFrames. The plugin reads it back and reports it as
/// latency. A fixed constant cannot work: N_plugin is whatever buffer size a
/// client negotiates on the virtual device, so a DAW at 128 frames and a
/// browser at 512 need different margins, and assuming the larger is the only
/// safe choice.
///
/// The constant below is a floor and a fallback for the window before the AU
/// exists — never a substitute for the computed value.
#define MAESTRO_SHM_MIN_DELAY_FRAMES  512u

/// The plugin's own SafetyOffset, i.e. how far ahead of the read point the HAL
/// guarantees it has written. It appears in the inequality above, so both sides
/// must agree on it; the plugin passes this to dp.SafetyOffset.
#define MAESTRO_SHM_PLUGIN_SAFETY     64u

/// Slack for scheduling jitter on either IO thread. The plugin is a sandboxed
/// coreaudiod helper competing for CPU, so this is not ceremonial.
#define MAESTRO_SHM_JITTER_MARGIN     256u

/// Compute D from the real device's geometry. Rounded up to a multiple of 64
/// purely so the logged value is easy to eyeball.
static inline uint32_t maestro_shm_compute_delay(uint32_t proxyBufferFrames,
                                                 uint32_t usbSafetyOffset)
{
    int64_t need = 2 * (int64_t)proxyBufferFrames + (int64_t)usbSafetyOffset
                 - (int64_t)MAESTRO_SHM_PLUGIN_SAFETY + (int64_t)MAESTRO_SHM_JITTER_MARGIN;
    if (need < (int64_t)MAESTRO_SHM_MIN_DELAY_FRAMES) need = MAESTRO_SHM_MIN_DELAY_FRAMES;
    need = (need + 63) & ~(int64_t)63;
    /* Never let D approach the ring size, or writes lap the read point. Half the
       ring still leaves room for the largest write-ahead the HAL can ask for. */
    if (need > (int64_t)(MAESTRO_SHM_RING_FRAMES / 2)) need = MAESTRO_SHM_RING_FRAMES / 2;
    return (uint32_t)need;
}

/// Hardware clock anchor, published by the proxy's render callback and consumed
/// by the plugin's GetZeroTimeStampImpl(). Protected by a seqlock (`clockSeq`
/// odd == write in progress) because it is written from one realtime thread and
/// read from another with no lock available to either.
///
/// NOTE: for an AUHAL output unit, `hwHostTime` is the time the buffer will be
/// HEARD, so it normally sits slightly in the FUTURE. It is still a valid point
/// on the device's timeline — readers must not reject it for that reason.
typedef struct {
    uint32_t magic;
    uint32_t version;

    uint32_t clockSeq;        /* seqlock: odd while the proxy is writing       */
    uint32_t clockGen;        /* bumped when the AU is (re)created: new origin */
    double   hwSampleTime;    /* device sample time at this anchor             */
    uint64_t hwHostTime;      /* mach_absolute_time matching hwSampleTime      */
    double   rateScalar;      /* HAL's smoothed rate estimate (1.0 == nominal) */
    double   hwNominalRate;   /* the USB device's nominal sample rate. NOT a
                                 constant: it changes when the rate changes, and
                                 the plugin re-rates itself to match. Compare it
                                 against your own nominal before trusting a slot
                                 index -- slots are named in HARDWARE frames.  */

    uint32_t ringFrames;      /* geometry, constant after allocation           */
    uint32_t bytesPerFrame;
    uint32_t delayFrames;     /* D, above — proxy owns the value               */

    /* Is the Symphony physically there? Written by the proxy, read by the
       plugin, which hides the virtual device when the answer is no.

       Tri-state on purpose. 0 is "the proxy never said", which is what an older
       proxy paired with a newer plugin produces, and it has to mean PRESENT --
       a plugin that hid the device because the other side was old would take
       the user's audio device away for no reason at all. Only an explicit
       MAESTRO_DEVICE_ABSENT hides anything.

       This reuses a field that was already reserved, so the layout, the
       assertions below, and MAESTRO_SHM_VERSION are all unchanged: a
       mixed-version pair still maps and still runs. */
    uint32_t devicePresence;

    /* Diagnostics only — nothing depends on this. The plugin publishes the last
       slot it wrote; the proxy logs (lastWriteFrame - readFrame) as `depth`.

       NOTE: depth does NOT settle at delayFrames. It settles at
       D + N_plugin + S_plugin - N_proxy - S_usb, plus the phase between the two
       IO threads — roughly 560-1070 frames at typical buffer sizes, measured at
       992 on the dev unit with D=1280. What matters is that it is FLAT: under
       the old open-loop FIFO this number wandered the full 32768-frame ring and
       pegged for over an hour at a stretch.

       The number that proves correctness is minHeadroom, not depth. A late write
       still leaves depth looking plausible; minHeadroom goes negative. */
    int64_t  lastWriteFrame;
    /* Buffers the plugin dropped because they landed behind the read point.
       Must stay at 0. Any growth means delayFrames is too small -- and note the
       alternative to dropping is NOT silence: an un-dropped late write sits in
       the ring until the reader laps to it and plays it out of nowhere. */
    uint32_t lateWrites;
    /* Frames the proxy consumed in its last callback. The late check needs it:
       the proxy reads a whole block [X, X+readFrames), so a write landing
       anywhere INSIDE that block is already too late, not just one before X. */
    uint32_t readFrames;
    /* Producer liveness, written by the AudioServerPlugin and read by the
       proxy. These live in the existing diagnostic padding so the v4 layout
       and mixed-version contract remain unchanged. */
    uint32_t producerActive;
    uint32_t producerEpoch;
    uint64_t producerLastHostTime;
    uint8_t  _pad[32];

    uint8_t  buf[MAESTRO_SHM_RING_BYTES];
} MaestroAudioShm;

/* devicePresence values. See the field. */
#define MAESTRO_DEVICE_UNKNOWN 0u
#define MAESTRO_DEVICE_PRESENT 1u
#define MAESTRO_DEVICE_ABSENT  2u

/// Publish whether the hardware is there. Plain atomic store -- this is a single
/// word that stands alone, so it needs no seqlock and must not take the clock's.
static inline void maestro_shm_set_presence(MaestroAudioShm* s, uint32_t presence)
{
    if (!s) return;
    __atomic_store_n(&s->devicePresence, presence, __ATOMIC_RELEASE);
}

/// Read it back. Anything other than an explicit "absent" reads as present, so
/// an old proxy, a torn field, or a value from a future version can never make
/// the device disappear.
static inline int maestro_shm_device_absent(const MaestroAudioShm* s)
{
    if (!s) return 0;
    return __atomic_load_n(&s->devicePresence, __ATOMIC_ACQUIRE) == MAESTRO_DEVICE_ABSENT;
}

/* A stalled producer is actionable only after I/O was explicitly started and
   at least one producer callback has occurred. A zero lastHostTime therefore
   represents a legitimate idle session, not a failure. */
#define MAESTRO_PRODUCER_STALL_SEC 0.50
static inline int maestro_shm_producer_stalled(const MaestroAudioShm* s,
                                                uint64_t now,
                                                double hostTicksPerSecond)
{
    if (!s || !__atomic_load_n(&s->producerActive, __ATOMIC_ACQUIRE)) return 0;
    const uint64_t last = __atomic_load_n(&s->producerLastHostTime, __ATOMIC_ACQUIRE);
    if (!last || now <= last || !(hostTicksPerSecond > 0.0)) return 0;
    return ((double)(now - last) / hostTicksPerSecond) >= MAESTRO_PRODUCER_STALL_SEC;
}

static inline int maestro_shm_producer_activity_changed(const MaestroAudioShm* s,
                                                         uint64_t previousHostTime)
{
    if (!s) return 0;
    const uint64_t current = __atomic_load_n(&s->producerLastHostTime, __ATOMIC_ACQUIRE);
    return current != 0 && current != previousHostTime;
}

MAESTRO_SHM_STATIC_ASSERT(offsetof(MaestroAudioShm, magic)        ==  0, "layout");
MAESTRO_SHM_STATIC_ASSERT(offsetof(MaestroAudioShm, clockSeq)     ==  8, "layout");
MAESTRO_SHM_STATIC_ASSERT(offsetof(MaestroAudioShm, hwSampleTime) == 16, "layout");
MAESTRO_SHM_STATIC_ASSERT(offsetof(MaestroAudioShm, hwHostTime)   == 24, "layout");
MAESTRO_SHM_STATIC_ASSERT(offsetof(MaestroAudioShm, rateScalar)   == 32, "layout");
MAESTRO_SHM_STATIC_ASSERT(offsetof(MaestroAudioShm, ringFrames)   == 48, "layout");
MAESTRO_SHM_STATIC_ASSERT(offsetof(MaestroAudioShm, lastWriteFrame) == 64, "layout");
MAESTRO_SHM_STATIC_ASSERT(offsetof(MaestroAudioShm, lateWrites) == 72, "layout");
MAESTRO_SHM_STATIC_ASSERT(offsetof(MaestroAudioShm, readFrames) == 76, "layout");
MAESTRO_SHM_STATIC_ASSERT(offsetof(MaestroAudioShm, producerActive) == 80, "layout");
MAESTRO_SHM_STATIC_ASSERT(offsetof(MaestroAudioShm, producerLastHostTime) == 88, "layout");
MAESTRO_SHM_STATIC_ASSERT(offsetof(MaestroAudioShm, devicePresence) == 60, "layout");
MAESTRO_SHM_STATIC_ASSERT(offsetof(MaestroAudioShm, buf)          == 128, "layout");

/* ── Clock anchor: publish / read ─────────────────────────────────────────── */

/// Called from the proxy's realtime render callback. Wait-free.
static inline void maestro_shm_publish_clock(MaestroAudioShm* s,
    double hwSampleTime, uint64_t hwHostTime, double rateScalar,
    double hwNominalRate, uint32_t generation)
{
    uint32_t seq = __atomic_load_n(&s->clockSeq, __ATOMIC_RELAXED);
    __atomic_store_n(&s->clockSeq, seq + 1u, __ATOMIC_RELAXED);  /* odd: writing */
    __atomic_thread_fence(__ATOMIC_RELEASE);

    s->hwSampleTime  = hwSampleTime;
    s->hwHostTime    = hwHostTime;
    s->rateScalar    = rateScalar;
    s->hwNominalRate = hwNominalRate;
    s->clockGen      = generation;

    __atomic_thread_fence(__ATOMIC_RELEASE);
    __atomic_store_n(&s->clockSeq, seq + 2u, __ATOMIC_RELAXED);  /* even: settled */
}

typedef struct {
    double   hwSampleTime;
    uint64_t hwHostTime;
    double   rateScalar;
    double   hwNominalRate;
    uint32_t generation;
} MaestroClockSnapshot;

/// Called from the plugin's realtime GetZeroTimeStampImpl(). Returns 0 if the
/// proxy has never published (generation 0) or the seqlock kept tearing.
static inline int maestro_shm_read_clock(const MaestroAudioShm* s,
                                         MaestroClockSnapshot* out)
{
    for (int attempt = 0; attempt < 8; ++attempt) {
        uint32_t s0 = __atomic_load_n(&s->clockSeq, __ATOMIC_RELAXED);
        if (s0 & 1u) continue;                       /* writer mid-update */
        __atomic_thread_fence(__ATOMIC_ACQUIRE);

        out->hwSampleTime  = s->hwSampleTime;
        out->hwHostTime    = s->hwHostTime;
        out->rateScalar    = s->rateScalar;
        out->hwNominalRate = s->hwNominalRate;
        out->generation    = s->clockGen;

        __atomic_thread_fence(__ATOMIC_ACQUIRE);
        if (__atomic_load_n(&s->clockSeq, __ATOMIC_RELAXED) == s0)
            return out->generation != 0u;
    }
    return 0;
}

/* ── Timeline-indexed access ──────────────────────────────────────────────── */

/// Two's-complement masking gives the correct slot for negative frame numbers
/// too, which happen briefly around a re-anchor.
static inline uint32_t maestro_shm_slot(int64_t frame)
{
    return (uint32_t)((uint64_t)frame & (uint64_t)MAESTRO_SHM_RING_MASK);
}

/// Plugin side: place `frames` of interleaved audio at the slot for `startFrame`.
static inline void maestro_shm_write_at(MaestroAudioShm* s, int64_t startFrame,
                                        const void* src, uint32_t frames)
{
    if (frames > MAESTRO_SHM_RING_FRAMES) frames = MAESTRO_SHM_RING_FRAMES;
    uint32_t pos   = maestro_shm_slot(startFrame);
    uint32_t first = MAESTRO_SHM_RING_FRAMES - pos;
    if (first > frames) first = frames;

    memcpy(s->buf + (size_t)pos * MAESTRO_SHM_BYTES_PER_FRAME, src,
           (size_t)first * MAESTRO_SHM_BYTES_PER_FRAME);
    if (first < frames)
        memcpy(s->buf,
               (const uint8_t*)src + (size_t)first * MAESTRO_SHM_BYTES_PER_FRAME,
               (size_t)(frames - first) * MAESTRO_SHM_BYTES_PER_FRAME);

    __atomic_store_n(&s->lastWriteFrame, startFrame + (int64_t)frames, __ATOMIC_RELAXED);
}

/// Proxy side: take `frames` from the slot for `startFrame`, zeroing as we go so
/// stale audio cannot replay once the plugin stops writing.
static inline void maestro_shm_read_at(MaestroAudioShm* s, int64_t startFrame,
                                       void* dst, uint32_t frames)
{
    if (frames > MAESTRO_SHM_RING_FRAMES) frames = MAESTRO_SHM_RING_FRAMES;
    uint32_t pos   = maestro_shm_slot(startFrame);
    uint32_t first = MAESTRO_SHM_RING_FRAMES - pos;
    if (first > frames) first = frames;

    uint8_t* head = s->buf + (size_t)pos * MAESTRO_SHM_BYTES_PER_FRAME;
    memcpy(dst, head, (size_t)first * MAESTRO_SHM_BYTES_PER_FRAME);
    memset(head, 0,   (size_t)first * MAESTRO_SHM_BYTES_PER_FRAME);

    if (first < frames) {
        uint32_t rest = frames - first;
        memcpy((uint8_t*)dst + (size_t)first * MAESTRO_SHM_BYTES_PER_FRAME,
               s->buf, (size_t)rest * MAESTRO_SHM_BYTES_PER_FRAME);
        memset(s->buf, 0, (size_t)rest * MAESTRO_SHM_BYTES_PER_FRAME);
    }
}

#endif /* MAESTRO_AUDIO_SHM_H */
