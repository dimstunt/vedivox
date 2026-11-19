import Foundation

/// The vedivox-mcp protocol: one JSON-RPC line in, at most one line out.
/// Lives in the library so the protocol rules are testable; `main.swift` only loops.
package enum MCPServer {

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    /// The answer to one input line, or nil when JSON-RPC wants silence (a notification).
    package static func reply(to line: Data) -> Data? {
        let request: JSONRPCRequest
        do {
            request = try JSONDecoder().decode(JSONRPCRequest.self, from: line)
        } catch {
            StdioTransport.log("Failed to decode request: \(error)")
            // Only text that is not JSON is a parse error. Valid JSON that is not a
            // request is answered under its own id, so the client's call stops waiting.
            guard let json = try? JSONDecoder().decode(AnyCodable.self, from: line) else {
                return encode(JSONRPCResponse(id: nil, error: JSONRPCErrorDetail(code: -32700, message: "Parse error")))
            }
            let rawId = (json.value as? [String: AnyCodable])?["id"]?.value
            let id = (rawId as? Int).map(RequestId.int) ?? (rawId as? String).map(RequestId.string)
            return encode(JSONRPCResponse(id: id, error: JSONRPCErrorDetail(code: -32600, message: "Invalid Request")))
        }

        StdioTransport.log("Received method: \(request.method)")

        // A request without an id is a notification: it gets no answer and,
        // for tools/call, does not run either.
        guard let id = request.id else { return nil }

        switch request.method {
        case "initialize":
            return encode(JSONRPCResponse(id: id, result: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([
                    "tools": .object([:]),
                ]),
                "serverInfo": .object([
                    "name": .string("vedivox-mcp"),
                    // shortcut: hardcoded, bump with MARKETING_VERSION until one source of truth exists
                    "version": .string("0.5.0"),
                ]),
            ])))
        case "ping":
            return encode(JSONRPCResponse(id: id, result: .object([:])))
        case "tools/list":
            return encode(JSONRPCResponse(id: id, result: .object(["tools": .array(tools.map(\.definition))])))
        case "tools/call":
            guard let name = request.params?["name"]?.value as? String else {
                return encode(JSONRPCResponse(id: id, error: JSONRPCErrorDetail(code: -32602, message: "Missing tool name")))
            }
            let arguments = request.params?["arguments"]?.value as? [String: AnyCodable] ?? [:]
            return encode(JSONRPCResponse(id: id, result: callTool(name: name, arguments: arguments)))
        default:
            return encode(JSONRPCResponse(
                id: id, error: JSONRPCErrorDetail(code: -32601, message: "Unknown method: \(request.method)")
            ))
        }
    }

    private typealias Run = @Sendable ([String: AnyCodable]) throws -> String

    /// The one tool registry: `tools/list` order and `tools/call` routing.
    /// Reading tools open the database themselves: on a Mac where Vedivox never
    /// ran there is none yet, and an import must still work.
    private static let tools: [(definition: AnyCodable, run: Run)] = [
        (ListMeetingsTool.definition, { try ListMeetingsTool.run(params: $0, db: DatabaseReader()) }),
        (GetMeetingTool.definition, { try GetMeetingTool.run(params: $0, db: DatabaseReader()) }),
        (GetTranscriptTool.definition, { try GetTranscriptTool.run(params: $0, db: DatabaseReader()) }),
        (ListSpeakersTool.definition, { try ListSpeakersTool.run(params: $0, db: DatabaseReader()) }),
        (SearchTranscriptsTool.definition, { try SearchTranscriptsTool.run(params: $0, db: DatabaseReader()) }),
        (UpdateMeetingTool.definition, UpdateMeetingTool.run),
        (UpdateSpeakerTool.definition, UpdateSpeakerTool.run),
        (MergeSpeakersTool.definition, MergeSpeakersTool.run),
        (ReprocessMeetingTool.definition, { try ReprocessMeetingTool.run(params: $0, db: DatabaseReader()) }),
        (MeetingEditTools.splitDefinition, { try MeetingEditTools.split(params: $0, db: DatabaseReader()) }),
        (MeetingEditTools.trimDefinition, { try MeetingEditTools.trim(params: $0, db: DatabaseReader()) }),
        (MeetingEditTools.mergeDefinition, { try MeetingEditTools.merge(params: $0, db: DatabaseReader()) }),
        (MeetingEditTools.undoDefinition, { try MeetingEditTools.undo(params: $0, db: DatabaseReader()) }),
        (ImportFileTool.definition, ImportFileTool.run),
        (ImportYouTubeTool.definition, ImportYouTubeTool.run),
        (UpdateSegmentTool.definition, UpdateSegmentTool.run),
        (ListSeriesTool.definition, { try ListSeriesTool.run(params: $0, db: DatabaseReader()) }),
        (CreateSeriesTool.definition, CreateSeriesTool.run),
        (MarkExcludedTool.definition, MarkExcludedTool.run),
        (UnmarkTool.definition, UnmarkTool.run),
        (ListMarksTool.definition, { try ListMarksTool.run(params: $0, db: DatabaseReader()) }),
        (GetLiveTranscriptTool.definition, { GetLiveTranscriptTool.run(params: $0) }),
    ]

    private static func callTool(name: String, arguments: [String: AnyCodable]) -> AnyCodable {
        guard let tool = tools.first(where: { ($0.definition.value as? [String: AnyCodable])?["name"]?.value as? String == name }) else {
            return content("Unknown tool: \(name)", isError: true)
        }
        do {
            return content(try tool.run(arguments))
        } catch {
            return content("Error: \(error)", isError: true)
        }
    }

    /// Wraps a text string in the MCP content response format.
    private static func content(_ text: String, isError: Bool = false) -> AnyCodable {
        var obj: [String: AnyCodable] = [
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
        ]
        if isError { obj["isError"] = .bool(true) }
        return .object(obj)
    }

    private static func encode(_ response: JSONRPCResponse) -> Data? {
        do {
            return try encoder.encode(response)
        } catch {
            StdioTransport.log("Error encoding response: \(error)")
            return nil
        }
    }
}
