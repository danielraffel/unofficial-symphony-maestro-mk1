// HostDriverKit.h — host-side stand-ins for the DriverKit, PCIDriverKit and
// AudioDriverKit types SymphonyThunderbridge.cpp uses.
//
// Purpose: compile the REAL driver source on the host and run its Start /
// StartDevice / Stop paths against a simulated card, recording every register
// access in order (see RegisterTrace.cpp and Drivers/Thunderbolt/run-tests.sh).
// Nothing here is shipped; none of it models the frameworks beyond what the
// driver calls. Hardware accesses go to HostBackend, which records them.
#pragma once

#include <Block.h>
#include <IOKit/IOReturn.h>
#include <mach/kern_return.h>

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <string>
#include <time.h>
#include <vector>

// ── Backend: the simulated card + trace recorder (implemented by the test) ──
struct HostBackend {
    virtual ~HostBackend() = default;
    virtual void     ConfigRead32(uint64_t off, uint32_t *v) = 0;
    virtual void     ConfigRead16(uint64_t off, uint16_t *v) = 0;
    virtual void     ConfigWrite16(uint64_t off, uint16_t v) = 0;
    virtual void     MemRead32(uint8_t mi, uint64_t off, uint32_t *v) = 0;
    virtual void     MemWrite32(uint8_t mi, uint64_t off, uint32_t v) = 0;
    virtual void     Sleep(uint64_t ms) = 0;
    // Host-side resource events that are not register accesses but that the
    // port-2 work must not change either (DMA allocations, stream formats…).
    virtual void     HostEvent(const std::string &what) = 0;
    virtual uint64_t NextDMAAddress(uint64_t size) = 0;
    // Personality properties the driver may read at Start (name → value).
    std::map<std::string, uint64_t> personalityNumbers;
    std::map<std::string, std::string> personalityStrings;
};
extern HostBackend *gHostBackend;

void HostLog(const char *fmt, ...);
#define OS_LOG_DEFAULT 0
#define OS_LOG_TYPE_DEFAULT 0
#define os_log(log, fmt, ...) HostLog(fmt, ##__VA_ARGS__)

static inline void IOSleep(uint64_t ms) { gHostBackend->Sleep(ms); }

// IOLock: the host test is single-threaded; count the holds so a test can see
// an unbalanced lock.
struct IOLock { int held = 0; };
static inline IOLock *IOLockAlloc() { return new IOLock; }
static inline void IOLockFree(IOLock *l) { delete l; }
extern int gHostLocksHeld;
static inline void IOLockLock(IOLock *l) { l->held++; gHostLocksHeld++; }
static inline void IOLockUnlock(IOLock *l) { l->held--; gHostLocksHeld--; }

// ── libkern ─────────────────────────────────────────────────────────────────
class OSObject {
public:
    virtual ~OSObject() = default;
    virtual bool init() { return true; }
    virtual void free() {}
    void retain() { refs_++; }
    void release() { if (--refs_ == 0) { free(); delete this; } }
private:
    int refs_ = 1;
};

#define OSDynamicCast(type, inst) dynamic_cast<type *>(inst)
#define OSTypeAlloc(type) (new type)
#define OSSafeReleaseNULL(inst) do { if (nullptr != (inst)) { (inst)->release(); (inst) = nullptr; } } while (0)
#define IONewZero(type, count) (static_cast<type *>(calloc((count), sizeof(type))))
#define IOSafeDeleteNULL(ptr, type, count) do { if (ptr) { ::free(ptr); (ptr) = nullptr; } } while (0)
#define IODelete(ptr, type, count) ::free(ptr)

struct OSNoRetainTag {};
static constexpr OSNoRetainTag OSNoRetain{};
struct OSRetainTag {};
static constexpr OSRetainTag OSRetain{};

template <typename T>
class OSSharedPtr {
public:
    OSSharedPtr() = default;
    OSSharedPtr(T *p, OSNoRetainTag) : p_(p) {}
    OSSharedPtr(T *p, OSRetainTag) : p_(p) { if (p_) p_->retain(); }
    OSSharedPtr(const OSSharedPtr &o) : p_(o.p_) { if (p_) p_->retain(); }
    template <typename U>
    OSSharedPtr(const OSSharedPtr<U> &o) : p_(o.get()) { if (p_) p_->retain(); }
    OSSharedPtr &operator=(const OSSharedPtr &o) {
        if (o.p_) o.p_->retain();
        if (p_) p_->release();
        p_ = o.p_;
        return *this;
    }
    ~OSSharedPtr() { if (p_) p_->release(); }
    T *get() const { return p_; }
    T *detach() { T *p = p_; p_ = nullptr; return p; }
    T *operator->() const { return p_; }
    explicit operator bool() const { return p_ != nullptr; }
private:
    T *p_ = nullptr;
};

class OSString : public OSObject {
public:
    static OSString *withCString(const char *s) { auto *o = new OSString; o->s_ = s; return o; }
    const char *getCStringNoCopy() const { return s_.c_str(); }
private:
    std::string s_;
};

class OSNumber : public OSObject {
public:
    static OSNumber *withNumber(uint64_t v, uint32_t) { auto *o = new OSNumber; o->v_ = v; return o; }
    uint32_t unsigned32BitValue() const { return (uint32_t)v_; }
    uint64_t unsigned64BitValue() const { return v_; }
private:
    uint64_t v_ = 0;
};

class OSDictionary : public OSObject {
public:
    ~OSDictionary() override { for (auto &kv : m_) kv.second->release(); }
    void set(const std::string &k, OSObject *o) { m_[k] = o; }
    OSObject *getObject(const char *key) const {
        auto it = m_.find(key);
        return it == m_.end() ? nullptr : it->second;
    }
private:
    std::map<std::string, OSObject *> m_;
};

class OSAction : public OSObject {};
typedef OSObject OSContainer;

// ── Dispatch ────────────────────────────────────────────────────────────────
// DispatchSync runs inline (after anything already queued on that queue, as a
// serial queue would). DispatchAsync and Cancel completions are deferred until
// the test calls HostPump(), which keeps the order deterministic.
typedef void (^HostBlock)(void);
void HostDefer(std::deque<HostBlock> *queue, HostBlock b);
void HostDrain(std::deque<HostBlock> *queue);
void HostPump();
extern std::deque<HostBlock> gHostCompletions;

class IODispatchQueue : public OSObject {
public:
    static kern_return_t Create(const char *, uint64_t, uint64_t, IODispatchQueue **out) {
        *out = new IODispatchQueue;
        return kIOReturnSuccess;
    }
    void DispatchSync(HostBlock b) { HostDrain(&pending); b(); }
    void DispatchAsync(HostBlock b) { HostDefer(&pending, b); }
    std::deque<HostBlock> pending;
};

static constexpr uint64_t kIOTimerClockMonotonicRaw = 1;

class IOTimerDispatchSource : public OSObject {
public:
    static kern_return_t Create(IODispatchQueue *, IOTimerDispatchSource **out) {
        *out = new IOTimerDispatchSource;
        return kIOReturnSuccess;
    }
    kern_return_t SetHandler(OSAction *) { return kIOReturnSuccess; }
    kern_return_t WakeAtTime(uint64_t, uint64_t, uint64_t) { return kIOReturnSuccess; }
    kern_return_t Cancel(HostBlock b) { HostDefer(&gHostCompletions, b); return kIOReturnSuccess; }
};

// ── IOService ───────────────────────────────────────────────────────────────
struct SuperDispatchTag {};
static constexpr SuperDispatchTag SUPERDISPATCH{};
static constexpr const char *kIOServiceDefaultQueueName = "Default";
static constexpr uint32_t kIOServicePowerCapabilityOff = 0x00000000;
static constexpr uint32_t kIOServicePowerCapabilityOn  = 0x00000002;

class IOUserClient;

class IOService : public OSObject {
public:
    kern_return_t Start(IOService *, SuperDispatchTag) { return kIOReturnSuccess; }
    kern_return_t Stop(IOService *, SuperDispatchTag) { return kIOReturnSuccess; }
    kern_return_t SetPowerState(uint32_t, SuperDispatchTag) { return kIOReturnSuccess; }
    kern_return_t NewUserClient(uint32_t, IOUserClient **, SuperDispatchTag) { return kIOReturnUnsupported; }
    kern_return_t RegisterService() { return kIOReturnSuccess; }
    kern_return_t CopyDispatchQueue(const char *, IODispatchQueue **out) {
        *out = new IODispatchQueue;
        return kIOReturnSuccess;
    }
    kern_return_t Create(IOService *, const char *, IOService **out) { *out = nullptr; return kIOReturnUnsupported; }
    // The service's own properties, which include its matched personality.
    kern_return_t CopyProperties(OSDictionary **out) {
        auto *d = new OSDictionary;
        for (auto &kv : gHostBackend->personalityNumbers)
            d->set(kv.first, OSNumber::withNumber(kv.second, 64));
        for (auto &kv : gHostBackend->personalityStrings)
            d->set(kv.first, OSString::withCString(kv.second.c_str()));
        *out = d;
        return kIOReturnSuccess;
    }
};

class IOUserClient : public IOService {};

// ── Memory / DMA ────────────────────────────────────────────────────────────
static constexpr uint64_t kIOMemoryDirectionIn    = 1;
static constexpr uint64_t kIOMemoryDirectionOut   = 2;
static constexpr uint64_t kIOMemoryDirectionInOut = 3;
static constexpr uint64_t kIOMemoryMapCacheModeInhibit = 0x100;

class IOMemoryMap : public OSObject {
public:
    explicit IOMemoryMap(void *a) : a_(a) {}
    uint64_t GetAddress() const { return (uint64_t)(uintptr_t)a_; }
private:
    void *a_;
};

class IOMemoryDescriptor : public OSObject {
public:
    ~IOMemoryDescriptor() override { ::free(mem_); }
    kern_return_t CreateMapping(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, IOMemoryMap **out) {
        *out = new IOMemoryMap(mem_);
        return kIOReturnSuccess;
    }
    void *mem_ = nullptr;
    uint64_t size_ = 0;
};

class IOBufferMemoryDescriptor;
void HostNoteBuffer(IOBufferMemoryDescriptor *b);

class IOBufferMemoryDescriptor : public IOMemoryDescriptor {
public:
    static kern_return_t Create(uint64_t, uint64_t capacity, uint64_t, IOBufferMemoryDescriptor **out) {
        auto *b = new IOBufferMemoryDescriptor;
        b->mem_ = calloc(1, capacity);
        b->size_ = capacity;
        char buf[64];
        snprintf(buf, sizeof(buf), "buffer-create size=%llu", (unsigned long long)capacity);
        gHostBackend->HostEvent(buf);
        *out = b;
        HostNoteBuffer(b);
        return kIOReturnSuccess;
    }
    kern_return_t SetLength(uint64_t) { return kIOReturnSuccess; }
};

struct IODMACommandSpecification { uint64_t options; uint64_t maxAddressBits; };
struct IOAddressSegment { uint64_t address; uint64_t length; };
static constexpr uint64_t kIODMACommandSpecificationNoOptions = 0;
static constexpr uint64_t kIODMACommandCreateNoOptions = 0;
static constexpr uint64_t kIODMACommandPrepareForDMANoOptions = 0;
static constexpr uint64_t kIODMACommandCompleteDMANoOptions = 0;
static constexpr uint64_t kIODMACommandPerformOperationOptionZero = 3;

class IODMACommand : public OSObject {
public:
    static kern_return_t Create(IOService *, uint64_t, const IODMACommandSpecification *, IODMACommand **out) {
        *out = new IODMACommand;
        return kIOReturnSuccess;
    }
    kern_return_t PrepareForDMA(uint64_t, IOMemoryDescriptor *mem, uint64_t, uint64_t,
                                uint64_t *flags, uint32_t *segCount, IOAddressSegment *segs) {
        addr_ = gHostBackend->NextDMAAddress(mem->size_);
        size_ = mem->size_;
        mem_ = mem;
        *flags = 0;
        *segCount = 1;
        segs[0].address = addr_;
        segs[0].length = size_;
        char buf[96];
        snprintf(buf, sizeof(buf), "dma-prepare size=%llu addr=0x%08llx",
                 (unsigned long long)size_, (unsigned long long)addr_);
        gHostBackend->HostEvent(buf);
        return kIOReturnSuccess;
    }
    kern_return_t CompleteDMA(uint64_t) {
        char buf[64];
        snprintf(buf, sizeof(buf), "dma-complete addr=0x%08llx", (unsigned long long)addr_);
        gHostBackend->HostEvent(buf);
        return kIOReturnSuccess;
    }
    kern_return_t PerformOperation(uint64_t op, uint64_t offset, uint64_t length, uint64_t, IOMemoryDescriptor *) {
        // The zero operation really zeroes (no trace line), so a test can see it.
        if (op == kIODMACommandPerformOperationOptionZero && mem_ && mem_->mem_ && offset + length <= mem_->size_)
            memset((char *)mem_->mem_ + offset, 0, length);
        return kIOReturnSuccess;
    }
private:
    uint64_t addr_ = 0, size_ = 0;
    IOMemoryDescriptor *mem_ = nullptr;
};

// ── PCI ─────────────────────────────────────────────────────────────────────
class IOPCIDevice : public IOService {
public:
    kern_return_t Open(IOService *, uint64_t) { gHostBackend->HostEvent("pci-open"); return kIOReturnSuccess; }
    void Close(IOService *, uint64_t) { gHostBackend->HostEvent("pci-close"); }
    void ConfigurationRead32(uint64_t off, uint32_t *v) { gHostBackend->ConfigRead32(off, v); }
    void ConfigurationRead16(uint64_t off, uint16_t *v) { gHostBackend->ConfigRead16(off, v); }
    void ConfigurationWrite16(uint64_t off, uint16_t v) { gHostBackend->ConfigWrite16(off, v); }
    kern_return_t GetBARInfo(uint8_t, uint8_t *memoryIndex, uint64_t *barSize, uint8_t *barType) {
        *memoryIndex = 0;
        *barSize = 0x400000;
        *barType = 0;
        return kIOReturnSuccess;
    }
    void MemoryRead32(uint8_t mi, uint64_t off, uint32_t *v) { gHostBackend->MemRead32(mi, off, v); }
    void MemoryWrite32(uint8_t mi, uint64_t off, uint32_t v) { gHostBackend->MemWrite32(mi, off, v); }
};

class IOInterruptDispatchSource : public OSObject {
public:
    static kern_return_t Create(IOService *, uint32_t index, IODispatchQueue *, IOInterruptDispatchSource **out) {
        char buf[48];
        snprintf(buf, sizeof(buf), "interrupt-source index=%u", index);
        gHostBackend->HostEvent(buf);
        *out = new IOInterruptDispatchSource;
        return kIOReturnSuccess;
    }
    kern_return_t SetHandler(OSAction *) { return kIOReturnSuccess; }
    kern_return_t SetEnableWithCompletion(bool on, HostBlock) {
        gHostBackend->HostEvent(on ? "interrupt-enable" : "interrupt-disable");
        return kIOReturnSuccess;
    }
    kern_return_t Cancel(HostBlock b) {
        gHostBackend->HostEvent("interrupt-cancel");
        HostDefer(&gHostCompletions, b);
        return kIOReturnSuccess;
    }
};

// ── AudioDriverKit ──────────────────────────────────────────────────────────
typedef uint32_t IOUserAudioObjectID;
typedef uint32_t IOUserAudioObjectPropertyElement;
typedef uint32_t IOUserAudioSelectorValue;
static constexpr IOUserAudioObjectPropertyElement IOUserAudioObjectPropertyElementMain = 0;
enum class IOUserAudioStartStopFlags : uint64_t { None = 0 };
enum class IOUserAudioObjectPropertyScope : uint32_t { Global, Input, Output };
enum class IOUserAudioClassID : uint32_t {
    VolumeControl, MuteControl, ClockSourceControl, DataSourceControl, PhantomPowerControl
};
enum class IOUserAudioTransportType : uint32_t { Thunderbolt };
enum class IOUserAudioStreamDirection : uint32_t { Output, Input };
enum class IOUserAudioStreamTerminalType : uint32_t { Line };
enum class IOUserAudioFormatID : uint32_t { LinearPCM };
enum IOUserAudioFormatFlags : uint32_t { IOUserAudioFormatFlagsNone = 0 };
enum IOUserAudioIOOperation : uint32_t { IOUserAudioIOOperationBeginRead, IOUserAudioIOOperationWriteEnd };
enum class IOUserAudioCustomPropertyDataType : uint32_t { None, Dictionary };

struct IOUserAudioStreamBasicDescription {
    double mSampleRate;
    IOUserAudioFormatID mFormatID;
    IOUserAudioFormatFlags mFormatFlags;
    uint32_t mBytesPerPacket;
    uint32_t mFramesPerPacket;
    uint32_t mBytesPerFrame;
    uint32_t mChannelsPerFrame;
    uint32_t mBitsPerChannel;
    uint32_t mReserved;
};
struct IOUserAudioLevelControlRange { float mMinimum; float mMaximum; };
struct IOUserAudioSelectorValueDescription { IOUserAudioSelectorValue mValue; OSSharedPtr<OSString> mName; };
struct IOUserAudioObjectPropertyAddress {
    uint32_t mSelector;
    IOUserAudioObjectPropertyScope mScope;
    IOUserAudioObjectPropertyElement mElement;
};

class IOUserAudioObject : public OSObject {};
class IOUserAudioDriver;
class IOUserAudioDevice;
class IOUserAudioLevelControl;
class IOUserAudioBooleanControl;

// What the driver published, so the test can play the part of Core Audio
// (change the sample rate, move the volume control).
class IOUserAudioStream;
class IOUserAudioSelectorControl;
class IOBufferMemoryDescriptor;
struct HostAudioRegistry {
    IOUserAudioDevice *device = nullptr;
    IOUserAudioLevelControl *volume = nullptr;
    IOUserAudioBooleanControl *mute = nullptr;
    // Two-port experiment (none of these produce trace lines):
    IOUserAudioStream *inStream = nullptr, *outStream = nullptr;
    std::vector<IOUserAudioSelectorControl *> portSources;   // input, output
    std::vector<IOBufferMemoryDescriptor *> buffers;         // every buffer, in creation order
    void *ioHandler = nullptr;                               // the IOOperationHandler block
    uint64_t lastConfigChangeAction = 0;
    uint32_t configChangeRequests = 0;
};
extern HostAudioRegistry gHostAudio;

class IOUserAudioControl : public IOUserAudioObject {};

class IOUserAudioLevelControl : public IOUserAudioControl {
public:
    static OSSharedPtr<IOUserAudioLevelControl> Create(IOUserAudioDriver *d, bool settable, float db,
            IOUserAudioLevelControlRange range, IOUserAudioObjectPropertyElement e,
            IOUserAudioObjectPropertyScope s, IOUserAudioClassID c) {
        auto *o = new IOUserAudioLevelControl;
        o->init(d, settable, db, range, e, s, c);
        gHostAudio.volume = o;
        return OSSharedPtr<IOUserAudioLevelControl>(o, OSNoRetain);
    }
    using OSObject::init;
    virtual bool init(IOUserAudioDriver *, bool, float db, IOUserAudioLevelControlRange,
                      IOUserAudioObjectPropertyElement, IOUserAudioObjectPropertyScope, IOUserAudioClassID) {
        db_ = db;
        return true;
    }
    float GetDecibelValue() const { return db_; }
    kern_return_t SetDecibelValue(float db) { db_ = db; return kIOReturnSuccess; }
private:
    float db_ = 0;
};

class IOUserAudioBooleanControl : public IOUserAudioControl {
public:
    static OSSharedPtr<IOUserAudioBooleanControl> Create(IOUserAudioDriver *d, bool settable, bool v,
            IOUserAudioObjectPropertyElement e, IOUserAudioObjectPropertyScope s, IOUserAudioClassID c) {
        auto *o = new IOUserAudioBooleanControl;
        o->init(d, settable, v, e, s, c);
        gHostAudio.mute = o;
        return OSSharedPtr<IOUserAudioBooleanControl>(o, OSNoRetain);
    }
    using OSObject::init;
    virtual bool init(IOUserAudioDriver *, bool, bool v, IOUserAudioObjectPropertyElement,
                      IOUserAudioObjectPropertyScope, IOUserAudioClassID) {
        v_ = v;
        return true;
    }
    bool GetControlValue() const { return v_; }
    kern_return_t SetControlValue(bool v) { v_ = v; return kIOReturnSuccess; }
private:
    bool v_ = false;
};

class IOUserAudioSelectorControl : public IOUserAudioControl {
public:
    using OSObject::init;
    virtual bool init(IOUserAudioDriver *, bool, IOUserAudioObjectPropertyElement,
                      IOUserAudioObjectPropertyScope, IOUserAudioClassID) { return true; }
    kern_return_t AddControlValueDescriptions(const IOUserAudioSelectorValueDescription *d, size_t n) {
        names.clear();
        for (size_t i = 0; i < n; i++) names.push_back(d[i].mName.get()->getCStringNoCopy());
        return kIOReturnSuccess;
    }
    kern_return_t SetCurrentSelectedValues(const IOUserAudioSelectorValue *v, size_t n) {
        if (n) selected = v[0];
        sets++;
        return kIOReturnSuccess;
    }
    // Host-test state (no trace lines).
    IOUserAudioSelectorValue selected = 0;
    uint32_t sets = 0;
    std::vector<std::string> names;
};

class IOUserAudioCustomProperty : public IOUserAudioObject {
public:
    static OSSharedPtr<IOUserAudioCustomProperty> Create(IOUserAudioDriver *, IOUserAudioObjectPropertyAddress, bool,
            IOUserAudioCustomPropertyDataType, IOUserAudioCustomPropertyDataType) {
        return OSSharedPtr<IOUserAudioCustomProperty>(new IOUserAudioCustomProperty, OSNoRetain);
    }
};

class IOUserAudioStream : public IOUserAudioObject {
public:
    static OSSharedPtr<IOUserAudioStream> Create(IOUserAudioDriver *, IOUserAudioStreamDirection dir, IOMemoryDescriptor *mem) {
        auto *s = new IOUserAudioStream;
        s->input_ = (dir == IOUserAudioStreamDirection::Input);
        char buf[80];
        snprintf(buf, sizeof(buf), "stream-create dir=%s buffer=%llu", s->input_ ? "in" : "out",
                 (unsigned long long)mem->size_);
        gHostBackend->HostEvent(buf);
        (s->input_ ? gHostAudio.inStream : gHostAudio.outStream) = s;
        s->memory = mem;
        return OSSharedPtr<IOUserAudioStream>(s, OSNoRetain);
    }
    kern_return_t SetAvailableStreamFormats(const IOUserAudioStreamBasicDescription *f, size_t n) {
        for (size_t i = 0; i < n; i++) {
            char buf[128];
            snprintf(buf, sizeof(buf), "stream-format dir=%s rate=%.0f channels=%u bytesPerFrame=%u bits=%u",
                     input_ ? "in" : "out", f[i].mSampleRate, f[i].mChannelsPerFrame,
                     f[i].mBytesPerFrame, f[i].mBitsPerChannel);
            gHostBackend->HostEvent(buf);
        }
        return kIOReturnSuccess;
    }
    kern_return_t SetCurrentStreamFormat(const IOUserAudioStreamBasicDescription *f) {
        current = *f;
        return kIOReturnSuccess;
    }
    kern_return_t SetIOMemoryDescriptor(IOMemoryDescriptor *mem) {
        memory = mem;
        char buf[80];
        snprintf(buf, sizeof(buf), "stream-buffer dir=%s buffer=%llu", input_ ? "in" : "out",
                 (unsigned long long)mem->size_);
        gHostBackend->HostEvent(buf);
        return kIOReturnSuccess;
    }
    // Host-test state (no trace lines).
    IOUserAudioStreamBasicDescription current = {};
    IOMemoryDescriptor *memory = nullptr;
    kern_return_t SetTerminalType(IOUserAudioStreamTerminalType) { return kIOReturnSuccess; }
    kern_return_t SetStartingChannel(uint32_t ch) {
        char buf[64];
        snprintf(buf, sizeof(buf), "stream-starting-channel dir=%s ch=%u", input_ ? "in" : "out", ch);
        gHostBackend->HostEvent(buf);
        return kIOReturnSuccess;
    }
private:
    bool input_ = false;
};

typedef kern_return_t (^IOOperationHandler)(IOUserAudioObjectID, IOUserAudioIOOperation, uint32_t, uint64_t, uint64_t);

class IOUserAudioDevice : public IOUserAudioObject {
public:
    using OSObject::init;
    virtual bool init(IOUserAudioDriver *, bool, OSString *, OSString *, OSString *, uint32_t) {
        gHostAudio.device = this;
        return true;
    }
    kern_return_t SetAvailableSampleRates(const double *, size_t) { return kIOReturnSuccess; }
    kern_return_t SetSampleRate(double r) { rate_ = r; return kIOReturnSuccess; }
    double GetSampleRate() const { return rate_; }
    kern_return_t SetTransportType(IOUserAudioTransportType) { return kIOReturnSuccess; }
    kern_return_t SetCanBeDefaultInputDevice(bool) { return kIOReturnSuccess; }
    kern_return_t SetCanBeDefaultOutputDevice(bool) { return kIOReturnSuccess; }
    kern_return_t SetCanBeDefaultSystemOutputDevice(bool) { return kIOReturnSuccess; }
    kern_return_t SetInputSafetyOffset(uint32_t v) { inSafety_ = v; return kIOReturnSuccess; }
    kern_return_t SetOutputSafetyOffset(uint32_t v) { outSafety_ = v; return kIOReturnSuccess; }
    kern_return_t SetInputLatency(uint32_t v) { inLatency_ = v; return kIOReturnSuccess; }
    kern_return_t SetOutputLatency(uint32_t v) { outLatency_ = v; return kIOReturnSuccess; }
    uint32_t GetInputSafetyOffset() const { return inSafety_; }
    uint32_t GetOutputSafetyOffset() const { return outSafety_; }
    uint32_t GetInputLatency() const { return inLatency_; }
    uint32_t GetOutputLatency() const { return outLatency_; }
    kern_return_t SetPreferredChannelsForStereo(uint32_t, uint32_t) { return kIOReturnSuccess; }
    kern_return_t AddStream(IOUserAudioStream *) { gHostBackend->HostEvent("device-add-stream"); return kIOReturnSuccess; }
    kern_return_t RemoveStream(IOUserAudioStream *) { return kIOReturnSuccess; }
    kern_return_t AddControl(IOUserAudioControl *) { return kIOReturnSuccess; }
    kern_return_t RemoveControl(IOUserAudioControl *) { return kIOReturnSuccess; }
    kern_return_t AddCustomProperty(IOUserAudioCustomProperty *) { return kIOReturnSuccess; }
    kern_return_t RemoveCustomProperty(IOUserAudioCustomProperty *) { return kIOReturnSuccess; }
    kern_return_t SetIOOperationHandler(IOOperationHandler h) {
        gHostAudio.ioHandler = (void *)Block_copy(h);
        return kIOReturnSuccess;
    }
    kern_return_t SetName(OSString *) { return kIOReturnSuccess; }
    // Per-channel names (option-card parity): recorded so a trace pins which
    // host channels get which name, and when. A null name removes it.
    kern_return_t SetElementName(uint32_t element, IOUserAudioObjectPropertyScope scope, OSString *name) {
        char buf[96];
        snprintf(buf, sizeof(buf), "element-name dir=%s ch=%u name=%s",
                 scope == IOUserAudioObjectPropertyScope::Input ? "in"
                 : scope == IOUserAudioObjectPropertyScope::Output ? "out" : "global",
                 element, name ? name->getCStringNoCopy() : "(none)");
        gHostBackend->HostEvent(buf);
        return kIOReturnSuccess;
    }
    kern_return_t UpdateCurrentZeroTimestamp(uint64_t, uint64_t) { return kIOReturnSuccess; }
    kern_return_t RequestDeviceConfigurationChange(uint64_t action, OSObject *) {
        gHostAudio.lastConfigChangeAction = action;
        gHostAudio.configChangeRequests++;
        gHostBackend->HostEvent("device-config-change-request");
        return kIOReturnSuccess;
    }
private:
    double rate_ = 0;
    uint32_t inSafety_ = 0, outSafety_ = 0, inLatency_ = 0, outLatency_ = 0;
};

class IOUserAudioDriver : public IOService {
public:
    virtual kern_return_t StartDevice(IOUserAudioObjectID, IOUserAudioStartStopFlags) { return kIOReturnSuccess; }
    virtual kern_return_t StopDevice(IOUserAudioObjectID, IOUserAudioStartStopFlags) { return kIOReturnSuccess; }
    kern_return_t AddObject(IOUserAudioObject *) { gHostBackend->HostEvent("driver-add-device"); return kIOReturnSuccess; }
    kern_return_t RemoveObject(IOUserAudioObject *) { return kIOReturnSuccess; }
    kern_return_t SetTransportType(IOUserAudioTransportType) { return kIOReturnSuccess; }
};

// ── The driver's own generated classes (normally produced by iig) ───────────
class SymphonyThunderbridge;

class SymphonyAudioDevice : public IOUserAudioDevice {
public:
    void SetPortModeDriver(SymphonyThunderbridge *d) { portModeDriver = d; }
    SymphonyThunderbridge *portModeDriver = nullptr;
};
class SymphonyUserClient : public IOUserClient {
public:
    void SetDriver(SymphonyThunderbridge *) {}
};
class SymphonyClockSelectorControl : public IOUserAudioSelectorControl {
public:
    void SetDriver(SymphonyThunderbridge *) {}
};
class SymphonyOpticalControl : public IOUserAudioSelectorControl {
public:
    void SetDriver(SymphonyThunderbridge *) {}
    void SetBoard(uint32_t) {}
};
class SymphonyPortSourceControl : public IOUserAudioSelectorControl {
public:
    SymphonyPortSourceControl() { gHostAudio.portSources.push_back(this); }
    void SetDriver(SymphonyThunderbridge *) {}
};
class SymphonyPhantomControl : public IOUserAudioBooleanControl {
public:
    void SetDriver(SymphonyThunderbridge *) {}
    void SetChannel(uint32_t) {}
};
class SymphonyMicGainControl : public IOUserAudioLevelControl {
public:
    void SetDriver(SymphonyThunderbridge *) {}
    void SetChannel(uint32_t) {}
};
