import Foundation
import Testing
@testable import MaestroCore

/// The Mac's "Symphony I/O : Maestro USB" volume control must play exactly the
/// level Maestro shows. The audio plug-in's control is a libASPL
/// VolumeControl (raw 0...64 for -64...0 dB, attenuation = 64 - raw) with
/// libASPL's default pow-2 transfer curve. Writing a linear scalar made the
/// Symphony louder (-52 dB played at -36, tester log 2026-11).
@Suite("USB Mac volume conversion")
struct USBMacVolumeTests {

    /// libASPL's VolumeCurve for the plug-in's parameters, transcribed from
    /// `libaspl-src/src/VolumeCurve.cpp` (ConvertScalarToRaw, ConvertRawToScalar,
    /// ConvertDBToRaw, ConvertRawToDB) in Float32 as there, with the default
    /// transfer function kPow2Over1Curve (numerator 2, denominator 1), applied
    /// because the dB range (64) is greater than 30. Deliberately not shared
    /// with `USBMacVolume`, so the test checks it independently.
    private enum LibASPL {
        static let rawMin: Int32 = 0, rawMax: Int32 = 64
        static let dbMin: Float32 = -64, dbMax: Float32 = 0
        static let numerator: Float32 = 2, denominator: Float32 = 1
        static var applyingCurve: Bool { (dbMax - dbMin) > 30 }

        static func scalarToRaw(_ input: Float32) -> Int32 {
            var s = min(1, max(0, input))
            let rawRange = rawMax - rawMin
            if applyingCurve { s = powf(s, denominator / numerator) }
            let steps = roundf(s * Float32(rawRange))
            return rawMin + Int32(steps)
        }

        static func rawToScalar(_ input: Int32) -> Float32 {
            let raw = min(rawMax, max(rawMin, input))
            var answer = Float32(raw - rawMin) / Float32(rawMax - rawMin)
            if applyingCurve { answer = powf(answer, numerator / denominator) }
            return answer
        }

        static func dbToRaw(_ input: Float32) -> Int32 {
            let db = min(dbMax, max(dbMin, input))
            let dbPerRaw = (dbMax - dbMin) / Float32(rawMax - rawMin)
            return rawMin + Int32(roundf((db - dbMin) / dbPerRaw))
        }

        static func rawToDB(_ raw: Int32) -> Float32 {
            let r = min(rawMax, max(rawMin, raw))
            return dbMin + Float32(r - rawMin) * ((dbMax - dbMin) / Float32(rawMax - rawMin))
        }

        /// ApogeeVolumeControl::SetRawValueImpl: attenuation = 64 - raw.
        static func attenuation(_ raw: Int32) -> Int { Int(max(0, 64 - raw)) }
    }

    /// Every whole dB (the knobs' step is 1 dB; the front panel and the keys
    /// move in whole dB), plus fractional values a computed level could hold.
    private static let wholeLevels: [Double] = (0...64).map { -Double($0) }
    private static let fractionalLevels: [Double] = stride(from: -64.0, through: 0.0, by: 0.25)
        .map { $0 } + [-52.000000001, -51.999999999, -0.0001, -63.9999]

    @Test("every whole dB from -64 to 0 plays at exactly that attenuation and reads back the same")
    func wholeLevelsAreExact() {
        for dB in Self.wholeLevels {
            let sent = USBMacVolume.scalar(forDB: dB)
            let raw = LibASPL.scalarToRaw(sent)
            #expect(LibASPL.attenuation(raw) == Int(-dB), "level \(dB) dB")
            // The same raw value the decibel property would have given.
            #expect(raw == LibASPL.dbToRaw(Float32(dB)), "level \(dB) dB, decibel path")
            // What Core Audio hands back after the set.
            let readBack = USBMacVolume.dB(forScalar: LibASPL.rawToScalar(raw))
            #expect(readBack == dB, "level \(dB) dB read back as \(readBack)")
            #expect(Double(LibASPL.rawToDB(raw)) == readBack, "level \(dB) dB, the control's own dB")
        }
    }

    @Test("a fractional level is never louder than asked for, nor than what the unit is sent")
    func fractionalLevelsAreNeverLouder() {
        for dB in Self.fractionalLevels + Self.wholeLevels {
            let att = LibASPL.attenuation(LibASPL.scalarToRaw(USBMacVolume.scalar(forDB: dB)))
            #expect(Double(att) >= -dB - 1e-5, "level \(dB) dB played at -\(att) dB")
            // The unit itself is sent UInt32(max(0, -dB)) by the knobs and the
            // front-panel push, and (-dB).rounded() by the Volume Keys handoff.
            #expect(att >= Int(max(0, min(64, -dB))), "level \(dB) dB vs knob write")
            #expect(att >= Int(max(0, min(64, (-dB).rounded()))), "level \(dB) dB vs rounded write")
            #expect(att - Int(max(0, min(64, -dB))) <= 1, "level \(dB) dB at most one step quieter")
        }
    }

    @Test("the tester's levels: -52, -57 and -56 dB are no longer played at -36, -43 and -41")
    func testerLevels() {
        for (dB, oldLouder) in [(-52.0, 36), (-57.0, 43), (-56.0, 41)] {
            // The old linear formula really is the bug: the test can tell them apart.
            let linear = Float32(max(0, min(1, (dB + 64) / 64)))
            #expect(LibASPL.attenuation(LibASPL.scalarToRaw(linear)) == oldLouder)
            #expect(Double(linear) * 64 - 64 == dB, "the linear read-back hid it")
            #expect(LibASPL.attenuation(LibASPL.scalarToRaw(USBMacVolume.scalar(forDB: dB))) == Int(-dB))
        }
    }

    @Test("the old linear formula fails the exhaustive check (control for the test above)")
    func linearFormulaFails() {
        let wrong = Self.wholeLevels.filter { dB in
            let linear = Float32(max(0, min(1, (dB + 64) / 64)))
            return LibASPL.attenuation(LibASPL.scalarToRaw(linear)) != Int(-dB)
        }
        #expect(wrong.count > 50)
        #expect(wrong.allSatisfy { dB in
            let linear = Float32(max(0, min(1, (dB + 64) / 64)))
            return LibASPL.attenuation(LibASPL.scalarToRaw(linear)) < Int(-dB)
        }, "every linear error was louder")
    }

    @Test("a level the Mac's keys or Sound settings set reads back as the level the unit plays")
    func everyRawReadsBackExactly() {
        for raw in LibASPL.rawMin...LibASPL.rawMax {
            let dB = USBMacVolume.dB(forScalar: LibASPL.rawToScalar(raw))
            #expect(dB == Double(-LibASPL.attenuation(raw)), "raw \(raw)")
            // Maestro writing that level back changes nothing.
            #expect(LibASPL.scalarToRaw(USBMacVolume.scalar(forDB: dB)) == raw, "raw \(raw) round trip")
        }
        // Out-of-range and broken values stay in range.
        #expect(USBMacVolume.dB(forScalar: -1) == -64)
        #expect(USBMacVolume.dB(forScalar: 2) == 0)
        #expect(USBMacVolume.dB(forScalar: .nan) == -64)
        #expect(USBMacVolume.attenuation(forDB: 6) == 0)
        #expect(USBMacVolume.attenuation(forDB: -90) == 64)
        #expect(USBMacVolume.attenuation(forDB: .nan) == 64)
    }

    // MARK: - Source checks

    private static func repoFile(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("the plug-in's control has the range the conversion assumes")
    func pluginRangeMatches() throws {
        let driver = try Self.repoFile("Drivers/AudioServerPlugin/ApogeeDriver.cpp")
        for line in ["vp.MinRawVolume     = 0;", "vp.MaxRawVolume     = 64;",
                     "vp.MinDecibelVolume = -64.0f;", "vp.MaxDecibelVolume =   0.0f;"] {
            #expect(driver.contains(line), "\(line)")
        }
        // No transfer function is set, so libASPL's default (pow 2) applies.
        #expect(!driver.contains("SetTransferFunction"))
        // When the fetched libASPL is present, its default is still pow 2 over 1.
        if let curve = try? Self.repoFile(
            "Drivers/AudioServerPlugin/build/_deps/libaspl-src/src/VolumeCurve.cpp") {
            #expect(curve.contains("mTransferFunction(kPow2Over1Curve)"))
            #expect(curve.contains("mRawToScalarExponentNumerator(2.0f)"))
            #expect(curve.contains("mRawToScalarExponentDenominator(1.0f)"))
        }
    }

    @Test("USB reads and writes go through the one conversion; ThunderBridge keeps decibels")
    func appUsesTheConversion() throws {
        let app = try Self.repoFile("Apps/Maestro/MaestroApp/AppState.swift")
        #expect(!app.contains("* 64.0 - 64.0"), "no linear read")
        #expect(!app.contains("(dB + 64.0) / 64.0"), "no linear write")
        #expect(!app.contains("Double(scalar) * 64 - 64"), "no linear remembered level")
        #expect(app.contains("let scalar = USBMacVolume.scalar(forDB: dB)"))
        #expect(app.contains("let dB = USBMacVolume.dB(forScalar: scalar)"))
        #expect(app.contains("level: USBMacVolume.dB(forScalar: scalar))"))

        // ThunderBridge: readASPVolume reads VolumeDecibels; writeASPVolume
        // returns before the USB write; writeMacVolume refuses Thunderbolt.
        let read = try #require(app.range(of: "func readASPVolume()"))
        let readBody = String(app[read.lowerBound...].prefix(1400))
        let tbRead = try #require(readBody.range(of: "if transportType == .thunderbolt {"))
        let usbRead = try #require(readBody.range(of: "} else {", range: tbRead.upperBound..<readBody.endIndex))
        let tbBody = readBody[tbRead.upperBound..<usbRead.lowerBound]
        #expect(tbBody.contains("kAudioDevicePropertyVolumeDecibels"))
        #expect(!tbBody.contains("USBMacVolume"))
        let write = try #require(app.range(of: "func writeASPVolume("))
        let writeBody = String(app[write.lowerBound...].prefix(900))
        let tbWrite = try #require(writeBody.range(of: "if transportType == .thunderbolt {"))
        let ret = try #require(writeBody.range(of: "return\n", range: tbWrite.upperBound..<writeBody.endIndex))
        let usbWrite = try #require(writeBody.range(of: "writeMacVolume(dB)"))
        #expect(ret.upperBound <= usbWrite.lowerBound)
        #expect(app.contains("guard aspDeviceID != kAudioObjectUnknown, transportType != .thunderbolt else { return }"))
    }
}
