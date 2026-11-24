import Foundation
import Testing

/// The USB helper's render callback runs on the Symphony's real-time IO
/// thread with a 32-frame (0.67 ms) budget. On 2026-11-23 Core Audio skipped
/// about two of its cycles a minute for running over that budget, each one an
/// audible cut-out of Maestro USB; the callback logged (os_log, fprintf and
/// fflush on a file) every 940 cycles and dispatched from the thread on a
/// stall. Nothing that can block, allocate or lock may be called there.
@Suite("USB helper real-time safety")
struct HelperRealTimeSafetyTests {
    private static let forbidden = [
        "LOG(", "LOG_V(", "LOG_ERR(", "os_log", "printf", "fflush", "fwrite", "dispatch_",
        "malloc", "calloc", "realloc", "free(", "xpc_", "pthread_mutex", "os_unfair_lock",
        "usleep", "sleep(", "Block_copy", "save_", "usb_vendor_",
    ]

    /// `text` with its C comments removed.
    private static func stripComments(_ text: String) -> String {
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            if text[i...].hasPrefix("/*"), let end = text.range(of: "*/", range: i..<text.endIndex) {
                i = end.upperBound
            } else if text[i...].hasPrefix("//") {
                i = text[i...].firstIndex(of: "\n") ?? text.endIndex
            } else {
                out.append(text[i]); i = text.index(after: i)
            }
        }
        return out
    }

    /// The body of `static OSStatus render_callback(` up to the closing brace
    /// at the start of a line.
    private static func renderCallbackBody() throws -> String {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Drivers/VolumeProxy/MaestroVolumeProxy.c")
        let text = try String(contentsOf: source, encoding: .utf8)
        let start = try #require(text.range(of: "static OSStatus render_callback("))
        let end = try #require(text.range(of: "\n}\n", range: start.upperBound..<text.endIndex))
        return stripComments(String(text[start.lowerBound..<end.upperBound]))
    }

    @Test("the render callback logs nothing, allocates nothing, takes no lock and dispatches nothing")
    func renderCallbackIsRealTimeSafe() throws {
        let body = try Self.renderCallbackBody()
        #expect(body.count > 2000, "found the callback")
        for call in Self.forbidden {
            #expect(!body.contains(call), "render_callback calls \(call)")
        }
    }

    @Test("the checker sees a log call when there is one")
    func checkerFindsLog() {
        let sample = "static OSStatus render_callback() {\n /* LOG(x) in a comment */\n LOG(\"render\");\n}\n"
        #expect(Self.stripComments(sample).contains("LOG("))
        #expect(!Self.stripComments("/* LOG(x) */ // LOG(y)\n").contains("LOG("))
    }
}
