import Foundation
import Testing
@testable import MaestroCore

struct SymphonyCardInputRoutingTests {
    @Test func servingDriverCapability() {
        let model = SymphonyRoutingModel(topology: .symphonyOnly, hostChannels: 32, unitBConfigured: false)
        for build: ServingDextBuild? in [nil, .olderThanBuildReporting, .build(0), .build(131), .build(132), .build(133)] {
            let routing = SymphonyCardInputRouting(model: model, servingBuild: build)
            let supported = build == .build(132) || build == .build(133)
            #expect(routing.channelCount == (supported ? 32 : 0))
            #expect((routing.resetCommand != nil) == supported)
            #expect((routing.command(host: 0, source: 1) != nil) == supported)
        }
        let converter = SymphonyRoutingModel(topology: .converterOnly(.init(port1: [.ad16x])),
                                            hostChannels: 32, unitBConfigured: false)
        let routing = SymphonyCardInputRouting(model: converter, servingBuild: .build(132))
        #expect(routing.channelCount == 0)
        #expect(routing.resetCommand == nil)
    }

    @Test func bytesAndRefusals() throws {
        for channels in [0, 32, 64] {
            for configured in [false, true] {
                let routing = SymphonyCardInputRouting(model: .init(topology: .symphonyOnly,
                    hostChannels: channels, unitBConfigured: configured))
                let count = channels == 0 ? 0 : (channels == 64 && configured ? 64 : 32)
                #expect(routing.channelCount == count)
                #expect(routing.command(host: -1, source: 0) == nil)
                #expect(routing.command(host: count, source: 0) == nil)
                #expect(routing.command(host: 0, source: count) == nil)
                #expect(routing.command(host: 0, source: -1) == nil)
                if count > 0 {
                    #expect(routing.command(host: 0, source: nil)?.payload == [0, 0, 0])
                    #expect(routing.command(host: count - 1, source: 0)?.payload == [UInt8(count - 1), 0, 1])
                    #expect(routing.resetCommand == .init(command: 0xB7, payload: []))
                }
            }
        }
        let both = SymphonyCardInputRouting(model: .init(topology: .symphonyOnly, hostChannels: 64, unitBConfigured: true))
        #expect(both.command(host: 0, source: 32) == .init(command: 0xB6, payload: [0, 32, 1]))
        #expect(both.command(host: 32, source: 0) == .init(command: 0xB6, payload: [32, 0, 1]))
        #expect(both.commands(edits: [0: 32, 1: 32, 2: -1]).map(\.payload) == [[0, 32, 1], [1, 32, 1], [2, 0, 0]])
        for topology: SymphonyRoutingModel.Topology in [.unknown, .converterOnly(.init(port1: [.ad16x])), .symphonyAndConverters([.ad16x])] {
            let routing = SymphonyCardInputRouting(model: .init(topology: topology, hostChannels: 64, unitBConfigured: true))
            #expect(routing.channelCount == 0)
            #expect(routing.command(host: 0, source: 0) == nil)
            #expect(routing.resetCommand == nil)
        }
    }

    @Test func refusedWritesAndResetPreserveSavedState() {
        let previous = [0: 4, 1: 5, 32: -1]
        #expect(SymphonyCardInputRouting.applying([], to: previous) == previous)
        let partial = SymphonyCardInputRouting.applying([.init(command: 0xB6, payload: [0, 32, 1])], to: previous)
        #expect(partial == [0: 32, 1: 5, 32: -1])
        #expect(SymphonyCardInputRouting.applying([.init(command: 0xB7, payload: [])], to: partial).isEmpty)
    }

    @Test func persistenceReplayAndReset() throws {
        let suite = UUID().uuidString
        let defaults = try #require(ScratchUserDefaults(suiteName: suite))
        defer { defaults.cleanup() }
        let store = SymphonyCardInputStore(scope: "cards.64", defaults: defaults)
        let other = SymphonyCardInputStore(scope: "cards.32", defaults: defaults)
        store.save([0: 32, 32: 0, 4: -1])
        #expect(other.load().isEmpty)
        let routing = SymphonyCardInputRouting(model: .init(topology: .symphonyOnly, hostChannels: 64, unitBConfigured: true))
        #expect(routing.commands(edits: store.load()).map(\.payload) == [[0, 32, 1], [4, 0, 0], [32, 0, 1]])
        #expect(routing.source(host: 4, edits: store.load()) == nil)
        #expect(routing.source(host: 2, edits: store.load()) == 2)
        store.save([:])
        #expect(store.load().isEmpty)
        #expect(defaults.data(forKey: store.key) == nil)
    }
}
