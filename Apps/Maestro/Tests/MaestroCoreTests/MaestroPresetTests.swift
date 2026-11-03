import Testing
import Foundation
@testable import MaestroCore

// MARK: - MaestroPreset Tests

@Suite("MaestroPreset")
struct MaestroPresetTests {

    // MARK: - Default values

    @Test func defaultOutputLevel() {
        let preset = MaestroPreset()
        #expect(preset.outputLevel == -20, "Default output level is -20 dB")
    }

    @Test func defaultOutputMuted() {
        let preset = MaestroPreset()
        #expect(preset.outputMuted == false)
    }

    @Test func defaultHPLevels() {
        let preset = MaestroPreset()
        #expect(preset.hp1Level == -20)
        #expect(preset.hp2Level == -20)
    }

    @Test func defaultInputChannelStatesEmpty() {
        let preset = MaestroPreset()
        #expect(preset.inputChannelStates.isEmpty)
    }

    @Test func defaultVersion() {
        let preset = MaestroPreset()
        #expect(preset.version == 1)
    }

    // MARK: - Codable round-trip

    @Test func roundTripOutputLevel() throws {
        var preset = MaestroPreset()
        preset.outputLevel = -32.0
        let data = try PropertyListEncoder().encode(preset)
        let decoded = try PropertyListDecoder().decode(MaestroPreset.self, from: data)
        #expect(decoded.outputLevel == -32.0)
    }

    @Test func roundTripOutputMuted() throws {
        var preset = MaestroPreset()
        preset.outputMuted = true
        let data = try PropertyListEncoder().encode(preset)
        let decoded = try PropertyListDecoder().decode(MaestroPreset.self, from: data)
        #expect(decoded.outputMuted == true)
    }

    @Test func roundTripHP1() throws {
        var preset = MaestroPreset()
        preset.hp1Level = -10.0
        preset.hp1Muted = true
        preset.hp1RoutingID = 42
        let data = try PropertyListEncoder().encode(preset)
        let decoded = try PropertyListDecoder().decode(MaestroPreset.self, from: data)
        #expect(decoded.hp1Level == -10.0)
        #expect(decoded.hp1Muted == true)
        #expect(decoded.hp1RoutingID == 42)
    }

    @Test func roundTripInputChannelStates() throws {
        var preset = MaestroPreset()
        preset.inputChannelStates = [
            InputChannelState(gain: 20, phantom: true, phase: false, hpf: true, softLimit: 2, inputType: 0),
            InputChannelState(gain: 0,  phantom: false, phase: true, hpf: false, softLimit: 0, inputType: 1),
        ]
        let data = try PropertyListEncoder().encode(preset)
        let decoded = try PropertyListDecoder().decode(MaestroPreset.self, from: data)
        #expect(decoded.inputChannelStates.count == 2)
        #expect(decoded.inputChannelStates[0].gain == 20)
        #expect(decoded.inputChannelStates[0].phantom == true)
        #expect(decoded.inputChannelStates[0].softLimit == 2)
        #expect(decoded.inputChannelStates[1].phase == true)
        #expect(decoded.inputChannelStates[1].inputType == 1)
    }

    @Test func roundTripDeviceSettings() throws {
        var preset = MaestroPreset()
        preset.opticalInFormat = 1
        preset.spdifReplaceID = 2
        preset.spdifMirrorID = 3
        preset.peakHoldMode = 2
        preset.overHoldMode = 0
        preset.meterBank1Source = 5
        preset.meterBank2Source = 7
        let data = try PropertyListEncoder().encode(preset)
        let decoded = try PropertyListDecoder().decode(MaestroPreset.self, from: data)
        #expect(decoded.opticalInFormat == 1)
        #expect(decoded.spdifReplaceID == 2)
        #expect(decoded.spdifMirrorID == 3)
        #expect(decoded.peakHoldMode == 2)
        #expect(decoded.overHoldMode == 0)
        #expect(decoded.meterBank1Source == 5)
        #expect(decoded.meterBank2Source == 7)
    }

    @Test func roundTripAllFields() throws {
        var preset = MaestroPreset()
        preset.outputLevel = -15.0
        preset.outputMuted = false
        preset.outputDimmed = true
        preset.outputSumToMono = false
        preset.hp1Level = -8.0
        preset.hp1Muted = false
        preset.hp1RoutingID = 7
        preset.hp2Level = -12.0
        preset.hp2Muted = true
        preset.hp2RoutingID = 3
        preset.inputChannelStates = [InputChannelState(gain: 40, phantom: true)]
        preset.outputChannelStates = [OutputChannelState(analogRefLevel: 2, digitalRefLevel: 4, trim: 1.0)]
        preset.channelNames = ["Kick", "Snare", "", "Bass"]
        preset.opticalInFormat = 1
        preset.spdifReplaceID = 1
        preset.spdifMirrorID = 2
        preset.peakHoldMode = 1
        preset.overHoldMode = 1
        preset.meterBank1Source = 1
        preset.meterBank2Source = 5

        let data = try PropertyListEncoder().encode(preset)
        let decoded = try PropertyListDecoder().decode(MaestroPreset.self, from: data)
        #expect(decoded == preset, "Round-trip must produce identical preset")
    }

    // MARK: - Channel Names (P3F-39)

    @Test func defaultChannelNamesEmpty() {
        let preset = MaestroPreset()
        #expect(preset.channelNames.isEmpty)
    }

    @Test func roundTripChannelNames() throws {
        var preset = MaestroPreset()
        preset.channelNames = ["Kick", "Snare", "Hi-Hat", "", "Bass", "GTR L", "GTR R", "Vox"]
        let data = try PropertyListEncoder().encode(preset)
        let decoded = try PropertyListDecoder().decode(MaestroPreset.self, from: data)
        #expect(decoded.channelNames.count == 8)
        #expect(decoded.channelNames[0] == "Kick")
        #expect(decoded.channelNames[3] == "")  // empty names preserved
        #expect(decoded.channelNames[7] == "Vox")
    }

    @Test func channelNamesPreserveEmptyStrings() throws {
        var preset = MaestroPreset()
        preset.channelNames = ["", "Named", ""]
        let data = try PropertyListEncoder().encode(preset)
        let decoded = try PropertyListDecoder().decode(MaestroPreset.self, from: data)
        #expect(decoded.channelNames == ["", "Named", ""])
    }

    @Test func channelNamesRoundTripViaJSON() throws {
        // Verify JSON encode/decode (used internally by AppState.makePreset/applyPreset)
        let names = ["Kick", "Snare", "", "Bass", "GTR", "Keys", "Vox 1", "Vox 2"]
        let jsonData = try JSONEncoder().encode(names)
        let decoded = try JSONDecoder().decode([String].self, from: jsonData)
        #expect(decoded == names)
    }

    @Test func presetWithNamesEquality() {
        var a = MaestroPreset()
        a.channelNames = ["Ch A", "Ch B"]
        var b = MaestroPreset()
        b.channelNames = ["Ch A", "Ch B"]
        var c = MaestroPreset()
        c.channelNames = ["Ch A", "DIFFERENT"]
        // Same creation time needed for equality
        b.createdAt = a.createdAt
        c.createdAt = a.createdAt
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - File I/O

    @Test func saveAndLoad() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).mst2")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var preset = MaestroPreset()
        preset.outputLevel = -25.0
        preset.outputMuted = true
        preset.hp1Level = -30.0
        preset.hp1RoutingID = 5

        try preset.save(to: tempURL)
        #expect(FileManager.default.fileExists(atPath: tempURL.path), "File must be created")

        let loaded = try MaestroPreset.load(from: tempURL)
        #expect(loaded.outputLevel == -25.0)
        #expect(loaded.outputMuted == true)
        #expect(loaded.hp1Level == -30.0)
        #expect(loaded.hp1RoutingID == 5)
    }

    @Test func savedFileIsXMLPlist() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).mst2")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try MaestroPreset().save(to: tempURL)
        let raw = try String(contentsOf: tempURL, encoding: .utf8)
        #expect(raw.hasPrefix("<?xml"), "File must start with XML declaration")
        #expect(raw.contains("<plist"), "File must contain plist element")
    }

    @Test func loadNonExistentFileThrows() {
        let badURL = URL(fileURLWithPath: "/tmp/does_not_exist_\(UUID().uuidString).mst2")
        #expect(throws: (any Error).self) {
            try MaestroPreset.load(from: badURL)
        }
    }

    @Test func loadCorruptDataThrows() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).mst2")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try "not a plist".write(to: tempURL, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) {
            try MaestroPreset.load(from: tempURL)
        }
    }
}

// MARK: - InputChannelState Tests

@Suite("InputChannelState")
struct InputChannelStateTests {

    @Test func defaultValues() {
        let state = InputChannelState()
        #expect(state.gain == 0)
        #expect(state.phantom == false)
        #expect(state.phase == false)
        #expect(state.hpf == false)
        #expect(state.softLimit == 0)
        #expect(state.inputType == 1)  // Default +4 dBu (matches original Maestro 2)
    }

    @Test func codableRoundTrip() throws {
        let state = InputChannelState(
            gain: 42.5,
            phantom: true,
            phase: true,
            hpf: false,
            softLimit: 3,
            inputType: 2
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(InputChannelState.self, from: data)
        #expect(decoded == state)
    }

    @Test func plistCodable() throws {
        let state = InputChannelState(gain: 20, phantom: true, softLimit: 1)
        let data = try PropertyListEncoder().encode(state)
        let decoded = try PropertyListDecoder().decode(InputChannelState.self, from: data)
        #expect(decoded.gain == 20)
        #expect(decoded.phantom == true)
        #expect(decoded.softLimit == 1)
    }

    @Test func equatable() {
        let a = InputChannelState(gain: 10, phantom: true)
        let b = InputChannelState(gain: 10, phantom: true)
        let c = InputChannelState(gain: 20, phantom: true)
        #expect(a == b)
        #expect(a != c)
    }
}

// MARK: - OutputChannelState Tests

@Suite("OutputChannelState")
struct OutputChannelStateTests {

    @Test func defaultValues() {
        let state = OutputChannelState()
        #expect(state.analogRefLevel == 1)   // Default +4 dBu
        #expect(state.digitalRefLevel == 2)  // Default -16 dBfs
        #expect(state.trim == 0.0)
    }

    @Test func codableRoundTrip() throws {
        let state = OutputChannelState(
            analogRefLevel: 2,
            digitalRefLevel: 5,
            trim: 1.5
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(OutputChannelState.self, from: data)
        #expect(decoded == state)
    }

    @Test func plistCodable() throws {
        let state = OutputChannelState(analogRefLevel: 2, digitalRefLevel: 3, trim: -1.0)
        let data = try PropertyListEncoder().encode(state)
        let decoded = try PropertyListDecoder().decode(OutputChannelState.self, from: data)
        #expect(decoded.analogRefLevel == 2)
        #expect(decoded.digitalRefLevel == 3)
        #expect(decoded.trim == -1.0)
    }

    @Test func equatable() {
        let a = OutputChannelState(analogRefLevel: 1, digitalRefLevel: 2, trim: 0.5)
        let b = OutputChannelState(analogRefLevel: 1, digitalRefLevel: 2, trim: 0.5)
        let c = OutputChannelState(analogRefLevel: 2, digitalRefLevel: 2, trim: 0.5)
        #expect(a == b)
        #expect(a != c)
    }
}

// MARK: - MaestroPreset with OutputChannelState Tests

@Suite("MaestroPreset+OutputChannelState")
struct MaestroPresetOutputTests {

    @Test func defaultOutputChannelStatesEmpty() {
        let preset = MaestroPreset()
        #expect(preset.outputChannelStates.isEmpty)
    }

    @Test func roundTripOutputChannelStates() throws {
        var preset = MaestroPreset()
        preset.outputChannelStates = [
            OutputChannelState(analogRefLevel: 1, digitalRefLevel: 0, trim: -1.0),
            OutputChannelState(analogRefLevel: 2, digitalRefLevel: 5, trim: 2.0),
        ]
        let data = try PropertyListEncoder().encode(preset)
        let decoded = try PropertyListDecoder().decode(MaestroPreset.self, from: data)
        #expect(decoded.outputChannelStates.count == 2)
        #expect(decoded.outputChannelStates[0].analogRefLevel == 1)
        #expect(decoded.outputChannelStates[0].trim == -1.0)
        #expect(decoded.outputChannelStates[1].analogRefLevel == 2)
        #expect(decoded.outputChannelStates[1].digitalRefLevel == 5)
    }

    @Test func backwardCompatibilityNoOutputStates() throws {
        // Presets saved before outputChannelStates was added should decode with empty array
        var preset = MaestroPreset()
        preset.outputLevel = -15.0
        let data = try PropertyListEncoder().encode(preset)
        let decoded = try PropertyListDecoder().decode(MaestroPreset.self, from: data)
        #expect(decoded.outputChannelStates.isEmpty)
    }
}
