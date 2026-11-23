import Foundation
import MaestroCore
import SystemExtensions

enum MaestroLaunchMode {
    case app
    case deactivateDriver

    init(arguments: [String]) {
        self = arguments == ["--deactivate-driver"] ? .deactivateDriver : .app
    }
}

@main
enum MaestroEntryPoint {
    @MainActor
    static func main() {
        switch MaestroLaunchMode(arguments: Array(CommandLine.arguments.dropFirst())) {
        case .deactivateDriver:
            DriverDeactivation.run()
        case .app:
            MaestroApp.main()
        }
    }
}

// The delegate holds no mutable state. Its callbacks are delivered on .main.
private final class DriverDeactivation: NSObject, OSSystemExtensionRequestDelegate, @unchecked Sendable {
    static func run() -> Never {
        // Protect direct invocations as well as the uninstall script.
        guard OriginalApogeeDrivers.loadedKextIDs().isDisjoint(with: OriginalApogeeDrivers.pciKernelExtensionBundleIDs) else {
            fail("Apogee's original Symphony driver is loaded. Shut down your Mac, disconnect the ThunderBridge or PCIe chassis, then start up and run the uninstaller again.")
        }

        let delegate = DriverDeactivation()
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: SystemExtensionInstaller.dextBundleID,
            queue: .main
        )
        request.delegate = delegate
        // The request holds its delegate weakly. Keep it alive while the main
        // queue delivers the result, including while macOS asks for approval.
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(120)) { [delegate] in
            withExtendedLifetime(delegate) {
                fail("Timed out waiting for macOS to remove the ThunderBridge driver.")
            }
        }
        OSSystemExtensionManager.shared.submitRequest(request)
        dispatchMain()
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Self.writeMessage("Confirm ThunderBridge driver removal when macOS asks.")
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            print("ThunderBridge driver removed.")
        case .willCompleteAfterReboot:
            print("Restart your Mac to finish removing the ThunderBridge driver.")
        @unknown default:
            Self.fail("macOS returned an unknown result while removing the ThunderBridge driver.")
        }
        exit(EXIT_SUCCESS)
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Self.fail("macOS could not remove the ThunderBridge driver. \(error.localizedDescription)")
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension replacement: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .cancel
    }

    private static func writeMessage(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func fail(_ message: String) -> Never {
        writeMessage(message)
        exit(EXIT_FAILURE)
    }
}
