import Foundation
import Testing
@testable import MaestroCore

struct ReferenceTrimTests {
    @Test func variableTrimRoundTripsAndRecallEncodesTheExpectedBytes() throws {
        let original = InputChannelState(inputType: AnalogInputLevel.variable.rawValue, trim: 20)
        var plus4 = original.switchingTrimReference(to: .plus4dBu)
        #expect(plus4.trim == 0)
        #expect(InputChannelLogic.analogIOTypeWithTrim(level: .plus4dBu, trim: plus4.trim) == 0x0001)
        plus4.trim = -1.5
        let data = try PropertyListEncoder().encode(plus4)
        let saved = try PropertyListDecoder().decode(InputChannelState.self, from: data)
        let variable = saved.switchingTrimReference(to: .variable)
        #expect(variable.trim == 20)
        #expect(InputChannelLogic.analogIOTypeWithTrim(level: .variable, trim: variable.trim) == 0x2800)
        let plus4Again = variable.switchingTrimReference(to: .plus4dBu)
        #expect(plus4Again.trim == -1.5)
        #expect(InputChannelLogic.analogIOTypeWithTrim(level: .plus4dBu, trim: plus4Again.trim) == 0xF101)
    }

    @Test func oldStoredChannelStatesSeedOnlyTheirActiveReference() throws {
        let input = try JSONDecoder().decode(InputChannelState.self,
            from: Data(#"{"inputType":2,"trim":-1.2}"#.utf8))
        #expect(input.trim == -1.2 && input.trimMinus10 == -1.2 && input.trimPlus4 == 0 && input.trimVariable == 0)
        let output = try JSONDecoder().decode(OutputChannelState.self,
            from: Data(#"{"analogRefLevel":2,"digitalRefLevel":2,"trim":-0.6}"#.utf8))
        #expect(output.trim == -0.6 && output.trimMinus10 == -0.6 && output.trimPlus4 == 0)
    }

    @Test func olderPresetLoadsAndDigitalReferenceDoesNotEraseTrimBanks() throws {
        var older = MaestroPreset()
        older.inputChannelStates = [InputChannelState(inputType: 0, trim: 20)]
        older.outputChannelStates = [OutputChannelState(analogRefLevel: 1, trim: -1.2)]
        let data = try PropertyListEncoder().encode(older)
        var plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        for key in ["inputChannelStates", "outputChannelStates"] {
            var rows = try #require(plist[key] as? [[String: Any]])
            for index in rows.indices {
                for field in ["trimPlus4", "trimMinus10", "trimVariable"] { rows[index].removeValue(forKey: field) }
            }
            plist[key] = rows
        }
        let oldData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let loaded = try PropertyListDecoder().decode(MaestroPreset.self, from: oldData)
        #expect(loaded.inputChannelStates[0].trimVariable == 20)
        #expect(loaded.outputChannelStates[0].trimPlus4 == -1.2)
        var minus10 = loaded.outputChannelStates[0].switchingTrimReference(to: 2)
        #expect(minus10.trim == 0)
        minus10.trim = -0.4
        minus10.digitalRefLevel = 0
        let plus4 = minus10.switchingTrimReference(to: 1)
        #expect(plus4.trim == -1.2 && plus4.trimMinus10 == -0.4 && plus4.digitalRefLevel == 0)
        #expect(plus4.switchingTrimReference(to: 2).trim == -0.4)
    }
}
