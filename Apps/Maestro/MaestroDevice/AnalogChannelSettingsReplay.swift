import Foundation
import MaestroCore

/// Replays the Mac-owned analog channel settings after a device connects.
/// The order mirrors Apogee's per-channel connect sequence.
public enum AnalogChannelSettingsReplay {
    public struct Result: Sendable, Equatable {
        public var applied: Int = 0
        public var failed: Int = 0
        public init(applied: Int = 0, failed: Int = 0) {
            self.applied = applied
            self.failed = failed
        }
    }

    public static func apply(
        inputs: [InputChannelState],
        outputs: [OutputChannelState],
        layout: CardLayout,
        device: any DeviceConnection,
        spacing: Duration? = nil
    ) async -> Result {
        // Converter systems do not expose Symphony analog channel settings.
        guard layout.converter == nil, layout.converters == nil else { return Result() }
        var result = Result()
        var first = true

        func write(_ address: PropertyAddress, _ value: PropertyValue) async {
            if !first, let spacing { try? await Task.sleep(for: spacing) }
            first = false
            do {
                try await device.setProperty(address, value: value)
                result.applied += 1
            } catch {
                result.failed += 1
            }
        }

        let inputCount = min(layout.analogInputStripCount, inputs.count)
        for index in 0..<inputCount {
            let state = inputs[index]
            let level = AnalogInputLevel(rawValue: state.inputType) ?? .plus4dBu
            await write(PropertyAddress(selector: .analogIOType, scope: .input, element: UInt32(index)),
                        .uint32(InputChannelLogic.analogIOTypeWithTrim(level: level, trim: state.trim)))
            await write(PropertyAddress(selector: .digitalRefLevel, scope: .input, element: UInt32(index)),
                        .uint32(state.digitalRefLevel))
            await write(PropertyAddress(selector: .softLimit, scope: .input, element: UInt32(index)),
                        .uint32(state.softLimit))
        }

        let outputCount = min(layout.analogOutputStripCount, outputs.count)
        for index in 0..<outputCount {
            let state = outputs[index]
            let trim = Int8(clamping: Int((state.trim * 10).rounded()))
            let packed = (UInt32(UInt8(bitPattern: trim)) << 8) | state.analogRefLevel
            await write(PropertyAddress(selector: .analogIOType, scope: .output, element: UInt32(index)),
                        .uint32(packed))
            await write(PropertyAddress(selector: .digitalRefLevel, scope: .output, element: UInt32(index)),
                        .uint32(state.digitalRefLevel))
        }
        return result
    }
}
