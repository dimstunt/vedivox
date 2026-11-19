import Foundation

/// Post-processing for ASR output: restores the letter «ё» and rewrites
/// transliterated technical terms back to their canonical spelling.
///
/// Two independent fixes, both cheap and model-free.
///
/// **1. The «ё» fix.** Parakeet TDT v3's vocabulary has 8192 tokens, 1161 of
/// them containing Cyrillic — and not a single one contains «ё». Even the rare
/// hard sign «ъ» is there (28 tokens); «ё» is not. So every «ё» the model hears
/// falls into token id 0, which is `<unk>`, and that literal leaks into the
/// transcript: `Вс<unk>` for «Всё», `ещ<unk>` for «ещё», `ч<unk>` for «чё».
/// Measured on the production database: 126 literal `<unk>` occurrences and
/// **zero** «ё» across 109 310 segments / 4 million characters.
///
/// **2. Term normalization.** The same model transliterates English technical
/// terms into Cyrillic: «дашборд» for dashboard, «гитхаб» for GitHub, «майлстоун»
/// for milestone. Measured over the production corpus, several terms come out
/// latin **0 %** of the time (dashboard 0/84, milestone 0/28).
///
/// FluidAudio ships CTC vocabulary boosting that looks like it should fix this,
/// but it does not: its candidate matching is plain Levenshtein over normalized
/// strings, so `similarity("малстоуны", "milestones") == 0` and the candidate is
/// rejected before any acoustic check runs. Adding Cyrillic aliases to *its*
/// dictionary makes matters far worse — verified by running it — because the
/// acoustic guard degenerates (Cyrillic tokenizes to `<unk>`, scoring −inf, so
/// "replace" always wins) and unrelated Russian words get overwritten with
/// dictionary terms («рабочее», «графики»). Hence this local, auditable pass instead.
enum TermNormalizer {

    // MARK: - Vocabulary

    /// One canonical term plus the misspellings that should collapse into it.
    struct Term: Sendable, Equatable {
        let canonical: String
        /// Normalized match forms — the canonical spelling and every alias.
        let forms: [String]

        init(canonical: String, aliases: [String]) {
            self.canonical = canonical
            forms = ([canonical] + aliases).map(TermNormalizer.normalizeForMatching)
        }
    }

    struct Vocabulary: Sendable, Equatable {
        let terms: [Term]

        static let empty = Vocabulary(terms: [])
        var isEmpty: Bool { terms.isEmpty }

        /// Parses the on-disk format: one term per line, `#` starts a comment,
        /// aliases follow a colon and are comma-separated.
        ///
        ///     milestone: майлстоун, малстоун
        ///     dashboard: дашборд
        static func parse(_ contents: String) -> Vocabulary {
            var terms: [Term] = []
            for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#") else { continue }

                let parts = line.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard let canonical = parts.first, !canonical.isEmpty else { continue }

                let aliases: [String]
                if parts.count > 1 {
                    aliases = parts[1]
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                } else {
                    aliases = []
                }
                terms.append(Term(canonical: canonical, aliases: aliases))
            }
            return Vocabulary(terms: terms)
        }

        static func load(from url: URL) -> Vocabulary {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                return .empty
            }
            return parse(contents)
        }
    }

    // MARK: - On-disk vocabulary

    /// `~/Library/Application Support/Vedivox/vocabulary/terms.txt`
    ///
    /// A plain file rather than a table: `DatabaseManager` runs with
    /// `eraseDatabaseOnSchemaChange` in DEBUG, which would wipe a hand-curated
    /// word list on every schema tweak. A file also stays editable in any
    /// editor and diffable in git.
    static var vocabularyDirectory: URL { DataDirectory.vocabulary }

    static var vocabularyURL: URL {
        vocabularyDirectory.appendingPathComponent("terms.txt")
    }

    /// Loads the user's vocabulary, seeding the file on first run.
    static func loadVocabulary() -> Vocabulary {
        let url = vocabularyURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(
                at: vocabularyDirectory, withIntermediateDirectories: true
            )
            try? seedContents.write(to: url, atomically: true, encoding: .utf8)
        }
        return Vocabulary.load(from: url)
    }

    /// What a new user's file starts as: instructions and examples that are
    /// commented out. Live entries apply to every transcript and to dictated
    /// text pasted into other apps, so a term the user did not choose rewrote
    /// their speech until they found the file.
    static let seedContents = """
        # Vedivox term vocabulary — fixes how terms and names are spelled in
        # transcripts and in dictation.
        #
        # Format:  canonical: alias1, alias2
        # Lines starting with # are ignored. Aliases are optional.
        #
        # Matching is fuzzy, so word forms need not be listed: «дашборды» is
        # pulled to the alias «дашборд» by itself. Short words are the
        # exception (6 letters or fewer are matched strictly): list their
        # forms one by one, as Docker does below.
        #
        # Careful with short and frequent words: an alias that looks like an
        # ordinary word rewrites normal speech. Do not add «прод», «релиз», «баг».
        #
        # Examples — remove the leading "# " to switch one on:
        #
        # Docker: докер, докера, докеру, докере, докером
        # GitHub: гитхаб, гитхап, гидхаб
        # dashboard: дашборд, дэшборд
        # Kubernetes: кубернетес, кубернетис
        # PostgreSQL: постгрес, постгре

        """

    // MARK: - Thresholds

    /// Minimum similarity for a replacement. Deliberately stricter than
    /// FluidAudio's 0.50–0.60: there is no acoustic verification here, so the
    /// string threshold is the only guard.
    static let similarityThreshold: Float = 0.80

    /// Short words are far likelier to collide with ordinary Russian — at 0.80
    /// «покер» matches the Docker alias «докер» (one edit out of five). Words
    /// this short must match nearly exactly.
    static let shortWordLength = 6
    static let shortWordThreshold: Float = 0.92

    /// Words shorter than this are never considered.
    static let minimumWordLength = 4

    /// Common Russian words that are never technical terms. Without this,
    /// single-edit neighbours of an alias get rewritten.
    static let protectedWords: Set<String> = [
        "стена", "стены", "стене", "арена", "антенна", "работа", "рабочее",
        "задача", "задачи", "задачу", "график", "графики", "графике",
        "сейчас", "значит", "конечно", "сергей", "елена", "алена", "афины",
        "машина", "причина", "картина", "команда", "минута", "минуты",
    ]

    // MARK: - Public API

    /// Applies both fixes to a segment list, preserving the pre-normalization
    /// text in `originalText` so the change stays reversible.
    ///
    /// `isEdited` is deliberately left alone: it drives the "edited by hand"
    /// badge in the transcript UI, and an automatic rewrite is not a hand edit.
    static func apply(
        to segments: [TranscriptSegment],
        vocabulary: Vocabulary
    ) -> [TranscriptSegment] {
        segments.map { segment in
            let rewritten = normalize(segment.text, vocabulary: vocabulary)
            guard rewritten != segment.text else { return segment }

            var updated = segment
            if updated.originalText == nil {
                updated.originalText = segment.text
            }
            updated.text = rewritten
            return updated
        }
    }

    /// Runs the «ё» restoration followed by vocabulary normalization.
    static func normalize(_ text: String, vocabulary: Vocabulary) -> String {
        let withYo = restoreYo(in: text)
        guard !vocabulary.isEmpty else { return withYo }
        return normalizeTerms(in: withYo, vocabulary: vocabulary)
    }

    // MARK: - «ё» restoration

    /// Replaces the literal `<unk>` token with «ё».
    ///
    /// Capitalization is inferred from position: `<unk>` opening a sentence
    /// becomes «Ё», everywhere else «ё». In practice the model emits it
    /// mid-word («Вс<unk>», «ещ<unk>»), where lowercase is always right.
    ///
    /// **This is the whole of it, deliberately.** The model does not always emit
    /// `<unk>` where «ё» belongs — it sometimes emits a plain «е», and «еще»,
    /// «Че», «Все» come out of a dictation unfixed. Going further would mean a
    /// dictionary of words whose «ё»-less spelling is never valid, and the user
    /// decided against it (2026-08-10): the gain is cosmetic and the risk is
    /// not, because «все» and «всё» are different words and a rewrite would
    /// change meaning. Do not «finish» this by adding fuzzy ёфикация.
    static func restoreYo(in text: String) -> String {
        guard text.contains("<unk>") else { return text }

        var result = ""
        result.reserveCapacity(text.count)
        var remainder = Substring(text)

        while let range = remainder.range(of: "<unk>") {
            result += remainder[remainder.startIndex ..< range.lowerBound]
            let after = remainder[range.upperBound...].first
            // Only inside a Russian word: the model emits `<unk>` for other
            // letters it lacks too (#3).
            if isCyrillic(result.last) || isCyrillic(after) {
                result.append(startsSentence(result) ? "Ё" : "ё")
            } else {
                result += "<unk>"
            }
            remainder = remainder[range.upperBound...]
        }
        result += remainder
        return result
    }

    private static func isCyrillic(_ character: Character?) -> Bool {
        character?.unicodeScalars.first.map { (0x0400 ... 0x04FF).contains($0.value) } ?? false
    }

    /// True when the text so far ends at a sentence boundary.
    private static func startsSentence(_ textSoFar: String) -> Bool {
        for character in textSoFar.reversed() {
            if character.isWhitespace { continue }
            return character == "." || character == "!" || character == "?"
        }
        return true // nothing before it — start of the segment
    }

    // MARK: - Term normalization

    private static func normalizeTerms(in text: String, vocabulary: Vocabulary) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var word = ""

        func flushWord() {
            guard !word.isEmpty else { return }
            result += bestReplacement(for: word, vocabulary: vocabulary) ?? word
            word = ""
        }

        for character in text {
            if character.isLetter || character.isNumber {
                word.append(character)
            } else {
                flushWord()
                result.append(character)
            }
        }
        flushWord()
        return result
    }

    /// Returns the canonical spelling when `word` is a close enough match to one
    /// of the vocabulary forms, otherwise nil.
    static func bestReplacement(for word: String, vocabulary: Vocabulary) -> String? {
        let normalized = normalizeForMatching(word)
        guard normalized.count >= minimumWordLength else { return nil }
        guard !protectedWords.contains(normalized) else { return nil }

        let threshold = normalized.count <= shortWordLength
            ? shortWordThreshold
            : similarityThreshold

        var best: (canonical: String, score: Float)?
        for term in vocabulary.terms {
            // Already spelled canonically — nothing to do.
            if normalized == normalizeForMatching(term.canonical) { return nil }
            for form in term.forms {
                let score = similarity(normalized, form)
                guard score >= threshold else { continue }
                if best == nil || score > best!.score {
                    best = (term.canonical, score)
                }
            }
        }
        return best?.canonical
    }

    // MARK: - String similarity

    /// Letters and digits only, lowercased.
    static func normalizeForMatching(_ word: String) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// `1 - distance / max(len)`, the same shape FluidAudio uses.
    static func similarity(_ lhs: String, _ rhs: String) -> Float {
        if lhs == rhs { return 1.0 }
        if lhs.isEmpty || rhs.isEmpty { return 0.0 }
        let distance = levenshtein(Array(lhs), Array(rhs))
        return 1.0 - Float(distance) / Float(max(lhs.count, rhs.count))
    }

    static func levenshtein(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }

        var previous = Array(0 ... rhs.count)
        var current = [Int](repeating: 0, count: rhs.count + 1)

        for i in 1 ... lhs.count {
            current[0] = i
            for j in 1 ... rhs.count {
                let substitution = previous[j - 1] + (lhs[i - 1] == rhs[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }
}
