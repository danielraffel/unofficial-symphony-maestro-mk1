extension InputChannelState {
    /// Save the active trim and recall the destination reference's trim.
    public func switchingTrimReference(to level: AnalogInputLevel) -> Self {
        var next = self
        switch AnalogInputLevel(rawValue: inputType) {
        case .plus4dBu: next.trimPlus4 = trim
        case .minus10dBV: next.trimMinus10 = trim
        case .variable: next.trimVariable = trim
        default: break
        }
        next.inputType = level.rawValue
        switch level {
        case .plus4dBu: next.trim = next.trimPlus4
        case .minus10dBV: next.trim = next.trimMinus10
        case .variable: next.trim = next.trimVariable
        case .mic, .instrument: next.trim = 0
        }
        return next
    }
}

extension OutputChannelState {
    /// Save the active trim and recall the destination reference's trim.
    public func switchingTrimReference(to level: UInt32) -> Self {
        guard OutputChannelLogic.offersAnalogRef(level) else { return self }
        var next = self
        switch analogRefLevel {
        case OutputChannelLogic.plus4dBu: next.trimPlus4 = trim
        case OutputChannelLogic.minus10dBV: next.trimMinus10 = trim
        default: break
        }
        next.analogRefLevel = level
        next.trim = level == OutputChannelLogic.plus4dBu ? next.trimPlus4 : next.trimMinus10
        return next
    }
}
