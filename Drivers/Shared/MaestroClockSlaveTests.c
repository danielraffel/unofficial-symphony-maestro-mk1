/* Simulation tests for MaestroClockSlave.h + the timeline-indexed buffer.
 *
 * The bug these exist to prevent took 8.4 HOURS of production logging to
 * characterise: ring fill wandered 0-682.7 ms and pegged for ~70 min. A defect
 * that only shows after an hour of drift is not one to discover on hardware, so
 * these drive a simulated clock and replay hours of timeline in milliseconds.
 *
 * The simulation models what the reviewer's own derivation describes:
 *   - the proxy wakes N_proxy + S_usb frames before the audio it fills is heard,
 *     and reads a WHOLE BLOCK [X, X + N_proxy) up front
 *   - the plugin's cycle at hw-now p writes [p + N + S + D, p + 2N + S + D)
 * and then asserts the invariant that actually matters: every slot the proxy
 * reads was written at a wallclock strictly earlier. That is the property D
 * exists to guarantee, and the one a fixed D=512 silently violated.
 */
#include "MaestroClockSlave.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails = 0;
#define CHECK(c, ...) do { if (!(c)) { printf("  FAIL: "); printf(__VA_ARGS__); printf("\n"); fails++; } } while (0)

#define HOST_HZ      24000000.0    /* Apple Silicon mach tick rate */
#define NOMINAL      48000.0

/* ---------------------------------------------------------------- helpers */

typedef struct {
    double   hwRate;          /* the hardware's ACTUAL rate (crystal error)  */
    uint64_t originHost;      /* host time at hw frame 0                     */
    uint32_t generation;
} HwClock;

static uint64_t hw_host_at(const HwClock* h, double frame)
{
    return h->originHost + (uint64_t)(frame * HOST_HZ / h->hwRate);
}

/* The anchor an AUHAL output callback would publish for output time X. */
static MaestroClockSnapshot hw_anchor(const HwClock* h, double X)
{
    MaestroClockSnapshot s;
    s.hwSampleTime  = X;
    s.hwHostTime    = hw_host_at(h, X);   /* legitimately in the FUTURE */
    s.rateScalar    = NOMINAL / h->hwRate;
    s.hwNominalRate = NOMINAL;
    s.generation    = h->generation;
    return s;
}

/* Like hw_anchor, but for a device whose nominal rate is NOT ours -- the case
   the 48 kHz pin used to make impossible. rateScalar is the HAL's estimate
   relative to the device's OWN nominal, so it stays ~1.0 as it does in life;
   deriving it from a fixed 48000 instead would trip the sanity band and the
   test would pass for the wrong reason. */
static MaestroClockSnapshot hw_anchor_rate(const HwClock* h, double X, double nominal)
{
    MaestroClockSnapshot s = hw_anchor(h, X);
    s.hwNominalRate = nominal;
    s.rateScalar    = nominal / h->hwRate;
    return s;
}

/* ------------------------------------------------- 1. clock tracking/drift */

static void test_tracking(double ppm, double hours)
{
    HwClock hw = { NOMINAL * (1.0 + ppm / 1e6), 1000000000ull, 1 };
    MaestroClockSlave c;
    const double P = 16384.0;

    const uint32_t Nproxy = 512, Susb = 14;
    double X = 0.0;
    uint64_t now = hw_host_at(&hw, 0) - (uint64_t)((Nproxy + Susb) * HOST_HZ / hw.hwRate);
    maestro_clock_init(&c, NOMINAL, P, HOST_HZ, now);

    double   prevSample = -1.0;
    uint64_t prevHost   = 0;
    double   worstErr   = 0.0;
    long     cycles     = (long)(hours * 3600.0 * hw.hwRate / Nproxy);

    for (long k = 0; k < cycles; k++) {
        X   = (double)k * Nproxy;
        now = hw_host_at(&hw, X) - (uint64_t)((Nproxy + Susb) * HOST_HZ / hw.hwRate);
        MaestroClockSnapshot a = hw_anchor(&hw, X);

        double   st; uint64_t ht;
        maestro_clock_tick(&c, now, &a, 1, &st, &ht);

        /* Contract: monotonic, exact multiples of the period, anchor in the past */
        if (st < prevSample) CHECK(0, "sample time went backwards at k=%ld", k);
        if (fmod(st, P) != 0.0) CHECK(0, "sample time %f is not a multiple of P", st);
        if (ht > now) CHECK(0, "host time is in the future at k=%ld", k);
        if (ht < prevHost) CHECK(0, "host time went backwards at k=%ld", k);
        prevSample = st; prevHost = ht;

        /* Does our timeline still track the hardware's? Compare the frame counts
           each has advanced since the anchor. Under v1 this error grew without
           bound; slaved, it must stay tiny. */
        if (k > 10) {
            double ours = maestro_clock_flywheel_at(&c, now);
            double theirs = X - (Nproxy + Susb) - c.aspToHwOffset;
            double err = fabs(ours - theirs);
            if (err > worstErr) worstErr = err;
        }
    }
    printf("  %+7.1f ppm over %.1f h: worst timeline error %.3f frames (%.4f ms)\n",
           ppm, hours, worstErr, worstErr * 1000.0 / NOMINAL);
    CHECK(worstErr < 2.0, "timeline drifted %.1f frames at %+.0f ppm", worstErr, ppm);
}

/* --------------------------------- 2. ordering: is D actually big enough? */

/* Returns the worst headroom (slots written-before-read). Negative == broken. */
/* `lateness` places the plugin's write within its cycle: 0.0 = it writes the
   instant it wakes (best case), 1.0 = it writes just before its deadline (worst
   case, and the one that decides whether D is adequate). A real sandboxed
   helper competing for CPU lands anywhere in between, so D must survive 1.0. */
static long test_ordering(uint32_t Nproxy, uint32_t Susb,
                          uint32_t Nplugin, uint32_t Splugin,
                          uint32_t D, double ppm, double lateness, int verbose)
{
    HwClock hw = { NOMINAL * (1.0 + ppm / 1e6), 1000000000ull, 1 };
    MaestroClockSlave c;
    maestro_clock_init(&c, NOMINAL, 16384.0, HOST_HZ, hw_host_at(&hw, 0));

    /* For each ring slot: when it was last written, and WHICH absolute frame it
       holds. Tracking the frame matters -- a slot still holds data from the
       previous lap, so checking only the timestamp makes a stale write look
       perfectly valid and hides the very failure we are testing for. */
    static int64_t writtenAt[MAESTRO_SHM_RING_FRAMES];
    static int64_t writtenFrame[MAESTRO_SHM_RING_FRAMES];
    for (size_t i = 0; i < MAESTRO_SHM_RING_FRAMES; i++) {
        writtenAt[i] = INT64_MIN; writtenFrame[i] = INT64_MIN;
    }

    long worst = 1 << 30;
    const long cycles = 4000;
    /* The ring is empty at t=0; only judge once steady state is reached. */
    const long warmup = 400;

    /* Deliberately offset the two threads' phases so we are not testing a lucky
       alignment: the plugin's cycle boundary sits mid-way through the proxy's. */
    const double pluginPhase = Nplugin * 0.5;

    for (long k = 1; k < cycles; k++) {
        double   X       = (double)k * Nproxy;         /* proxy output time  */
        double   proxyNowF = X - Nproxy - Susb;        /* proxy's hw "now"   */
        uint64_t proxyNowH = hw_host_at(&hw, proxyNowF);

        /* Replay every plugin cycle that completed before the proxy woke. */
        for (long j = 0;; j++) {
            double p = (double)j * Nplugin + pluginPhase;
            /* The cycle wakes at p; the data actually lands `lateness` of a
               buffer later. Its content is unchanged -- only when it appears. */
            double landed = p + (double)Nplugin * lateness;
            if (hw_host_at(&hw, landed) > proxyNowH) break;
            double wStart = p + Nplugin + Splugin + (double)D;
            double wEnd   = wStart + Nplugin;
            for (double f = wStart; f < wEnd; f += 1.0) {
                uint32_t sl = maestro_shm_slot((int64_t)f);
                writtenAt[sl]    = (int64_t)hw_host_at(&hw, landed);
                writtenFrame[sl] = (int64_t)f;
            }
        }

        /* Now the proxy reads [X, X + Nproxy). Every slot must already hold data
           written at a host time <= the proxy's wake. */
        if (k >= warmup) {
            for (double f = X; f < X + Nproxy; f += 1.0) {
                uint32_t sl = maestro_shm_slot((int64_t)f);
                long headroom;
                if (writtenFrame[sl] != (int64_t)f) {
                    /* The slot does not hold this frame at all -- it still has
                       the previous lap's audio, which is exactly what a listener
                       would hear. */
                    headroom = -1;
                } else {
                    headroom = (long)((int64_t)proxyNowH - writtenAt[sl]);
                }
                if (headroom < worst) worst = headroom;
            }
        }
        (void)c;
    }
    if (verbose)
        printf("  N_proxy=%4u S_usb=%3u N_plugin=%4u D=%5u write@%.0f%% -> %s\n",
               Nproxy, Susb, Nplugin, D, lateness * 100.0,
               worst < 0 ? "NEGATIVE — reads unwritten slots" : "ok");
    return worst;
}

/* -------------------------------- 3. what v1's open-loop FIFO used to do */

static void test_v1_regression(void)
{
    /* v1: plugin pushed on the Mac's clock, proxy popped on the Symphony's,
       nothing reconciled them. Model the fill level directly. */
    const double ppm = 100.0;              /* ~0.36 s/hour of divergence */
    const double hwRate = NOMINAL * (1.0 + ppm / 1e6);
    double fill = 0.0, worst = 0.0;
    for (long sec = 0; sec < 3600 * 8; sec++) {
        /* Producer on the Mac's clock, consumer on the Symphony's. Nothing
           reconciles them, so the difference integrates. Deliberately NOT
           clamped: the point is how far it WANTS to go. The real ring bounds it
           at 32768 frames by dropping samples, which is what pegging looked
           like in the production logs. */
        fill += (NOMINAL - hwRate);
        if (fabs(fill) > worst) worst = fabs(fill);
    }
    printf("  v1 open-loop FIFO at %.0f ppm over 8 h: fill excursion %.0f frames (%.0f ms)\n",
           ppm, worst, worst * 1000.0 / NOMINAL);
    CHECK(worst > 10000.0, "v1 model should diverge badly; got %.0f", worst);
}

/* ------------------------------------------------------- 4. edge cases */

static void test_edges(void)
{
    HwClock hw = { NOMINAL, 1000000000ull, 1 };
    MaestroClockSlave c;
    const double P = 16384.0;
    double st; uint64_t ht;

    /* (a) no anchor at all -> flywheels, still emits a legal stamp */
    maestro_clock_init(&c, NOMINAL, P, HOST_HZ, 1000000000ull);
    MaestroClockOutcome o = maestro_clock_tick(&c, 1000000000ull + 24000000ull, NULL, 0, &st, &ht);
    CHECK(o == kMaestroClockFlywheel, "no anchor should flywheel");
    /* It must still ADVANCE while coasting -- a stalled timeline is exactly the
       freeze mode we guard against -- and stay on the period grid. */
    CHECK(fmod(st, 16384.0) == 0.0, "flywheel stamp %f is off the period grid", st);
    CHECK(ht <= 1000000000ull + 24000000ull, "flywheel host time is in the future");

    /* (b) a stale anchor (proxy stopped publishing) must be refused */
    maestro_clock_init(&c, NOMINAL, P, HOST_HZ, 1000000000ull);
    MaestroClockSnapshot a = hw_anchor(&hw, 48000.0);
    uint64_t late = a.hwHostTime + (uint64_t)(0.5 * HOST_HZ);   /* 500 ms later */
    o = maestro_clock_tick(&c, late, &a, 1, &st, &ht);
    CHECK(o == kMaestroClockFlywheel, "stale anchor should be refused, got %d", o);

    /* (c) a future-dated anchor must be ACCEPTED — an AUHAL output timestamp is
           when the audio will be heard, so it legitimately leads `now` */
    maestro_clock_init(&c, NOMINAL, P, HOST_HZ, 1000000000ull);
    a = hw_anchor(&hw, 48000.0);
    uint64_t early = a.hwHostTime - (uint64_t)(0.011 * HOST_HZ);  /* 11 ms before */
    o = maestro_clock_tick(&c, early, &a, 1, &st, &ht);
    CHECK(o == kMaestroClockReanchored, "future-dated anchor must be accepted, got %d", o);

    /* (d) rate mismatch -> refuse rather than emit garbled audio */
    maestro_clock_init(&c, NOMINAL, P, HOST_HZ, 1000000000ull);
    a = hw_anchor(&hw, 48000.0);
    a.hwNominalRate = 96000.0;
    o = maestro_clock_tick(&c, a.hwHostTime, &a, 1, &st, &ht);
    CHECK(o == kMaestroClockRateMismatch, "96k hardware should be refused, got %d", o);

    /* (e) THE FREEZE. A hardware timeline restart with NO generation bump.
           Before the discontinuity guard this pinned the period index and the
           clock stopped advancing for hours. It must re-anchor and keep going. */
    maestro_clock_init(&c, NOMINAL, P, HOST_HZ, hw_host_at(&hw, 0));
    for (int k = 1; k < 400; k++) {
        a = hw_anchor(&hw, (double)k * 512.0);
        maestro_clock_tick(&c, hw_host_at(&hw, (double)k * 512.0 - 526.0), &a, 1, &st, &ht);
    }
    double before = st;
    /* device IO restarts: sample time drops to ~0, generation UNCHANGED */
    HwClock hw2 = { NOMINAL, hw_host_at(&hw, 400.0 * 512.0), 1 };
    double advanced = 0.0;
    for (int k = 1; k < 400; k++) {
        a = hw_anchor(&hw2, (double)k * 512.0);
        maestro_clock_tick(&c, hw_host_at(&hw2, (double)k * 512.0 - 526.0), &a, 1, &st, &ht);
        if (st > before) advanced = st - before;
    }
    CHECK(advanced > 0.0, "clock FROZE after an unannounced hardware restart");
    printf("  after unannounced hw restart, clock advanced %.0f frames (must be > 0)\n", advanced);

    /* (f) generation bump (AudioUnit recreated) re-anchors cleanly */
    hw.generation = 2;
    a = hw_anchor(&hw, 1000.0);
    o = maestro_clock_tick(&c, hw_host_at(&hw, 1000.0 - 526.0), &a, 1, &st, &ht);
    CHECK(o == kMaestroClockReanchored, "generation bump should re-anchor, got %d", o);
}

/* ------------------------------------- 4. rate change: mismatch, then follow
 *
 * Until 2026-09-11 this transition could not happen: the proxy read the USB
 * device's rate and, if it was not 48000, set it back. The picker in System
 * Setup therefore "worked" -- the hardware audibly re-clocked -- and then
 * reverted ~200 ms later. Now the proxy binds AUHAL at whatever rate the
 * device is at and publishes that rate in the anchor, and the plugin FOLLOWS
 * by re-rating its own virtual device, which re-runs StartIOImpl and so
 * re-inits this clock at the new rate.
 *
 * That handshake is the only part of the change that runs without hardware, so
 * it is pinned here. The properties that matter:
 *   - a hardware rate we cannot map is REFUSED, never rendered
 *   - the timeline keeps ADVANCING while refused. Following costs a HAL
 *     configuration change; a clock that freezes for its duration is the stall
 *     mode these tests exist for, not a safe pause
 *   - the anchor the proxy parks mid-rebuild (hwHostTime = 0) must read as
 *     merely ABSENT, not as a rate mismatch -- the plugin must not chase a
 *     rate no AudioUnit is producing yet
 *   - after following, the NEW rate is the one that maps and the OLD one is
 *     refused. Symmetry is the part that catches a hardcoded 48000 in the
 *     comparison, which would let a 48k anchor through at 96k forever.
 */
static void test_rate_change(void)
{
    const double P = 16384.0;
    MaestroClockSlave c;
    double st; uint64_t ht;
    MaestroClockOutcome o;

    /* Locked at 48 kHz, the way a running session sits. */
    HwClock hw48 = { NOMINAL, 1000000000ull, 7 };
    maestro_clock_init(&c, NOMINAL, P, HOST_HZ, hw_host_at(&hw48, 0.0));

    MaestroClockSnapshot a = hw_anchor(&hw48, 4096.0);
    o = maestro_clock_tick(&c, a.hwHostTime, &a, 1, &st, &ht);
    CHECK(o == kMaestroClockReanchored, "should anchor at 48k, got %d", o);
    a = hw_anchor(&hw48, 8192.0);
    o = maestro_clock_tick(&c, a.hwHostTime, &a, 1, &st, &ht);
    CHECK(o == kMaestroClockLocked, "should lock at 48k, got %d", o);

    /* The user picks 96 kHz. The proxy tears the AudioUnit down and parks a
       deliberately stale anchor carrying the NEW rate before rebuilding. */
    double   prev = st;
    uint64_t now  = hw_host_at(&hw48, 8192.0);
    MaestroClockSnapshot parked;
    parked.hwSampleTime  = 0.0;
    parked.hwHostTime    = 0;
    parked.rateScalar    = 1.0;
    parked.hwNominalRate = 2.0 * NOMINAL;
    parked.generation    = 8;
    for (int k = 0; k < 4; k++) {
        now += (uint64_t)(P * HOST_HZ / NOMINAL);
        o = maestro_clock_tick(&c, now, &parked, 1, &st, &ht);
        CHECK(o == kMaestroClockFlywheel,
              "parked anchor must read as absent, not as a rate change, got %d", o);
        CHECK(st >= prev, "timeline went backwards over the parked anchor");
        prev = st;
    }

    /* The AudioUnit comes up at 96 kHz and publishes for real. We are still a
       48 kHz device until the HAL completes the configuration change, so every
       one of these must be refused -- and must still hand back a live stamp. */
    HwClock hw96 = { 2.0 * NOMINAL, now, 9 };
    double  firstRefused = -1.0;
    /* One tick per ZeroTimeStampPeriod, which is what the HAL actually does.
       Ticking faster than that says nothing: the flywheel stamp is quantised to
       the period, so a burst of calls inside one period legitimately returns the
       same frame and would read as a freeze. */
    for (int k = 1; k <= 8; k++) {
        const double X = (double)k * P;
        a = hw_anchor_rate(&hw96, X, 2.0 * NOMINAL);
        o = maestro_clock_tick(&c, hw_host_at(&hw96, X) - 1024, &a, 1, &st, &ht);
        CHECK(o == kMaestroClockRateMismatch,
              "96k hardware against a 48k device should mismatch, got %d", o);
        CHECK(st >= prev, "timeline went backwards while the rate was unmappable");
        if (firstRefused < 0.0) firstRefused = st;
        prev = st;
    }
    CHECK(st > firstRefused, "clock FROZE while waiting to follow the rate change");
    printf("  advanced %.0f frames while refusing an unmappable rate (must be > 0)\n",
           st - firstRefused);

    /* The follow completes: the HAL applies the configuration change and the ASP
       notices its own nominal rate moved. It re-rates rather than re-inits,
       because a re-init resets flywheelAsp and lastPeriodIndex and so walks the
       sample time backwards -- which is exactly what the next assertion forbids.
       The timeline must stay monotonic straight through a rate change; only the
       slope may move. */
    maestro_clock_rerate(&c, 2.0 * NOMINAL, hw_host_at(&hw96, 8.0 * P));
    CHECK(c.nominalRate == 2.0 * NOMINAL, "re-rate did not take");
    CHECK(c.anchored == 0, "re-rate must drop the old rate's anchor");
    a = hw_anchor_rate(&hw96, 9.0 * P, 2.0 * NOMINAL);
    o = maestro_clock_tick(&c, hw_host_at(&hw96, 9.0 * P) - 1024, &a, 1, &st, &ht);
    CHECK(o == kMaestroClockReanchored, "should re-anchor at 96k, got %d", o);
    CHECK(st >= prev, "timeline went backwards THROUGH the rate change (%f < %f)",
          st, prev);
    prev = st;
    a = hw_anchor_rate(&hw96, 10.0 * P, 2.0 * NOMINAL);
    o = maestro_clock_tick(&c, hw_host_at(&hw96, 10.0 * P) - 1024, &a, 1, &st, &ht);
    CHECK(o == kMaestroClockLocked, "should lock at 96k, got %d", o);
    CHECK(st >= prev, "timeline went backwards after the rate change");
    CHECK(fmod(st, P) == 0.0, "96k stamp %f is off the period grid", st);

    /* Symmetry: now that we ARE 96 kHz, a 48 kHz anchor is the unmappable one. */
    a = hw_anchor(&hw48, 11.0 * P);
    a.hwHostTime = hw_host_at(&hw96, 11.0 * P);
    o = maestro_clock_tick(&c, a.hwHostTime - 1024, &a, 1, &st, &ht);
    CHECK(o == kMaestroClockRateMismatch,
          "48k hardware against a 96k device should mismatch, got %d", o);
}

int main(void)
{
    printf("== clock tracking (slaved: error must stay ~0 at any drift) ==\n");
    test_tracking(   0.0, 2.0);
    test_tracking( +50.0, 2.0);
    test_tracking(-100.0, 2.0);
    test_tracking(+250.0, 2.0);

    printf("== v1 regression model ==\n");
    test_v1_regression();

    printf("== ordering: D must cover 2*N_proxy + S_usb - S_plugin ==\n");
    /* The old fixed D=512. It survives a prompt writer -- which is why it might
       have looked fine on a casual hardware test -- and fails the moment the
       plugin writes near its deadline, or the client picks a small buffer.
       That combination is why this was caught in review and not in testing. */
    CHECK(test_ordering(512, 14, 512, 64, 512, 50.0, 0.0, 1) >= 0,
          "D=512 unexpectedly fails even a prompt writer");
    CHECK(test_ordering(512, 14, 512, 64, 512, 50.0, 1.0, 1) < 0,
          "D=512 should FAIL a deadline writer — the defect review caught");
    CHECK(test_ordering(512, 14, 128, 64, 512, 50.0, 0.0, 1) < 0,
          "D=512 should FAIL at a 128-frame client buffer");

    /* The computed D, across client buffer sizes a real app may pick, with the
       plugin writing at its deadline every time. This is the guarantee. */
    const uint32_t clientBufs[] = { 128, 256, 512, 1024, 2048 };
    const uint32_t D = maestro_shm_compute_delay(512, 14);
    printf("  computed D = %u frames (%.1f ms)\n", D, D * 1000.0 / NOMINAL);
    for (size_t i = 0; i < sizeof(clientBufs)/sizeof(clientBufs[0]); i++) {
        long h = test_ordering(512, 14, clientBufs[i], MAESTRO_SHM_PLUGIN_SAFETY,
                               D, 50.0, 1.0, 1);
        CHECK(h >= 0, "computed D=%u insufficient at client buffer %u", D, clientBufs[i]);
    }

    printf("== edge cases ==\n");
    test_edges();

    printf("== rate change: refuse, keep time, then follow ==\n");
    test_rate_change();

    printf(fails ? "\nFAILED (%d)\n" : "\nALL PASS\n", fails);
    return fails != 0;
}
