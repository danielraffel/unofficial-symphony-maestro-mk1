// measure-latency.swift — DEV TOOL (not shipped in the PKG).
//
// Reports the real CoreAudio output latency for each connected Symphony device so you can compare
// Thunderbolt vs USB with numbers instead of vibes.
//
//   swift Tools/measure-latency.swift            # all Symphony devices
//   swift Tools/measure-latency.swift --all      # every audio device on the system
//
// What it measures (this is the honest, full picture — most tools only show one term):
//   presentation latency = device latency + safety offset + (buffer frames) + stream latency
// all converted to milliseconds at the device's current sample rate. That sum is what actually
// determines how long after you hand CoreAudio a sample it reaches the converter.
//
// Note: this is the *reported* latency the driver publishes to CoreAudio — it's what apps like
// Logic use for delay compensation. It is not an acoustic round-trip measurement (that would need
// a physical loopback cable), but it's the number that matters for host latency, and it's exactly
// what differs between the Thunderbolt (PCIe DMA) and USB (isochronous) paths.

import CoreAudio
import Foundation

let showAll = CommandLine.arguments.contains("--all")

func devices() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    return ids
}

func name(_ id: AudioObjectID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cf: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr,
          let s = cf?.takeRetainedValue() as String? else { return "<unknown>" }
    return s
}

func u32(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector,
         _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput) -> UInt32? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope,
                                          mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(id, &addr) else { return nil }
    var v: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr else { return nil }
    return v
}

func sampleRate(_ id: AudioObjectID) -> Double? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v: Double = 0
    var size = UInt32(MemoryLayout<Double>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v) == noErr, v > 0 else { return nil }
    return v
}

/// Latency of the first output stream (drivers often report a chunk of latency here, not on the device).
func streamLatency(_ id: AudioObjectID) -> UInt32 {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &streams) == noErr,
          let first = streams.first else { return 0 }
    var lAddr = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyLatency,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v: UInt32 = 0
    var lSize = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(first, &lAddr, 0, nil, &lSize, &v) == noErr else { return 0 }
    return v
}

func hasOutput(_ id: AudioObjectID) -> Bool {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
        mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf) == noErr else { return false }
    let abl = buf.assumingMemoryBound(to: AudioBufferList.self)
    return UnsafeMutableAudioBufferListPointer(abl).contains { $0.mNumberChannels > 0 }
}

print("")
print("Symphony output latency (as reported to CoreAudio — the number hosts use for delay compensation)")
print(String(repeating: "─", count: 92))
print(String(format: "%-30s %8s %7s %8s %8s %8s %10s", ("Device" as NSString).utf8String!,
             ("rate" as NSString).utf8String!, ("buf" as NSString).utf8String!,
             ("device" as NSString).utf8String!, ("safety" as NSString).utf8String!,
             ("stream" as NSString).utf8String!, ("TOTAL" as NSString).utf8String!))
print(String(repeating: "─", count: 92))

var any = false
for d in devices() {
    let n = name(d)
    guard showAll || n.contains("Symphony") else { continue }
    guard hasOutput(d) else { continue }
    guard let sr = sampleRate(d) else { continue }
    any = true

    let devLat  = u32(d, kAudioDevicePropertyLatency) ?? 0
    let safety  = u32(d, kAudioDevicePropertySafetyOffset) ?? 0
    let buffer  = u32(d, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal) ?? 0
    let strLat  = streamLatency(d)
    let totalFrames = Double(devLat + safety + buffer + strLat)
    let ms = { (f: Double) in f / sr * 1000.0 }

    print(String(format: "%-30@ %7.0f  %6u %6u  %6u  %6u  %7.2f ms",
                 n as NSString, sr, buffer, devLat, safety, strLat, ms(totalFrames)))
}
print(String(repeating: "─", count: 92))
if !any {
    print("No Symphony output device found. Connect one (or pass --all to list every device).")
} else {
    print("frames shown; TOTAL = (device + safety + buffer + stream) frames converted to ms at the device rate.")
    print("Lower TOTAL = less host latency. Compare the Thunderbolt device vs the USB device.")
}
print("")
