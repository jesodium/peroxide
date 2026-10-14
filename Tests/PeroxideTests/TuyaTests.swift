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
