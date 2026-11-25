import Foundation
import MaestroCore
import MaestroDevice

enum DisplayMeterBank: Hashable {
    case input, output, digitalInput, digitalOutput, mixer
    case unitBInput, unitBOutput, unitBDigitalInput, unitBDigitalOutput
}

extension AppState {
    private func meterDisplaySettings(for device: (any DeviceConnection)?) -> MeterDisplaySettings {
        let peak: UInt32
        let over: UInt32
        if let connection = device as? XPCDeviceConnection {
            (peak, over) = connection.cachedMeterHoldModes()
        } else {
            let store = (device as? ThunderboltDeviceConnection)?.settingsStore
                ?? (device as? ThunderboltUnitBConnection)?.settingsStore
            peak = store?.value(for: PropertyAddress(selector: .peakHoldMode))?.asUInt32 ?? 0
            over = store?.value(for: PropertyAddress(selector: .oversHoldMode))?.asUInt32 ?? 0
        }
        return MeterDisplaySettings(peakWireValue: peak, overWireValue: over)
    }

    func updateMeterHolds(over: [DisplayMeterBank: Set<Int>]) {
        let now = ProcessInfo.processInfo.systemUptime
        let settingsA = meterDisplaySettings(for: device)
        let settingsB = meterDisplaySettings(for: unitBDevice)

        func advance(_ bank: DisplayMeterBank, _ levels: [Double], _ settings: MeterDisplaySettings) -> [Double] {
            var holds = meterHolds.removeValue(forKey: bank) ?? []
            if holds.count != levels.count { holds = Array(repeating: MeterHold(), count: levels.count) }
            let clipped = over[bank] ?? []
            var lit: Set<Int> = []
            for index in levels.indices {
                holds[index].update(level: levels[index], over: clipped.contains(index),
                                    at: now, settings: settings)
                if holds[index].isOver { lit.insert(index) }
            }
            meterHolds[bank] = holds
            if meterOvers[bank] != lit { meterOvers[bank] = lit }
            return holds.map(\.peak)
        }

        inputPeakHold = advance(.input, inputMeterLevels, settingsA)
        outputPeakHold = advance(.output, outputMeterLevels, settingsA)
        digitalInputPeakHold = advance(.digitalInput, digitalInputMeterLevels, settingsA)
        digitalOutputPeakHold = advance(.digitalOutput, digitalOutputMeterLevels, settingsA)
        mixerPeakHold = advance(.mixer, mixerMeterLevels, settingsA)
        if unitBOnCard {
            unitBInputPeakHold = advance(.unitBInput, unitBInputMeterLevels, settingsB)
            unitBOutputPeakHold = advance(.unitBOutput, unitBOutputMeterLevels, settingsB)
            unitBDigitalInputPeakHold = advance(.unitBDigitalInput, unitBDigitalInputMeterLevels, settingsB)
            unitBDigitalOutputPeakHold = advance(.unitBDigitalOutput, unitBDigitalOutputMeterLevels, settingsB)
        } else {
            for bank: DisplayMeterBank in [.unitBInput, .unitBOutput, .unitBDigitalInput, .unitBDigitalOutput] {
                meterHolds.removeValue(forKey: bank)
                if meterOvers[bank] != nil { meterOvers.removeValue(forKey: bank) }
            }
        }
    }

    func clearDisplayedMeterHolds() {
        meterHolds.removeAll()
        meterOvers.removeAll()
        for keyPath in [\.inputPeakHold, \.outputPeakHold, \.digitalInputPeakHold,
                        \.digitalOutputPeakHold, \.mixerPeakHold, \.unitBInputPeakHold,
                        \.unitBOutputPeakHold, \.unitBDigitalInputPeakHold, \.unitBDigitalOutputPeakHold]
            as [ReferenceWritableKeyPath<AppState, [Double]>] {
            self[keyPath: keyPath] = Array(repeating: -60, count: self[keyPath: keyPath].count)
        }
    }

    func meterIsOver(_ bank: DisplayMeterBank, _ index: Int?, offset: Int = 0) -> Bool {
        guard let index else { return false }
        return meterOvers[bank]?.contains(index + offset) == true
    }

    func inputMeterIsOver(_ index: Int?, digital: Bool = false, offset: Int = 0) -> Bool {
        guard transportType != nil,
              MeterOverSources.available(card: transportType != .usb).input else { return false }
        return meterIsOver(digital ? .digitalInput : .input, index, offset: offset)
    }

    func outputMeterIsOver(_ index: Int?, digital: Bool = false, offset: Int = 0) -> Bool {
        let bank: DisplayMeterBank
        if activeUnit == .b {
            bank = digital ? .unitBDigitalOutput : .unitBOutput
        } else {
            bank = digital ? .digitalOutput : .output
        }
        return meterIsOver(bank, index, offset: offset)
    }

    func mixerInputMeterPresentation(strip: Int) -> (level: Double, peak: Double, over: Bool) {
        var index = strip
        var bank = DisplayMeterBank.input
        var levels = inputMeterLevels
        var peaks = inputPeakHold
        if unitBOnCard, strip >= cardLayout.mixerChannels.count {
            index -= cardLayout.mixerChannels.count
            bank = .unitBInput
            levels = unitBInputMeterLevels
            peaks = unitBInputPeakHold
        } else if transportType == .usb {
            let layout = cardLayout
            if layout.isKnown {
                let channels = layout.mixerChannels
                if channels.indices.contains(strip) {
                    let channel = channels[strip]
                    let digitalChannel = channel.channelOnBoard - layout.slots[channel.boardIndex].analogInputChannels
                    if digitalChannel >= 0 {
                        index = channel.boardIndex * CardLayout.digitalMeterChannelsPerBoard + digitalChannel
                        bank = .digitalInput
                        levels = digitalInputMeterLevels
                        peaks = digitalInputPeakHold
                    }
                }
            }
        }
        return (levels.indices.contains(index) ? levels[index] : -60,
                peaks.indices.contains(index) ? peaks[index] : -60,
                meterIsOver(bank, index))
    }
}
