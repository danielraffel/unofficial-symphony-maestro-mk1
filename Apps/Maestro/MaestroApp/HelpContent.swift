import Foundation
import MaestroCore

// Help's content as data, so the page and its search read the same strings.
// The sections themselves are in HelpView.swift (`HelpSection.all`).

/// The sections of Help, in no particular order. A pop-up's "See Help for
/// more." names one of these.
enum HelpSectionID: String {
    case whatItDoes, connecting, controls, settings, clock, inputOutput, modules
    case micPreStrip, micPreQuestions, routing, mixer, mixerUSB, volumeKeys
    case vbus, usbOutput, interfaceMode, twoUnits, troubleshooting
    case apogeeDrivers, uninstalling, about, feedback, donate
}

struct HelpSection: Identifiable {
    let id: HelpSectionID
    let title: String
    let items: [HelpItem]
}

/// A question with its answer, or (without a title) text directly under the
/// section heading.
struct HelpItem {
    var title: String? = nil
    let blocks: [HelpBlock]
}

enum HelpBlock {
    /// A paragraph, as inline Markdown.
    case text(String)
    /// "• **term** — description".
    case bullet(String, String)
    /// A Terminal command with a Copy button.
    case command(String)
    case link(String, URL)
    /// `ManualApogeeRemovalSteps`, the collapsed last-resort steps.
    case manualApogeeRemoval

    /// The Markdown this block is drawn from.
    var markdown: String {
        switch self {
        case .text(let text): return text
        case .bullet(let term, let description): return "\(term) — \(description)"
        case .command(let command): return command
        case .link(let title, _): return title
        case .manualApogeeRemoval:
            return ([ManualApogeeRemovalSteps.title, OriginalApogeeDrivers.manualRemovalIntro]
                + OriginalApogeeDrivers.manualRemovalParts).joined(separator: " ")
        }
    }
}

enum HelpSearch {
    /// The section to mark in the list: the last one, in page order, whose
    /// top has reached the top of the scroll area (within `slack` points);
    /// before any has, the first.
    static func currentSection(tops: [HelpSectionID: CGFloat], order: [HelpSectionID],
                               slack: CGFloat = 40) -> HelpSectionID? {
        var result = order.first
        for id in order {
            guard let top = tops[id] else { continue }
            if top <= slack { result = id } else { break }
        }
        return result
    }

    /// What Help draws for an answer: runs of paragraphs and bullets joined
    /// into one text each, and the other blocks one by one.
    enum Run {
        case prose(AttributedString)
        case block(HelpBlock)
    }

    /// A whole section as runs: its heading, each question's title and the
    /// answers are one text wherever nothing but text lies between them, so
    /// a selection can run from the heading to the end of the section.
    /// Commands, links and the removal steps stay blocks of their own.
    static func runs(_ section: HelpSection) -> [Run] {
        var result: [Run] = []
        var prose: AttributedString?
        func add(_ piece: AttributedString, gap: String) {
            if var text = prose {
                text += AttributedString(gap)
                text += piece
                prose = text
            } else {
                prose = piece
            }
        }
        func flush() {
            if let text = prose { result.append(.prose(text)) }
            prose = nil
        }
        var heading = AttributedString(section.title)
        heading.font = .headline
        add(heading, gap: "")
        for item in section.items {
            var first = true
            if let title = item.title {
                var question = AttributedString(title)
                question.font = .callout.weight(.semibold)
                add(question, gap: "\n\n")
                first = false
            }
            for run in runs(item.blocks) {
                switch run {
                case .prose(let text):
                    // Straight under a heading or a question: next line.
                    add(text, gap: prose == nil ? "" : (first ? "\n" : (item.title != nil && isJustTitle(prose, item.title) ? "\n" : "\n\n")))
                case .block:
                    flush(); result.append(run)
                }
                first = false
            }
        }
        flush()
        return result
    }

    /// Whether the text so far ends with this question title (the answer's
    /// first paragraph then follows on the next line, not after a gap).
    private static func isJustTitle(_ text: AttributedString?, _ title: String?) -> Bool {
        guard let text, let title else { return false }
        return String(text.characters).hasSuffix(title)
    }

    /// An empty line a third of the usual height.
    static var bulletGap: AttributedString {
        var gap = AttributedString("\n")
        gap.font = .system(size: 4)
        return gap
    }

    /// Consecutive paragraphs and bullets become one attributed text:
    /// paragraphs a blank line apart, bullets on consecutive lines.
    static func runs(_ blocks: [HelpBlock]) -> [Run] {
        var result: [Run] = []
        var prose: AttributedString?
        var lastWasBullet = false
        func flush() {
            if let text = prose { result.append(.prose(text)) }
            prose = nil
        }
        for block in blocks {
            let piece: AttributedString
            let isBullet: Bool
            switch block {
            case .text(let markdown):
                piece = attributed(markdown); isBullet = false
            case .bullet(let term, let description):
                var bold = AttributedString(term)
                bold.inlinePresentationIntent = .stronglyEmphasized
                piece = AttributedString("\u{2022} ") + bold + attributed(" \u{2014} \(description)")
                isBullet = true
            default:
                flush(); result.append(.block(block)); lastWasBullet = false
                continue
            }
            if var text = prose {
                if isBullet && lastWasBullet {
                    // Between bullets: a new line and a thin spacer line, so a
                    // list reads as separate items without a full blank line.
                    text += AttributedString("\n") + bulletGap
                } else {
                    text += AttributedString("\n\n")
                }
                text += piece
                prose = text
            } else {
                prose = piece
            }
            lastWasBullet = isBullet
        }
        flush()
        return result
    }

    /// A paragraph as inline Markdown, the way Help draws it.
    static func attributed(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }

    /// Text as it reads on screen: Markdown markers and link addresses removed.
    static func plain(_ markdown: String) -> String {
        String(attributed(markdown).characters)
    }

    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The sections and questions that contain every word of `query`, in the
    /// section title, the question or its answer. An empty query keeps everything.
    static func filter(_ sections: [HelpSection], query: String) -> [HelpSection] {
        let terms = folded(query).split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return sections }
        return sections.compactMap { section in
            let items = section.items.filter { item in
                let parts = [section.title, item.title ?? ""] + item.blocks.map { plain($0.markdown) }
                let text = folded(parts.joined(separator: "\n"))
                return terms.allSatisfy { text.contains($0) }
            }
            return items.isEmpty ? nil : HelpSection(id: section.id, title: section.title, items: items)
        }
    }
}
