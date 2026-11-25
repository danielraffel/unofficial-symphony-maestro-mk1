// loopback-latency.swift — DEV TOOL (not shipped in the PKG).
//
// Measures the real round trip of a cable from output 1 to input 1 and compares
// it with what the devices report, which is what a DAW uses to line recordings
// up. A short click is played on output 1 of OUTPUT DEVICE and found in input 1
// of "Symphony I/O : USB Audio". Times are compared on the host clock, so the
// IO buffer sizes drop out: what is left is the latency each device should
// report (device latency + safety offset, out and in).
//
//   swift Tools/loopback-latency.swift "Symphony I/O : Maestro USB" [clicks]
//   swift Tools/loopback-latency.swift "Symphony I/O : USB Audio" [clicks]

import AudioToolbox
import CoreAudio
import Foundation

let args = CommandLine.arguments
let outName = args.count > 1 ? args[1] : "Symphony I/O : Maestro USB"
let inName = "Symphony I/O : USB Audio"
let clicks = Int(args.count > 2 ? args[2] : "8") ?? 8

func device(_ want: String) -> AudioObjectID? {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
    for id in ids {
        var n = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var s: Unmanaged<CFString>?; var z = UInt32(8)
        AudioObjectGetPropertyData(id, &n, 0, nil, &z, &s)
        if (s?.takeRetainedValue() as String?) == want { return id }
    }
    return nil
}
func u32(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var v: UInt32 = 0; var z = UInt32(4)
    AudioObjectGetPropertyData(id, &a, 0, nil, &z, &v)
    return v
}
func rate(_ id: AudioObjectID) -> Double {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v: Float64 = 0; var z = UInt32(8)
    AudioObjectGetPropertyData(id, &a, 0, nil, &z, &v)
    return v
}

guard let outDev = device(outName), let inDev = device(inName) else { print("device not found"); exit(1) }
let sr = rate(inDev)
var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
func ticksToSamples(_ t: Int64) -> Double { Double(t) * Double(tb.numer) / Double(tb.denom) / 1e9 * sr }

let reportedOut = u32(outDev, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput)
    + u32(outDev, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput)
let reportedIn = u32(inDev, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput)
    + u32(inDev, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput)

final class Shared {
    var phase = 0          // frames until the next click
    var clickHostTimes: [UInt64] = []
    var hits: [UInt64] = []
    var lastIn: Float = 0
    var armed = true
    var peak: Float = 0
    var renderError: OSStatus = 0
    let lock = NSLock()
}
let shared = Shared()
let period = Int(sr / 2)   // a click every half second
let threshold: Float = Float(ProcessInfo.processInfo.environment["LOOPBACK_THRESHOLD"] ?? "0.02") ?? 0.02

func makeUnit(_ dev: AudioObjectID, input: Bool) -> AudioUnit {
    var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
        componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0, componentFlagsMask: 0)
    var u: AudioUnit?
    AudioComponentInstanceNew(AudioComponentFindNext(nil, &desc)!, &u)
    var one: UInt32 = 1, zero: UInt32 = 0
    if input {
        AudioUnitSetProperty(u!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4)
        AudioUnitSetProperty(u!, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, 4)
    }
    var d = dev
    AudioUnitSetProperty(u!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, 4)
    var fmt = AudioStreamBasicDescription(mSampleRate: sr, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
        mBitsPerChannel: 32, mReserved: 0)
    AudioUnitSetProperty(u!, kAudioUnitProperty_StreamFormat, input ? kAudioUnitScope_Output : kAudioUnitScope_Input,
                         input ? 1 : 0, &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
    return u!
}

let outUnit = makeUnit(outDev, input: false)
let inUnit = makeUnit(inDev, input: true)
let ref = Unmanaged.passUnretained(shared).toOpaque()

var outCB = AURenderCallbackStruct(inputProc: { ref, _, ts, _, frames, data in
    let s = Unmanaged<Shared>.fromOpaque(ref).takeUnretainedValue()
    guard let list = UnsafeMutableAudioBufferListPointer(data) else { return noErr }
    let perSample = 1e9 / sr * Double(tb.denom) / Double(tb.numer)
    for f in 0..<Int(frames) {
        var v: Float = 0
        if s.phase == 0 {
            v = 0.5
            s.lock.lock(); s.clickHostTimes.append(ts.pointee.mHostTime + UInt64(Double(f) * perSample)); s.lock.unlock()
        }
        s.phase = (s.phase + 1) % period
        for b in list { b.mData?.assumingMemoryBound(to: Float.self)[f] = (b.mData == list[0].mData) ? v : 0 }
    }
    return noErr
}, inputProcRefCon: ref)
AudioUnitSetProperty(outUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &outCB,
                     UInt32(MemoryLayout<AURenderCallbackStruct>.size))

var inBuf = [Float](repeating: 0, count: 8192 * 2)
var inCB = AURenderCallbackStruct(inputProc: { ref, flags, ts, bus, frames, _ in
    let s = Unmanaged<Shared>.fromOpaque(ref).takeUnretainedValue()
    // Two non-interleaved channels: two buffers.
    let buf = UnsafeMutablePointer<Float>.allocate(capacity: Int(frames) * 2)
    defer { buf.deallocate() }
    let abl = AudioBufferList.allocate(maximumBuffers: 2)
    defer { free(abl.unsafeMutablePointer) }
    abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: buf)
    abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4, mData: buf + Int(frames))
    let st = AudioUnitRender(inUnit, flags, ts, bus, frames, abl.unsafeMutablePointer)
    if st != noErr { s.lock.lock(); s.renderError = st; s.lock.unlock(); return st }
    let perSample = 1e9 / sr * Double(tb.denom) / Double(tb.numer)
    for f in 0..<Int(frames) {
        let v = abs(buf[f])
        if v > s.peak { s.peak = v }
        if s.armed && v > threshold {
            s.lock.lock(); s.hits.append(ts.pointee.mHostTime + UInt64(Double(f) * perSample)); s.lock.unlock()
            s.armed = false
        } else if !s.armed && v < 0.01 {
            // re-arm once the click has passed
        }
    }
    if !s.armed {
        // re-arm after 0.2 s of quiet
        s.lock.lock()
        if let last = s.hits.last, ts.pointee.mHostTime > last + UInt64(0.2e9 * Double(tb.denom) / Double(tb.numer)) { s.armed = true }
        s.lock.unlock()
    }
    return noErr
}, inputProcRefCon: ref)
AudioUnitSetProperty(inUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &inCB,
                     UInt32(MemoryLayout<AURenderCallbackStruct>.size))

AudioUnitInitialize(outUnit); AudioUnitInitialize(inUnit)
AudioOutputUnitStart(inUnit); AudioOutputUnitStart(outUnit)
Thread.sleep(forTimeInterval: Double(clicks) * 0.5 + 1.0)
AudioOutputUnitStop(outUnit); AudioOutputUnitStop(inUnit)

shared.lock.lock()
var delays: [Double] = []
for c in shared.clickHostTimes {
    if let h = shared.hits.first(where: { $0 > c && Double($0 - c) * Double(tb.numer) / Double(tb.denom) < 2e8 }) {
        delays.append(ticksToSamples(Int64(h) - Int64(c)))
    }
}
shared.lock.unlock()
print("output: \(outName)  input: \(inName)  rate \(Int(sr)) Hz")
print("clicks sent \(shared.clickHostTimes.count), found \(delays.count), input 1 peak \(shared.peak), input render error \(shared.renderError)")
guard !delays.isEmpty else { print("no click came back: check the cable from output 1 to input 1"); exit(2) }
let sorted = delays.sorted(), median = sorted[sorted.count / 2]
print(String(format: "measured beyond the IO buffers: median %.1f samples (min %.1f, max %.1f) = %.2f ms",
             median, sorted.first!, sorted.last!, median / sr * 1000))
print("reported: output \(reportedOut) + input \(reportedIn) = \(reportedOut + reportedIn) samples")
print(String(format: "difference (measured - reported): %+.1f samples", median - Double(reportedOut + reportedIn)))
