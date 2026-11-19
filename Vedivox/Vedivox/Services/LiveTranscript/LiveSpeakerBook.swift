import Foundation

/// What a turn of live text is labelled with.
struct LiveSpeaker: Equatable, Sendable {
    enum Kind: String, Sendable {
        case me, known, unknown
    }

    let kind: Kind
    let name: String
    /// Similarity of the voice to the named speaker's voiceprint; nil where
    /// no name is claimed.
    var confidence: Float?

    static let me = LiveSpeaker(kind: .me, name: "me")
    /// System audio nobody has been told apart in.
    static let others = LiveSpeaker(kind: .unknown, name: "others")
}

/// Who is who on the call track of a running recording, from one precise pass
/// to the next.
///
/// Every pass numbers its own clusters; a reader needs the same «Speaker 2»
/// for the whole recording. The book is given the voice of each cluster of a
/// pass and answers with a key that stays the same for that voice. What the
/// key reads as — a name or «Speaker N» — is asked separately, at reading
/// time: a voice a later pass recognises renames everything it said before.
///
/// Pure: no model, no audio, no database.
struct LiveSpeakerBook: Sendable {
    struct Config: Sendable {
        /// A voice joins the nearest key at this cosine similarity or above.
        /// Cluster centroids of one person from two passes sit far above it,
        /// of two people below (design D9).
        var joinThreshold: Float = 0.5
        /// A voice with less speech behind it than this is not trusted at all.
        var minVoiceSeconds: Double = 1
        /// …and with less than this it may join a key but not start one: a
        /// stray «угу» must not become a «Speaker N».
        var minNewVoiceSeconds: Double = 2
    }

    /// A confirmed speaker a pass recognised a voice as.
    struct Identity: Equatable, Sendable {
        let speakerId: String
        let name: String
        var confidence: Float
    }

    private struct Cluster {
        /// «Speaker N», by order of appearance; never reused.
        let number: Int
        /// Seconds-weighted sum of unit vectors: its direction is the centroid.
        var sum: [Float]
        var identity: Identity?
    }

    let config: Config
    private var clusters: [Cluster] = []

    init(config: Config = Config()) {
        self.config = config
    }

    /// Takes one voice of a pass — the vector of its cluster and the seconds
    /// of speech behind it — and returns the key of the speaker it belongs
    /// to, or nil when the voice is too thin to say.
    ///
    /// `identity`: who the pass recognised the voice as. A named voice goes
    /// to its speaker's key whatever the vectors say, and never into the key
    /// of somebody else; the name it brings sticks.
    mutating func assign(voice: [Float], seconds: Double, identity: Identity? = nil) -> Int? {
        guard seconds >= config.minVoiceSeconds, let unit = Self.unit(voice) else { return nil }
        // Vectors of another size are kept apart, not compared: a mismatch
        // would trip `cosineSimilarity`'s precondition mid-recording.
        let comparable = clusters.indices.filter { clusters[$0].sum.count == unit.count }
        let own = identity.flatMap { given in comparable.first { clusters[$0].identity?.speakerId == given.speakerId } }
        let nearest = comparable
            // A voice with a name joins nobody else's.
            .filter { identity == nil || clusters[$0].identity == nil }
            .map { (index: $0, similarity: cosineSimilarity(unit, clusters[$0].sum)) }
            .max { $0.similarity < $1.similarity }

        let index: Int
        if let joined = own ?? nearest.flatMap({ $0.similarity >= config.joinThreshold ? $0.index : nil }) {
            index = joined
            for i in unit.indices { clusters[index].sum[i] += Float(seconds) * unit[i] }
        } else if seconds >= config.minNewVoiceSeconds || identity != nil {
            index = clusters.count
            clusters.append(Cluster(number: index + 1, sum: unit.map { Float(seconds) * $0 }))
        } else {
            return nil
        }
        if let identity { clusters[index].identity = identity }
        return index
    }

    /// The label of every key given out so far, indexed by key.
    var speakers: [LiveSpeaker] {
        clusters.map { cluster in
            cluster.identity.map { LiveSpeaker(kind: .known, name: $0.name, confidence: $0.confidence) }
                ?? LiveSpeaker(kind: .unknown, name: "Speaker \(cluster.number)")
        }
    }

    private static func unit(_ vector: [Float]) -> [Float]? {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        return vector.map { $0 / norm }
    }
}
