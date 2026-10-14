import Carbon.HIToolbox
import XCTest
@testable import Peroxide

final class TuyaTests: XCTestCase {
    func testFrameRoundTrip() throws {
        let key = "0123456789abcdef"
        let body = Data(#"{"dps":{"20":true}}"#.utf8)
        var buf = try frame(cmd: 10, payload: Data(count: 4) + Data("3.3".utf8) + Data(count: 12) + aes(body, key: key, encrypt: true))
        XCTAssertEqual(crc32(Data("123456789".utf8)), 0xCBF4_3926)
        var partial = buf.prefix(10)
        XCTAssertNil(parse(&partial))
        let (cmd, payload) = try XCTUnwrap(parse(&buf))
        XCTAssertEqual(cmd, 10)
        XCTAssertTrue(buf.isEmpty)
        XCTAssertEqual(try decode(payload, key: key), body)
    }
}

final class ClapTests: XCTestCase {
    func testDoubleClap() {
        var d = ClapDetector()
        for t in stride(from: 0.0, to: 1, by: 0.01) { XCTAssertFalse(d.feed(peak: 0.005, rms: 0.002, now: t)) }
        XCTAssertFalse(d.feed(peak: 0.3, rms: 0.05, now: 1.0))
        XCTAssertTrue(d.feed(peak: 0.3, rms: 0.05, now: 1.4))
        XCTAssertFalse(d.feed(peak: 0.3, rms: 0.05, now: 2.0))
        XCTAssertFalse(d.feed(peak: 0.3, rms: 0.05, now: 5.0))
        XCTAssertFalse(d.feed(peak: 0.3, rms: 0.05, now: 6.0))
    }
}

final class CalibratorTests: XCTestCase {
    func testCalibrates() {
        var c = ClapCalibrator()
        for t in stride(from: 0.0, to: 3, by: 0.01) { c.feed(peak: 0.01, now: t) }
        XCTAssertEqual(c.phase, .clap)
        for (t, p) in [(4.0, 0.3), (4.01, 0.4), (4.5, 0.25)] as [(Double, Float)] { c.feed(peak: p, now: t) }
        c.feed(peak: 0.01, now: 5)
        XCTAssertEqual(c.claps, [0.4, 0.25])
        guard case .done(let th) = c.phase else { return XCTFail("\(c.phase)") }
        XCTAssertEqual(th, 0.075, accuracy: 0.0001)
    }

    func testGivesUpWithoutClaps() {
        var c = ClapCalibrator()
        for t in stride(from: 0.0, to: 14, by: 0.01) { c.feed(peak: 0.01, now: t) }
        guard case .failed = c.phase else { return XCTFail("\(c.phase)") }
    }

    func testBusyRoom() {
        var c = ClapCalibrator()
        for t in stride(from: 0.0, to: 3, by: 0.01) { c.feed(peak: t.truncatingRemainder(dividingBy: 0.5) < 0.01 ? 0.15 : 0.04, now: t) }
        XCTAssertEqual(c.phase, .clap)
        c.feed(peak: 0.15, now: 3.5)
        XCTAssertEqual(c.claps, [], "a normal loud moment isn't a clap")
        for t in [4.0, 4.5, 5.0] { c.feed(peak: t == 5 ? 0.04 : 0.5, now: t) }
        guard case .done(let th) = c.phase else { return XCTFail("\(c.phase)") }
        XCTAssert(th > 0.15 && th < 0.5, "\(th)")
    }
}

final class BandTests: XCTestCase {
    func rms(_ band: Mic.Band, hz: Double, sr: Double = 48000) -> Float {
        var f = band.filter(sampleRate: sr)
        let ys = (0..<4800).map { i in Float(sin(2 * .pi * hz * Double(i) / sr)) }.map { f?.run($0) ?? $0 }
        return (ys[2400...].reduce(0) { $0 + $1 * $1 } / 2400).squareRoot()
    }

    func testBandsSeparate() {
        XCTAssertGreaterThan(rms(.bass, hz: 60), 0.6)
        XCTAssertLessThan(rms(.bass, hz: 5000), 0.01)
        XCTAssertGreaterThan(rms(.highs, hz: 8000), 0.6)
        XCTAssertLessThan(rms(.highs, hz: 60), 0.01)
        XCTAssertGreaterThan(rms(.mids, hz: 1000), 0.6)
        XCTAssertLessThan(rms(.mids, hz: 60), 0.15)
        XCTAssertEqual(rms(.all, hz: 440), 0.707, accuracy: 0.01)
    }
}

@MainActor final class HotkeyTests: XCTestCase {
    func testMods() {
        let m = Hotkeys.carbon([.command, .control, .capsLock])
        XCTAssertEqual(m, cmdKey | controlKey)
        XCTAssertEqual(Hotkeys.symbols(m), "⌃⌘")
    }
}
