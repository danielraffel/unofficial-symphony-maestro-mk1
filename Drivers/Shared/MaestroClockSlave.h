/// MaestroClockSlave.h — the virtual device's clock, as pure arithmetic.
///
/// Extracted from ApogeeDevice so it can be tested without libASPL, without
/// CoreAudio and without real hardware. Every input is a parameter: the caller
/// supplies `now` and the host tick rate, so a test can drive a simulated clock
/// at any drift and replay hours of timeline in milliseconds. That matters here
/// because the bug this code exists to fix took 8.4 hours of production logging
/// to characterise, and a defect that only appears after an hour of drift is not
/// one you want to discover on hardware.
///
/// The job: libASPL's stock GetZeroTimeStampImpl derives the timeline purely
/// from mach_absolute_time() at exactly the nominal rate, so the virtual device
/// ticks on the Mac's crystal while audio physically leaves on the Symphony's.
/// Here we instead evaluate the hardware's own line, published by the proxy's
/// render callback, so both ends tick on the same crystal.
///
/// Contract obligations this must satisfy (AudioServerPlugIn.h):
///   - sample time advances in exact multiples of the period, never backwards
///   - the returned host time is an anchor in the PAST
///   - the seed is constant unless the timeline genuinely breaks

#ifndef MAESTRO_CLOCK_SLAVE_H
#define MAESTRO_CLOCK_SLAVE_H

#include <stdint.h>
#include <math.h>
#include "MaestroAudioShm.h"

/// An anchor older than this means the proxy stopped publishing — hardware
/// unplugged, asleep, AudioUnit torn down, or the daemon died.
#define MAESTRO_CLOCK_STALE_PAST_SEC    0.25
/// For an AUHAL *output* unit the published host time is when the buffer will be
/// HEARD, so it legitimately sits in the future. Only reject absurd values.
#define MAESTRO_CLOCK_ABSURD_FUTURE_SEC 1.0
/// A same-generation jump larger than this is a hardware timeline restart that
/// nobody announced — see maestro_clock_tick.
#define MAESTRO_CLOCK_JUMP_SEC          0.1

typedef enum {
    kMaestroClockFlywheel     = 0,  /* no usable anchor; coasting              */
    kMaestroClockLocked       = 1,  /* tracking the hardware line              */
    kMaestroClockReanchored   = 2,  /* (re)established the mapping this tick   */
    kMaestroClockRateMismatch = 3   /* hardware is at a different nominal rate */
} MaestroClockOutcome;

typedef struct {
    /* configuration */
    double   nominalRate;
    double   periodFrames;
    double   hostTicksPerSecond;
    /* state */
    int      anchored;
    uint32_t anchorGen;
    double   aspToHwOffset;
    double   flywheelAsp;
    uint64_t flywheelHost;
    double   ticksPerFrame;
    int64_t  lastPeriodIndex;
    int64_t  cachedPeriodIndex;
    uint64_t lastZeroHost;
} MaestroClockSlave;

static inline void maestro_clock_init(MaestroClockSlave* c, double nominalRate,
                                      double periodFrames, double hostTicksPerSecond,
                                      uint64_t now)
{
    c->nominalRate        = nominalRate;
    c->periodFrames       = periodFrames;
    c->hostTicksPerSecond = hostTicksPerSecond;
    c->anchored           = 0;
    c->anchorGen          = 0;
    c->aspToHwOffset      = 0.0;
    c->flywheelAsp        = 0.0;
    c->flywheelHost       = now;
    c->ticksPerFrame      = hostTicksPerSecond / nominalRate;
    c->lastPeriodIndex    = -1;
    c->cachedPeriodIndex  = -1;
    c->lastZeroHost       = 0;
}

static inline double maestro_clock_flywheel_at(const MaestroClockSlave* c, uint64_t host)
{
    return c->flywheelAsp + ((double)host - (double)c->flywheelHost) / c->ticksPerFrame;
}

/// Adopt a new nominal rate WITHOUT restarting the timeline.
///
/// maestro_clock_init would do the job but resets flywheelAsp and
/// lastPeriodIndex, which walks the sample time backwards -- forbidden by
/// AudioServerPlugIn.h unless the seed changes too, and a seed change is the
/// hard resync we exist to avoid. So instead: freeze the current value at the
/// OLD slope, switch the slope, and leave the period grid alone. The value is
/// continuous, only the slope moves -- the same trade the re-anchor path makes
/// below, and the same shape libASPL's own stock implementation uses when it
/// notices the rate moved (libaspl-src/src/Device.cpp:1266-1277).
///
/// The anchor is dropped deliberately: the mapping it holds is in the OLD rate's
/// frames and has no meaning in the new one. The next hardware sighting
/// re-anchors, and that path already preserves continuity.
static inline void maestro_clock_rerate(MaestroClockSlave* c, double nominalRate,
                                        uint64_t now)
{
    if (!(nominalRate > 0.0)) return;
    c->flywheelAsp   = maestro_clock_flywheel_at(c, now);
    c->flywheelHost  = now;
    c->nominalRate   = nominalRate;
    c->ticksPerFrame = c->hostTicksPerSecond / nominalRate;
    c->anchored      = 0;
    c->anchorGen     = 0;
    c->aspToHwOffset = 0.0;
}

/// Map one of our sample times onto the hardware timeline. Returns 0 until the
/// hardware clock has been seen at least once.
static inline int maestro_clock_to_hardware(const MaestroClockSlave* c,
                                            double aspSampleTime, int64_t* outHwFrame)
{
    if (!c->anchored) return 0;
    *outHwFrame = (int64_t)llrint(aspSampleTime + c->aspToHwOffset);
    return 1;
}

/// Produce the zero timestamp for this call.
///
/// `hw` may be NULL (or `hwPresent` 0) when no anchor could be read; the clock
/// then coasts on its last known line rather than stalling.
static inline MaestroClockOutcome maestro_clock_tick(
    MaestroClockSlave* c, uint64_t now,
    const MaestroClockSnapshot* hw, int hwPresent,
    double* outSampleTime, uint64_t* outHostTime)
{
    const double hostHz = c->hostTicksPerSecond;
    MaestroClockOutcome outcome = kMaestroClockFlywheel;
    int hwValid = hwPresent && hw != NULL;

    if (hwValid) {
        const double ageSec = ((double)now - (double)hw->hwHostTime) / hostHz;
        if (ageSec > MAESTRO_CLOCK_STALE_PAST_SEC)          hwValid = 0;
        else if (-ageSec > MAESTRO_CLOCK_ABSURD_FUTURE_SEC) hwValid = 0;
        else if (!(hw->rateScalar > 0.5 && hw->rateScalar < 2.0)) hwValid = 0;
        else if (!(hw->hwNominalRate > 0.0))                hwValid = 0;
        else if (fabs(hw->hwNominalRate - c->nominalRate) > 1.0) {
            /* Slots are named in HARDWARE frames while our audio is in OUR
               frames. That identity holds only while the nominal rates agree;
               otherwise AUHAL resamples between us and the indexing is
               meaningless. Refuse rather than emit garbled audio. */
            hwValid = 0;
            outcome = kMaestroClockRateMismatch;
        }
    }

    double aspNow;

    if (hwValid) {
        /* mRateScalar is actual-ticks-per-frame over nominal, already smoothed
           by the HAL. Trust it rather than differencing two anchors over a
           ~10 ms baseline, which amplifies jitter. */
        c->ticksPerFrame = (hostHz / hw->hwNominalRate) * hw->rateScalar;

        const double hwNow =
            hw->hwSampleTime + ((double)now - (double)hw->hwHostTime) / c->ticksPerFrame;

        /* Re-anchor on a first sighting, on a new AudioUnit (new sample-time
           origin), OR on an unannounced discontinuity. The last case is real: if
           the device's IO restarts while the AU instance survives -- what a
           nominal-rate change does -- hwSampleTime drops back toward zero with
           no generation bump. Without this guard our sample time jumps backward,
           the period index pins at its last value, and the clock FREEZES until
           the hardware timeline climbs back past it. Hours, not glitches. */
        int discontinuity = 0;
        if (c->anchored && hw->generation == c->anchorGen) {
            const double expected = maestro_clock_flywheel_at(c, now);
            const double actual   = hwNow - c->aspToHwOffset;
            if (fabs(actual - expected) > MAESTRO_CLOCK_JUMP_SEC * c->nominalRate)
                discontinuity = 1;
        }

        if (!c->anchored || hw->generation != c->anchorGen || discontinuity) {
            /* Re-anchor with CONTINUITY: our sample time at `now` must not jump,
               or the HAL sees a broken timeline. Only the slope may change, and
               only by tens of ppm, which the HAL's IIR absorbs. Deliberately NOT
               bumping the seed: a seed change forces a hard resync, which is the
               audible break we are avoiding. */
            const double predicted = maestro_clock_flywheel_at(c, now);
            c->aspToHwOffset = hwNow - predicted;
            c->anchorGen     = hw->generation;
            c->anchored      = 1;
            aspNow           = predicted;
            outcome          = kMaestroClockReanchored;
        } else {
            aspNow  = hwNow - c->aspToHwOffset;
            outcome = kMaestroClockLocked;
        }
    } else {
        aspNow = maestro_clock_flywheel_at(c, now);
    }

    /* Keep the flywheel primed so a hardware dropout continues smoothly from
       exactly where the hardware line left off. */
    c->flywheelAsp  = aspNow;
    c->flywheelHost = now;

    /* Quantize onto the period grid. */
    int64_t k = (int64_t)floor(aspNow / c->periodFrames);
    if (k < 0) k = 0;
    if (k <= c->lastPeriodIndex) k = c->lastPeriodIndex;
    c->lastPeriodIndex = k;

    const double zeroSample = (double)k * c->periodFrames;
    uint64_t zeroHost;
    if (k == c->cachedPeriodIndex && c->lastZeroHost != 0) {
        /* Same period: hand back the identical pair. The contract says the stamp
           is stable until the next boundary, and stability costs nothing. */
        zeroHost = c->lastZeroHost;
    } else {
        double hostAtZero = (double)now - (aspNow - zeroSample) * c->ticksPerFrame;
        if (hostAtZero > (double)now) hostAtZero = (double)now;
        zeroHost = (uint64_t)hostAtZero;
        if (zeroHost < c->lastZeroHost) zeroHost = c->lastZeroHost;
        c->cachedPeriodIndex = k;
        c->lastZeroHost      = zeroHost;
    }

    *outSampleTime = zeroSample;
    *outHostTime   = zeroHost;
    return outcome;
}

#endif /* MAESTRO_CLOCK_SLAVE_H */
