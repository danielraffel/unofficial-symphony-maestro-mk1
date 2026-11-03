/* Contract tests for Drivers/Shared/MaestroAudioShm.h.
   Compiled BOTH as C and as C++ — the layout static_asserts must hold in each,
   because the proxy is C and the AudioServerPlugin is C++. */
#include "MaestroAudioShm.h"
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <time.h>

static int fails = 0;
#define CHECK(c, msg) do { if (!(c)) { printf("  FAIL: %s\n", msg); fails++; } } while (0)

static MaestroAudioShm* shm;

/* ---- slot math, including the negative frame numbers that occur at re-anchor ---- */
static void test_slots(void)
{
    CHECK(maestro_shm_slot(0) == 0, "slot(0)");
    CHECK(maestro_shm_slot(511) == 511, "slot(511)");
    CHECK(maestro_shm_slot(MAESTRO_SHM_RING_FRAMES) == 0, "slot wraps at ring size");
    CHECK(maestro_shm_slot(MAESTRO_SHM_RING_FRAMES + 7) == 7, "slot wraps +7");
    /* negative: two's-complement masking must land on the right slot */
    CHECK(maestro_shm_slot(-1) == MAESTRO_SHM_RING_FRAMES - 1, "slot(-1)");
    CHECK(maestro_shm_slot(-MAESTRO_SHM_RING_FRAMES) == 0, "slot(-ringFrames)");
    /* a very large frame number: 48kHz for a year without losing alignment */
    int64_t yr = (int64_t)48000 * 60 * 60 * 24 * 365;
    CHECK(maestro_shm_slot(yr) == (uint32_t)(yr & (MAESTRO_SHM_RING_FRAMES - 1)), "slot(1 year)");
}

/* ---- write/read round trip, wrap-around, and read-zeroes-behind ---- */
static void test_roundtrip(void)
{
    const uint32_t N = 512;
    float src[512 * MAESTRO_SHM_CHANNELS], dst[512 * MAESTRO_SHM_CHANNELS];
    for (uint32_t i = 0; i < N * MAESTRO_SHM_CHANNELS; i++) src[i] = (float)(i + 1);

    /* straddle the wrap point deliberately */
    int64_t start = (int64_t)MAESTRO_SHM_RING_FRAMES - 100;
    maestro_shm_write_at(shm, start, src, N);
    CHECK(__atomic_load_n(&shm->lastWriteFrame, __ATOMIC_RELAXED) == start + (int64_t)N,
          "lastWriteFrame published");

    maestro_shm_read_at(shm, start, dst, N);
    int ok = 1;
    for (uint32_t i = 0; i < N * MAESTRO_SHM_CHANNELS; i++) if (dst[i] != src[i]) { ok = 0; break; }
    CHECK(ok, "wrap-around round trip preserves every sample");

    /* the reader must zero behind itself, or audio replays once the plugin stops */
    float again[512 * MAESTRO_SHM_CHANNELS];
    maestro_shm_read_at(shm, start, again, N);
    int zeroed = 1;
    for (uint32_t i = 0; i < N * MAESTRO_SHM_CHANNELS; i++) if (again[i] != 0.0f) { zeroed = 0; break; }
    CHECK(zeroed, "read zeroes behind itself (no stale replay)");
}

static void test_producer_stall_detection(void)
{
    const double hz = 1000000000.0;
    memset(shm, 0, sizeof(*shm));

    /* No active I/O: an idle session must never be considered stalled. */
    shm->producerLastHostTime = 1000000000ull;
    CHECK(!maestro_shm_producer_stalled(shm, 2000000000ull, hz),
          "idle producer does not trigger recovery");

    /* Active, but no callback has happened yet: still legitimate startup. */
    shm->producerActive = 1;
    shm->producerLastHostTime = 0;
    CHECK(!maestro_shm_producer_stalled(shm, 2000000000ull, hz),
          "active producer without first write does not trigger recovery");

    /* A recent callback is healthy; an old callback is a recoverable stall. */
    shm->producerLastHostTime = 1600000000ull;
    CHECK(!maestro_shm_producer_stalled(shm, 2000000000ull, hz),
          "recent producer callback is healthy");
    shm->producerLastHostTime = 1000000000ull;
    CHECK(maestro_shm_producer_stalled(shm, 2000000000ull, hz),
          "active producer stall is detected");
    CHECK(!maestro_shm_producer_activity_changed(shm, 1000000000ull),
          "same producer callback does not re-arm recovery");
    shm->producerLastHostTime = 2100000000ull;
    CHECK(maestro_shm_producer_activity_changed(shm, 1000000000ull),
          "new producer callback re-arms recovery");

    /* Stop I/O clears the condition even if the old timestamp remains. */
    shm->producerActive = 0;
    CHECK(!maestro_shm_producer_stalled(shm, 4000000000ull, hz),
          "stopped producer does not trigger recovery");
}

/* ---- seqlock: a reader must never observe a torn anchor ---- */
static volatile int stop = 0;
static void* writer(void* _)
{
    (void)_;
    /* Pace the writer. The real publisher is a render callback running ~94x/sec
       and holding the seqlock for nanoseconds, so contention is negligible. An
       unpaced tight loop here is not a realistic stressor -- it just starves the
       reader past its retry bound and makes the test flaky. We still publish far
       faster than production to stress the ordering. */
    struct timespec nap = { 0, 20 * 1000 };   /* 20 us */
    for (uint64_t n = 1; !stop; n++) {
        /* every field derived from n, so any tear is detectable */
        maestro_shm_publish_clock(shm, (double)n, n, 1.0 + (double)(n % 3), (double)n, (uint32_t)n);
        nanosleep(&nap, NULL);
    }
    return NULL;
}
static void test_seqlock(void)
{
    pthread_t th;
    int torn = 0, reads = 0;
    stop = 0;
    pthread_create(&th, NULL, writer, NULL);
    struct timespec rnap = { 0, 5 * 1000 };   /* 5 us */
    for (int i = 0; i < 20000; i++) {
        MaestroClockSnapshot s;
        if (maestro_shm_read_clock(shm, &s)) {
            reads++;
            if (s.hwSampleTime != (double)s.hwHostTime ||
                s.hwNominalRate != (double)s.hwHostTime ||
                (uint32_t)s.hwHostTime != s.generation ||
                s.rateScalar != 1.0 + (double)(s.hwHostTime % 3)) torn++;
        }
        if ((i & 0x3F) == 0) nanosleep(&rnap, NULL);
    }
    stop = 1;
    pthread_join(th, NULL);
    CHECK(reads > 15000, "seqlock reader makes progress at realistic write rates");
    CHECK(torn == 0, "seqlock never yields a torn anchor");
    printf("  (seqlock: %d consistent reads, %d torn)\n", reads, torn);
}

int main(void)
{
    shm = (MaestroAudioShm*)calloc(1, sizeof(MaestroAudioShm));
    if (!shm) return 1;
    shm->magic = MAESTRO_SHM_MAGIC; shm->version = MAESTRO_SHM_VERSION;
    printf("sizeof(MaestroAudioShm) = %zu, buf at %zu\n",
           sizeof(MaestroAudioShm), offsetof(MaestroAudioShm, buf));
    test_slots();
    test_roundtrip();
    test_producer_stall_detection();
    test_seqlock();
    printf(fails ? "FAILED (%d)\n" : "ALL PASS\n", fails);
    free(shm);
    return fails != 0;
}
