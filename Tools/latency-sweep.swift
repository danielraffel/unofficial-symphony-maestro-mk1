// latency-sweep.swift — DEV TOOL (not shipped in the PKG).
//
// Tries settings for the latency "Symphony I/O : Maestro USB" adds over USB and
// reports, for each, the latency Core Audio reports and whether audio was read
// before it was written (a dropout).
//
//   swift Tools/latency-sweep.swift                 # default sweep, 20 s per setting
//   swift Tools/latency-sweep.swift --seconds 60 --load
//   swift Tools/latency-sweep.swift --reset         # back to the helper's defaults
//
// Each setting is the helper's IO buffer on the USB device, plus the slack and
// floor of its ring delay (MaestroAudioShm.h, maestro_shm_compute_delay_tuned).
// Needs the helper from 0.9.22 build 1105 or later, the Symphony on USB, and
// audio playing to Maestro USB for the whole run: the tool plays a test tone
// there itself with afplay (make Maestro USB the Mac's output first). --load
// adds CPU load on every core for the duration. Nothing is saved: restarting
// the helper, or --reset, puts the defaults back.

import CoreAudio
import Foundation
import XPC

let args = CommandLine.arguments
func value(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let seconds = Double(value("--seconds") ?? "20") ?? 20
let load = args.contains("--load")

let connection = xpc_connection_create_mach_service("com.danielraffel.Maestro.volumeproxy", nil, 0)
xpc_connection_set_event_handler(connection) { _ in }
xpc_connection_resume(connection)

func send(_ fill: (xpc_object_t) -> Void) -> xpc_object_t? {
    let msg = xpc_dictionary_create(nil, nil, 0)
    fill(msg)
    let reply = xpc_connection_send_message_with_reply_sync(connection, msg)
    return xpc_get_type(reply) == XPC_TYPE_DICTIONARY ? reply : nil
}

func tune(buffer: UInt64, margin: UInt64, floor: UInt64) -> Bool {
    send {
        xpc_dictionary_set_string($0, "command", "setLatencyTuning")
        xpc_dictionary_set_uint64($0, "bufferFrames", buffer)
        xpc_dictionary_set_uint64($0, "jitterMargin", margin)
        xpc_dictionary_set_uint64($0, "minDelay", floor)
    } != nil
}

struct Stats { var delay: UInt64; var late: UInt64; var worst: Int64; var seen: Bool; var rate: Double }
func stats() -> Stats? {
    guard let r = send({ xpc_dictionary_set_string($0, "command", "getLatencyStats") }) else { return nil }
    return Stats(delay: xpc_dictionary_get_uint64(r, "delayFrames"),
                 late: xpc_dictionary_get_uint64(r, "lateWrites"),
                 worst: xpc_dictionary_get_int64(r, "worstHeadroom"),
                 seen: xpc_dictionary_get_bool(r, "headroomSeen"),
                 rate: xpc_dictionary_get_double(r, "rate"))
}

/// Reported output latency of Maestro USB in frames: device + safety + buffer.
func reportedLatency() -> (frames: UInt32, buffer: UInt32)? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    for id in ids {
        var name: Unmanaged<CFString>?
        var n = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var ns = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &n, 0, nil, &ns, &name) == noErr,
              let s = name?.takeRetainedValue() as String?, s.contains("Maestro USB") else { continue }
        func get(_ sel: AudioObjectPropertySelector) -> UInt32 {
            var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeOutput,
                                               mElement: kAudioObjectPropertyElementMain)
            var v: UInt32 = 0; var z = UInt32(4)
            AudioObjectGetPropertyData(id, &a, 0, nil, &z, &v)
            return v
        }
        let buffer = get(kAudioDevicePropertyBufferFrameSize)
        return (get(kAudioDevicePropertyLatency) + get(kAudioDevicePropertySafetyOffset) + buffer, buffer)
    }
    return nil
}

// A long tone to Maestro USB (the Mac's output), so the plugin writes all run.
let tone = FileManager.default.temporaryDirectory.appendingPathComponent("maestro-sweep-tone.aiff")
if !FileManager.default.fileExists(atPath: tone.path) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    p.arguments = ["-o", tone.path, String(repeating: "latency sweep tone. ", count: 400)]
    try? p.run(); p.waitUntilExit()
}

if args.contains("--reset") {
    print(tune(buffer: 0, margin: 0, floor: 0) ? "helper back on its defaults" : "helper did not answer")
    exit(0)
}

// (IO buffer, slack, floor) — 0 = the helper's default.
var settings: [(UInt64, UInt64, UInt64)] = [
    (0, 0, 0),
    (256, 256, 256),
    (256, 128, 128),
    (128, 128, 128),
    (128, 64, 64),
    (64, 64, 64),
]
// --settings 64:32:32,32:32:32 replaces the list (buffer:margin:floor).
if let list = value("--settings") {
    settings = list.split(separator: ",").compactMap { item in
        let p = item.split(separator: ":").compactMap { UInt64($0) }
        return p.count == 3 ? (p[0], p[1], p[2]) : nil
    }
}

var loaders: [Process] = []
if load {
    for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/timeout")
        p.arguments = [String(Int(seconds * Double(settings.count) + 30)), "/usr/bin/yes"]
        p.standardOutput = FileHandle.nullDevice
        try? p.run()
        loaders.append(p)
    }
}

print("buffer margin floor |  D frames  reported ms | late writes  worst headroom")
for (buffer, margin, floor) in settings {
    guard tune(buffer: buffer, margin: margin, floor: floor) else { print("helper did not answer"); break }
    Thread.sleep(forTimeInterval: 1.5)          // the output is rebuilt
    let player = Process()
    // --player PATH BUFFER: a DAW-like player at a small IO buffer
    // (Tools/small-buffer-player.swift, compiled) instead of afplay.
    if let path = value("--player"), let i = args.firstIndex(of: "--player"), i + 2 < args.count {
        player.executableURL = URL(fileURLWithPath: path)
        player.arguments = [args[i + 2], String(Int(seconds))]
    } else {
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["-t", String(Int(seconds)), tone.path]
    }
    try? player.run()
    Thread.sleep(forTimeInterval: 1.0)
    let before = stats()
    Thread.sleep(forTimeInterval: seconds - 1.0)
    let after = stats()
    player.terminate()
    let latency = reportedLatency()
    let rate = after?.rate ?? 48000
    let ms = latency.map { String(format: "%.2f", Double($0.frames) * 1000 / rate) } ?? "?"
    let late = (after?.late ?? 0) &- (before?.late ?? 0)
    let worst = after.map { $0.seen ? String($0.worst) : "no audio" } ?? "?"
    print(String(format: "%6llu %6llu %5llu | %9llu  %11@ | %11llu  %@",
                 buffer, margin, floor, after?.delay ?? 0, ms as NSString, late, worst as NSString))
}
loaders.forEach { $0.terminate() }
_ = tune(buffer: 0, margin: 0, floor: 0)
print("helper back on its defaults")
