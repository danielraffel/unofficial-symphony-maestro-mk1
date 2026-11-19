import Foundation
import MaestroCore

/// Replays the Mac-owned analog channel settings after a device connects.
/// The order mirrors Apogee's per-channel connect sequence.
public enum AnalogChannelSettingsReplay {
    public struct Result: Sendable, Equatable {
        public var applied: Int = 0
        public var failed: Int = 0
        /// Writes left out because the unit already had the value.
        public var skipped: Int = 0
        public init(applied: Int = 0, failed: Int = 0, skipped: Int = 0) {
            self.applied = applied
            self.failed = failed
            self.skipped = skipped
        }
    }

    /// Whether the replay runs for this connection. Over USB it follows
    /// `MAESTRO_USB_REPLAY_SETTINGS` (`XPCDeviceConnection.replaysOnConnect`),
    /// as the rest of the connect replay does.
    public static func runs(overUSB: Bool, usbReplayEnabled: Bool) -> Bool {
        !overUSB || usbReplayEnabled
    }

    /// Whether a layout's channels may be written from saved state: a
    /// Symphony I/O whose cards are known. An unknown layout may name
    /// channels the unit does not have, and its saved state is not scoped to
    /// these cards. Converters on port 1 have none of these settings; a
    /// Symphony I/O on port 1 with converters on port 2 still gets its own.
    public static func replays(layout: CardLayout) -> Bool {
        layout.isKnown && layout.converter == nil && layout.converterLayout == nil
    }

    /// Per channel, in the original's order: analog type with trim, Digital
    /// Ref, Soft Limit (inputs); analog type with trim, Digital Ref (outputs).
    ///
    /// Where the unit can be read (an input's analog type, 0x60, and the
    /// Digital Ref) it is read first and only a value that differs is
    /// written, so a connect is not slowed by writes that change nothing; a
    /// read that fails (ThunderBridge has none) still writes. The trim rides
    /// in the analog type write and cannot be read, so a type write with a
    /// trim other than 0 (the unit's start value) is always sent. The
    /// firmware answers 0x60 for inputs only (`SymphonyIOStateData.cpp`,
    /// the AnalogIOType get), so an output's type is always written.
    ///
    /// Mic and Instrument channels (a Mic Pre's) are not replayed: the type
    /// alone (trim "do not set") without gain, phantom, filter, phase, group
    /// and insert would not restore them. The Input page sends that whole set
    /// when the level is changed there.
    public static func apply(
        inputs: [InputChannelState],
        outputs: [OutputChannelState],
        layout: CardLayout,
        device: any DeviceConnection,
        spacing: Duration? = nil
    ) async -> Result {
        guard replays(layout: layout) else { return Result() }
        var result = Result()
        var wrote = false

        func write(_ address: PropertyAddress, _ value: PropertyValue) async {
            if wrote, let spacing { try? await Task.sleep(for: spacing) }
            wrote = true
            do {
                try await device.setProperty(address, value: value)
                result.applied += 1
            } catch {
                result.failed += 1
            }
        }

        func unitHas(_ address: PropertyAddress, _ value: UInt32) async -> Bool {
            guard let current = (try? await device.getProperty(address))?.asUInt32 else { return false }
            return current == value
        }

        /// Write the packed type and trim unless the unit has that type and
        /// the trim is 0. Inputs only can be read.
        func writeType(_ address: PropertyAddress, type: UInt32, packed: UInt32) async {
            if address.scope == .input, (packed >> 8) & 0xFF == 0, await unitHas(address, type) {
                result.skipped += 1
                return
            }
            await write(address, .uint32(packed))
        }

        func writeIfDifferent(_ address: PropertyAddress, _ value: UInt32) async {
            if await unitHas(address, value) {
                result.skipped += 1
                return
            }
            await write(address, .uint32(value))
        }

        let inputCount = min(layout.analogInputStripCount, inputs.count)
        for index in 0..<inputCount {
            let state = inputs[index]
            let element = UInt32(index)
            let level = AnalogInputLevel(rawValue: state.inputType) ?? .plus4dBu
            if !level.isPreampLevel {
                await writeType(PropertyAddress(selector: .analogIOType, scope: .input, element: element),
                                type: level.rawValue,
                                packed: InputChannelLogic.analogIOTypeWithTrim(level: level, trim: state.trim))
            }
            await writeIfDifferent(PropertyAddress(selector: .digitalRefLevel, scope: .input, element: element),
                                   state.digitalRefLevel)
            let softLimit = InputChannelLogic.coerceSoftLimit(
                state.softLimit, card: layout.cardForAnalogInputStrip(index))
            await write(PropertyAddress(selector: .softLimit, scope: .input, element: element),
                        .uint32(softLimit))
        }

        let outputCount = min(layout.analogOutputStripCount, outputs.count)
        for index in 0..<outputCount {
            let state = outputs[index]
            let element = UInt32(index)
            let trim = Int8(clamping: Int((state.trim * 10).rounded()))
            let packed = (UInt32(UInt8(bitPattern: trim)) << 8) | state.analogRefLevel
            await writeType(PropertyAddress(selector: .analogIOType, scope: .output, element: element),
                            type: state.analogRefLevel, packed: packed)
            await writeIfDifferent(PropertyAddress(selector: .digitalRefLevel, scope: .output, element: element),
                                   state.digitalRefLevel)
        }
        return result
    }
}
