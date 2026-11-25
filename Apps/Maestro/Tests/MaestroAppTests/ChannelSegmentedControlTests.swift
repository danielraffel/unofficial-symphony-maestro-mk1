import AppKit
import SwiftUI
import Testing
import MaestroCore
@testable import MaestroApp

/// The Update channel control is AppKit's segmented control (so its halves
/// can be wide enough for the newest versions below them). It must still
/// follow `.disabled`, and a choice that opens a dialog first must leave the
/// old channel selected.
@MainActor
@Suite("Channel segmented control")
struct ChannelSegmentedControlTests {
    final class Box { var channel = UpdateChannel.stable; var writes: [UpdateChannel] = [] }

    private func host(_ view: some View) -> (NSWindow, NSSegmentedControl?) {
        let host = NSHostingView(rootView: AnyView(view.frame(width: ChannelReleasesRow.width)))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 400, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (window, Self.find(in: host))
    }

    private static func find(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl { return control }
        for sub in view.subviews { if let found = find(in: sub) { return found } }
        return nil
    }

    @Test func followsDisabled() throws {
        let box = Box()
        let binding = Binding(get: { box.channel }, set: { box.channel = $0 })
        let (disabledWindow, disabled) = host(ChannelSegmentedControl(selection: binding).disabled(true))
        defer { disabledWindow.close() }
        #expect(try #require(disabled).isEnabled == false)
        let (enabledWindow, enabled) = host(ChannelSegmentedControl(selection: binding))
        defer { enabledWindow.close() }
        #expect(try #require(enabled).isEnabled == true)
        #expect(enabled?.frame.width == ChannelReleasesRow.width)
    }

    @Test func aChoiceTheBindingRefusesLeavesTheOldChannelSelected() throws {
        let box = Box()
        // Like the channel picker: Beta opens a dialog and saves nothing yet.
        let binding = Binding(get: { box.channel }, set: { box.writes.append($0) })
        let (window, found) = host(ChannelSegmentedControl(selection: binding))
        defer { window.close() }
        let control = try #require(found)
        #expect(control.selectedSegment == 0)
        control.selectedSegment = 1
        control.sendAction(control.action, to: control.target)
        #expect(box.writes == [.beta])
        #expect(control.selectedSegment == 0)
    }
}
