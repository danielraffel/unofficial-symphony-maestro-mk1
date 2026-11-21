import Foundation
import Testing
@testable import MaestroApp

/// Help's search: it reads the same strings the page draws (`HelpSection.all`).
@Suite("Help search")
struct HelpSearchTests {
    private let all = HelpSection.all(micPreInstalled: true)

    private func titles(_ query: String, in sections: [HelpSection]? = nil) -> [String] {
        HelpSearch.filter(sections ?? all, query: query).flatMap { section in
            section.items.map { $0.title ?? section.title }
        }
    }

    @Test("An empty or blank query keeps every section and question")
    func emptyQuery() {
        for query in ["", "   ", "\n\t"] {
            let shown = HelpSearch.filter(all, query: query)
            #expect(shown.map(\.id) == all.map(\.id))
            #expect(shown.map(\.items.count) == all.map(\.items.count))
        }
        #expect(all.count == 20)
        #expect(HelpSection.all(micPreInstalled: false).count == 18)
    }

    @Test("A word in a question's title finds that question")
    func questionTitle() {
        // "thanks" is in one title and in no answer.
        #expect(titles("thanks") == ["How can I say thanks?"])
        #expect(titles("Identify") == ["What do Reset Routing and Identify do?"])
    }

    @Test("A word only in an answer finds the whole question")
    func answerBody() throws {
        // "voltmeter" is in one answer and in no title.
        #expect(titles("voltmeter") == ["Why doesn't the D/A meter move when I change a Trim?"])
        let shown = try #require(HelpSearch.filter(all, query: "voltmeter").first)
        #expect(shown.id == .inputOutput && shown.title == "Input & Output")
        #expect(shown.items.first?.blocks.count == 1)
        // A bullet, and text directly under a section heading.
        #expect(titles("condenser") == ["Your Mic Pre channel strip"])
        // The Terminal command.
        #expect(titles("uninstall.sh") == ["Uninstalling"])
    }

    @Test("A section's title finds everything in that section")
    func sectionTitle() throws {
        let shown = HelpSearch.filter(all, query: "troubleshooting")
        let section = try #require(shown.first { $0.id == .troubleshooting })
        #expect(section.items.count == all.first { $0.id == .troubleshooting }?.items.count)
        #expect(section.items.count == 7)
    }

    @Test("Every word must match; they need not be together or in order")
    func severalWords() {
        #expect(titles("peaks infinite") == ["How long are Peaks and Overs held?"])
        #expect(titles("infinite   peaks") == ["How long are Peaks and Overs held?"])
        #expect(titles("peaks zzzz").isEmpty)
        // One word from the section title, one from an answer.
        #expect(titles("routing rack") == ["What do Reset Routing and Identify do?"])
    }

    @Test("Markdown markers and link addresses are not part of the text")
    func markdownIgnored() {
        #expect(HelpSearch.plain("Route **Mixer 1** or *that* [guide](https://example.com/a%20b)")
            == "Route Mixer 1 or that guide")
        // Numbered steps and bold step numbers keep their numbers.
        #expect(HelpSearch.plain("1. Restart your Mac") == "1. Restart your Mac")
        #expect(HelpSearch.plain("**1.** Update Maestro") == "1. Update Maestro")
        let sample = [HelpSection(id: .mixer, title: "Mixer", items: [
            HelpItem(title: "Direct", blocks: [.text("Route **Mixer 1** to an output, see [the guide](https://example.com/zebra).")]),
            HelpItem(title: "Other", blocks: [.bullet("Master", "sets the level")]),
        ])]
        #expect(titles("mixer 1", in: sample) == ["Direct"])
        #expect(titles("1**", in: sample).isEmpty)
        #expect(titles("**", in: sample).isEmpty)
        #expect(titles("zebra", in: sample).isEmpty)
        #expect(titles("guide).", in: sample).isEmpty)
        #expect(titles("master sets", in: sample) == ["Other"])
        // The real page: "**Mixer 1**" in an answer.
        #expect(titles("mixer 1").contains("When do I hear an input directly through the Symphony?"))
        #expect(titles("**").isEmpty)
    }

    @Test("Case and accents do not matter")
    func caseAndDiacritics() {
        #expect(titles("IDENTIFY") == titles("identify"))
        #expect(titles("ídéntify") == titles("identify"))
        let sample = [HelpSection(id: .about, title: "Café", items: [HelpItem(blocks: [.text("Señor Müller")])])]
        #expect(titles("cafe", in: sample) == ["Café"])
        #expect(titles("SENOR muller", in: sample) == ["Café"])
        #expect(titles("CAFÉ", in: sample) == ["Café"])
    }

    @Test("Nothing matches a word that is nowhere in Help")
    func noMatch() {
        #expect(HelpSearch.filter(all, query: "qqzzxxyy").isEmpty)
    }

    @Test("Every question has an answer, and titles are not repeated")
    func content() {
        let questions = all.flatMap(\.items).compactMap(\.title)
        #expect(questions.count == 35)
        #expect(Set(questions).count == questions.count)
        #expect(Set(all.map(\.title)).count == all.count)
        for item in all.flatMap(\.items) {
            #expect(!item.blocks.isEmpty)
            for block in item.blocks {
                #expect(!HelpSearch.plain(block.markdown).isEmpty)
                // Nothing left unparsed.
                #expect(!HelpSearch.plain(block.markdown).contains("]("), "\(block.markdown.prefix(60))")
            }
        }
    }

    /// The info pop-ups that have a matching Help section end with the link
    /// to it. About Clock Status has no section in Help, so it has no link.
    @Test("Info pop-ups end with See Help for more., each at its own section")
    @MainActor
    func popoverLinks() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MaestroApp")
        let settings = try String(contentsOf: root.appendingPathComponent("SettingsViews.swift"), encoding: .utf8)
        let monitor = try String(contentsOf: root.appendingPathComponent("MonitorViews.swift"), encoding: .utf8)
        #expect(settings.contains("SeeHelpLink(section: .twoUnits, appState: appState, popover: $showPortsInfo)"))
        #expect(settings.contains("SeeHelpLink(section: .vbus, appState: appState, popover: $showVBusInfo)"))
        #expect(settings.contains("SeeHelpLink(section: .interfaceMode, appState: appState, popover: $showAIMInfo)"))
        #expect(monitor.contains("SeeHelpLink(section: .troubleshooting, appState: appState, popover: $showPortMessageInfo)"))
        #expect(settings.components(separatedBy: "SeeHelpLink(").count == 4)
        #expect(SeeHelpLink.title == "See Help for more.")
        // Every section a link names is in Help, with or without an 8MicPre.
        let shown = Set(HelpSection.all(micPreInstalled: false).map(\.id))
        for id in [HelpSectionID.twoUnits, .vbus, .interfaceMode, .troubleshooting] { #expect(shown.contains(id)) }

        let state = AppState()
        state.openHelp(at: .vbus)
        #expect(state.showHelp && state.helpSection == .vbus)
        state.showHelp = false
        state.openHelp()   // the Help menu: at the top
        #expect(state.showHelp && state.helpSection == nil)
    }
}
