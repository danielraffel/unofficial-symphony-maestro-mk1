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
        #expect(all.count == 23)
        #expect(HelpSection.all(micPreInstalled: false).count == 21)
    }

    @Test("A word in a question's title finds that question")
    func questionTitle() {
        // "documentation" is in one title.
        #expect(titles("documentation") == ["Where do I find Apogee's own documentation and software?"])
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
        #expect(section.items.count == 8)
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
        #expect(questions.count == 43)
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

    /// The info pop-ups end with the link to their Help section.
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
        #expect(settings.contains("SeeHelpLink(section: .clock, appState: appState, popover: $showClockStatusInfo)"))
        #expect(settings.components(separatedBy: "SeeHelpLink(").count == 6)
        #expect(SeeHelpLink.title == "See Help for more.")
        // The status bar's pop-up is closed when its message goes, by the bar
        // (the button that owns the pop-up is gone by then).
        let bar = try #require(monitor.range(of: "        .padding(.vertical, 6)\n"))
        #expect(monitor[bar.upperBound...].contains("""
                    .onChange(of: appState.portStatusMessage == nil) { _, gone in
                        if gone { showPortMessageInfo = false }
                    }
            """))

        let state = AppState()
        state.openHelp(at: .vbus)
        #expect(state.showHelp && state.helpSection == .vbus)
        state.showHelp = false
        state.openHelp()   // the Help menu: at the top
        #expect(state.showHelp && state.helpSection == nil)
    }

    /// The section each `SeeHelpLink(section: .name, …)` in the app's sources names.
    static func linkTargets(in source: String) -> [String] {
        source.components(separatedBy: "SeeHelpLink(section: .").dropFirst().map { rest in
            String(rest.prefix { $0.isLetter || $0.isNumber })
        }
    }

    @Test("Every See Help for more. link names a section that Help shows")
    func linkTargetsExist() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("MaestroApp")
        // With or without an 8MicPre.
        let shown = Set(HelpSection.all(micPreInstalled: false).map(\.id.rawValue))
        var found: [String] = []
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        where file.pathExtension == "swift" {
            let targets = Self.linkTargets(in: try String(contentsOf: file, encoding: .utf8))
            for target in targets {
                #expect(shown.contains(target), "\(file.lastPathComponent): no Help section \(target)")
            }
            found += targets
        }
        #expect(Set(found) == ["twoUnits", "vbus", "interfaceMode", "troubleshooting", "clock", "feedback"])
        // The check itself: a name Help does not have is not in the set.
        #expect(Self.linkTargets(in: "SeeHelpLink(section: .nowhere, appState: a, popover: $p)") == ["nowhere"])
        #expect(!shown.contains("nowhere") && !shown.contains("micPreStrip"))
    }

    /// Help says how things work. It does not report what is or is not
    /// finished, and never calls anything an experiment (owner's rule).
    static let statusPhrases = ["experiment", "untested", "not confirmed", "known gap", "rough edges", "works today"]

    static func statusPhrases(in sections: [HelpSection]) -> [String] {
        let text = sections.flatMap { section in
            [section.title] + section.items.flatMap { [$0.title ?? ""] + $0.blocks.map { HelpSearch.plain($0.markdown) } }
        }.joined(separator: "\n").lowercased()
        return statusPhrases.filter { text.contains($0) }
    }

    @Test("Help has no status report or hedge, and no \"experiment\"")
    func noStatusPhrases() {
        #expect(Self.statusPhrases(in: all) == [])
        // The check itself: each phrase is found, in a title or an answer, in any case.
        for phrase in Self.statusPhrases {
            let inAnswer = [HelpSection(id: .about, title: "T", items: [HelpItem(blocks: [.text("It is **\(phrase.uppercased())**.")])])]
            #expect(Self.statusPhrases(in: inAnswer) == [phrase])
            let inTitle = [HelpSection(id: .about, title: "What \(phrase)", items: [HelpItem(blocks: [.text("x")])])]
            #expect(Self.statusPhrases(in: inTitle) == [phrase])
        }
        let more = ["has not been tested", "not been tried", "support is new", "are welcome", "tested with",
                    "should keep", "limitation of"]
        let text = all.flatMap { $0.items.flatMap { $0.blocks.map { HelpSearch.plain($0.markdown) } } }
            .joined(separator: "\n").lowercased()
        for phrase in more { #expect(!text.contains(phrase), "\(phrase)") }
    }

    @Test("an answer's paragraphs and bullets are one text, so a selection can run across them")
    func proseRuns() {
        let runs = HelpSearch.runs([.text("One."), .text("Two **bold**."), .bullet("Term", "what it does"),
                                    .bullet("Other", "more"), .command("ls"), .text("After.")])
        #expect(runs.count == 3)
        guard case .prose(let first) = runs[0], case .block(.command(let command)) = runs[1],
              case .prose(let last) = runs[2] else { Issue.record("unexpected runs"); return }
        #expect(String(first.characters) == "One.\n\nTwo bold.\n\n\u{2022} Term \u{2014} what it does\n\n\u{2022} Other \u{2014} more")
        #expect(command == "ls")
        #expect(String(last.characters) == "After.")
    }

    @Test("a section is one text from its heading to its end, broken only by a command, link or the removal steps")
    func sectionRuns() {
        let section = HelpSection(id: .vbus, title: "VBus", items: [
            HelpItem(blocks: [.text("Intro.")]),
            HelpItem(title: "What is it?", blocks: [.text("Extra channels."), .text("Off by default.")]),
            HelpItem(title: "How?", blocks: [.text("Choose a size."), .command("ls"), .text("Then reopen.")]),
        ])
        let runs = HelpSearch.runs(section)
        #expect(runs.count == 3)
        guard case .prose(let first) = runs[0], case .block(.command) = runs[1], case .prose(let last) = runs[2]
        else { Issue.record("unexpected runs"); return }
        #expect(String(first.characters)
                == "VBus\nIntro.\n\nWhat is it?\nExtra channels.\n\nOff by default.\n\nHow?\nChoose a size.")
        #expect(String(last.characters) == "Then reopen.")
    }

    @Test("the list marks the section at the top of the page")
    func currentSection() {
        let order: [HelpSectionID] = [.whatItDoes, .clock, .vbus]
        #expect(HelpSearch.currentSection(tops: [.whatItDoes: 0, .clock: 300, .vbus: 900], order: order) == .whatItDoes)
        #expect(HelpSearch.currentSection(tops: [.whatItDoes: -400, .clock: 10, .vbus: 500], order: order) == .clock)
        #expect(HelpSearch.currentSection(tops: [.whatItDoes: -900, .clock: -500, .vbus: -20], order: order) == .vbus)
        #expect(HelpSearch.currentSection(tops: [:], order: order) == .whatItDoes)
        #expect(HelpSearch.currentSection(tops: [:], order: []) == nil)
    }

    @Test("Up and Down move to the neighbouring section and stop at the ends")
    func neighbour() {
        let order: [HelpSectionID] = [.whatItDoes, .clock, .vbus]
        #expect(HelpSearch.neighbour(of: .clock, in: order, step: 1) == .vbus)
        #expect(HelpSearch.neighbour(of: .clock, in: order, step: -1) == .whatItDoes)
        #expect(HelpSearch.neighbour(of: .vbus, in: order, step: 1) == nil)
        #expect(HelpSearch.neighbour(of: .whatItDoes, in: order, step: -1) == nil)
        #expect(HelpSearch.neighbour(of: nil, in: order, step: 1) == .whatItDoes)
    }
}
