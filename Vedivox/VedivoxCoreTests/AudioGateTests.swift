import XCTest

final class AudioGateTests: XCTestCase {

    // MARK: - Unit Tests (synthetic signals)

    func testSilentSystemPassesMicThrough() {
        let mic = [Float](repeating: 0.5, count: 1600) // 100ms at 16kHz
        let sys = [Float](repeating: 0.0, count: 1600)

        let result = AudioGate.apply(micSamples: mic, systemSamples: sys, sampleRate: 16000)

        XCTAssertEqual(result.count, mic.count)
        let nonZero = result.filter { abs($0) > 0.001 }.count
        XCTAssertEqual(nonZero, mic.count, "All samples should pass when system is silent")
    }

    func testLoudSystemSuppressesMic() {
        // 1 second at 16kHz — system has loud sine wave throughout
        let mic = [Float](repeating: 0.5, count: 16000)
        let sys = (0 ..< 16000).map { i in sin(Float(i) * 0.1) * 0.8 }

        let result = AudioGate.apply(micSamples: mic, systemSamples: sys, sampleRate: 16000)

        let zeroCount = result.filter { abs($0) < 0.001 }.count
        XCTAssertGreaterThan(
            Double(zeroCount) / Double(result.count), 0.7,
            "Most mic should be suppressed when system is loud"
        )
    }

    func testHoldKeepsGateClosedAfterSystemStops() {
        // 2 seconds: system loud for 1s, then silent for 1s
        let sampleRate: Double = 16000
        let totalSamples = Int(2.0 * sampleRate)
        let halfSamples = totalSamples / 2

        let mic = [Float](repeating: 0.5, count: totalSamples)
        var sys = (0 ..< halfSamples).map { i in sin(Float(i) * 0.1) * 0.8 }
        sys += [Float](repeating: 0.0, count: halfSamples)

        let config = AudioGate.Config(holdTime: 0.500)
        let result = AudioGate.apply(micSamples: mic, systemSamples: sys, sampleRate: sampleRate, config: config)

        // Check that samples right after system stops (16000..24000 = 500ms hold) are still suppressed
        let holdEnd = halfSamples + Int(0.5 * sampleRate)
        let holdRegion = result[halfSamples ..< min(holdEnd, result.count)]
        let suppressedInHold = holdRegion.filter { abs($0) < 0.01 }.count
        XCTAssertGreaterThan(
            Double(suppressedInHold) / Double(holdRegion.count), 0.8,
            "Hold region should still be mostly suppressed"
        )
    }

    func testRmsEnergyComputation() {
        let silence = [Float](repeating: 0.0, count: 160)
        let energySilent = AudioGate.rmsEnergy(silence, frameLength: 160)
        XCTAssertEqual(energySilent.count, 1)
        XCTAssertEqual(energySilent[0], 0.0, accuracy: 0.001)

        let loud = [Float](repeating: 1.0, count: 160)
        let energyLoud = AudioGate.rmsEnergy(loud, frameLength: 160)
        XCTAssertEqual(energyLoud[0], 1.0, accuracy: 0.001)
    }

    func testEmptyInputReturnsEmpty() {
        let result = AudioGate.apply(micSamples: [], systemSamples: [], sampleRate: 16000)
        XCTAssertTrue(result.isEmpty)
    }

    func testMismatchedLengthsHandled() {
        // Mic longer than system — extra mic samples pass through
        let mic = [Float](repeating: 0.5, count: 3200)
        let sys = [Float](repeating: 0.0, count: 1600)

        let result = AudioGate.apply(micSamples: mic, systemSamples: sys, sampleRate: 16000)
        XCTAssertEqual(result.count, mic.count)
    }

    // MARK: - Integration Test (real audio)

    func testEchoSuppressionOnRealAudio() throws {
        let bundle = Bundle(for: type(of: self))
        guard let micURL = bundle.url(forResource: "test_mic_30s", withExtension: "wav"),
              let sysURL = bundle.url(forResource: "test_system_30s", withExtension: "wav") else {
            throw XCTSkip("Test audio files not in bundle — add test_mic_30s.wav and test_system_30s.wav to VedivoxTests target")
        }

        let micSamples = try AudioGate.loadSamples(from: micURL)
        let sysSamples = try AudioGate.loadSamples(from: sysURL)

        XCTAssertGreaterThan(micSamples.count, 0)
        XCTAssertGreaterThan(sysSamples.count, 0)

        let result = AudioGate.apply(micSamples: micSamples, systemSamples: sysSamples, sampleRate: 16000)
        XCTAssertEqual(result.count, micSamples.count)

        // Compute energy correlation between system and gated mic.
        // After suppression, where system is loud mic should be near-zero.
        let frameLength = 160 // 10ms at 16kHz
        let sysEnergy = AudioGate.rmsEnergy(sysSamples, frameLength: frameLength)
        let gatedMicEnergy = AudioGate.rmsEnergy(result, frameLength: frameLength)

        let frameCount = min(sysEnergy.count, gatedMicEnergy.count)
        guard frameCount > 0 else { return }

        // Count frames where system is active AND gated mic is also active (echo leak)
        let sysThreshold = sysEnergy.sorted()[min(Int(Double(sysEnergy.count) * 0.95), sysEnergy.count - 1)] * 0.1
        var activeSystemFrames = 0
        var leakFrames = 0
        for i in 0 ..< frameCount {
            if sysEnergy[i] > sysThreshold {
                activeSystemFrames += 1
                if gatedMicEnergy[i] > sysThreshold * 0.5 {
                    leakFrames += 1
                }
            }
        }

        // There should be some system activity in this fragment
        XCTAssertGreaterThan(activeSystemFrames, 10, "Expected system audio activity in test fragment")

        // Leak rate should be low (< 20% of system-active frames)
        let leakRate = activeSystemFrames > 0 ? Double(leakFrames) / Double(activeSystemFrames) : 0
        XCTAssertLessThan(leakRate, 0.2, "Echo leak rate should be < 20%, got \(Int(leakRate * 100))%")
    }
}
