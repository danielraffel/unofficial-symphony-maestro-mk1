// small-buffer-player.swift — DEV TOOL (not shipped in the PKG).
//
// Plays a quiet sine to "Symphony I/O : Maestro USB" through an AUHAL output
// unit with a small IO buffer, the way a DAW at 32 or 64 frames does, for the
// latency sweep (Tools/latency-sweep.swift --player). A DAW's render happens
// close to its deadline; afplay's large buffer writes far ahead and hides how
// much margin the bridge really has.
//
//   swift Tools/small-buffer-player.swift <buffer frames> <seconds>

import AudioToolbox
import CoreAudio
import Foundation

let args = CommandLine.arguments
let bufferFrames = UInt32(args.count > 1 ? args[1] : "32") ?? 32
let seconds = Double(args.count > 2 ? args[2] : "20") ?? 20

func deviceNamed(_ want: String) -> AudioObjectID? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    for id in ids {
        var n = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var s: Unmanaged<CFString>?; var z = UInt32(8)
        AudioObjectGetPropertyData(id, &n, 0, nil, &z, &s)
        if (s?.takeRetainedValue() as String?) == want { return id }
    }
    return nil
}

guard var device = deviceNamed("Symphony I/O : Maestro USB") else {
    print("Maestro USB not found"); exit(1)
}
var desc = AudioComponentDescription(componentType: kAudioUnitType_Output,
    componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
    componentFlags: 0, componentFlagsMask: 0)
guard let comp = AudioComponentFindNext(nil, &desc) else { exit(1) }
var unitOpt: AudioUnit?
AudioComponentInstanceNew(comp, &unitOpt)
guard let unit = unitOpt else { exit(1) }
AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                     &device, UInt32(MemoryLayout<AudioObjectID>.size))
var frames = bufferFrames
var fsz = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
let st = AudioObjectSetPropertyData(device, &fsz, 0, nil, 4, &frames)
var got: UInt32 = 0; var gz = UInt32(4)
AudioObjectGetPropertyData(device, &fsz, 0, nil, &gz, &got)
print("client buffer requested \(bufferFrames), set status \(st), now \(got)")

var fmt = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
    mBitsPerChannel: 32, mReserved: 0)
AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                     &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

final class Phase { var value = 0.0 }
let phase = Phase()
var callback = AURenderCallbackStruct(inputProc: { ref, _, _, _, frames, data in
    let p = Unmanaged<Phase>.fromOpaque(ref).takeUnretainedValue()
    guard let list = UnsafeMutableAudioBufferListPointer(data) else { return noErr }
    let step = 2.0 * Double.pi * 440.0 / 48000.0
    for f in 0..<Int(frames) {
        let v = Float(sin(p.value) * 0.05)
        p.value += step
        for b in list { b.mData?.assumingMemoryBound(to: Float.self)[f] = v }
    }
    return noErr
}, inputProcRefCon: Unmanaged.passUnretained(phase).toOpaque())
AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                     &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
AudioUnitInitialize(unit)
AudioOutputUnitStart(unit)
Thread.sleep(forTimeInterval: seconds)
AudioOutputUnitStop(unit)
AudioComponentInstanceDispose(unit)
