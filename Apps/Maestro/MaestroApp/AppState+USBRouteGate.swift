import Foundation
import MaestroCore
import MaestroDevice

// USB: the one gate for every audible destination of the unit's routing table
// (`0x31`): the I/O board outputs (32-63) and the two headphone crosspoints
// (224-227). A destination plays a mixer only when the restore wrote that
// mixer in full on this connection (`usbMixerIsWritten`); until then it is
// direct or disabled, the real route is owed, and the restore sends it.
//
// The headphone crosspoints were written past this gate until 0.9.21. A
// headphone following Line 1/2 had been pointed at Mixer 1 by an earlier
// version (Mixer 1 was then the default for Line 1/2), the unit keeps its
// routing until it is power-cycled, and the restore then wrote every strip of
// that mixer at 0 dB, unmuted: live inputs in the headphones.
extension AppState {
    /// One route of the unit's table over USB. A mixer source is written
    /// only when that mixer is written; otherwise the destination is disabled
    /// (the "no source" byte), the route is owed and `.deferred` is returned.
    @MainActor
    @discardableResult
    func writeUSBRoute(destination: UInt8, source: UInt8, device: any DeviceConnection,
                       restoring: Bool = false) async throws -> CardWriteResult {
        let address = PropertyAddress(selector: .routing, scope: .output, element: UInt32(destination))
        if let mixer = CardOutputTableOrder.mixer(ofSource: source),
           device is XPCDeviceConnection, !usbMixerIsWritten(mixer) {
            try await device.setProperty(address, value: .uint32(UInt32(SymphonyIORoutingAddress.none)))
            usbRestoreOwed = true
            if !restoring {
                outputRouteDeferredSinceSave = true
                usbRestoreRetryAfter = .distantPast
            }
            updateRestoreStatus()
            return .deferred
        }
        try await device.setProperty(address, value: .uint32(UInt32(source)))
        return .written
    }

    /// Whether the Mixer page may send a mixer's strips to the unit: always
    /// on ThunderBridge and PCIe (and in simulation); over USB never for a
    /// recall (the page opening, Mix 1/2, a card layout change), and for a
    /// reset only once the connection's restore has written that mixer.
    @MainActor
    func mixerPageMayWriteStrips(mixer: Int, recalling: Bool) -> Bool {
        guard device is XPCDeviceConnection else { return true }
        return !recalling && usbMixerIsWritten(mixer)
    }

    /// The first step of the USB restore, before any mixer strip is written:
    /// no audible destination may be left on a mixer that is about to be
    /// written. In order:
    ///
    /// 1. both headphone crosspoints: the saved source's direct route as it
    ///    is, disabled when the pair it follows is fed by a mixer; a
    ///    headphone nobody chose a source for on USB 1-2, the firmware's
    ///    default (and what the helper writes when it configures the unit);
    /// 2. every saved output route: direct as saved, disabled when fed by a
    ///    mixer;
    /// 3. once after the routing and mixer reset (the saved copy is gone, so
    ///    what the unit holds is unknown): every other output on the helper's
    ///    direct default.
    ///
    /// A mixer in `kept` is already written on this connection and stays in
    /// step: its routes are left alone, so a retry does not silence it.
    /// Returns whether every write landed; when one did not, the caller
    /// writes no mixer.
    @MainActor
    func usbPointRoutesAwayFromMixers(_ device: XPCDeviceConnection, keeping kept: Set<Int>) async -> Bool {
        // An older helper puts Line 1/2 back on Mixer 1 at every configure,
        // so under it every output is written, every time.
        let unknown = RoutingMixerReset.isPending(.usbOutputRouting) || usbHelperOutdated
        let saved = cachedOutputRouteMap()
        var writes: [(destination: UInt8, source: UInt8)] = []
        func add(_ destination: UInt8, _ source: UInt8) {
            if let mixer = CardOutputTableOrder.mixer(ofSource: source) {
                if !kept.contains(mixer) { writes.append((destination, SymphonyIORoutingAddress.none)) }
            } else {
                writes.append((destination, source))
            }
        }
        for headphone in SymphonyIOHeadphoneRouting.Headphone.allCases {
            let destinations = headphone.destinations
            if let sources = usbHeadphoneSources(headphone, cachedRoutes: saved) {
                add(destinations.left, sources.left)
                add(destinations.right, sources.right)
            } else {
                add(destinations.left, SymphonyIORoutingAddress.p2pBase)
                add(destinations.right, SymphonyIORoutingAddress.p2pBase &+ 1)
            }
        }
        let outputs = SymphonyIORoutingAddress.ioBoard0Base..<(SymphonyIORoutingAddress.ioBoard1Base
            &+ UInt8(SymphonyIORoutingAddress.channelsPerIOBoard))
        for destination in outputs {
            if let source = saved[destination] {
                add(destination, source)
            } else if unknown, let direct = SymphonyIOHeadphoneRouting.bootTableSource(
                forDestination: destination, transport: .usb) {
                add(destination, direct)
            }
        }
        var failed = 0
        for write in writes {
            guard self.device === device, !hardwareWritesSuspended else { return false }
            do {
                try await device.setProperty(
                    PropertyAddress(selector: .routing, scope: .output, element: UInt32(write.destination)),
                    value: .uint32(UInt32(write.source)))
            } catch {
                failed += 1
                print("[Maestro] USB restore: destination \(write.destination) ← source \(write.source) failed: \(error)")
            }
        }
        print("[Maestro] USB restore: \(writes.count - failed) of \(writes.count) routes on the unit before the mixers (sent or already there; see the sent/held line); no output or headphone is on a mixer that is not set")
        if unknown, failed == 0 { RoutingMixerReset.clearPending(.usbOutputRouting) }
        return failed == 0
    }

    /// The crosspoint sources of a headphone whose Output Source is saved:
    /// what Output Routing feeds the pair it follows. Nil when no source is
    /// saved or none can be determined (nothing is then written).
    @MainActor
    func usbHeadphoneSources(_ headphone: SymphonyIOHeadphoneRouting.Headphone,
                             cachedRoutes: [UInt8: UInt8]) -> (left: UInt8, right: UInt8)? {
        guard let usb = device as? XPCDeviceConnection else { return nil }
        let selector: AudioPropertySelector = headphone == .headphone1 ? .headphone1RoutingID : .headphone2RoutingID
        guard let id = usb.settingsStore.value(for: PropertyAddress(selector: selector))?.asUInt32,
              let pair = SymphonyIOHeadphoneRouting.outputPairDestinations(sourceID: id),
              let left = SymphonyIOHeadphoneRouting.inheritedSource(
                forDestination: pair.left, cachedRoutes: cachedRoutes, transport: .usb),
              let right = SymphonyIOHeadphoneRouting.inheritedSource(
                forDestination: pair.right, cachedRoutes: cachedRoutes, transport: .usb) else { return nil }
        return (left, right)
    }

    /// The last step of the USB restore: both headphones' saved sources,
    /// through the gate. Returns whether nothing failed or is still owed.
    @MainActor
    func syncUSBHeadphoneCrosspoints(_ device: XPCDeviceConnection) async -> Bool {
        var done = true
        for (headphone, selector) in [(SymphonyIOHeadphoneRouting.Headphone.headphone1, AudioPropertySelector.headphone1RoutingID),
                                      (.headphone2, .headphone2RoutingID)] {
            guard self.device === device, !hardwareWritesSuspended else { return false }
            guard let id = device.settingsStore.value(for: PropertyAddress(selector: selector))?.asUInt32,
                  SymphonyIOHeadphoneRouting.isValidSourceID(id) else { continue }
            // No source for the pair it follows: nothing is written (as a
            // user's own choice would do), and nothing is owed.
            guard usbHeadphoneSources(headphone, cachedRoutes: cachedOutputRouteMap()) != nil else { continue }
            if await !HeadphoneCrosspoint.apply(headphone, sourceID: id, device: device,
                                                cachedRoutes: cachedOutputRouteMap(), transport: .usb,
                                                state: self, restoring: true) {
                done = false
            }
        }
        return done
    }
}
