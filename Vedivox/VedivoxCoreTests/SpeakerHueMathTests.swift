import XCTest

final class SpeakerHueMathTests: XCTestCase {

    func testFallbackIsDeterministicAndInRange() {
        let a = SpeakerHueMath.fallback("speaker-id-1")
        XCTAssertEqual(a, SpeakerHueMath.fallback("speaker-id-1"))
        XCTAssertNotEqual(a, SpeakerHueMath.fallback("speaker-id-2"))
        for key in ["x", "me", "Алиса Примерова", ""] {
            let hue = SpeakerHueMath.fallback(key)
            XCTAssertGreaterThanOrEqual(hue, 0)
            XCTAssertLessThan(hue, 360)
        }
    }

    func testNextHueOnEmptyIsDefault() {
        XCTAssertEqual(SpeakerHueMath.nextHue(existing: []), 210)
    }

    func testNextHuePicksLargestGapMidpoint() {
        // Existing at 0 and 90 → largest gap is 90..360, midpoint 225.
        XCTAssertEqual(SpeakerHueMath.nextHue(existing: [0, 90]), 225)
        // Single existing at 100 → opposite side of the circle: 280.
        XCTAssertEqual(SpeakerHueMath.nextHue(existing: [100]), 280)
    }

    func testNextHueKeepsMinimumDistanceForSmallSets() {
        var hues: [Double] = []
        for _ in 0 ..< 8 {
            let next = SpeakerHueMath.nextHue(existing: hues)
            for existing in hues {
                let diff = abs(next - existing)
                let circular = min(diff, 360 - diff)
                XCTAssertGreaterThanOrEqual(
                    circular, 20,
                    "hue \(next) too close to \(existing) in \(hues)"
                )
            }
            hues.append(next)
        }
    }

    func testSRGBMatchesKnownOKLCHPoints() {
        func assertRGB(_ got: (r: Double, g: Double, b: Double), _ want: (Double, Double, Double), line: UInt = #line) {
            XCTAssertEqual(got.r, want.0, accuracy: 0.005, line: line)
            XCTAssertEqual(got.g, want.1, accuracy: 0.005, line: line)
            XCTAssertEqual(got.b, want.2, accuracy: 0.005, line: line)
        }
        assertRGB(SpeakerHueMath.srgb(l: 1, c: 0, h: 0), (1, 1, 1))
        assertRGB(SpeakerHueMath.srgb(l: 0, c: 0, h: 0), (0, 0, 0))
        // CSS `red` is oklch(0.6279554 0.2576833 29.2338851).
        assertRGB(SpeakerHueMath.srgb(l: 0.6279554, c: 0.2576833, h: 29.2338851), (1, 0, 0))
        // Out-of-gamut input clamps instead of escaping 0...1.
        let wild = SpeakerHueMath.srgb(l: 0.9, c: 0.4, h: 140)
        for v in [wild.r, wild.g, wild.b] { XCTAssertTrue((0 ... 1).contains(v)) }
    }

    func testEvenSpreadCoversCircleUniformly() {
        XCTAssertEqual(SpeakerHueMath.evenSpread(count: 0), [])
        let four = SpeakerHueMath.evenSpread(count: 4)
        XCTAssertEqual(four.count, 4)
        // Steps of 90° starting at 210.
        XCTAssertEqual(four, [210, 300, 30, 120])
        // All unique for a realistic pool size.
        let sixty = SpeakerHueMath.evenSpread(count: 60)
        XCTAssertEqual(Set(sixty).count, 60)
    }
}
