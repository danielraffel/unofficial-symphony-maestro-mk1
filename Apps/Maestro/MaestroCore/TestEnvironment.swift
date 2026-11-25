import Foundation

/// True inside the app's own test runs. Code that would otherwise find and
/// drive the Mac's real audio devices (the Symphony, its volume control)
/// checks it, so a test can never change a real device: on 2026-11-22 a test
/// run set the real ThunderBridge device's volume.
public enum TestEnvironment {
    public static let isRunningTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil { return true }
        let process = ProcessInfo.processInfo.processName.lowercased()
        if process.contains("xctest") || process.contains("swiftpm-testing-helper") { return true }
        return NSClassFromString("XCTestCase") != nil || NSClassFromString("Testing.Test") != nil
    }()
}
