import AppKit
import SwiftUI
import Testing
import MaestroCore
@testable import MaestroApp

/// Tester report 2026-11-22 (diagnostics 73D9A557): Converters only, port 1 =
/// AD-16X, DA-16X, AD-16X, DA-16X; port 2 = DA-16X; 64 channels.
extension StandardDefaultsSuites {
@Suite("Converters on both ports at 64 channels", .serialized)
@MainActor
struct ConverterTwoPortTests {
    static let chain = "ad16x+da16x+ad16x+da16x|da16x"

    private func state(clearBoards: Bool = true) throws -> AppState {
        let s = AppState()
        if clearBoards { s.primaryBoardType = .none; s.secondaryBoardType = .none }
        let system = try #require(ConverterSystem(simulationName: Self.chain))
        s.converterSystem = system
        s.connectedUnit = system.connectedUnit
        return s
    }

    @Test func counts() throws {
        let s = try state()
        let layout = s.cardLayout
        if let r = s.converterRoutingLayout {
        }
        #expect(layout.analogOutputStripCount == 48)
        #expect(layout.analogInputStripCount == 32)
        #expect(s.softwareReturnPairCount == 32)
    }

    private func host(_ view: AnyView) -> (NSWindow, NSHostingView<AnyView>) {
        let root = AnyView(
            NavigationSplitView {
                List { ForEach(0..<7, id: \.self) { Text("Area \($0)") } }
                    .frame(minWidth: 158, idealWidth: 158)
            } detail: {
                VStack(spacing: 0) {
                    Text("Status").frame(maxWidth: .infinity)
                    view.frame(maxHeight: .infinity)
                }
            }
            .frame(minWidth: 800, minHeight: 500)
        )
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: 1440, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    @Test func outputRoutingFitsWindow() throws {
        let s = try state()
        let (w, h) = host(AnyView(OutputRoutingView(appState: s).environment(s)))
        defer { w.close() }
        #expect(h.fittingSize.height <= 500)
        #expect(h.fittingSize.width <= 800)
    }

    @Test func inputRoutingFitsWindow() throws {
        let s = try state()
        let (w, h) = host(AnyView(InputRoutingView(appState: s).environment(s)))
        defer { w.close() }
        #expect(h.fittingSize.height <= 500)
        #expect(h.fittingSize.width <= 800)
    }

    @Test func staleBoardsCounts() throws {
        let s = try state(clearBoards: false)
        s.primaryBoardType = .analogADDA16; s.secondaryBoardType = .analogADDA16
        let (w, h) = host(AnyView(InputRoutingView(appState: s).environment(s)))
        defer { w.close() }
        let (w2, h2) = host(AnyView(OutputRoutingView(appState: s).environment(s)))
        defer { w2.close() }
        #expect(s.cardLayout.analogOutputStripCount == 48)
        #expect(h.fittingSize.height <= 500)
        #expect(h2.fittingSize.height <= 500)
    }

    @Test func unavailableNoteAlone() throws {
        let (w, h) = host(AnyView(ConverterRoutingUnavailableNote(title: "Input Routing")))
        defer { w.close() }
        #expect(h.fittingSize.height <= 500)
    }
}
}
