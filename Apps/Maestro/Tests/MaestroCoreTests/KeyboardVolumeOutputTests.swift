import Testing
@testable import MaestroCore

/// Device Settings › Volume Keys › Audio Output: the entries, their names,
/// the default, and what is sent to the driver and the USB helper.
@Suite("Volume Keys: Audio Output")
struct KeyboardVolumeOutputTests {
    @Test("a Symphony I/O offers Speaker, Headphone 1, Headphone 2, in that order, and no None")
    func symphonyEntries() {
        let entries = KeyboardVolumeOutput.entries(hasAnalogOutput: true, convertersOnly: false)
        #expect(entries == [.speakers, .headphone1, .headphone2])
        #expect(!entries.contains(.none) && !entries.contains(.mixer1Level))
        #expect(KeyboardVolumeOutput.defaultOutput(hasAnalogOutput: true, convertersOnly: false) == .speakers)
    }

    @Test("without an analog output card the Speaker entry is left out and Headphone 1 is the default")
    func noAnalogOutputCard() {
        let entries = KeyboardVolumeOutput.entries(hasAnalogOutput: false, convertersOnly: false)
        #expect(entries == [.headphone1, .headphone2])
        #expect(KeyboardVolumeOutput.defaultOutput(hasAnalogOutput: false, convertersOnly: false) == .headphone1)
        // A saved Speaker becomes Headphone 1; a saved headphone is kept.
        #expect(KeyboardVolumeOutput.resolve(saved: 1, hasAnalogOutput: false, convertersOnly: false) == .headphone1)
        #expect(KeyboardVolumeOutput.resolve(saved: 3, hasAnalogOutput: false, convertersOnly: false) == .headphone2)
    }

    @Test("converters only: the Mixer 1 level (default) and None, nothing else")
    func converterEntries() {
        for analog in [true, false] {
            let entries = KeyboardVolumeOutput.entries(hasAnalogOutput: analog, convertersOnly: true)
            #expect(entries == [.mixer1Level, .none])
            #expect(KeyboardVolumeOutput.defaultOutput(hasAnalogOutput: analog, convertersOnly: true) == .mixer1Level)
        }
        // A Symphony I/O choice saved for the same key does not carry over.
        #expect(KeyboardVolumeOutput.resolve(saved: 2, hasAnalogOutput: true, convertersOnly: true) == .mixer1Level)
        #expect(KeyboardVolumeOutput.resolve(saved: 0, hasAnalogOutput: true, convertersOnly: true) == .none)
        // None is never a Symphony I/O choice.
        #expect(KeyboardVolumeOutput.resolve(saved: 0, hasAnalogOutput: true, convertersOnly: false) == .speakers)
        #expect(KeyboardVolumeOutput.resolve(saved: 4, hasAnalogOutput: true, convertersOnly: false) == .speakers)
    }

    @Test("nothing saved, or something unreadable, is the default")
    func resolveDefault() {
        #expect(KeyboardVolumeOutput.resolve(saved: nil, hasAnalogOutput: true, convertersOnly: false) == .speakers)
        #expect(KeyboardVolumeOutput.resolve(saved: 99, hasAnalogOutput: true, convertersOnly: false) == .speakers)
        #expect(KeyboardVolumeOutput.resolve(saved: 2, hasAnalogOutput: true, convertersOnly: false) == .headphone1)
        #expect(KeyboardVolumeOutput.resolve(saved: 3, hasAnalogOutput: true, convertersOnly: false) == .headphone2)
    }

    @Test("the Speaker entry is named after the speaker mode, as in the original",
          arguments: [(UInt32(0), "Speaker (0ch)"), (2, "Speaker (2ch)"), (6, "Speaker (6ch)"),
                      (8, "Speaker (8ch)"), (9, "Speaker (2ch)"), (10, "Speaker (2ch)")])
    func speakerLabel(mode: UInt32, expected: String) {
        #expect(KeyboardVolumeOutput.speakers.label(speakerMode: mode) == expected)
    }

    @Test("the other names do not depend on the speaker mode")
    func otherLabels() {
        for mode: UInt32 in [0, 2, 6, 8] {
            #expect(KeyboardVolumeOutput.headphone1.label(speakerMode: mode) == "Headphone 1")
            #expect(KeyboardVolumeOutput.headphone2.label(speakerMode: mode) == "Headphone 2")
            #expect(KeyboardVolumeOutput.mixer1Level.label(speakerMode: mode) == "Mixer 1 level")
            #expect(KeyboardVolumeOutput.none.label(speakerMode: mode) == "None")
        }
    }

    @Test("the keys do nothing with Speaker chosen in Line mode, and with None; a headphone is always moved")
    func lineModeNoOp() {
        #expect(KeyboardVolumeOutput.speakers.keysDoNothing(speakerMode: 0))
        for mode: UInt32 in [2, 6, 8, 9, 10] { #expect(!KeyboardVolumeOutput.speakers.keysDoNothing(speakerMode: mode)) }
        for mode: UInt32 in [0, 2, 6, 8] {
            #expect(!KeyboardVolumeOutput.headphone1.keysDoNothing(speakerMode: mode))
            #expect(!KeyboardVolumeOutput.headphone2.keysDoNothing(speakerMode: mode))
            #expect(!KeyboardVolumeOutput.mixer1Level.keysDoNothing(speakerMode: mode))
            #expect(KeyboardVolumeOutput.none.keysDoNothing(speakerMode: mode))
        }
    }

    @Test("leaving Line puts back the choice Line displaced, unless the user chose another meanwhile")
    func leavingLine() {
        #expect(KeyboardVolumeOutput.headphone1.afterLeavingLine(displaced: .speakers) == .speakers)
        #expect(KeyboardVolumeOutput.headphone1.afterLeavingLine(displaced: .headphone2) == .headphone2)
        // Nothing was displaced (it was already Headphone 1, or the user picked one in Line).
        #expect(KeyboardVolumeOutput.headphone1.afterLeavingLine(displaced: nil) == .headphone1)
        #expect(KeyboardVolumeOutput.headphone2.afterLeavingLine(displaced: nil) == .headphone2)
        #expect(KeyboardVolumeOutput.speakers.afterLeavingLine(displaced: nil) == .speakers)
        // The choice is no longer the one Line made: it stands.
        #expect(KeyboardVolumeOutput.headphone2.afterLeavingLine(displaced: .speakers) == .headphone2)
    }

    @Test("setting Line makes Headphone 1 the choice, whatever it was; nothing else changes it")
    func speakerModeChangedByTheUser() {
        for old: UInt32 in [2, 6, 8, 9, 10] {
            for output in [KeyboardVolumeOutput.speakers, .headphone1, .headphone2] {
                #expect(output.afterUserChange(ofSpeakerModeFrom: old, to: 0) == .headphone1)
                // Between speaker modes, and out of Line: unchanged.
                #expect(output.afterUserChange(ofSpeakerModeFrom: old, to: 6) == output)
                #expect(output.afterUserChange(ofSpeakerModeFrom: 0, to: old) == output)
            }
        }
        // Line chosen while already in Line: nothing (a Speaker (0ch) chosen by hand stays).
        #expect(KeyboardVolumeOutput.speakers.afterUserChange(ofSpeakerModeFrom: 0, to: 0) == .speakers)
        #expect(KeyboardVolumeOutput.headphone2.afterUserChange(ofSpeakerModeFrom: 0, to: 0) == .headphone2)
        // The converter choices have no speaker mode.
        #expect(KeyboardVolumeOutput.none.afterUserChange(ofSpeakerModeFrom: 2, to: 0) == KeyboardVolumeOutput.none)
        #expect(KeyboardVolumeOutput.mixer1Level.afterUserChange(ofSpeakerModeFrom: 2, to: 0) == .mixer1Level)
    }

    @Test("nothing saved in Line mode is Headphone 1; a saved choice, Speaker included, is kept in Line mode")
    func nothingSavedInLineMode() {
        #expect(KeyboardVolumeOutput.resolve(saved: nil, hasAnalogOutput: true, convertersOnly: false, speakerMode: 0) == .headphone1)
        #expect(KeyboardVolumeOutput.resolve(saved: nil, hasAnalogOutput: true, convertersOnly: false, speakerMode: 2) == .speakers)
        #expect(KeyboardVolumeOutput.resolve(saved: nil, hasAnalogOutput: true, convertersOnly: false, speakerMode: nil) == .speakers)
        #expect(KeyboardVolumeOutput.resolve(saved: 1, hasAnalogOutput: true, convertersOnly: false, speakerMode: 0) == .speakers)
        #expect(KeyboardVolumeOutput.resolve(saved: 3, hasAnalogOutput: true, convertersOnly: false, speakerMode: 0) == .headphone2)
        // No analog output card: Headphone 1 in every mode, and never Speaker.
        for mode: UInt32? in [0, 2, nil] {
            #expect(KeyboardVolumeOutput.resolve(saved: nil, hasAnalogOutput: false, convertersOnly: false, speakerMode: mode) == .headphone1)
            #expect(KeyboardVolumeOutput.resolve(saved: 1, hasAnalogOutput: false, convertersOnly: false, speakerMode: mode) == .headphone1)
        }
        // Converters have no Line mode.
        #expect(KeyboardVolumeOutput.resolve(saved: nil, hasAnalogOutput: true, convertersOnly: true, speakerMode: 0) == .mixer1Level)
    }

    @Test("the mute key is ignored only with None: Speaker in Line mode still mutes the speaker")
    func muteKey() {
        #expect(KeyboardVolumeOutput.none.muteKeyDoesNothing)
        for output in [KeyboardVolumeOutput.speakers, .headphone1, .headphone2, .mixer1Level] {
            #expect(!output.muteKeyDoesNothing)
        }
        #expect(KeyboardVolumeOutput.speakers.keysDoNothing(speakerMode: 0))
    }

    @Test("what the driver is sent: the original's 1, 2, 3; on converters 1 for the level and 0 for None")
    func driverValues() {
        #expect(KeyboardVolumeOutput.speakers.driverValue == 1)
        #expect(KeyboardVolumeOutput.headphone1.driverValue == 2)
        #expect(KeyboardVolumeOutput.headphone2.driverValue == 3)
        #expect(KeyboardVolumeOutput.mixer1Level.driverValue == 1)
        #expect(KeyboardVolumeOutput.none.driverValue == 0)
    }

    @Test("what the USB helper is sent, and the properties that hold each output's level and mute")
    func helperValuesAndSelectors() {
        #expect(KeyboardVolumeOutput.speakers.helperValue == 1)
        #expect(KeyboardVolumeOutput.headphone1.helperValue == 2)
        #expect(KeyboardVolumeOutput.headphone2.helperValue == 3)
        #expect(KeyboardVolumeOutput.mixer1Level.helperValue == nil)
        #expect(KeyboardVolumeOutput.none.helperValue == nil)
        #expect(KeyboardVolumeOutput.speakers.levelSelector == .outputLevel)
        #expect(KeyboardVolumeOutput.speakers.muteSelector == .outputMute)
        #expect(KeyboardVolumeOutput.headphone1.levelSelector == .headphone1Level)
        #expect(KeyboardVolumeOutput.headphone1.muteSelector == .headphone1Mute)
        #expect(KeyboardVolumeOutput.headphone2.levelSelector == .headphone2Level)
        #expect(KeyboardVolumeOutput.headphone2.muteSelector == .headphone2Mute)
        #expect(KeyboardVolumeOutput.none.levelSelector == nil && KeyboardVolumeOutput.mixer1Level.muteSelector == nil)
    }

    @Test("only a driver from build 142 on is told the choice")
    func driverGate() {
        #expect(!KeyboardVolumeOutput.driverSupports(nil))
        #expect(!KeyboardVolumeOutput.driverSupports(.olderThanBuildReporting))
        #expect(!KeyboardVolumeOutput.driverSupports(.build(141)))
        #expect(KeyboardVolumeOutput.driverSupports(.build(142)))
        #expect(KeyboardVolumeOutput.driverSupports(.build(150)))
    }

    @Test("a unit is listed as its prefix and its name")
    func peripheralNames() {
        #expect(KeyboardVolumeOutput.peripheralName(prefix: "A", name: "Symphony I/O") == "A Symphony I/O")
        #expect(KeyboardVolumeOutput.peripheralName(prefix: "B", name: "Symphony I/O") == "B Symphony I/O")
        #expect(KeyboardVolumeOutput.peripheralName(prefix: "", name: "Symphony I/O") == "Symphony I/O")
    }
}
