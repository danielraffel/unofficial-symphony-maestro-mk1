import MaestroCore

/// Targets for monitor buttons and the front-panel encoder. Callers apply the
/// same new switch value to every returned target.
public enum MonitorOutputToggle {
    public enum Control: CaseIterable, Sendable {
        case mute, dim, sum
    }

    public static func targets(for control: Control, clicked: SymphonyIORequestBuilder.MonitorOutput,
                               option: Bool, speakerMode: UInt32) -> [SymphonyIORequestBuilder.MonitorOutput] {
        let outputs = option ? SymphonyIORequestBuilder.MonitorOutput.allCases : [clicked]
        return outputs.filter {
            $0 != .speaker || speakerMode != SpeakerOutputLogic.line || control == .mute
        }
    }

    public static func respondsToMuteAll(_ output: SymphonyIORequestBuilder.MonitorOutput, levelDB: Double,
                                         speakerMode: UInt32) -> Bool {
        levelDB > -64 && (output != .speaker || speakerMode != SpeakerOutputLogic.line)
    }
}
