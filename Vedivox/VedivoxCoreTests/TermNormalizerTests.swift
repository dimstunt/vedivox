import XCTest

/// Tests for the model-free transcript post-processing pass.
///
/// Two behaviours are covered: restoring the letter «ё» that Parakeet cannot
/// emit, and rewriting transliterated technical terms to canonical spelling.
///
/// The false-positive tests matter more than the happy path. Running
/// FluidAudio's own CTC vocabulary boosting with Cyrillic aliases destroyed the
/// transcript — «рабочее» and «графики» became dictionary terms — because its
/// acoustic guard degenerates on Cyrillic and its 0.50–0.60 threshold is far too
/// loose. Those exact cases are pinned below.
final class TermNormalizerTests: XCTestCase {

    /// A working vocabulary of neutral, widely used terms. Aliases that
    /// collide with ordinary words (скринов → screenshot, a short alias one
    /// edit away from a common word) are deliberately absent. The seed of a
    /// new user's file carries no live terms, so the tests bring their own.
    private let vocabulary = TermNormalizer.Vocabulary.parse("""
        # Docker — короткий термин, поэтому падежи перечислены явно: на словах
        # в 6 букв и меньше действует строгий порог 0.92, и «докере» до «докер»
        # не дотягивается (0.83). Почти столько же даёт «покер» → «докер»
        # (0.80), так что послабление порога переписало бы обычную речь.
        Docker: докер, докера, докеру, докере, докером

        GitHub: гитхаб, гитхап, гидхаб
        dashboard: дашборд, дэшборд, дажборд
        milestone: майлстоун, малстоун, майлстон, мейлстоун
        deliverable: деливрабл, деливерабл, деливраблы
        backlog: бэклог, бэклок
        screenshot: скриншот
        Kubernetes: кубернетес, кубернетис
        PostgreSQL: постгрес, постгре
        """)

    /// A new user's file must not rewrite anything until they add a term.
    func testSeedFileHasNoLiveTerms() {
        XCTAssertTrue(TermNormalizer.Vocabulary.parse(TermNormalizer.seedContents).terms.isEmpty)
        XCTAssertEqual(
            TermNormalizer.normalize("докер и скриншоты", vocabulary: .parse(TermNormalizer.seedContents)),
            "докер и скриншоты"
        )
    }

    // MARK: - «ё» restoration

    /// Strings shaped like Parakeet output — it has no «ё» token, so
    /// it emits `<unk>` (token id 0) instead.
    func testRestoresYoInTranscripts() {
        let cases = [
            ("Вс<unk>, договорились, ладно.", "Всё, договорились, ладно."),
            ("есть ещ<unk> один вопрос", "есть ещё один вопрос"),
            ("ч<unk> там с релизом?", "чё там с релизом?"),
            ("В том, что не самол<unk>ты.", "В том, что не самолёты."),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(TermNormalizer.restoreYo(in: input), expected)
        }
    }

    func testCapitalizesYoAtSentenceStart() {
        XCTAssertEqual(TermNormalizer.restoreYo(in: "<unk>лка"), "Ёлка")
        XCTAssertEqual(TermNormalizer.restoreYo(in: "Да. <unk>лка"), "Да. Ёлка")
        XCTAssertEqual(TermNormalizer.restoreYo(in: "вс<unk> тут"), "всё тут")
    }

    /// #3: «ё» is a Russian letter — `<unk>` inside a Latin word is something else.
    func testLeavesUnkOutsideCyrillicWords() {
        XCTAssertEqual(TermNormalizer.restoreYo(in: "caf<unk> au lait"), "caf<unk> au lait")
        XCTAssertEqual(TermNormalizer.restoreYo(in: "<unk>cole, вс<unk>"), "<unk>cole, всё")
    }

    func testLeavesTextWithoutUnkUntouched() {
        let text = "Обычный текст без токенов."
        XCTAssertEqual(TermNormalizer.restoreYo(in: text), text)
    }

    // MARK: - Vocabulary parsing

    func testParsesCanonicalAndAliases() {
        let vocab = TermNormalizer.Vocabulary.parse(
            """
            # комментарий
            dashboard: дашборд, дэшборд
            Docker

            """
        )
        XCTAssertEqual(vocab.terms.count, 2)
        XCTAssertEqual(vocab.terms[0].canonical, "dashboard")
        XCTAssertEqual(vocab.terms[0].forms.count, 3) // канон + два алиаса
        XCTAssertEqual(vocab.terms[1].canonical, "Docker")
        XCTAssertEqual(vocab.terms[1].forms.count, 1)
    }

    func testSeedVocabularyParses() {
        XCTAssertFalse(vocabulary.isEmpty)
        XCTAssertTrue(vocabulary.terms.contains { $0.canonical == "GitHub" })
    }

    // MARK: - Term replacement

    func testRewritesTransliteratedTerms() {
        let cases = [
            ("дашборд", "dashboard"),
            ("докер", "Docker"),
            ("докере", "Docker"),
            ("гитхаб", "GitHub"),
            ("майлстоун", "milestone"),
            ("бэклог", "backlog"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(
                TermNormalizer.bestReplacement(for: input, vocabulary: vocabulary),
                expected,
                "«\(input)» должно стать \(expected)"
            )
        }
    }

    /// Fuzzy matching is what absorbs Russian case endings, so declined forms
    /// need no separate dictionary entries.
    func testAbsorbsRussianMorphology() {
        for form in ["дашборды", "дашборда", "дашборду", "дашборде"] {
            XCTAssertEqual(
                TermNormalizer.bestReplacement(for: form, vocabulary: vocabulary),
                "dashboard",
                "склонение «\(form)» должно подтянуться к dashboard"
            )
        }
    }

    func testLeavesCanonicalSpellingAlone() {
        for word in ["dashboard", "Docker", "GitHub"] {
            XCTAssertNil(TermNormalizer.bestReplacement(for: word, vocabulary: vocabulary))
        }
    }

    // MARK: - False positives (regressions against FluidAudio's behaviour)

    /// Exactly the substitutions FluidAudio's boosting produced on a real
    /// 3-minute fragment. None of them may happen here.
    func testDoesNotRewriteOrdinaryRussianWords() {
        let mustSurvive = [
            "рабочее", "задачи", "задачу", "задачки", "графики", "графике",
            "сейчас", "значит", "проект", "доску", "конечно",
            "прод", "релиз", "баг", "стейдж", "деплой", "ревью",
        ]
        for word in mustSurvive {
            XCTAssertNil(
                TermNormalizer.bestReplacement(for: word, vocabulary: vocabulary),
                "«\(word)» — обычная речь, трогать нельзя"
            )
        }
    }

    /// «покер» is one edit away from the Docker alias «докер» (0.80), which is
    /// why short words get a much stricter threshold. «стена» and «арена» are
    /// the same case against a user's own short alias («атена»).
    func testShortWordsUseStricterThreshold() {
        XCTAssertNil(TermNormalizer.bestReplacement(for: "покер", vocabulary: vocabulary))
        let withShortAlias = TermNormalizer.Vocabulary.parse("Term: атена")
        XCTAssertNil(TermNormalizer.bestReplacement(for: "стена", vocabulary: withShortAlias))
        XCTAssertNil(TermNormalizer.bestReplacement(for: "арена", vocabulary: withShortAlias))
        XCTAssertNil(TermNormalizer.bestReplacement(for: "стена", vocabulary: vocabulary))
        XCTAssertNil(TermNormalizer.bestReplacement(for: "арена", vocabulary: vocabulary))
    }

    func testIgnoresVeryShortWords() {
        for word in ["код", "да", "их"] {
            XCTAssertNil(TermNormalizer.bestReplacement(for: word, vocabulary: vocabulary))
        }
    }

    // MARK: - Similarity arithmetic

    /// Pins the reason CTC boosting cannot fix transliteration: across scripts
    /// the strings share no characters at all.
    func testCrossScriptSimilarityIsZero() {
        XCTAssertEqual(TermNormalizer.similarity("малстоуны", "milestones"), 0.0)
        XCTAssertEqual(TermNormalizer.similarity("дашборд", "dashboard"), 0.0)
    }

    func testWithinScriptSimilarityIsUsable() {
        XCTAssertEqual(TermNormalizer.similarity("малстоунов", "малстоун"), 0.8, accuracy: 0.001)
        XCTAssertEqual(TermNormalizer.similarity("metabas", "metabase"), 0.875, accuracy: 0.001)
    }

    // MARK: - Sentence-level normalization

    func testNormalizesWholeSentencePreservingPunctuation() {
        let input = "Вот дашборд, а там ещё дашборд. А в докере график."
        let output = TermNormalizer.normalize(input, vocabulary: vocabulary)
        XCTAssertEqual(output, "Вот dashboard, а там ещё dashboard. А в Docker график.")
    }

    func testCombinesYoFixAndTermRewrite() {
        let output = TermNormalizer.normalize("Вс<unk> в дашборде", vocabulary: vocabulary)
        XCTAssertEqual(output, "Всё в dashboard")
    }

    func testEmptyVocabularyStillFixesYo() {
        let output = TermNormalizer.normalize("вс<unk> тут", vocabulary: .empty)
        XCTAssertEqual(output, "всё тут")
    }

    // MARK: - Segment application

    func testApplyStoresOriginalTextAndLeavesEditedFlag() {
        let segment = TranscriptSegment(
            meetingId: "m1",
            speakerLabel: "S1",
            source: .mic,
            startTime: 0,
            endTime: 1,
            text: "открой дашборд"
        )
        let result = TermNormalizer.apply(to: [segment], vocabulary: vocabulary)

        XCTAssertEqual(result[0].text, "открой dashboard")
        XCTAssertEqual(result[0].originalText, "открой дашборд")
        XCTAssertFalse(result[0].isEdited, "автозамена — не ручная правка")
    }

    func testApplyLeavesUnchangedSegmentsIdentical() {
        let segment = TranscriptSegment(
            meetingId: "m1",
            speakerLabel: "S1",
            source: .mic,
            startTime: 0,
            endTime: 1,
            text: "обычный текст"
        )
        let result = TermNormalizer.apply(to: [segment], vocabulary: vocabulary)

        XCTAssertEqual(result[0].text, "обычный текст")
        XCTAssertNil(result[0].originalText, "нечего откатывать — поле не трогаем")
    }

    /// A hand edit must not be clobbered by a later automatic pass.
    func testApplyPreservesExistingOriginalText() {
        var segment = TranscriptSegment(
            meetingId: "m1",
            speakerLabel: "S1",
            source: .mic,
            startTime: 0,
            endTime: 1,
            text: "открой дашборд"
        )
        segment.originalText = "исходная расшифровка"
        segment.isEdited = true

        let result = TermNormalizer.apply(to: [segment], vocabulary: vocabulary)
        XCTAssertEqual(result[0].originalText, "исходная расшифровка")
        XCTAssertTrue(result[0].isEdited)
    }

    // MARK: - Idempotency

    /// A safety net, not the primary defence. The live draft is architecturally
    /// protected instead: normalization runs only over the unconfirmed tail, and
    /// confirmed text is normalized once at commit time and never again — so a
    /// second pass over the same word cannot happen by construction. These tests
    /// exist so that if that structure is ever undone, the failure surfaces here
    /// rather than as words mangling themselves on screen.

    /// The whole point: running the pass over its own output must change nothing.
    func testNormalizingTwiceChangesNothing() {
        let inputs = [
            "открыл дашборд и посмотрел гитхаб",
            "Вс<unk> в докеру, скриншот не нужен",
            "поставил майлстоун и деливрабл в бэклог",
            "докер, кубернетес, гитхаб, постгрес",
            "обычная речь без единого термина",
        ]

        for input in inputs {
            let once = TermNormalizer.normalize(input, vocabulary: vocabulary)
            let twice = TermNormalizer.normalize(once, vocabulary: vocabulary)
            XCTAssertEqual(twice, once, "второй проход изменил «\(once)»")
        }
    }

    /// Every canonical spelling has to be a fixed point of the pass.
    func testCanonicalSpellingsAreLeftAlone() {
        let canonical = """
            Docker GitHub dashboard milestone deliverable \
            backlog screenshot Kubernetes PostgreSQL
            """
        XCTAssertEqual(TermNormalizer.normalize(canonical, vocabulary: vocabulary), canonical)
    }

    /// The case the early return in `bestReplacement` exists for: a canonical
    /// form one edit away from its own alias. Without that guard the canonical
    /// matches its alias list and gets "corrected" to itself — and with two
    /// aliases scoring differently it could settle on the other spelling instead.
    ///
    /// The seed vocabulary cannot reach this state (canonicals are Latin,
    /// aliases Cyrillic, so their similarity is 0), which is exactly why the case
    /// needs a vocabulary of its own.
    func testCanonicalIsNotPulledBackToItsOwnAlias() {
        let vocabulary = TermNormalizer.Vocabulary(terms: [
            TermNormalizer.Term(canonical: "milestone", aliases: ["mileston", "milestoun"]),
        ])

        XCTAssertEqual(TermNormalizer.normalize("milestone", vocabulary: vocabulary), "milestone")
        // And the alias still resolves — the guard must not disable the rewrite.
        XCTAssertEqual(TermNormalizer.normalize("mileston", vocabulary: vocabulary), "milestone")
    }

    /// «ё» restoration has to survive re-running too: it is the first half of
    /// every pass, and the draft path re-enters it on each update.
    func testYoRestorationIsIdempotent() {
        let restored = TermNormalizer.restoreYo(in: "Вс<unk>, ещ<unk> раз")

        XCTAssertEqual(restored, "Всё, ещё раз")
        XCTAssertEqual(TermNormalizer.restoreYo(in: restored), restored)
    }
}
