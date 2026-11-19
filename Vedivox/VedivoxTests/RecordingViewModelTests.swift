import XCTest
@testable import Vedivox

// MARK: - Mock Audio Session

actor MockAudioSession: AudioSessionProtocol {
    private(set) var state: CaptureState
    var systemAudioEnabled: Bool = false

    /// Track calls for verification.
    private(set) var startRecordingCallCount = 0
    private(set) var resetCallCount = 0
    private(set) var stopRecordingCallCount = 0

    init(initialState: CaptureState = .idle) {
        self.state = initialState
    }

    func startRecording(meetingId: String) async throws -> (micURL: URL, systemURL: URL?) {
        // Mirror the REAL AudioSessionManager guard (rejects only .recording)
        guard state != .recording else {
            throw AudioSessionManager.AudioSessionError.alreadyRecording
        }
        state = .recording
        startRecordingCallCount += 1
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(meetingId)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let micURL = dir.appendingPathComponent("mic.wav")
        FileManager.default.createFile(atPath: micURL.path, contents: nil)
        return (micURL, nil)
    }

    func setLiveSinks(mic: LiveAudioSink?, system: LiveAudioSink?) async {}

    func stopRecording() async -> RecordingResult {
        stopRecordingCallCount += 1
        state = .stopped
        return RecordingResult(micAudioURL: nil, systemAudioURL: nil)
    }

    func reset() async {
        state = .idle
        resetCallCount += 1
    }
}

// MARK: - Tests

@MainActor
final class RecordingViewModelTests: XCTestCase {

    private var mockSession: MockAudioSession!
    private var db: DatabaseManager!
    private var vm: RecordingViewModel!

    override func setUp() async throws {
        db = try makeTestDB()
        mockSession = MockAudioSession(initialState: .idle)
        vm = RecordingViewModel(audioSession: mockSession, meetingRepo: MeetingRepository(db: db))
    }

    // MARK: - Race condition: start during processing

    /// Reproduces the bug: after stopRecording the audio session is in .stopped state.
    /// Starting a new recording during processing should succeed, not throw .alreadyRecording.
    func testStartRecordingDuringProcessing_succeeds() async {
        // Simulate: recording happened, then stopRecording set audio session to .stopped
        mockSession = MockAudioSession(initialState: .stopped)
        vm = RecordingViewModel(audioSession: mockSession, meetingRepo: MeetingRepository(db: db))
        vm.state = .processing // pipeline still running

        // Minimal AppState for the call (pipeline won't actually run)
        let appState = AppState()

        await vm.startRecording(appState: appState)

        // Should have transitioned to .recording, NOT .error
        XCTAssertEqual(vm.state, .recording,
                       "Starting a recording while processing should succeed, not produce an error")
        let callCount = await mockSession.startRecordingCallCount
        XCTAssertEqual(callCount, 1)
    }

    /// After stopRecording, the audio session is .stopped. A new startRecording must
    /// reset the session to .idle before calling startRecording on it.
    func testStartRecording_resetsAudioSessionBeforeStart() async {
        mockSession = MockAudioSession(initialState: .stopped)
        vm = RecordingViewModel(audioSession: mockSession, meetingRepo: MeetingRepository(db: db))
        vm.state = .processing

        let appState = AppState()
        await vm.startRecording(appState: appState)

        let resetCount = await mockSession.resetCallCount
        XCTAssertGreaterThanOrEqual(resetCount, 1,
                                    "Audio session should be reset before starting a new recording")
    }

    // MARK: - Guard: reject concurrent recording

    /// The guard should still prevent starting while already recording.
    func testStartRecordingWhileRecording_isBlocked() async {
        vm.state = .recording
        let appState = AppState()

        await vm.startRecording(appState: appState)

        // Guard returns early; state should remain .recording (not .error, not .idle)
        XCTAssertEqual(vm.state, .recording)
        let callCount = await mockSession.startRecordingCallCount
        XCTAssertEqual(callCount, 0, "Should not call audioSession.startRecording while already recording")
    }

    // MARK: - Guard: two stops at once

    /// Menu + notification, or two `vedivox record stop`: both pass the
    /// `.recording` guard unless the block precedes the first await. Only one
    /// may stop the capture; the second reports that it did nothing.
    func testTwoConcurrentStops_onlyOneStops() async {
        let appState = AppState()
        let vm: RecordingViewModel = vm
        await vm.startRecording(appState: appState)
        XCTAssertEqual(vm.state, .recording)

        async let first = vm.stopRecording(appState: appState)
        async let second = vm.stopRecording(appState: appState)
        let results = await [first, second]

        XCTAssertEqual(results.filter { $0 }.count, 1, "ровно один стоп остановил запись")
        let stops = await mockSession.stopRecordingCallCount
        XCTAssertEqual(stops, 1, "захват останавливается один раз")
    }
}
