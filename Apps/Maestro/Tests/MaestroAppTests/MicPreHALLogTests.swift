import CoreAudio
import Testing
@testable import MaestroApp

@Suite struct MicPreHALLogTests {
    @Test func namesPropertiesByTheirFourCharacterCode() {
        #expect(MicPreHALLog.fourCC(kAudioDevicePropertyChannelNominalLineLevel) == "nlvl")
        #expect(MicPreHALLog.fourCC(kAudioObjectPropertyScopeInput) == "inpt")
        #expect(MicPreHALLog.fourCC(7) == "0x00000007")
    }

    @Test func keepsTheDevicesInputScopeAndEverythingFromAControl() {
        #expect(MicPreHALLog.keeps(objectIsDevice: true, scope: kAudioObjectPropertyScopeInput))
        #expect(!MicPreHALLog.keeps(objectIsDevice: true, scope: kAudioObjectPropertyScopeOutput))
        #expect(!MicPreHALLog.keeps(objectIsDevice: true, scope: kAudioObjectPropertyScopeGlobal))
        #expect(MicPreHALLog.keeps(objectIsDevice: false, scope: kAudioObjectPropertyScopeGlobal))
    }

    @Test func showsVolumesAsDecibelsAndTheRestAsNumbers() {
        func bytes(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value) { Array($0) } }
        #expect(MicPreHALLog.valueText(selector: kAudioDevicePropertyChannelNominalLineLevel, bytes: bytes(3)) == "3")
        #expect(MicPreHALLog.valueText(selector: kAudioDevicePropertyVolumeDecibels,
                                       bytes: bytes(Float32(42.5).bitPattern)) == "42.50")
        #expect(MicPreHALLog.valueText(selector: kAudioDevicePropertyPhantomPower, bytes: nil) == "unreadable")
        #expect(MicPreHALLog.valueText(selector: kAudioDevicePropertyPhantomPower, bytes: [1, 2]) == "2 bytes")
    }

    @Test func oneLinePerNotification() {
        let address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyChannelNominalLineLevel,
            mScope: kAudioObjectPropertyScopeInput, mElement: 1)
        #expect(MicPreHALLog.line(stamp: "T", objectIsDevice: true, objectID: 90, address: address, value: "3")
            == "[MicPreHAL] T device 'nlvl' scope 'inpt' element 1 = 3")
        #expect(MicPreHALLog.line(stamp: "T", objectIsDevice: false, objectID: 91, address: address, value: "3")
            .hasPrefix("[MicPreHAL] T control 91 "))
    }
}
