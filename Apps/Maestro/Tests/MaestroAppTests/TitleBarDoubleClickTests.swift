import Testing
@testable import MaestroApp

@Suite("Title bar double-click follows the system setting")
struct TitleBarDoubleClickTests {
    @Test func actions() {
        #expect(TitleBarDoubleClick.action(for: nil) == .zoom)
        #expect(TitleBarDoubleClick.action(for: "Maximize") == .zoom)
        #expect(TitleBarDoubleClick.action(for: "Fill") == .zoom)
        #expect(TitleBarDoubleClick.action(for: "Minimize") == .minimize)
        #expect(TitleBarDoubleClick.action(for: "None") == .none)
    }
}
