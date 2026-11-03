import Testing
import Foundation
@testable import MaestroDevice
import MaestroCore

/// Card-simulation harness: drive the app with option-board configurations we do
/// not physically own, so the UI (mic pre above all) can be screenshotted and
/// compared against the original Maestro.
///
/// The harness is debug-only: it activates solely from a launch argument or the
/// matching `UserDefaults` key, neither of which any UI writes.
@Suite("Simulated cards")
struct SimulatedCardsTests {

    // MARK: - Presenting a configuration

    @Test func simulatedDeviceReportsTheBoardTypesReadCardTypesReads() async throws {
        let device = try SimulatedDevice.symphonyIO(configuration: .devUnit)
        let b1 = try await device.getProperty(PropertyAddress(selector: .primaryBoardType)).asUInt32
        let b2 = try await device.getProperty(PropertyAddress(selector: .secondaryBoardType)).asUInt32
        #expect(b1 == UInt32(IOCardType.optical.rawValue))
        #expect(b2 == UInt32(IOCardType.analogAD16.rawValue))
    }

    @Test func boardTypesAreReadOnly() async throws {
        let device = try SimulatedDevice.symphonyIO(configuration: .devUnit)
        let addr = PropertyAddress(selector: .primaryBoardType)
        #expect(await device.isPropertySettable(addr) == false)
    }

    /// Every legal configuration presents coherently: the published board types
    /// round-trip, and the channel arithmetic matches the card model.
    @Test func everyLegalConfigurationPresentsCoherently() async throws {
        for c1 in IOCardType.allCases {
            for c2 in IOCardType.allCases {
                let config = CardConfiguration(slot1: c1, slot2: c2)
                guard config.isValid else { continue }
                let device = try SimulatedDevice.symphonyIO(configuration: config)
                #expect(device.cardConfiguration == config)

                let raw1 = try await device.getProperty(PropertyAddress(selector: .primaryBoardType)).asUInt32
                let raw2 = try await device.getProperty(PropertyAddress(selector: .secondaryBoardType)).asUInt32
                #expect(raw1 == UInt32(c1.rawValue), "\(c1)/\(c2) slot 1")
                #expect(raw2 == UInt32(c2.rawValue), "\(c1)/\(c2) slot 2")

                #expect(device.cardConfiguration.totalInputChannels
                        == c1.totalInputChannels + c2.totalInputChannels)
                #expect(device.cardConfiguration.totalOutputChannels
                        == c1.totalOutputChannels + c2.totalOutputChannels)
            }
        }
    }

    @Test func illegalConfigurationsRefuseToBuild() {
        #expect(throws: CardConfiguration.ValidationError.micPreInSlot1) {
            _ = try SimulatedDevice.symphonyIO(
                configuration: CardConfiguration(slot1: .micPre8, slot2: .optical))
        }
        #expect(throws: CardConfiguration.ValidationError.micPreHostHasNoAnalogInputs(host: .analogDA16)) {
            _ = try SimulatedDevice.symphonyIO(
                configuration: CardConfiguration(slot1: .analogDA16, slot2: .micPre8))
        }
    }

    // MARK: - Channel counts / USB mode

    /// A unit whose cards total more than 16 channels either way enumerates wide.
    @Test func widthFollowsTheCards() throws {
        let wide = try SimulatedDevice.symphonyIO(configuration: .devUnit)   // 32 in / 32 out
        #expect(wide.identifier.mode.channelCount == 32)

        // 16x16 + MicPre is a 16-channel unit — the MicPre adds nothing.
        let narrow = try SimulatedDevice.symphonyIO(configuration: .sixteenBySixteenPlusMicPre)
        #expect(narrow.cardConfiguration.totalInputChannels == 16)
        #expect(narrow.identifier.mode.channelCount == 16)
    }

    // MARK: - Mic pre controls appear only where a preamp exists

    /// The MicPre delegate covers channels 1-8 of the host board's analog inputs
    /// and nothing else. Mic gain / phantom must exist on exactly those.
    @Test func micPreControlsScopedToPreampedChannels() async throws {
        let device = try SimulatedDevice.symphonyIO(configuration: .sixteenBySixteenPlusMicPre)
        for ch in UInt32(0)..<8 {
            #expect(await device.hasProperty(PropertyAddress(selector: .micGain, scope: .input, element: ch)),
                    "channel \(ch) should have mic gain")
            #expect(await device.hasProperty(PropertyAddress(selector: .phantom, scope: .input, element: ch)))
        }
        for ch in UInt32(8)..<16 {
            #expect(await device.hasProperty(PropertyAddress(selector: .micGain, scope: .input, element: ch)) == false,
                    "channel \(ch) has no preamp and must not expose mic gain")
        }
    }

    /// No MicPre installed → no mic-pre controls anywhere.
    @Test func noMicPreMeansNoMicControls() async throws {
        let device = try SimulatedDevice.symphonyIO(configuration: .devUnit)
        for ch in UInt32(0)..<32 {
            #expect(await device.hasProperty(PropertyAddress(selector: .micGain, scope: .input, element: ch)) == false)
            #expect(await device.hasProperty(PropertyAddress(selector: .phantom, scope: .input, element: ch)) == false)
        }
    }

    // MARK: - Labels

    /// Numbering is continuous across the whole device, not per-card, and a
    /// preamped channel is named from its current analog level.
    /// Evidence: `SymphonyIOBoard_MicPre8ch.cpp:914-961`, `SymphonyIO_Stream.cpp:653-655`.
    @Test func micPreLabelsLeadThenLineLabelsContinue() throws {
        let device = try SimulatedDevice.symphonyIO(configuration: .sixteenBySixteenPlusMicPre)
        let labels = device.simulatedInputLabels()
        #expect(labels.count == 16)
        #expect(labels.prefix(8) == ["Mic 1", "Mic 2", "Mic 3", "Mic 4",
                                     "Mic 5", "Mic 6", "Mic 7", "Mic 8"])
        #expect(labels[8] == "Line 9")
        #expect(labels.last == "Line 16")
    }

    /// Instrument is only real on channels 1-4, and the label follows the level.
    @Test func instrumentLabelsOnTheFirstFour() throws {
        let device = try SimulatedDevice.symphonyIO(configuration: .sixteenBySixteenPlusMicPre)
        let labels = device.simulatedInputLabels(micChannelsUseInstrument: [0, 1, 2, 3])
        #expect(labels.prefix(4) == ["Inst 1", "Inst 2", "Inst 3", "Inst 4"])
        #expect(labels[4] == "Mic 5")
    }

    @Test func devUnitLabelsMixLineAndDigital() throws {
        let device = try SimulatedDevice.symphonyIO(configuration: .devUnit)
        let labels = device.simulatedInputLabels()
        // 8x8 OPT (8 analog) + AD16 (16 analog) = 24 analog, then 8 ADAT.
        #expect(labels.count == 32)
        #expect(labels[0] == "Line 1")
        #expect(labels[23] == "Line 24")
        #expect(labels[24] == "ADAT 25")
        #expect(labels[31] == "ADAT 32")
    }

    // MARK: - Meter geometry

    /// The meter payload is always 32 words; only the populated slots carry data.
    /// Slots 0-15 are card slot 1, 16-31 card slot 2 — rigid and card-independent.
    @Test func meterSlotsFollowTheRigidBoardMap() throws {
        let device = try SimulatedDevice.symphonyIO(configuration: .devUnit)
        #expect(device.simulatedMeterWordCount == 32)
        let inputs = device.simulatedActiveMeterSlots(isInput: true)
        // Board 1 (8x8 OPT): 8 analog + 8 ADAT = 16 slots, 0..15
        // Board 2 (AD16): 16 analog inputs = 16 slots, 16..31
        #expect(inputs == Array(0..<32))
    }

    /// A 16x16 + MicPre unit: 16 input slots on board 1, and board 2 carries
    /// NOTHING — the MicPre has no channels of its own.
    @Test func micPreOccupiesNoMeterSlots() throws {
        let device = try SimulatedDevice.symphonyIO(configuration: .sixteenBySixteenPlusMicPre)
        let inputs = device.simulatedActiveMeterSlots(isInput: true)
        #expect(inputs == Array(0..<16))
        let outputs = device.simulatedActiveMeterSlots(isInput: false)
        #expect(outputs == Array(0..<16))
    }

    /// AD16 in slot 1 fills all 16 slots in both directions (16 analog in,
    /// 16 digital out), while an empty chassis fills none.
    @Test func meterSlotsTrackPopulatedChannelsOnly() throws {
        let device = try SimulatedDevice.symphonyIO(
            configuration: CardConfiguration(slot1: .analogAD16, slot2: .none))
        #expect(device.simulatedActiveMeterSlots(isInput: true) == Array(0..<16))
        #expect(device.simulatedActiveMeterSlots(isInput: false) == Array(0..<16))
        // (AD16 outputs 16 digital channels, so its 16 output slots are populated too.)
        let empty = try SimulatedDevice.symphonyIO(
            configuration: CardConfiguration(slot1: .none, slot2: .none))
        #expect(empty.simulatedActiveMeterSlots(isInput: true).isEmpty)
    }

    // MARK: - Activation is opt-in and inert by default

    private func scratchDefaults(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name)!
    }

    @Test func inertWhenNoKeysArePresent() throws {
        let d = scratchDefaults("maestro.tests.cards.inert")
        #expect(SimulatedDevice.isSimulatingCards(defaults: d) == false)
        #expect(try SimulatedDevice.simulationRequest(defaults: d) == nil)
    }

    @Test func activatesFromDefaultsKeys() throws {
        let d = scratchDefaults("maestro.tests.cards.active")
        d.set("analogADDA16", forKey: CardSimulation.primaryKey)
        d.set("micPre8", forKey: CardSimulation.secondaryKey)
        #expect(SimulatedDevice.isSimulatingCards(defaults: d))
        #expect(try SimulatedDevice.simulationRequest(defaults: d)
                == CardConfiguration.sixteenBySixteenPlusMicPre)
        d.removePersistentDomain(forName: "maestro.tests.cards.active")
    }

    @Test func activationRejectsAnImpossibleRequest() {
        let d = scratchDefaults("maestro.tests.cards.bad")
        d.set("micPre8", forKey: CardSimulation.primaryKey)
        #expect(throws: CardConfiguration.ValidationError.micPreInSlot1) {
            _ = try SimulatedDevice.simulationRequest(defaults: d)
        }
        d.removePersistentDomain(forName: "maestro.tests.cards.bad")
    }

    /// The keys are namespaced and not written by anything in the normal app.
    @Test func keyNamesAreDebugNamespaced() {
        #expect(CardSimulation.primaryKey == "MaestroSimulatePrimaryBoard")
        #expect(CardSimulation.secondaryKey == "MaestroSimulateSecondaryBoard")
    }
}
