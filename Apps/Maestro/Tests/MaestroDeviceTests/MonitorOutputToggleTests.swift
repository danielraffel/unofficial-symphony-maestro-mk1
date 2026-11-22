import Testing
import MaestroCore
@testable import MaestroDevice

struct MonitorOutputToggleTests {
    @Test(arguments: MonitorOutputToggle.Control.allCases, SymphonyIORequestBuilder.MonitorOutput.allCases)
    func optionClickTargets(control: MonitorOutputToggle.Control, clicked: SymphonyIORequestBuilder.MonitorOutput) {
        let stereo = SpeakerOutputLogic.stereo
        let line = SpeakerOutputLogic.line
        #expect(MonitorOutputToggle.targets(for: control, clicked: clicked, option: false, speakerMode: stereo) == [clicked])
        #expect(Set(MonitorOutputToggle.targets(for: control, clicked: clicked, option: true, speakerMode: stereo))
                == [.speaker, .headphone1, .headphone2])
        let lineTargets: Set<SymphonyIORequestBuilder.MonitorOutput> = control == .mute ? [.speaker, .headphone1, .headphone2]
            : [.headphone1, .headphone2]
        #expect(Set(MonitorOutputToggle.targets(for: control, clicked: clicked, option: true, speakerMode: line))
                == lineTargets)
        #expect(MonitorOutputToggle.targets(for: control, clicked: clicked, option: false, speakerMode: line)
                == (lineTargets.contains(clicked) ? [clicked] : []))
    }

    @Test(arguments: SymphonyIORequestBuilder.MonitorOutput.allCases, [-64.0, -63.0, 0.0])
    func muteAllSkipsMinimumAndLineSpeaker(output: SymphonyIORequestBuilder.MonitorOutput, level: Double) {
        #expect(MonitorOutputToggle.respondsToMuteAll(output, levelDB: level, speakerMode: SpeakerOutputLogic.stereo)
                == (level > -64))
        #expect(MonitorOutputToggle.respondsToMuteAll(output, levelDB: level, speakerMode: SpeakerOutputLogic.line)
                == (level > -64 && output != .speaker))
    }
}
