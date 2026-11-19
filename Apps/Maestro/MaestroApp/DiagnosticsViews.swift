import AppKit
import SwiftUI

/// Where the Diagnostics switch appears in Device Settings › Diagnostics & Feedback.
///
/// Decision (2026-11-18): Beta only for now. Revisit when the next beta is
/// promoted to Stable: AGENTS.md › Release channels › "Decisions for the next
/// promotion" lists this switch and every piece of copy that says "Beta" with it.
enum DiagnosticsAvailability {
    /// Flip to `true` to show the switch on the Stable channel too.
    static let showOnStable = false

    /// Always shown while a recording is running, so it can be stopped.
    static func showsSwitch(betaChannel: Bool, recording: Bool) -> Bool {
        recording || betaChannel || showOnStable
    }
}

/// The words, kept short and in one place (settings row, notice, bar, Help).
enum DiagnosticsCopy {
    static var canSend: Bool { DiagnosticsSender.configured != nil }

    static var caption: String {
        canSend
            ? "Records what Maestro and the driver are doing while you reproduce a problem. When you stop, you can send it privately to the developer."
            : "Records what Maestro and the driver are doing, then saves a file to your Desktop you can email to the developer."
    }
    static let consentTitle = "Turn on diagnostics?"
    static var consent: String {
        canSend
            ? "Maestro records what it and the driver do until you press Stop Diagnostics. The file is saved to your Desktop, and nothing is sent unless you agree."
            : "Maestro records what it and the driver do until you press Stop Diagnostics, then saves a file to your Desktop for you to email to \(DiagnosticsRecorder.sendTo)."
    }
    static let bar = "Reproduce the problem, then press Stop Diagnostics."
    static let connectionHint = "Connection problem? Turn your Symphony or converter off and on while this runs."
    static func savedNoSend(_ name: String) -> String {
        "\(name)\n\nPlease read it, then email it to \(DiagnosticsRecorder.sendTo). Don't attach it to a GitHub issue, which is public."
    }
}

/// Device Settings › Diagnostics & Feedback: the on/off switch.
struct DiagnosticsSettingsRow: View {
    @Environment(DiagnosticsRecorder.self) private var diagnostics
    @State private var askConsent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Diagnostics", isOn: Binding(
                get: { diagnostics.isRecording },
                set: { on in
                    if on { askConsent = true } else { Task { await diagnostics.stopAndSave() } }
                }))
                .disabled(diagnostics.isSaving)
            Text(DiagnosticsCopy.caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .alert(DiagnosticsCopy.consentTitle, isPresented: $askConsent) {
            Button("Turn On") { diagnostics.start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(DiagnosticsCopy.consent)
        }
    }
}

/// Shown across the top of the window while diagnostics is on: one button.
struct DiagnosticsBar: View {
    @Environment(DiagnosticsRecorder.self) private var diagnostics

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(.red).frame(width: 8, height: 8)
            if diagnostics.isSaving {
                Text("Saving diagnostics…").font(.callout.weight(.semibold))
                ProgressView().controlSize(.small)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 10) {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("Diagnostics on · \(elapsed(at: context.date))")
                                .font(.callout.weight(.semibold))
                                .monospacedDigit()
                        }
                        Text(DiagnosticsCopy.bar).font(.callout).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Text(DiagnosticsCopy.connectionHint)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            if diagnostics.isRecording {
                Button("Stop Diagnostics") { Task { await diagnostics.stopAndSave() } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.red.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func elapsed(at date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSince(diagnostics.startedAt ?? date)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The email address is remembered on this Mac only, to save retyping it.
let diagnosticsContactKey = "maestro.diagnostics.contact"

/// After stopping: the file is on the Desktop; optionally describe the setup
/// and the problem, and agree to email it.
struct DiagnosticsSendSheet: View {
    let file: URL
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @AppStorage(diagnosticsContactKey) private var contact = ""
    @State private var note = ""
    @State private var working = ""
    @State private var doing = ""
    @State private var connections: Set<String> = []
    @State private var symphony = ""
    @State private var cards: Set<String> = []
    @State private var converters: Set<String> = []
    @State private var issue = ""
    @State private var state: SendState = .editing

    enum SendState: Equatable { case editing, sending, sent(String), failed(String) }

    /// The hardware Maestro knows about, in display order.
    static let knownConnections = ["USB", "ThunderBridge", "PCIe card"]
    static let symphonyAnswers = ["None", "One", "Two"]
    static let knownCards = ["8x8 AES", "8x8 Optical (ADAT)", "16 Analog In / 16 Optical Out",
                             "16 Optical In / 16 Analog Out", "16x16 Analog", "2x6", "8 Mic Pre"]
    static let knownConverters = ["AD-16X", "DA-16X", "Rosetta 800"]
    private var hasSymphony: Bool { symphony == "One" || symphony == "Two" }
    private func ordered(_ picked: Set<String>, _ known: [String]) -> [String] { known.filter(picked.contains) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch state {
            case .sent(let reference):
                Label("Sent to the developer", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                Text("Thank you. Your reference is **\(reference)**; mention it if you write to us about this. A copy is on your Desktop as \(file.lastPathComponent).")
                    .fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            default:
                form
            }
        }
        .padding(20)
        .frame(width: 760)
        .interactiveDismissDisabled(state == .sending)
    }

    @ViewBuilder private var form: some View {
        VStack(alignment: .leading, spacing: 6) {
            (Text("Diagnostics saved to your Desktop: ").font(.headline)
                + Text(file.lastPathComponent).font(.headline.weight(.regular)))
            Text("Thanks for considering sharing the diagnostics and your answers with the developer, so we can investigate and get back to you. Everything is optional.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        ScrollView {
            HStack(alignment: .top, spacing: 24) {
                // Left: how to reach them, and the setup, by ticking.
                VStack(alignment: .leading, spacing: 12) {
                    Field("Your email, so we can get back to you") {
                        TextField("name@example.com", text: $contact)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.emailAddress)
                    }
                    Field("How are your devices connected?") {
                        CheckboxGrid(options: Self.knownConnections, picked: $connections, columns: 3)
                    }
                    Field("Do you have a Symphony I/O Mk I?") {
                        Picker("", selection: $symphony) {
                            ForEach(Self.symphonyAnswers, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    if hasSymphony {
                        Field("Which cards are in it?") {
                            CheckboxGrid(options: Self.knownCards, picked: $cards, columns: 2)
                        }
                    }
                    Field("Do you have any external converters?") {
                        CheckboxGrid(options: Self.knownConverters, picked: $converters, columns: 3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                // Right: the problem.
                VStack(alignment: .leading, spacing: 12) {
                    Field("What isn't working?") { NoteEditor(text: $note, minHeight: 64) }
                    Field("What is working?") { NoteEditor(text: $working, minHeight: 38) }
                    Field("What were you doing? (DAW, sample rate…)") { NoteEditor(text: $doing, minHeight: 38) }
                    Field("Existing GitHub issue") {
                        TextField("Link, if you already reported this", text: $issue)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)

        // What pressing the button means, where it can't be missed.
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "envelope.badge").foregroundStyle(.orange)
            Text("By pressing **Agree and Send**, you agree that Maestro emails this diagnostics file (attached) and anything you entered above to the developer, to help diagnose the problem. Nothing is sent until you press it. It is never posted publicly, and a copy stays on your Desktop.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.yellow.opacity(0.55)))

        if case .failed(let message) = state {
            Text("\(message) The file is still on your Desktop; you can also email it to \(DiagnosticsRecorder.sendTo).")
                .font(.callout).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            Spacer()
            if state == .sending { ProgressView().controlSize(.small) }
            Button("Don't Send", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(state == .sending)
            Button(state.isFailed ? "Try Again" : "Agree and Send") { Task { await send() } }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .keyboardShortcut(.defaultAction)
                .disabled(state == .sending)
        }
    }

    private func send() async {
        guard let sender = DiagnosticsSender.configured else { return }
        state = .sending
        let message = DiagnosticsSender.Message(
            note: note, working: working, doing: doing,
            connections: ordered(connections, Self.knownConnections), symphony: symphony,
            cards: hasSymphony ? ordered(cards, Self.knownCards) : [],
            converters: ordered(converters, Self.knownConverters),
            issue: issue, contact: contact,
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            channel: appState.updateChannel?.rawValue.capitalized ?? "")
        do {
            state = .sent(try await sender.send(report: file, message: message))
        } catch {
            state = .failed(DiagnosticsSender.userMessage(for: error))
        }
    }
}

private extension DiagnosticsSendSheet.SendState {
    var isFailed: Bool { if case .failed = self { return true } else { return false } }
}

/// One labelled field. Everything in the form is optional, said once at the top.
private struct Field<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.medium))
            content
        }
    }
}

/// Checkboxes in a grid; any number can be ticked.
private struct CheckboxGrid: View {
    let options: [String]
    @Binding var picked: Set<String>
    var columns: Int

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: columns),
                  alignment: .leading, spacing: 4) {
            ForEach(options, id: \.self) { option in
                Toggle(option, isOn: Binding(
                    get: { picked.contains(option) },
                    set: { if $0 { picked.insert(option) } else { picked.remove(option) } }))
                    .toggleStyle(.checkbox)
            }
        }
    }
}

/// A bordered multi-line text field.
private struct NoteEditor: View {
    @Binding var text: String
    var minHeight: CGFloat

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.35)))
    }
}

/// The send form (or, in a build that cannot send, the saved notice) and the
/// offer to save an unfinished session.
struct DiagnosticsAlerts: ViewModifier {
    @Environment(DiagnosticsRecorder.self) private var diagnostics
    @State private var offeredUnfinished = false
    @State private var showUnfinished = false

    func body(content: Content) -> some View {
        @Bindable var d = diagnostics
        let canSend = DiagnosticsCopy.canSend
        content
            .sheet(item: Binding(get: { canSend ? d.lastSaved.map(SavedFile.init) : nil },
                                 set: { if $0 == nil { d.lastSaved = nil } })) { saved in
                DiagnosticsSendSheet(file: saved.url)
            }
            .alert("Diagnostics saved to your Desktop",
                   isPresented: Binding(get: { !canSend && d.lastSaved != nil }, set: { if !$0 { d.lastSaved = nil } }),
                   presenting: d.lastSaved) { url in
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("OK", role: .cancel) {}
            } message: { url in
                Text(DiagnosticsCopy.savedNoSend(url.lastPathComponent))
            }
            .alert("Save unfinished diagnostics?", isPresented: $showUnfinished) {
                Button("Save to Desktop") { Task { await diagnostics.saveUnfinished() } }
                Button("Discard", role: .destructive) { diagnostics.discardUnfinished() }
            } message: {
                Text("Diagnostics was still on when Maestro last quit. Save what was recorded?")
            }
            .task {
                guard !offeredUnfinished else { return }
                offeredUnfinished = true
                if diagnostics.hasUnfinishedSession && !diagnostics.isRecording { showUnfinished = true }
            }
    }
}

private struct SavedFile: Identifiable {
    let url: URL
    var id: URL { url }
}
