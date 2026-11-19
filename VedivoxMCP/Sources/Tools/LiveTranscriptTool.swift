import Foundation

/// Live text of the meeting being recorded: the one reading of the app's
/// `live_transcript` answer, shared by `vedivox live` and the MCP tool so the two
/// cannot give different turns for the same question.
package enum LiveTranscript {
    /// Who a turn is said by — a live label, put by a few seconds of voice.
    package struct Speaker: Codable, Equatable, Sendable {
        /// `me` — the microphone; `known` — a confirmed speaker recognised by
        /// voice; `unknown` — a voice without a name, or nobody in particular.
        package let kind: String
        /// `me`, the speaker's name, `Speaker N`, or `others`.
        package let name: String
        /// Similarity to the named speaker's voiceprint; only with `known`.
        package let confidence: Double?

        package init(kind: String, name: String, confidence: Double? = nil) {
            self.kind = kind
            self.name = name
            self.confidence = confidence
        }

        /// An app that has not been relaunched since the update still answers
        /// with the track's label alone, `"me"` or `"others"`.
        package init(from decoder: Decoder) throws {
            if let label = try? decoder.singleValueContainer().decode(String.self) {
                self.init(kind: label == "me" ? "me" : "unknown", name: label)
                return
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                kind: try container.decode(String.self, forKey: .kind),
                name: try container.decode(String.self, forKey: .name),
                confidence: try container.decodeIfPresent(Double.self, forKey: .confidence)
            )
        }
    }

    package struct Turn: Codable, Equatable, Sendable {
        package let speaker: Speaker
        package let track: String
        package let from: Double
        package let to: Double
        package let text: String
    }

    /// The machine output of `vedivox live --json`.
    package struct Document: Encodable, Equatable, Sendable {
        package let meetingId: String
        /// `ready`, `loading` or `unavailable`: why an empty list may be empty.
        package let state: String
        /// Seconds since the recording started.
        package let elapsed: Double
        /// Audio live recognition skipped because it fell behind.
        package let droppedSeconds: Double
        package let turns: [Turn]

        enum CodingKeys: String, CodingKey {
            case meetingId = "meeting_id"
            case state, elapsed
            case droppedSeconds = "dropped_seconds"
            case turns
        }
    }

    package enum Failure: Error, Equatable {
        /// The app answered without the fields of a live transcript.
        case malformed(String)
    }

    /// `90s`, `5m`, `1h` → seconds. A bare number is refused: `5` would be
    /// five seconds to one reader and five minutes to another.
    package static func seconds(fromDuration raw: String) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard let unit = text.last, let scale = ["s": 1.0, "m": 60, "h": 3600][unit],
              let value = Double(text.dropLast()), value.isFinite, value >= 0
        else { return nil }
        return value * scale
    }

    /// `precise`: the app first refines the stretch with a pass of the
    /// regular pipeline — better text and who said it — and answers when done.
    package static func request(lastSeconds: Double?, precise: Bool = false) -> AppCommandRequest {
        var params = lastSeconds.map { ["last": String($0)] } ?? [:]
        if precise { params["precise"] = "1" }
        return AppCommandRequest(command: AppCommandName.liveTranscript, params: params)
    }

    package static func document(from response: AppCommandResponse) throws -> Document {
        guard let data = response.data,
              let meetingId = data["meeting_id"], let state = data["state"],
              let elapsed = data["elapsed"].flatMap(Double.init),
              let turns = data["turns"].flatMap({ try? JSONDecoder().decode([Turn].self, from: Data($0.utf8)) })
        else { throw Failure.malformed("the app did not answer with a live transcript (older Vedivox build?)") }
        return Document(
            meetingId: meetingId, state: state, elapsed: elapsed,
            droppedSeconds: data["dropped_seconds"].flatMap(Double.init) ?? 0, turns: turns
        )
    }

    /// What a person or an agent reads: a header that says how far to trust
    /// the text, then one line per turn.
    package static func render(_ document: Document) -> String {
        var lines = [
            "Live transcript of \(document.meetingId), recording \(formatTimestamp(document.elapsed)). "
                + "Preliminary text, up to ~15 s behind; me = microphone; on the call a name = a confirmed speaker "
                + "recognised by voice, Speaker N = a voice without a name, others = nobody told apart.",
        ]
        switch document.state {
        case "ready": break
        case "loading": lines.append("Live recognition is still loading: no text yet does not mean nobody spoke.")
        default: lines.append("Live recognition is unavailable for this recording.")
        }
        if document.droppedSeconds > 0 {
            lines.append(String(format: "Live recognition fell behind and skipped %.0f s of audio.", document.droppedSeconds))
        }
        if document.turns.isEmpty, document.state == "ready" {
            lines.append("No speech in this stretch.")
        }
        lines += document.turns.map { "[\(formatTimestamp($0.from))] \($0.speaker.name): \($0.text)" }
        return lines.joined(separator: "\n")
    }
}

/// MCP tool: get_live_transcript — what is being said in the meeting recorded right now.
package enum GetLiveTranscriptTool {
    package static let definition: AnyCodable = .object([
        "name": .string("get_live_transcript"),
        "description": .string(
            "Live text of the meeting Vedivox is recording right now: everything said so far, or only the last "
            + "minutes. Use it to answer «what was just asked» during a call. The text is preliminary — "
            + "recognised in windows while the recording runs, up to ~15 s behind; the final transcript "
            + "(get_transcript) appears after the recording stops. Each turn starts with who said it: `me` is the "
            + "microphone; on the call a name is a confirmed speaker recognised by voice, `Speaker N` a voice without "
            + "a name (the same N is the same voice for the whole recording), `others` speech nobody was told apart "
            + "in. The labels are preliminary too and may differ from the final transcript. Fails when nothing is "
            + "being recorded."
        ),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "last": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Only the last stretch of the recording: a number with a unit, e.g. \"90s\", \"5m\", \"1h\". "
                        + "Omit for the whole recording so far."
                    ),
                ]),
                "precise": .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "Refine the last minutes first (up to 10) with the pipeline the final transcript uses: better "
                        + "text, names of recognised speakers, the last words included. Takes a few seconds; without "
                        + "it the answer is immediate, and the last minute or so is quick text without names."
                    ),
                ]),
            ]),
        ]),
    ])

    package static func run(params: [String: AnyCodable]) -> String {
        var lastSeconds: Double?
        if let raw = params["last"]?.value as? String {
            guard let seconds = LiveTranscript.seconds(fromDuration: raw) else {
                return "Error: last must be a number with a unit: 90s, 5m, 1h"
            }
            lastSeconds = seconds
        }
        do {
            let precise = params["precise"]?.value as? Bool ?? false
            guard let response = try AppCommandDispatch.runIfServing(
                LiveTranscript.request(lastSeconds: lastSeconds, precise: precise)
            ) else {
                return "Error: Vedivox is not running; nothing is recording"
            }
            guard response.ok else { return AppCommandDispatch.describe(response) }
            return LiveTranscript.render(try LiveTranscript.document(from: response))
        } catch LiveTranscript.Failure.malformed(let message) {
            return "Error: \(message)"
        } catch {
            return "Error: \(error)"
        }
    }
}
