import XCTest

/// The Listen section's model (listen-queue § 7).
@MainActor
final class ListenViewModelTests: XCTestCase {

    private func item(_ speaker: String, fragments: Int) -> ListenQueueItem {
        let meetingId = "meeting-\(speaker)"
        return ListenQueueItem(
            members: [.init(meetingId: meetingId, speakerId: speaker)],
            reason: .almostKnown(bestSim: 0.7), seconds: 120, meetingTitle: "M", meetingStart: .distantPast,
            speakerLabel: speaker,
            fragments: (0 ..< fragments).map {
                .init(meetingId: meetingId, start: Double($0) * 30, end: Double($0) * 30 + 20, track: .system, text: "f\($0)")
            },
            candidates: [], isSkipped: false, segmentIds: []
        )
    }

    /// A model over an empty database: no meeting is found, so nothing plays.
    private func model(_ items: [ListenQueueItem]) throws -> ListenViewModel {
        let model = ListenViewModel(db: try makeTestDB())
        model.items = items
        model.select(items.first?.id, autoplay: false)
        return model
    }

    // MARK: Fragment navigator

    func testMoveFragment_stepsThroughTheVoiceAndStopsAtItsEnds() throws {
        let model = try model([item("a", fragments: 3)])
        XCTAssertEqual(model.fragment?.text, "f0")
        XCTAssertFalse(model.canMoveFragment(by: -1))
        XCTAssertTrue(model.canMoveFragment(by: 1))

        model.moveFragment(by: 1)
        XCTAssertEqual(model.fragmentIndex, 1)
        XCTAssertEqual(model.fragment?.text, "f1")

        model.moveFragment(by: 1)
        model.moveFragment(by: 1)
        XCTAssertEqual(model.fragment?.text, "f2", "за последним фрагментом остаёмся на нём")
        XCTAssertFalse(model.canMoveFragment(by: 1))
        XCTAssertTrue(model.canMoveFragment(by: -1))

        model.moveFragment(by: -5)
        XCTAssertEqual(model.fragmentIndex, 0)
    }

    func testAnotherVoice_startsFromItsFirstFragment() throws {
        let model = try model([item("a", fragments: 3), item("b", fragments: 2)])
        model.moveFragment(by: 2)

        model.moveItem(by: 1)

        XCTAssertEqual(model.selected?.speakerLabel, "b")
        XCTAssertEqual(model.fragmentIndex, 0)
        XCTAssertEqual(model.fragment?.text, "f0")
    }

    func testVoiceWithoutFragments_hasNowhereToMove() throws {
        let model = try model([item("a", fragments: 0)])
        model.moveFragment(by: 1)
        XCTAssertNil(model.fragment)
        XCTAssertFalse(model.canMoveFragment(by: 1))
        XCTAssertFalse(model.canMoveFragment(by: -1))
    }

    // MARK: Refresh

    /// What the model asked the queue builder for.
    @MainActor
    private final class Calls {
        var builds = 0
        var counts = 0
        /// Queues handed out in order; the last one repeats.
        var queues: [[ListenQueueItem]] = [[]]
        var voices = 0
    }

    /// Holds a build or a count until the test lets it through.
    @MainActor
    private final class Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async { await withCheckedContinuation { waiters.append($0) } }
        func open() {
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    private func model(
        _ calls: Calls, pause: Duration = .milliseconds(20), minInterval: Duration = .milliseconds(20)
    ) throws -> ListenViewModel {
        ListenViewModel(
            db: try makeTestDB(), pause: pause, minInterval: minInterval,
            build: { _, _ in
                calls.builds += 1
                return calls.queues[min(calls.builds, calls.queues.count) - 1]
            },
            count: {
                calls.counts += 1
                return calls.voices
            }
        )
    }

    /// Waits for `condition`, then a little longer for what must not follow.
    private func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0 ..< 300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "не дождались", file: file, line: line)
        try await Task.sleep(for: .milliseconds(150))
    }

    func testBurstOfChanges_whileTheSectionIsOpen_isOneRebuild() async throws {
        let calls = Calls()
        calls.voices = 3
        let model = try model(calls)
        await model.open(meetingFilter: nil)
        XCTAssertEqual(calls.builds, 1)

        for _ in 0 ..< 25 { model.dataChanged() }
        try await settle { calls.counts == 1 }

        XCTAssertEqual(calls.builds, 2, "25 изменений подряд — одно перестроение")
        XCTAssertEqual(calls.counts, 1)
        XCTAssertEqual(model.count, 3)
    }

    func testChangesWhileTheSectionIsClosed_buildTheQueueOnceAhead_thenOnlyRecountTheBadge() async throws {
        let calls = Calls()
        calls.voices = 5
        calls.queues = [[item("a", fragments: 1)]]
        let model = try model(calls)

        for _ in 0 ..< 25 { model.dataChanged() }
        try await settle { calls.counts == 1 }
        XCTAssertEqual(calls.builds, 1, "первое обновление после запуска строит очередь заранее")
        XCTAssertEqual(model.count, 5)
        XCTAssertTrue(model.isLoaded)
        XCTAssertEqual(model.items.count, 1, "первое открытие сразу видит список")

        model.dataChanged()
        try await settle { calls.counts == 2 }
        XCTAssertEqual(calls.builds, 1, "дальше при закрытом разделе — только счётчик")

        await model.open(meetingFilter: nil)
        model.leave()
        calls.voices = 0
        model.dataChanged()
        try await settle { calls.counts == 3 }
        XCTAssertEqual(calls.builds, 2, "очередь строило только открытие раздела")
        XCTAssertNil(model.count, "ноль голосов — без значка")
    }

    func testRefreshes_keepTheMinimumInterval() async throws {
        let calls = Calls()
        let model = try model(calls, pause: .milliseconds(10), minInterval: .seconds(1))

        model.dataChanged()
        try await settle { calls.counts == 1 }
        model.dataChanged()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(calls.counts, 1, "второе обновление ждёт интервала")

        try await settle { calls.counts == 2 }
        XCTAssertEqual(calls.counts, 2)
    }

    func testChangeDuringARefresh_getsOneMore() async throws {
        let calls = Calls()
        let gate = Gate()
        let model = ListenViewModel(
            db: try makeTestDB(), pause: .milliseconds(10), minInterval: .milliseconds(10),
            build: { _, _ in [] },
            count: {
                calls.counts += 1
                if calls.counts == 1 { await gate.wait() }
                return 0
            }
        )

        model.dataChanged()
        try await settle { calls.counts == 1 }
        model.dataChanged() // lands while the first recount is still out
        gate.open()
        try await settle { calls.counts == 2 }
        XCTAssertEqual(calls.counts, 2)
    }

    func testBeforeTheFirstQueue_theSectionIsLoading_andAReturnShowsTheLastList() async throws {
        let calls = Calls()
        let gate = Gate()
        let queue = [item("a", fragments: 1)]
        let model = ListenViewModel(db: try makeTestDB(), build: { _, _ in
            calls.builds += 1
            await gate.wait()
            return queue
        }, count: { 0 })

        let first = Task { await model.open(meetingFilter: nil) }
        try await settle { calls.builds == 1 }
        XCTAssertFalse(model.isLoaded, "очередь ещё строится — это не «ничего нет»")
        gate.open()
        await first.value
        XCTAssertTrue(model.isLoaded)
        XCTAssertEqual(model.items, queue)
        XCTAssertEqual(model.selectedId, queue[0].id)

        model.leave()
        let again = Task { await model.open(meetingFilter: nil) }
        try await settle { calls.builds == 2 }
        XCTAssertEqual(model.items, queue, "прошлый список на экране, пока строится новый")
        XCTAssertTrue(model.isLoaded)
        gate.open()
        await again.value

        let filtered = Task { await model.open(meetingFilter: "another-meeting") }
        try await settle { calls.builds == 3 }
        XCTAssertTrue(model.items.isEmpty, "другой фильтр — другой список")
        XCTAssertFalse(model.isLoaded)
        gate.open()
        await filtered.value
    }

    func testCancelledOrFailedRebuild_keepsTheList() async throws {
        struct Broken: Error {}
        let calls = Calls()
        let queue = [item("a", fragments: 2), item("b", fragments: 1)]
        let model = ListenViewModel(db: try makeTestDB(), build: { _, _ in
            calls.builds += 1
            if calls.builds == 2 { throw CancellationError() }
            if calls.builds == 3 { throw Broken() }
            return queue
        }, count: { 0 })

        await model.open(meetingFilter: nil)
        await model.reload()
        XCTAssertEqual(model.items, queue, "отмена не стирает список")
        await model.reload()
        XCTAssertEqual(model.items, queue, "ошибка тоже")
        XCTAssertTrue(model.isLoaded)
    }

    func testCancelledFirstBuild_staysLoading() async throws {
        let model = ListenViewModel(db: try makeTestDB(), build: { _, _ in throw CancellationError() }, count: { 0 })
        await model.open(meetingFilter: nil)
        XCTAssertFalse(model.isLoaded, "отменённое построение — ещё не «ничего нет»")
    }

    func testSlowerOlderRebuild_doesNotOverwriteTheNewerOne() async throws {
        let calls = Calls()
        let gate = Gate()
        let old = [item("old", fragments: 1)]
        let new = [item("new", fragments: 1)]
        let model = ListenViewModel(db: try makeTestDB(), build: { _, _ in
            calls.builds += 1
            guard calls.builds == 1 else { return new }
            await gate.wait()
            return old
        }, count: { 0 })

        let first = Task { await model.reload() }
        try await settle { calls.builds == 1 }
        await model.reload()
        gate.open()
        await first.value

        XCTAssertEqual(model.items, new)
    }

    func testRebuildWithoutTheSelectedVoice_selectsTheFirstFromItsFirstFragment() async throws {
        let calls = Calls()
        calls.queues = [[item("a", fragments: 3), item("b", fragments: 2)], [item("b", fragments: 2)]]
        let model = try model(calls)
        await model.open(meetingFilter: nil)
        model.moveFragment(by: 2)

        await model.reload()

        XCTAssertEqual(model.selected?.speakerLabel, "b")
        XCTAssertEqual(model.fragmentIndex, 0)
    }
}
