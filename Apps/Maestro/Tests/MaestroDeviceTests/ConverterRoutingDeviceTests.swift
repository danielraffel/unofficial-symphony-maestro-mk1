import Foundation
import Testing
import MaestroCore
@testable import MaestroDevice

@Suite("Converter routing on the device side")
struct ConverterRoutingDeviceTests {
    @Test("link watch to the port status message: down = no hardware, recovering = bus error")
    func linkStateSelectsTheMessage() {
        #expect(LinkState.State.down.portStatusLink == .noHardware)
        #expect(LinkState.State.recovering.portStatusLink == .busError)
        #expect(LinkState.State.up.portStatusLink == .other)
        #expect(LinkState.State.unknown.portStatusLink == .other)
    }

    @Test("0xB5 converter bytes equal the Symphony card route's for the same entry")
    func outputBytesMatchTheCardRoute() {
        // Same command, same layout [entry, slot, enable] as the Symphony I/O path.
        #expect(ConverterRouting.outputRouteCommand == ThunderboltCardRouting.outputRouteCommand)
        let card = ThunderboltCardRouting.Route(channel: 3, slot: 130, enabled: true).payload
        #expect(Data(ConverterRouting.outputCommand(bus: 3, source: 130).payload) == card)
        // Mixer sources are the ones the Symphony grid's Mixer rows reach.
        #expect(ThunderboltCardRouting.slot(forSource: SymphonyIORoutingAddress.mixer1Base)
                == UInt8(ConverterRouting.mixerSource(mixer: 1, side: 0)))
        #expect(ThunderboltCardRouting.pciOutBase == UInt8(ConverterRouting.pciOutBase))
    }
}
