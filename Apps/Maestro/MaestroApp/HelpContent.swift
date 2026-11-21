import Foundation
import MaestroCore

// Help's content as data, so the page and its search read the same strings.
// The sections themselves are in HelpView.swift (`HelpSection.all`).

/// The sections of Help, in no particular order. A pop-up's "See Help for
/// more." names one of these.
enum HelpSectionID: String {
    case whatItDoes, connecting, worksToday, settings, inputOutput, modules
    case micPreStrip, micPreQuestions, routing, mixer, mixerUSB, volumeKeys
    case vbus, usbOutput, interfaceMode, twoUnits, troubleshooting
    case apogeeDrivers, uninstalling, about
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
