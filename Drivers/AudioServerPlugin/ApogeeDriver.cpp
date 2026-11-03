/// ApogeeDriver.cpp — AudioServerPlugin for Apogee Symphony IO MKI
///
/// Architecture:
///   macOS volume keys → ApogeeVolumeControl::SetRawValueImpl
///     → XPC → MaestroVolumeProxy LaunchDaemon
///       → UNIX socket → Apogee daemon → hardware DAC
///
///   Apps write audio → our virtual device (default output)
///     → OnWriteMixedOutput → shared memory ring buffer (via XPC shmem)
///       → MaestroVolumeProxy HAL AudioUnit → real USB Symphony IO → speakers
///
/// Why shared memory via the proxy (not direct AudioDeviceIOProc from here):
///   This plugin runs in com.apple.audio.Core-Audio-Driver-Service.helper,
///   a sandboxed coreaudiod helper. Targeting another device's IO from inside
///   that helper creates a circular coreaudiod dependency and destabilizes the
///   system. MaestroVolumeProxy runs outside the sandbox and freely uses a HAL
///   output AudioUnit to play audio to the USB device. The shared ring buffer
///   (allocated by the proxy, mapped here via xpc_shmem) is the zero-copy
///   bridge between the two processes.

#include <aspl/Driver.hpp>
#include <aspl/Plugin.hpp>
#include <aspl/Device.hpp>
#include <aspl/Stream.hpp>
#include <aspl/VolumeControl.hpp>
#include <aspl/MuteControl.hpp>
#include <aspl/ControlRequestHandler.hpp>
#include <aspl/IORequestHandler.hpp>

// VolumeCurve is forward-declared in the public VolumeControl.hpp header;
// including the src/ implementation header makes the type complete so our
// VolumeControl subclass (which holds unique_ptr<VolumeCurve>) can compile.
#include "VolumeCurve.hpp"

#include <CoreAudio/CoreAudio.h>
#include <xpc/xpc.h>
#include <mach/mach_time.h>

#include "MaestroAudioShm.h"
#include "MaestroClockSlave.h"

#include <memory>
#include <atomic>
#include <vector>
#include <cmath>
#include <os/log.h>
#include <dispatch/dispatch.h>

// ── Logging ──────────────────────────────────────────────────────────────── //

static os_log_t sLog = os_log_create("com.apogee.audio.symphonyio-asp", "driver");

// ── Globals ───────────────────────────────────────────────────────────────── //

static std::shared_ptr<aspl::Driver> sDriver;

// XPC connection to MaestroVolumeProxy (volume/mute forwarding + audio shmem)
// Mutated ONLY on sXPCQueue; read from control threads, hence atomic.
static std::atomic<xpc_connection_t> sXPCConn{nullptr};
// Serial queue owning the connection's lifecycle. The event handler can replace
// sXPCConn, so it must not run concurrently with itself.
static dispatch_queue_t sXPCQueue = nullptr;
/// Repeating timer that keeps this device on the hardware's rate while idle.
/// See its construction in CreateDriver for why it has to exist.
///
/// Safe today because nothing is ever torn down: sDriver is created once behind
/// `if (!sDriver)` (:975), never reset, and coreaudiod does not unload HAL
/// plugins. If a teardown path is ever added, dispatch_source_cancel on this
/// MUST precede destroying the device -- the handler dereferences sDeviceRaw.
static dispatch_source_t sFollowTimer = nullptr;
static int sReconnectAttempt = 0;
static void connectToProxy();
static void requestAudioShmem();
static void scheduleProxyReconnect();
static void resendVolumeAndMuteXPC();
static void sendHardwareRateXPC(double rate);

// ── Shared audio bridge ───────────────────────────────────────────────────── //
//
// Allocated by MaestroVolumeProxy via mach_vm_allocate, shared via xpc_shmem,
// and mapped here when the proxy sends "audioShmem". The layout — and the
// reasoning behind replacing the old head/tail FIFO with a timeline-indexed
// buffer — lives in Drivers/Shared/MaestroAudioShm.h, which BOTH processes
// compile so the two views cannot drift apart.

// Written on the XPC queue, read on the realtime IO thread.
static std::atomic<MaestroAudioShm*> sSharedShm{nullptr};
static std::atomic<bool> sIOActive{false};

/// mach timebase, resolved once and cached.
static double HostTicksPerSecond()
{
    static double cached = 0.0;
    if (cached == 0.0) {
        mach_timebase_info_data_t tb;
        mach_timebase_info(&tb);
        cached = (double(tb.denom) / double(tb.numer)) * 1e9;
    }
    return cached;
}

/// Every rate the Symphony can run at, so this device can follow the hardware
/// to any of them. The list is the one Apogee's own HAL plugin advertised
/// (`og_source/maestrolink/Software/SymphonyIO.cpp:2918-2935`) rather than a
/// guess; the checked-in XMOS firmware caps at 96 kHz
/// (`og_source/symphonymk1/ext/SymphonyIO/Software/XMOS/SymphonyIO/src/XMOS/USB/customdefines.h:217`),
/// but the real device's own AvailableNominalSampleRates is what governs, and
/// we only ever follow a rate it has actually reported.
///
/// "Available" here means "can be followed", not "can be chosen": the hardware
/// owns the rate (it is the UAC2 clock), so SetNominalSampleRateImpl accepts
/// only the rate the hardware is actually at. libASPL gates the follower's own
/// set against this list (Device::CheckNominalSampleRate), which is why the list
/// must hold every rate we might follow.
///
/// Capped at 96 kHz because this plugin is the 16-channel USB path. The ceiling
/// belongs to that USB mode specifically, not to USB in general -- the MK1 has
/// three USB AIM modes with three different ceilings, per
/// og_source/generic/ApogeeUSBProductID.h:40-42:
///
///     0x10  16ch  44.1-96k   <- this plugin (dp.ChannelCount = 16 below)
///     0x11   8ch  44.1-192k
///     0x12  32ch  44.1-48k
///
/// The firmware source in og_source is the 0x10 build, which is why MAX_FREQ is
/// 96000 there (og_source/symphonymk1/ext/SymphonyIO/Software/XMOS/SymphonyIO/
/// src/XMOS/USB/customdefines.h:217, MIN_FREQ 44100 at :218): the same file sets
/// NUM_USB_CHAN_OUT to 16 at :195 and PID_AUDIO_2 to
/// eApogeeConstant_USB_ProductID_SymphonyIOUSBAudio (0x10) at :228. The 8-channel
/// 192 kHz firmware is not in og_source. The hardware agrees for the mode we run:
/// "Symphony I/O : USB Audio" reports exactly {44100, 48000, 88200, 96000}.
///
/// So this table is right as long as this plugin is 16-channel, and it is
/// hardwired to be (dp.ChannelCount = 16). If 8-channel mode is ever supported,
/// this table has to become mode-dependent rather than constant -- the app
/// already models all three modes in MaestroCore/ClockConfig.swift:164-170, and
/// a unit in 8-channel mode at 192 kHz would currently be refused by
/// IsFollowableRate and left silent.
///
/// 176.4 and 192 kHz are also real for this box over Thunderbolt, which is a
/// different driver entirely (SymphonyThunderbridge), not this one. Listing them
/// here advertised a capability this device does not have: Audio MIDI Setup would
/// offer 192 kHz and SetNominalSampleRateImpl would then refuse it, because no
/// hardware rate can ever agree with it.
///
/// Apogee's own plugin did list all six, but it is not evidence the USB path
/// reached them: the list is one flat hardcoded table that never looks at the
/// boot mode at all (og_source/symphonymk1/ext/maestrolink/Software/
/// SymphonyIO.cpp:2918-2932 -- aRates[0..5], 44.1 through 192, returned
/// unconditionally). The very next case is where that plugin says what it
/// actually is on USB: in eSymphonyIO_BootMode_USBAudio it answers
/// kAudioDevicePropertyNominalSampleRate with m_nMeasuredSampleRate (:2940-2953)
/// -- a follower reporting what the hardware is doing, exactly like this one.
static const std::vector<AudioValueRange> kSymphonyRates = {
    {44100.0, 44100.0}, {48000.0, 48000.0}, {88200.0, 88200.0},
    {96000.0, 96000.0},
};

/// Can this device follow `rate`? Asked before requesting a configuration
/// change, so an unfollowable rate produces one clear log line instead of a
/// libASPL rejection with no explanation of what was rejected or why.
static bool IsFollowableRate(double rate)
{
    for (const auto& r : kSymphonyRates) {
        if (rate >= r.mMinimum - 1.0 && rate <= r.mMaximum + 1.0) return true;
    }
    return false;
}

/// Our virtual device, slaved to the Symphony's clock.
///
/// The arithmetic lives in Drivers/Shared/MaestroClockSlave.h so it can be
/// tested against a simulated clock at arbitrary drift, without libASPL,
/// CoreAudio or hardware. This class is the thin adapter: it supplies `now`,
/// mirrors the bits the realtime IO thread needs into atomics, and logs.
class ApogeeDevice : public aspl::Device {
public:
    using aspl::Device::Device;

    OSStatus StartIOImpl(UInt32 clientID, UInt32 startCount) override
    {
        if (startCount == 0) {
            // Fresh IO session: restart the timeline at zero and drop any anchor
            // so the first hardware sighting re-anchors cleanly.
            maestro_clock_init(&clock_, GetNominalSampleRate(),
                double(GetZeroTimeStampPeriod()), HostTicksPerSecond(),
                mach_absolute_time());
            PublishToIOThread();
            lastOutcome_        = kMaestroClockFlywheel;
            rateMismatchLogged_ = false;
            followRequested_    = 0.0;
            os_log_info(sLog, "ApogeeSymIO: StartIO — timeline reset, awaiting hardware clock");
        }
        return aspl::Device::StartIOImpl(clientID, startCount);
    }

    OSStatus GetZeroTimeStampImpl(UInt32 clientID,
        Float64* outSampleTime,
        UInt64* outHostTime,
        UInt64* outSeed) override
    {
        (void)clientID;
        const UInt64 now = mach_absolute_time();

        // Our own nominal rate moves under us: the follower below asks for a
        // configuration change and the HAL applies it between IO cycles. Notice
        // it here, which is where libASPL's own stock implementation notices the
        // same thing (libaspl-src/src/Device.cpp:1266-1277), and re-rate the
        // timeline instead of restarting it -- a restart would walk the sample
        // time backwards, which AudioServerPlugIn.h forbids without a seed bump,
        // and a seed bump is the hard resync this clock exists to avoid.
        const Float64 myRate = GetNominalSampleRate();
        if (std::fabs(myRate - clock_.nominalRate) > 1.0) {
            maestro_clock_rerate(&clock_, myRate, now);
            PublishToIOThread();
            lastOutcome_        = kMaestroClockFlywheel;
            rateMismatchLogged_ = false;
            followRequested_    = 0.0;
            os_log_info(sLog, "ApogeeSymIO: re-rated to %.0f Hz — re-anchoring", myRate);
        }

        MaestroAudioShm* shm = sSharedShm.load(std::memory_order_acquire);
        MaestroClockSnapshot hw;
        const int present = (shm != nullptr) && maestro_shm_read_clock(shm, &hw);

        Float64 sampleTime = 0.0;
        UInt64  hostTime   = 0;
        const MaestroClockOutcome outcome =
            maestro_clock_tick(&clock_, now, &hw, present, &sampleTime, &hostTime);

        PublishToIOThread();

        // The proxy computes the real D once it has the device, which is well
        // after we map the shmem. Adopt it whenever it changes, or we advertise
        // the provisional value forever -- a constant, systematic A/V error, the
        // very bug this work exists to remove. Never from this thread:
        // SetLatencyAsync triggers a configuration change.
        if (shm) {
            const uint32_t d = __atomic_load_n(&shm->delayFrames, __ATOMIC_RELAXED);
            if (d != adoptedDelay_ && d > 0 && d < MAESTRO_SHM_RING_FRAMES) {
                adoptedDelay_ = d;
                auto* self = this;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    // +14 is the USB device's own latency, measured in frames at
                    // 48 kHz. If it is really a fixed time rather than a fixed
                    // frame count it is understated at higher rates -- by at most
                    // 42 frames at 192 kHz, which is 0.2 ms and a fifth of one
                    // buffer. Reading kAudioDevicePropertyLatency from the real
                    // device would settle it, but only the proxy can see that
                    // device, so it would have to come across the shared memory.
                    self->SetLatencyAsync(d + 14);
                    os_log_info(sLog, "ApogeeSymIO: adopted D=%u frames — reporting %u latency",
                                d, d + 14);
                });
            }
        }

        if (outcome != lastOutcome_) {
            switch (outcome) {
            case kMaestroClockReanchored:
                os_log_info(sLog,
                    "ApogeeSymIO: clock anchored to hardware (gen=%u rateScalar=%.9f)",
                    hw.generation, hw.rateScalar);
                break;
            case kMaestroClockFlywheel:
                os_log_info(sLog,
                    "ApogeeSymIO: no hardware clock — coasting on last known line");
                break;
            case kMaestroClockRateMismatch:
                if (!rateMismatchLogged_) {
                    rateMismatchLogged_ = true;
                    os_log_error(sLog,
                        "ApogeeSymIO: hardware is at %.0f Hz but this device is %.0f Hz — "
                        "cannot map timeline, no audio until the rates agree",
                        hw.hwNominalRate, GetNominalSampleRate());
                }
                break;
            case kMaestroClockLocked:
                break;
            }
            lastOutcome_ = outcome;
        }

        // The mismatch is genuinely resolved: the next one is new news, even at a
        // rate we asked for before. Deliberately NOT cleared on Flywheel, which
        // is what a parked anchor looks like while the proxy rebuilds its
        // AudioUnit -- and the proxy parks one on every rate change. Clearing
        // there would re-request the same target as soon as the anchor came back,
        // so a hardware notification arriving twice (AppleUSBAudio does that)
        // would cost two configuration changes and two IO restarts for one user
        // action.
        if (outcome == kMaestroClockLocked || outcome == kMaestroClockReanchored) {
            followRequested_ = 0.0;
        }

        // Follow the hardware. It owns the rate -- it IS the UAC2 clock -- so a
        // mismatch is ours to resolve, not something to ask the user about. Once
        // per distinct target so a rate we cannot reach does not spin, and never
        // from this thread: SetNominalSampleRateAsync takes a lock and requests a
        // configuration change. Deliberately outside the transition guard above,
        // because the mismatch persists across ticks while the change lands.
        if (outcome == kMaestroClockRateMismatch) {
            RequestFollow(hw.hwNominalRate, myRate);
        }

        *outSampleTime = sampleTime;
        *outHostTime   = hostTime;
        *outSeed       = 1;   // constant: every transition above is continuous
        return kAudioHardwareNoError;
    }

    /// Map one of our sample times onto the hardware timeline, for the IO thread.
    /// Returns false until the hardware clock has been seen at least once.
    bool MapToHardware(Float64 aspSampleTime, int64_t* outHwFrame) const
    {
        if (!anchored_.load(std::memory_order_acquire)) return false;
        *outHwFrame = int64_t(std::llrint(
            aspSampleTime + aspToHwOffset_.load(std::memory_order_relaxed)));
        return true;
    }

    uint32_t AnchorGeneration() const
    {
        return anchorGen_.load(std::memory_order_acquire);
    }

    /// The output stream, so a rate change can carry the stream format with it.
    /// libASPL does NOT propagate the device's nominal rate to its streams --
    /// Stream::SetPhysicalFormatImpl only stores what it is given
    /// (libaspl-src/src/Stream.cpp:98-103), and its header comment claiming it
    /// calls Device::SetSampleRateAsync() describes a method that does not exist
    /// in v3.1.2. libaspl-src/test/TestOperations.cpp:128-156 is the proof: the
    /// device goes 44100 -> 48000 with both streams left at 44100.
    void AdoptStream(std::shared_ptr<aspl::Stream> stream)
    {
        stream_ = std::move(stream);
    }

    /// Follow the hardware's current rate, for callers that are not the IO thread.
    ///
    /// The follower in GetZeroTimeStampImpl only runs while something is playing
    /// through this device, because that is the only time the HAL asks us for a
    /// timestamp. So an idle device would sit at the wrong rate until the next
    /// playback -- which is the state right after boot, where we are created at
    /// 48 kHz and the XMOS powers up at 44.1 kHz (DEFAULT_FREQ,
    /// og_source/symphonymk1/ext/SymphonyIO/Software/XMOS/SymphonyIO/src/XMOS/
    /// USB/customdefines.h:220). Catching it when the shared memory arrives means
    /// the first playback of the session starts at the right rate instead of
    /// paying a configuration change a few buffers in.
    ///
    /// Show or hide this device according to whether the Symphony is plugged in.
    ///
    /// Reported: Maestro USB stays selectable in Sound and Audio MIDI Setup with
    /// the Symphony disconnected or powered off — and worse, once selected it
    /// holds on, so the Mac has no working output until the user goes and
    /// changes it back by hand. A virtual device is not a promise that hardware
    /// exists; this one only means anything while the hardware is there.
    ///
    /// The proxy is the only side that can see the hardware, so it publishes
    /// presence and this reads it. Anything short of an explicit "absent" —
    /// including no shared memory at all, and including an older proxy that
    /// never sets the field — counts as present. Hiding a device because we are
    /// unsure would take away the user's audio output to fix a cosmetic problem.
    ///
    /// Hidden AND not-default-able, because they answer different questions:
    /// hidden keeps it out of the lists, and clearing the default flag is what
    /// makes the HAL let go of it and move the system on to something audible
    /// instead of holding a dead device.
    ///
    /// Only writes on a change — these are property setters that notify
    /// listeners, and this runs once a second forever.
    void UpdatePresence()
    {
        MaestroAudioShm* shm = sSharedShm.load(std::memory_order_acquire);
        const bool absent = shm && maestro_shm_device_absent(shm);
        /* ASPL does not guarantee that the default-device flags start true.
           On the first timer tick the cached state is also false, so an
           equality-only early return would leave Maestro USB visible in Audio
           MIDI Setup but filtered out of the macOS Sound menu. Publish the
           initial state once, then retain the change-only fast path. */
        if (presencePropertiesInitialized_ && absent == hiddenForAbsence_) return;
        hiddenForAbsence_ = absent;
        presencePropertiesInitialized_ = true;

        SetIsHidden(absent);
        SetCanBeDefaultDevice(!absent);
        SetCanBeDefaultSystemDevice(!absent);
        os_log_info(sLog, "ApogeeSymIO: Symphony %s — this device is now %s",
                    absent ? "disconnected" : "connected",
                    absent ? "hidden" : "available");
    }

    /// Safe from any queue EXCEPT the IO thread: the request it makes takes
    /// libASPL's write mutex.
    void FollowHardwareRateNow()
    {
        MaestroAudioShm* shm = sSharedShm.load(std::memory_order_acquire);
        MaestroClockSnapshot hw;
        if (!shm || !maestro_shm_read_clock(shm, &hw)) return;
        if (!(hw.hwNominalRate > 0.0)) return;
        const Float64 myRate = GetNominalSampleRate();
        if (std::fabs(hw.hwNominalRate - myRate) <= 1.0) return;
        RequestFollow(hw.hwNominalRate, myRate);
    }

protected:
    /// The hardware owns the rate. This device only ever follows it, so the only
    /// legal set is to the rate the hardware is already at -- which is the one
    /// the follower in GetZeroTimeStampImpl issues.
    ///
    /// So a rate set from elsewhere (Audio MIDI Setup pointed at this device, a
    /// DAW asking us to re-rate) does not change the rate here: slots in the
    /// shared ring are named in HARDWARE frames, so our rate matching the
    /// device's is not a preference, it is the premise.
    ///
    /// It is not dropped either. The request is forwarded to the proxy, which
    /// moves the real USB device; the new rate comes back through shared memory
    /// and the follower brings this device along a moment later. So the Format
    /// popup works, it just takes the long way round -- which is the only way
    /// round that keeps the ring indexed correctly.
    ///
    /// libASPL discards the status we return -- it is traced, not returned to the
    /// HAL (libaspl-src/src/Device.g.cpp:201-222) -- so the caller sees its set
    /// "succeed" and reads back the old rate until the hardware arrives.
    /// The HAL may drop a requested configuration change instead of performing
    /// it, in which case SetNominalSampleRateImpl is never entered. Clearing the
    /// dedupe key here frees the follower at the exact moment the request dies,
    /// rather than waiting out RequestFollow's retry deadline. An abort the HAL
    /// does not route here is covered by that deadline instead -- this is the
    /// fast path, not the only one.
    OSStatus AbortConfigurationChange(AudioObjectID objectID, UInt64 changeAction,
                                      void* changeInfo) override
    {
        followRequested_ = 0.0;
        return aspl::Device::AbortConfigurationChange(objectID, changeAction, changeInfo);
    }

    OSStatus SetNominalSampleRateImpl(Float64 rate) override
    {
        MaestroAudioShm* shm = sSharedShm.load(std::memory_order_acquire);
        MaestroClockSnapshot hw;
        const bool haveHw = (shm != nullptr) && maestro_shm_read_clock(shm, &hw);
        const double hwRate = haveHw ? hw.hwNominalRate : 0.0;

        // Either way, this request has now been answered: stop suppressing the
        // follower on this target.
        followRequested_ = 0.0;

        // hwRate == 0.0 means we cannot see the hardware at all (no shared memory
        // yet, or the proxy is down), and then anything is accepted -- there is no
        // fact to check the request against, and refusing everything would make
        // the device unusable exactly when the proxy is restarting. Self-healing
        // rather than a hole: the moment the shared memory is mapped,
        // FollowHardwareRateNow corrects the rate, and the first IO tick does too.
        if (hwRate > 0.0 && std::fabs(rate - hwRate) > 1.0) {
            // Somebody wants a real change: the Format popup in Audio MIDI Setup,
            // the Sound pane, a DAW. We still cannot BE that rate before the
            // hardware is -- but we can pass the request to something that can
            // say yes, and then follow it there. Until that lands this device is
            // unchanged, which is the honest answer to "are you 96 kHz yet".
            //
            // Only for a rate this device could actually advertise. Moving the
            // hardware somewhere we cannot follow would strand us mismatched,
            // which is silence, and it would be silence we asked for.
            if (IsFollowableRate(rate)) {
                os_log_info(sLog,
                    "ApogeeSymIO: asking the hardware to move %.0f Hz → %.0f Hz; "
                    "this device follows when it gets there", hwRate, rate);
                sendHardwareRateXPC(rate);
            } else {
                os_log_error(sLog,
                    "ApogeeSymIO: refusing %.0f Hz — not a rate this device can "
                    "advertise (hardware is at %.0f Hz)", rate, hwRate);
            }
            return kAudioHardwareUnsupportedOperationError;
        }

        const OSStatus status = aspl::Device::SetNominalSampleRateImpl(rate);
        if (status != kAudioHardwareNoError) return status;

        // Carry the stream format along. We are inside PerformConfigurationChange,
        // so Device::RequestConfigurationChange applies these in place rather than
        // queueing them (libaspl-src/src/Device.cpp:1589-1615, :1685-1706).
        if (stream_) {
            AudioStreamBasicDescription fmt = stream_->GetPhysicalFormat();
            fmt.mSampleRate = rate;
            stream_->SetPhysicalFormatAsync(fmt);
            stream_->SetVirtualFormatAsync(fmt);
        }

        os_log_info(sLog, "ApogeeSymIO: now a %.0f Hz device (following the hardware)", rate);
        return kAudioHardwareNoError;
    }

private:
    /// How long a follow request gets to land before it is assumed lost.
    ///
    /// A configuration change is normally applied in well under a second; three
    /// seconds is long enough that a slow one is never re-asked, and short enough
    /// that a user who just turned the Mac on does not sit through silence.
    static constexpr double kFollowRetrySeconds = 3.0;

    /// Ask to become a `target` Hz device.
    ///
    /// Once per distinct target, EXCEPT that an unanswered request is re-asked
    /// after kFollowRetrySeconds. That exception is the whole point of the
    /// timestamp: the HAL can drop a requested configuration change without
    /// performing it and without aborting it, and then nothing clears the dedupe
    /// key -- not SetNominalSampleRateImpl, which is never entered, not
    /// AbortConfigurationChange, which never fires, and not the tick-side clear,
    /// because with the hardware at the target rate every tick is still a
    /// mismatch. The device then stays at the wrong rate forever: meters move,
    /// because the HAL meters our own signal, but no frame ever reaches the ring,
    /// so nothing is heard. The one thing that recovered it was toggling the
    /// device in Audio MIDI Setup or Sound, which drives StartIOImpl with
    /// startCount == 0 and resets the key by hand.
    ///
    /// Re-asking makes that self-heal in three seconds instead of needing the
    /// user to know the trick. It does not spin: the retry only happens while the
    /// rates still disagree, and a target this device cannot advertise is latched
    /// permanently (timestamp 0) so its one log line stays one log line.
    ///
    /// Never applies the rate here: SetNominalSampleRateAsync takes a lock and
    /// requests a configuration change, and one caller is the realtime IO thread.
    /// `myRate` is only for the log line.
    void RequestFollow(Float64 target, Float64 myRate)
    {
        const uint64_t now = mach_absolute_time();

        if (!IsFollowableRate(target)) {
            // Latch it and never retry -- re-asking for a rate we cannot advertise
            // would only repeat the message. Timestamp 0 means "no outstanding
            // request", which is what the retry branch below tests.
            Float64 expected = followRequested_.load(std::memory_order_relaxed);
            if (expected == target) return;
            if (!followRequested_.compare_exchange_strong(expected, target,
                    std::memory_order_acq_rel, std::memory_order_relaxed)) {
                return;
            }
            followRequestedAt_.store(0, std::memory_order_relaxed);
            os_log_error(sLog,
                "ApogeeSymIO: hardware reports %.0f Hz, which is not a rate this "
                "device can advertise — staying at %.0f Hz, no audio until they agree",
                target, myRate);
            return;
        }

        // Whoever swaps the target in owns the request. The IO thread and the XPC
        // queue can both reach here, and a plain check-then-set would let both
        // through and queue the change twice.
        Float64 expected = followRequested_.load(std::memory_order_relaxed);
        if (expected == target) {
            uint64_t asked = followRequestedAt_.load(std::memory_order_relaxed);
            if (asked == 0) return;                       // latched, not retryable
            const double waited = double(now - asked) / HostTicksPerSecond();
            if (waited < kFollowRetrySeconds) return;
            // The timestamp swap is what serialises the retry: two threads past
            // the deadline check race here and exactly one re-asks.
            if (!followRequestedAt_.compare_exchange_strong(asked, now,
                    std::memory_order_acq_rel, std::memory_order_relaxed)) {
                return;
            }
            os_log_error(sLog,
                "ApogeeSymIO: still %.0f Hz %.1fs after asking to follow the hardware "
                "to %.0f Hz — the configuration change was dropped, asking again",
                myRate, waited, target);
        } else {
            // Timestamp first: a thread that arrives between the two writes would
            // otherwise read a timestamp belonging to the previous target and
            // could re-ask immediately.
            followRequestedAt_.store(now, std::memory_order_relaxed);
            if (!followRequested_.compare_exchange_strong(expected, target,
                    std::memory_order_acq_rel, std::memory_order_relaxed)) {
                return;   // someone else claimed it between the load and here
            }
        }

        auto* self = this;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            const OSStatus st = self->SetNominalSampleRateAsync(target);
            if (st == kAudioHardwareNoError) {
                os_log_info(sLog, "ApogeeSymIO: following the hardware to %.0f Hz", target);
            } else {
                os_log_error(sLog,
                    "ApogeeSymIO: could not follow the hardware to %.0f Hz (status %d)",
                    target, (int)st);
            }
        });
    }

    /// clock_ is touched only under libASPL's IO mutex; the IO thread reads
    /// these mirrors instead.
    void PublishToIOThread()
    {
        aspToHwOffset_.store(clock_.aspToHwOffset, std::memory_order_release);
        anchorGen_.store(clock_.anchorGen, std::memory_order_release);
        anchored_.store(clock_.anchored != 0, std::memory_order_release);
    }

    std::shared_ptr<aspl::Stream> stream_;

    MaestroClockSlave   clock_{};
    MaestroClockOutcome lastOutcome_ = kMaestroClockFlywheel;
    bool                rateMismatchLogged_ = false;
    uint32_t            adoptedDelay_ = 0;
    /// The rate we last asked to follow, so one mismatch does not queue a
    /// configuration change on every IO cycle while the first one lands. Written
    /// from the IO thread, from the HAL's configuration-change thread, and from
    /// the XPC queue when the shared memory arrives, so it is atomic -- a torn
    /// read here would either skip a needed follow or queue a redundant one.
    std::atomic<Float64> followRequested_{0.0};
    /// When that request went out, in mach ticks, so an unanswered one can be
    /// re-asked. 0 means there is nothing outstanding to retry -- either no
    /// request has been made, or the target is one this device cannot advertise
    /// and retrying would just repeat a log line.
    std::atomic<uint64_t> followRequestedAt_{0};

    /// Whether this device is currently hidden because the hardware is gone.
    /// Only ever touched from the XPC queue's 1 Hz timer.
    bool hiddenForAbsence_ = false;
    bool presencePropertiesInitialized_ = false;

    std::atomic<bool>     anchored_{false};
    std::atomic<double>   aspToHwOffset_{0.0};
    std::atomic<uint32_t> anchorGen_{0};
};

static ApogeeDevice* sDeviceRaw = nullptr;  // for the IO thread; owned by sDriver
static void reconcileControlsFromProxy(xpc_object_t event);

// ── XPC helpers ──────────────────────────────────────────────────────────── //

/// Create (or recreate) the XPC connection to MaestroVolumeProxy.
///
/// Must run on sXPCQueue. Safe to call repeatedly: any previous connection is
/// cancelled and released first.
static void connectToProxy()
{
    if (xpc_connection_t old = sXPCConn.exchange(nullptr, std::memory_order_acq_rel)) {
        xpc_connection_cancel(old);
        xpc_release(old);
    }

    xpc_connection_t conn = xpc_connection_create_mach_service(
        "com.danielraffel.Maestro.volumeproxy", sXPCQueue, 0);
    if (!conn) {
        os_log_error(sLog, "ApogeeSymIO: could not create XPC connection — retrying");
        scheduleProxyReconnect();
        return;
    }

    xpc_connection_set_event_handler(conn, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR) {
            os_log_error(sLog, "ApogeeSymIO: XPC error: %s",
                xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION));

            if (event == XPC_ERROR_CONNECTION_INTERRUPTED) {
                // The proxy died; launchd will relaunch it and XPC reconnects
                // this same object. The new process allocates its own buffer, so
                // ours is stale — drop it and ask again.
                sSharedShm.store(nullptr, std::memory_order_release);
                os_log_info(sLog, "ApogeeSymIO: proxy interrupted — re-requesting shmem");
                requestAudioShmem();

            } else if (event == XPC_ERROR_CONNECTION_INVALID) {
                // The service NAME left the bootstrap namespace — what
                // `launchctl bootout` does, and what the installer's own
                // postinstall does on every upgrade. Per Apple's contract this
                // connection is "useless and should be disposed of": every
                // subsequent send is silently discarded, so audio AND volume/mute
                // die permanently with no further events. Recreating the
                // connection is the only recovery. Retry forever with backoff —
                // the daemon is KeepAlive and will come back.
                sSharedShm.store(nullptr, std::memory_order_release);
                os_log_error(sLog, "ApogeeSymIO: proxy service invalid — reconnecting");
                scheduleProxyReconnect();
            }
        } else if (xpc_get_type(event) == XPC_TYPE_DICTIONARY) {
                // Handle replies from proxy
                const char* cmd = xpc_dictionary_get_string(event, "command");
                if (cmd && strcmp(cmd, "audioShmem") == 0) {
                    xpc_object_t shmem = xpc_dictionary_get_value(event, "shmem");
                    if (shmem) {
                        // xpc_shmem_map(obj, &ptr) → returns size, fills ptr
                        void*  ptr = nullptr;
                        size_t sz  = xpc_shmem_map(shmem, &ptr);
                        if (ptr && sz >= sizeof(MaestroAudioShm)) {
                            auto* shm = static_cast<MaestroAudioShm*>(ptr);
                            // The plugin and the proxy are deployed by separate
                            // scripts, so a version-skewed pair is a real
                            // possibility. Refuse it loudly rather than
                            // misinterpreting the other side's layout.
                            const uint32_t magic = shm->magic;
                            const uint32_t ver   = shm->version;
                            if (magic == MAESTRO_SHM_MAGIC &&
                                ver   == MAESTRO_SHM_VERSION &&
                                shm->ringFrames    == MAESTRO_SHM_RING_FRAMES &&
                                shm->bytesPerFrame == MAESTRO_SHM_BYTES_PER_FRAME) {
                                sSharedShm.store(shm, std::memory_order_release);
                                __atomic_store_n(&shm->producerActive,
                                    sIOActive.load(std::memory_order_acquire) ? 1u : 0u,
                                    __ATOMIC_RELEASE);
                                sReconnectAttempt = 0;   // healthy again
                                os_log_info(sLog,
                                    "ApogeeSymIO: Audio shmem mapped (%zu bytes, v%u, D=%u frames) — ready",
                                    sz, ver, shm->delayFrames);
                                // First sight of the hardware's rate. We are on
                                // sXPCQueue, not the IO thread, so this is the one
                                // place a rate can be adopted with nothing playing
                                // -- and right after boot, or after the proxy was
                                // relaunched, that is exactly the situation.
                                if (sDeviceRaw) sDeviceRaw->FollowHardwareRateNow();
                                // Reconcile the virtual controls with the
                                // proxy's persisted hardware state before
                                // restating it. Without this handshake, a
                                // plugin reconnect briefly (or permanently)
                                // leaves the HUD at the construction default
                                // (-20 dB/unmuted) even though the proxy has
                                // restored the user's previous volume/mute.
                                reconcileControlsFromProxy(event);
                                // The reply is also the first proof the proxy
                                // is alive and reading our messages. Restate
                                // the reconciled values so older proxies and
                                // transient reconnects remain harmless.
                                resendVolumeAndMuteXPC();
                            } else {
                                os_log_error(sLog,
                                    "ApogeeSymIO: shmem contract mismatch (magic=0x%08X v%u) — redeploy MaestroVolumeProxy",
                                    magic, ver);
                            }
                        } else {
                            os_log_error(sLog,
                                "ApogeeSymIO: xpc_shmem_map failed (%zu bytes, need %zu)",
                                sz, sizeof(MaestroAudioShm));
                        }
                    }
                }
            }
    });

    sXPCConn.store(conn, std::memory_order_release);
    xpc_connection_resume(conn);
    os_log_info(sLog, "ApogeeSymIO: XPC proxy connection created");
    requestAudioShmem();
}

static void sendAttenuationXPC(uint32_t attenuation)
{
    xpc_connection_t conn = sXPCConn.load(std::memory_order_acquire);
    if (!conn) return;
    xpc_object_t msg = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_string(msg, "command", "setAttenuation");
    xpc_dictionary_set_uint64(msg, "attenuation", attenuation);
    xpc_connection_send_message(conn, msg);
    xpc_release(msg);
}

/// Ask the proxy to move the REAL USB device to `rate`.
///
/// This device follows the hardware and cannot lead it, so a rate set here has
/// to become a rate set over there. The proxy owns the HAL AudioUnit on the real
/// device, so it is the one process that can do it.
static void sendHardwareRateXPC(double rate)
{
    xpc_connection_t conn = sXPCConn.load(std::memory_order_acquire);
    if (!conn) return;
    xpc_object_t msg = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_string(msg, "command", "setHardwareRate");
    xpc_dictionary_set_double(msg, "rate", rate);
    xpc_connection_send_message(conn, msg);
    xpc_release(msg);
}

static void sendMuteXPC(bool muted)
{
    xpc_connection_t conn = sXPCConn.load(std::memory_order_acquire);
    if (!conn) return;
    xpc_object_t msg = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_string(msg, "command", "setMute");
    xpc_dictionary_set_bool(msg, "muted", muted);
    xpc_connection_send_message(conn, msg);
    xpc_release(msg);
}

/// Backoff: 250 ms, 500 ms, 1 s, 2 s, then 5 s forever. Reset on a successful
/// mapping.
static void scheduleProxyReconnect()
{
    static const int kDelaysMs[] = { 250, 500, 1000, 2000, 5000 };
    const int idx = sReconnectAttempt < 4 ? sReconnectAttempt : 4;
    const int delayMs = kDelaysMs[idx];
    sReconnectAttempt++;
    os_log_info(sLog, "ApogeeSymIO: reconnect attempt %d in %d ms",
                sReconnectAttempt, delayMs);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delayMs * NSEC_PER_MSEC),
                   sXPCQueue, ^{ connectToProxy(); });
}

static void requestAudioShmem()
{
    xpc_connection_t conn = sXPCConn.load(std::memory_order_acquire);
    if (!conn) return;
    xpc_object_t msg = xpc_dictionary_create(nullptr, nullptr, 0);
    xpc_dictionary_set_string(msg, "command", "requestAudioShmem");
    xpc_connection_send_message(conn, msg);
    xpc_release(msg);
    os_log_info(sLog, "ApogeeSymIO: Requested audio shmem from proxy");
}

// ── Custom VolumeControl ─────────────────────────────────────────────────── //

/// SetRawValueImpl is the virtual extension point called by both the scalar
/// and dB write paths (SetScalarValue/SetDecibelValue both call SetRawValue).
///
/// Apogee range: raw 0 = -64 dB (atten=64), raw 64 = 0 dB (atten=0)
///               attenuation = 64 − rawValue
class ApogeeVolumeControl : public aspl::VolumeControl {
public:
    explicit ApogeeVolumeControl(std::shared_ptr<const aspl::Context> ctx,
                                  const aspl::VolumeControlParameters& p)
        : aspl::VolumeControl(ctx, p) {}

    // ── Hide the two conversion selectors the HAL cannot marshal ─────────── //
    //
    // macOS 26 hosts third-party AudioServerPlugIns out of process, and the XPC
    // bridge it uses — get_property_data:qualifier:data_size:reply: — carries
    // only an output SIZE. It has no way to pass the *input* payload that the
    // two in/out level-control selectors need. So when the volume-key handler
    // asks the HAL to convert a scalar to decibels, the HAL fails the call with
    // kAudioHardwareUnspecifiedError ('what', 2003329396) before this plugin is
    // ever reached, and abandons the key press without writing a new value.
    //
    // Measured on 26.6.2 (2026-09-14): every volume-up/down press produced two
    // `HALS_UCPlugIn::ObjectGetPropertyData ... Error: 2003329396` in coreaudiod
    // and zero calls into this class, while mute — which needs no conversion —
    // reached SetIsMuted() and worked. Scalar reads of this control succeeded
    // throughout, so the transport is fine; only the conversion is unroutable.
    //
    // Hiding the conversion selectors is enough to keep the key path on scalar
    // arithmetic. The value and range themselves are still safe to expose:
    // they are ordinary reads and let the macOS HUD render the actual dB level.
    // The previous implementation hid all four selectors, which restored key
    // presses but left the HUD with no usable dB range and made its slider look
    // stuck at full scale.
    //
    // Nothing on the USB path needs these: AppState listens to VolumeScalar for
    // USB/ASP (AppState.swift:1357) and only reads VolumeDecibels on the
    // Thunderbolt path, which is a different device and unaffected. The
    // hardware mapping itself is unchanged — SetRawValueImpl still converts
    // raw 0..64 to attenuation 64..0 exactly as before.
    static bool IsHiddenDecibelProperty(const AudioObjectPropertyAddress* address)
    {
        if (address == nullptr) {
            return false;
        }
        switch (address->mSelector) {
        case kAudioLevelControlPropertyConvertScalarToDecibels:
        case kAudioLevelControlPropertyConvertDecibelsToScalar:
            return true;
        default:
            return false;
        }
    }

    Boolean HasProperty(AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address) const override
    {
        if (IsHiddenDecibelProperty(address)) {
            return false;
        }
        return aspl::VolumeControl::HasProperty(objectID, clientPID, address);
    }

    OSStatus IsPropertySettable(AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address,
        Boolean* outIsSettable) const override
    {
        if (IsHiddenDecibelProperty(address)) {
            return kAudioHardwareUnknownPropertyError;
        }
        return aspl::VolumeControl::IsPropertySettable(
            objectID, clientPID, address, outIsSettable);
    }

    OSStatus GetPropertyDataSize(AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address,
        UInt32 qualifierDataSize,
        const void* qualifierData,
        UInt32* outDataSize) const override
    {
        if (IsHiddenDecibelProperty(address)) {
            return kAudioHardwareUnknownPropertyError;
        }
        return aspl::VolumeControl::GetPropertyDataSize(
            objectID, clientPID, address, qualifierDataSize, qualifierData, outDataSize);
    }

    OSStatus GetPropertyData(AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address,
        UInt32 qualifierDataSize,
        const void* qualifierData,
        UInt32 inDataSize,
        UInt32* outDataSize,
        void* outData) const override
    {
        if (IsHiddenDecibelProperty(address)) {
            return kAudioHardwareUnknownPropertyError;
        }
        return aspl::VolumeControl::GetPropertyData(objectID, clientPID, address,
            qualifierDataSize, qualifierData, inDataSize, outDataSize, outData);
    }

    OSStatus SetPropertyData(AudioObjectID objectID,
        pid_t clientPID,
        const AudioObjectPropertyAddress* address,
        UInt32 qualifierDataSize,
        const void* qualifierData,
        UInt32 inDataSize,
        const void* inData) override
    {
        if (IsHiddenDecibelProperty(address)) {
            return kAudioHardwareUnknownPropertyError;
        }
        return aspl::VolumeControl::SetPropertyData(objectID, clientPID, address,
            qualifierDataSize, qualifierData, inDataSize, inData);
    }

protected:
    OSStatus SetRawValueImpl(SInt32 value) override
    {
        OSStatus r = aspl::VolumeControl::SetRawValueImpl(value);
        if (r == kAudioHardwareNoError) {
            uint32_t atten = static_cast<uint32_t>(std::max(0, 64 - (int)value));
            os_log_info(sLog, "Volume raw=%d scalar=%.3f → attenuation=%u",
                (int)value, GetScalarValue(), atten);
            sendAttenuationXPC(atten);
        }
        return r;
    }
};

// ── Custom MuteControl ───────────────────────────────────────────────────── //

class ApogeeMuteControl : public aspl::MuteControl {
public:
    explicit ApogeeMuteControl(std::shared_ptr<const aspl::Context> ctx,
                                const aspl::MuteControlParameters& p)
        : aspl::MuteControl(ctx, p) {}

protected:
    OSStatus SetIsMutedImpl(bool isMuted) override
    {
        OSStatus r = aspl::MuteControl::SetIsMutedImpl(isMuted);
        if (r == kAudioHardwareNoError) {
            os_log_info(sLog, "Mute=%d → proxy", (int)isMuted);
            sendMuteXPC(isMuted);
        }
        return r;
    }
};

/// The two controls, for the XPC queue; lifetime owned by the device.
/// Published during CreateDriver, before connectToProxy is ever dispatched.
static ApogeeVolumeControl* sVolCtrlRaw  = nullptr;
static ApogeeMuteControl*   sMuteCtrlRaw = nullptr;

static void reconcileControlsFromProxy(xpc_object_t event)
{
    if (sVolCtrlRaw && xpc_dictionary_get_value(event, "attenuation")) {
        const uint64_t attenuation = std::min<uint64_t>(
            64, xpc_dictionary_get_uint64(event, "attenuation"));
        const SInt32 raw = static_cast<SInt32>(64 - attenuation);
        if (sVolCtrlRaw->GetRawValue() != raw)
            sVolCtrlRaw->SetRawValue(raw);
    }
    if (sMuteCtrlRaw && xpc_dictionary_get_value(event, "muted")) {
        sMuteCtrlRaw->SetIsMuted(xpc_dictionary_get_bool(event, "muted"));
    }
}

/// Push the controls' current values at the proxy.
///
/// Reads through the controls rather than caching a copy, so this says what the
/// HUD says by construction -- there is no second source of truth to drift.
static void resendVolumeAndMuteXPC()
{
    if (sVolCtrlRaw) {
        const SInt32 raw = sVolCtrlRaw->GetRawValue();
        const uint32_t atten = static_cast<uint32_t>(std::max(0, 64 - (int)raw));
        os_log_info(sLog, "ApogeeSymIO: restating volume to the proxy (raw=%d → attenuation=%u)",
                    (int)raw, atten);
        sendAttenuationXPC(atten);
    }
    if (sMuteCtrlRaw) sendMuteXPC(sMuteCtrlRaw->GetIsMuted());
}

// ── Control handler ──────────────────────────────────────────────────────── //

class ApogeeControlHandler : public aspl::ControlRequestHandler {
public:
    OSStatus OnStartIO() override
    {
        os_log_info(sLog, "ApogeeSymIO: StartIO");
        sIOActive.store(true, std::memory_order_release);
        if (!sSharedShm.load(std::memory_order_acquire)) {
            // Shmem not yet mapped — re-request from proxy (handles reconnects)
            requestAudioShmem();
        }
        if (MaestroAudioShm* shm = sSharedShm.load(std::memory_order_acquire)) {
            __atomic_fetch_add(&shm->producerEpoch, 1u, __ATOMIC_RELAXED);
            __atomic_store_n(&shm->producerLastHostTime, 0ull, __ATOMIC_RELEASE);
            __atomic_store_n(&shm->producerActive, 1u, __ATOMIC_RELEASE);
        }
        return kAudioHardwareNoError;
    }

    void OnStopIO() override
    {
        os_log_info(sLog, "ApogeeSymIO: StopIO");
        sIOActive.store(false, std::memory_order_release);
        receivedAudio_.store(false, std::memory_order_relaxed);
        if (MaestroAudioShm* shm = sSharedShm.load(std::memory_order_acquire))
            __atomic_store_n(&shm->producerActive, 0u, __ATOMIC_RELEASE);
    }

    std::shared_ptr<aspl::Client> OnAddClient(
        const aspl::ClientInfo& info) override
    {
        os_log_info(sLog, "ApogeeSymIO: Client added pid=%d", info.ClientID);
        return std::make_shared<aspl::Client>(info);
    }

    void OnRemoveClient(std::shared_ptr<aspl::Client>) override
    {
        os_log_info(sLog, "ApogeeSymIO: Client removed");
    }

    std::atomic<bool> receivedAudio_{false};
};

// ── IO handler ───────────────────────────────────────────────────────────── //

/// Receives mixed audio from apps and pushes it to the shared ring buffer.
/// MaestroVolumeProxy's HAL AudioUnit render callback consumes from the ring
/// and delivers audio to the real USB Symphony IO device.
///
/// Called on the realtime IO thread — no allocation, no blocking.
class ApogeeIOHandler : public aspl::IORequestHandler {
public:
    explicit ApogeeIOHandler(ApogeeControlHandler* ctrl) : ctrl_(ctrl) {}

    /// `timestamp` is where this buffer belongs on OUR timeline, in frames.
    /// We map it onto the hardware timeline and deposit it at exactly that slot,
    /// offset by the agreed presentation delay. No write pointer, no fill level:
    /// the slot IS the time, so the latency is delayFrames by construction and a
    /// skipped cycle costs one buffer of silence rather than a permanent offset.
    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>&,
        Float64, Float64 timestamp,
        const void* bytes, UInt32 bytesCount) override
    {
        MaestroAudioShm* shm = sSharedShm.load(std::memory_order_acquire);
        if (!shm || !sDeviceRaw) return;

        MaestroClockSnapshot hw;
        if (!maestro_shm_read_clock(shm, &hw)) return;

        // Never write against a timeline the device has not anchored to. After
        // an AudioUnit restart the slots still hold audio mapped by the OLD
        // timeline, and writing into that window splices the two together.
        if (hw.generation != sDeviceRaw->AnchorGeneration()) return;

        int64_t hwFrame = 0;
        if (!sDeviceRaw->MapToHardware(timestamp, &hwFrame)) return;  // no anchor yet

        const uint32_t frames = bytesCount / MAESTRO_SHM_BYTES_PER_FRAME;
        if (frames == 0) return;

        const int64_t slot = hwFrame + int64_t(shm->delayFrames);

        // A buffer that lands behind the proxy's read point cannot be heard on
        // time -- and if left in the ring it does not simply vanish: the reader
        // laps to it 32768 frames later and plays it, out of nowhere. Drop it
        // and count it. A non-zero lateWrites is the signal that D is too small.
        // The proxy consumed [hwSampleTime, hwSampleTime + readFrames) in its
        // last callback, so anything landing INSIDE that block is already too
        // late -- not merely anything before its start.
        const int64_t consumedEnd = int64_t(std::llrint(hw.hwSampleTime))
                                  + int64_t(__atomic_load_n(&shm->readFrames, __ATOMIC_RELAXED));
        if (slot < consumedEnd) {
            __atomic_fetch_add(&shm->lateWrites, 1u, __ATOMIC_RELAXED);
            return;
        }

        maestro_shm_write_at(shm, slot, bytes, frames);

        /* Publish callback liveness after the slot is committed. The proxy
           uses this only while active I/O is asserted; an idle AudioUnit with
           no app writes must never trigger a rebuild. */
        __atomic_store_n(&shm->producerLastHostTime, mach_absolute_time(), __ATOMIC_RELEASE);

        if (!ctrl_->receivedAudio_.load(std::memory_order_relaxed)) {
            ctrl_->receivedAudio_.store(true, std::memory_order_relaxed);
            os_log_info(sLog,
                "ApogeeSymIO: First audio (%u frames) → hw frame %lld → USB device",
                frames, (long long)hwFrame);
        }
    }

private:
    ApogeeControlHandler* ctrl_;
};

// ── Driver creation ──────────────────────────────────────────────────────── //

// Resolve the bundled artwork independently of the installation directory.
static std::string DeviceIconURL()
{
    CFBundleRef bundle = CFBundleGetBundleWithIdentifier(CFSTR("com.apogee.audio.symphonyio-asp"));
    if (!bundle) return {};
    CFURLRef url = CFBundleCopyResourceURL(bundle, CFSTR("AppIconRounded"), CFSTR("icns"), nullptr);
    if (!url) return {};
    CFStringRef text = CFURLGetString(url);
    CFIndex capacity = CFStringGetMaximumSizeForEncoding(CFStringGetLength(text), kCFStringEncodingUTF8) + 1;
    std::string result(static_cast<size_t>(capacity), '\0');
    if (CFStringGetCString(text, result.data(), capacity, kCFStringEncodingUTF8))
        result.resize(strlen(result.c_str()));
    else
        result.clear();
    CFRelease(url);
    return result;
}

static std::shared_ptr<aspl::Driver> CreateDriver()
{
    os_log_info(sLog, "ApogeeSymIO: Creating driver");

    auto context = std::make_shared<aspl::Context>();

    // Device parameters — named to match the real device's "Symphony I/O : ..."
    // style while staying distinct from "Symphony I/O : USB Audio".
    aspl::DeviceParameters dp;
    dp.Name         = "Symphony I/O : Maestro USB";
    dp.Manufacturer = "Apogee Electronics";
    dp.IconURL      = DeviceIconURL();

    // A STABLE UID, because libASPL's default is a random one per load:
    //   deviceUID_(!params.DeviceUID.empty() ? params.DeviceUID
    //                                        : params.ModelUID + ":" + GenerateUID())
    // (libaspl src/Device.cpp:21-22; the field is documented as the "persistent
    // token that can identify the same audio device across boot sessions" at
    // include/aspl/Device.hpp:42-45, and GetDeviceUID's contract at :192-200).
    // Leaving it empty minted a fresh "libaspl:xxxx" every time coreaudiod
    // loaded the plugin -- observed drift: Logic had "libaspl:debc-68b1-aea2-f9dd"
    // saved as its output device while the live device was
    // "libaspl:4dbc-3155-ff15-59d4". A DAW stores the UID, not the name, so every
    // coreaudiod restart silently dropped "Maestro USB" out of its I/O settings.
    // ModelUID is set too so the plugin is identifiable as ours rather than as
    // libASPL's default "libaspl".
    dp.DeviceUID    = "com.apogee.audio.symphonyio-asp:usb";
    dp.ModelUID     = "com.apogee.audio.symphonyio-asp:model";
    dp.SampleRate   = 48000;
    dp.ChannelCount = 16;
    dp.EnableMixing = true;

    // Presentation latency (frames @ dp.SampleRate). libASPL defaults Latency and SafetyOffset to 0,
    // which was actively WRONG: this device is NOT direct hardware — audio flows
    //   app → this plugin → shmem ring → MaestroVolumeProxy render → AppleUSBAudio → DAC.
    // That extra hop has real latency a direct device doesn't, yet we were reporting LESS than the
    // raw "Symphony I/O : USB Audio" device (which honestly reports ~14+14), so a DAW's delay
    // compensation was misaligned on our device. Report the dominant added term: the proxy's
    // render-buffer depth (one 512-frame downstream IO buffer between the plugin and the hardware).
    // Conservative estimate — precise per-firmware calibration would need an acoustic loopback
    // (a future enhancement to Tools/measure-latency.swift), but a defensible non-zero value is far
    // better than 0 for delay compensation.
    // v2 makes this number TRUE rather than aspirational. Audio deposited by
    // OnWriteMixedOutput lands at a slot the proxy reads exactly delayFrames
    // later on the shared hardware timeline, so the bridge adds precisely
    // MAESTRO_SHM_DELAY_FRAMES — not the 0-683 ms the old FIFO wandered through.
    // Downstream of us the USB device adds its own latency and safety offset
    // (~14 + 14 frames) that clients of THIS device cannot see, so fold it in.
    // Provisional: the real D is computed by the proxy from the USB device's
    // own buffer size and safety offset, and cannot be known here. We adopt it
    // via SetLatencyAsync once the shmem arrives. Safety offset is write-ahead,
    // not latency, so only the device's own latency (~14 frames) is added.
    dp.Latency      = MAESTRO_SHM_MIN_DELAY_FRAMES + 14;
    // How far ahead of the read point the HAL guarantees it has written. 32 was
    // thin for a writer that is a sandboxed helper competing for CPU. This value
    // appears in the D inequality, so the proxy must agree on it -- hence the
    // shared constant rather than a literal.
    dp.SafetyOffset = MAESTRO_SHM_PLUGIN_SAFETY;

    // One rate observation per this many frames. libASPL defaults it to the
    // sample rate — a full second — which leaves the HAL's clock filter slow to
    // settle after a re-anchor. 16384 frames is comfortably above Apple's 10923
    // minimum (AudioServerPlugIn.h:437, a frame count, so it does not scale with
    // the rate) and needs no adjusting when we follow the hardware: the period
    // stays 16384 frames at every rate, which is 0.37 s of observations at
    // 44.1 kHz and 0.085 s at 192 kHz. Faster at high rates is the harmless
    // direction.
    dp.ZeroTimeStampPeriod = 16384;

    auto device = std::make_shared<ApogeeDevice>(context, dp);
    sDeviceRaw = device.get();   // for the IO thread; lifetime owned by sDriver

    // The main stereo pair must be Left/Right so CoreAudio sends mono to both.
    // Remaining line/digital outputs are discrete, not surround positions:
    // libASPL's default Left + n labels output 3 Center and sends mono there.
    // An all-discrete layout instead sends mono only to output 1, even with
    // PreferredChannelsForStereo set. Indexed multichannel I/O preserves all
    // 16 channels with this stereo pair plus discrete remainder (see the live
    // playback verification); explicitly labeled file conversion is separate.
    // Publish the layout before attaching the device to the plugin (so the
    // configuration change is applied immediately). Keep stereo on outputs 1-2.
    std::vector<AudioChannelDescription> channels(dp.ChannelCount);
    for (UInt32 n = 0; n < dp.ChannelCount; ++n) {
        channels[n].mChannelLabel = n == 0 ? kAudioChannelLabel_Left
            : n == 1 ? kAudioChannelLabel_Right
            : kAudioChannelLabel_Discrete_0 + n;
    }
    device->SetPreferredChannelsAsync(std::move(channels));
    device->SetPreferredChannelsForStereoAsync({1, 2});

    // Advertise every rate the Symphony can run at. Without this libASPL reports
    // a single-entry list built from the current rate
    // (libaspl-src/src/Device.cpp:168-181), and CheckNominalSampleRate would
    // reject the follower's own set -- so the device could never leave 48 kHz
    // no matter what the hardware did.
    device->SetAvailableSampleRatesAsync(kSymphonyRates);

    // Output stream — interleaved Float32 16-channel so OnWriteMixedOutput delivers
    // interleaved bytes that match what the proxy's render callback expects.
    // 16 channels = 8 stereo pairs matching the USB device's 16 output channels.
    aspl::StreamParameters sp;
    sp.Direction                  = aspl::Direction::Output;
    sp.Format.mSampleRate         = 48000.0;
    sp.Format.mFormatID           = kAudioFormatLinearPCM;
    sp.Format.mFormatFlags        = kAudioFormatFlagsNativeFloatPacked; // interleaved
    sp.Format.mBitsPerChannel     = 32;
    sp.Format.mChannelsPerFrame   = 16;
    sp.Format.mBytesPerFrame      = 16 * sizeof(Float32);
    sp.Format.mFramesPerPacket    = 1;
    sp.Format.mBytesPerPacket     = 16 * sizeof(Float32);
    auto stream = device->AddStreamAsync(sp);

    // Streams are gated separately from the device: SetPhysicalFormatAsync checks
    // GetAvailablePhysicalFormats() (libaspl-src/src/Stream.cpp:78-96) and the
    // default list is just the current format. Both the physical and virtual
    // lists are needed -- the HAL reads both, and the rate follower sets both.
    {
        std::vector<AudioStreamRangedDescription> formats;
        formats.reserve(kSymphonyRates.size());
        for (const auto& r : kSymphonyRates) {
            AudioStreamRangedDescription rd{};
            rd.mFormat = sp.Format;
            rd.mFormat.mSampleRate = r.mMinimum;
            rd.mSampleRateRange = r;
            formats.push_back(rd);
        }
        stream->SetAvailablePhysicalFormatsAsync(formats);
        stream->SetAvailableVirtualFormatsAsync(formats);
    }
    device->AdoptStream(stream);

    // VolumeControl: -64 dB (raw=0, atten=64) → 0 dB (raw=64, atten=0)
    aspl::VolumeControlParameters vp;
    vp.Scope            = kAudioObjectPropertyScopeOutput;
    vp.MinRawVolume     = 0;
    vp.MaxRawVolume     = 64;
    vp.MinDecibelVolume = -64.0f;
    vp.MaxDecibelVolume =   0.0f;
    auto volCtrl = std::make_shared<ApogeeVolumeControl>(context, vp);
    // Safe default: raw 44 = -20 dB (atten 20). libASPL defaults to MaxRawVolume
    // (0 dB = 100%) which is dangerously loud on coreaudiod restart. The send this
    // triggers goes nowhere -- there is no XPC connection yet -- which is why
    // resendVolumeAndMuteXPC restates it once the proxy answers.
    volCtrl->SetRawValue(44);
    device->AddVolumeControlAsync(volCtrl);
    sVolCtrlRaw = volCtrl.get();

    // MuteControl
    aspl::MuteControlParameters mp;
    mp.Scope = kAudioObjectPropertyScopeOutput;
    auto muteCtrl = std::make_shared<ApogeeMuteControl>(context, mp);
    device->AddMuteControlAsync(muteCtrl);
    sMuteCtrlRaw = muteCtrl.get();

    // IO lifecycle + audio handlers
    auto ctrl = std::make_shared<ApogeeControlHandler>();
    auto io   = std::make_shared<ApogeeIOHandler>(ctrl.get());
    device->SetControlHandler(ctrl);
    device->SetIOHandler(io);

    os_log_info(sLog, "ApogeeSymIO: Device ready — stream + volume + mute");

    auto plugin = std::make_shared<aspl::Plugin>(context);
    plugin->AddDevice(device);
    auto driver = std::make_shared<aspl::Driver>(context, plugin);

    // XPC connection to MaestroVolumeProxy, on its own serial queue so the
    // event handler can safely replace the connection on INVALID.
    sXPCQueue = dispatch_queue_create("com.apogee.symphonyio-asp.xpc",
                                      DISPATCH_QUEUE_SERIAL);
    dispatch_async(sXPCQueue, ^{ connectToProxy(); });

    // Watch the hardware while nothing is playing: its rate, and whether it is
    // plugged in at all.
    //
    // The follower in GetZeroTimeStampImpl only runs when the HAL asks us for a
    // timestamp, which it only does while this device has IO running. So every
    // rate change made with this device idle -- the front panel, Audio MIDI
    // Setup pointed at the raw device, another app, a DAW imposing its project
    // rate -- left us at the old rate until the next playback, and the first
    // buffers of that playback then paid a configuration change. Worse, until
    // the rates agreed the clock mapping could not be built at all
    // (kMaestroClockRateMismatch), because ring slots are named in HARDWARE
    // frames: an idle device at the wrong rate is a device that starts silent.
    //
    // FollowHardwareRateNow was written for exactly this and was only called
    // once, when the shared memory first mapped. The proxy already publishes
    // hwNominalRate on every change, so the missing piece was simply looking at
    // it. Two shm reads per second on a queue that is otherwise asleep, with a
    // half-second leeway so it coalesces with other timers; RequestFollow dedupes
    // per distinct target under a CAS, so this cannot spin on a rate we cannot
    // reach, and both checks cost nothing while nothing has changed.
    //
    // UpdatePresence rides the same tick for the same reason: the device has to
    // disappear from Sound when the Symphony is unplugged whether or not the
    // Maestro app is running.
    //
    // This is deliberately in the driver rather than in the Maestro app: the
    // virtual device must follow the hardware whether or not the app is
    // running, and an app that has to be open for audio to work is not a fix.
    sFollowTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, sXPCQueue);
    if (sFollowTimer) {
        dispatch_source_set_timer(sFollowTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                                  NSEC_PER_SEC,
                                  NSEC_PER_SEC / 2);
        dispatch_source_set_event_handler(sFollowTimer, ^{
            if (!sDeviceRaw) return;
            sDeviceRaw->FollowHardwareRateNow();
            sDeviceRaw->UpdatePresence();
        });
        dispatch_resume(sFollowTimer);
    } else {
        os_log_error(sLog,
            "ApogeeSymIO: could not create the rate-follow timer — this device "
            "will only adopt a new hardware rate once something plays through it");
    }

    return driver;
}

// ── CFPlugIn factory ─────────────────────────────────────────────────────── //

extern "C" void* ApogeeSymIO_Create(CFAllocatorRef, CFUUIDRef typeUUID)
{
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        os_log_error(sLog, "ApogeeSymIO_Create: wrong type UUID");
        return nullptr;
    }
    os_log_info(sLog, "ApogeeSymIO_Create: initializing");
    if (!sDriver) sDriver = CreateDriver();
    return sDriver->GetReference();
}
