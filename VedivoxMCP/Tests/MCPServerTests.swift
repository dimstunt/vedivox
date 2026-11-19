import Foundation
import Testing
@testable import VedivoxMCPLib

@Suite("vedivox-mcp protocol", .serialized)
struct MCPServerTests {
    private func reply(_ json: String) -> String? {
        MCPServer.reply(to: Data(json.utf8)).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test("ping gets an empty result")
    func ping() {
        #expect(reply(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#) == #"{"id":7,"jsonrpc":"2.0","result":{}}"#)
    }

    @Test("a notification gets no answer, and a tools/call notification does not run")
    func notification() throws {
        let captured = CapturedCommand()
        let answer = try withStubbedApp(capturing: captured) {
            reply(#"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"create_series","arguments":{"name":"X"}}}"#)
        }
        #expect(answer == nil)
        #expect(captured.value == nil)
        #expect(reply(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    }

    @Test("a line that is not JSON is answered with id null")
    func parseError() {
        #expect(reply("{oops") == #"{"error":{"code":-32700,"message":"Parse error"},"id":null,"jsonrpc":"2.0"}"#)
    }

    private func invalidRequest(id: String) -> String {
        #"{"error":{"code":-32600,"message":"Invalid Request"},"id":\#(id),"jsonrpc":"2.0"}"#
    }

    @Test("valid JSON that is not a request is -32600 under the request's own id")
    func invalidRequestKeepsTheId() {
        #expect(reply(#"{"jsonrpc":"2.0","id":5}"#) == invalidRequest(id: "5"))
        #expect(reply(#"{"jsonrpc":"2.0","id":"a","method":7}"#) == invalidRequest(id: #""a""#))
        #expect(reply("[1,2]") == invalidRequest(id: "null"))
    }

    /// MCP forbids a null id; read as "no id" it made a request a silent
    /// notification and the client waited for an answer forever.
    @Test("a request with a null id is answered -32600 and does not run")
    func nullId() throws {
        let captured = CapturedCommand()
        let answer = try withStubbedApp(capturing: captured) {
            reply(#"{"jsonrpc":"2.0","id":null,"method":"tools/call","params":{"name":"create_series","arguments":{"name":"X"}}}"#)
        }
        #expect(answer == invalidRequest(id: "null"))
        #expect(captured.value == nil)
    }

    @Test("an unknown method with an id is -32601")
    func unknownMethod() {
        #expect(reply(#"{"jsonrpc":"2.0","id":"a","method":"nope"}"#)?.contains(#""code":-32601"#) == true)
    }

    /// On a Mac where Vedivox never ran there is no Vedivox.sqlite: import must still
    /// reach the app, and a reading tool says the database is missing.
    @Test("import_file works without a database; list_meetings reports it missing")
    func noDatabase() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("vedivox-nodb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let media = empty.appendingPathComponent("talk.mp3")
        try Data().write(to: media)
        defer { try? FileManager.default.removeItem(at: empty) }

        let saved = ProcessInfo.processInfo.environment[VedivoxDataDirectory.environmentKey]
        setenv(VedivoxDataDirectory.environmentKey, empty.path, 1)
        defer {
            if let saved {
                setenv(VedivoxDataDirectory.environmentKey, saved, 1)
            } else {
                unsetenv(VedivoxDataDirectory.environmentKey)
            }
        }

        let captured = CapturedCommand()
        let imported = try withStubbedApp(capturing: captured) {
            reply(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"import_file","arguments":{"file_path":"\#(media.path)"}}}"#)
        }
        #expect(captured.params["path"] == media.path)
        #expect(imported?.contains("isError") == false)

        let listed = reply(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_meetings","arguments":{}}}"#)
        #expect(listed?.contains("Vedivox database not found") == true)
        #expect(listed?.contains(#""isError":true"#) == true)
    }
}

@Suite("MCP numeric arguments", .serialized)
struct MCPNumericArgumentTests {
    /// A JSON number that is not an exact Int64 used to crash vedivox-mcp (1e20)
    /// or quietly hit another row (4.7 → 4); now it is refused before the app.
    @Test("segment_id and mark_id refuse a fractional or out-of-range number")
    func inexactIds() throws {
        let captured = CapturedCommand()
        for bad in [1e20, 4.7] {
            let segment = try withStubbedApp(capturing: captured) {
                try UpdateSegmentTool.run(params: ["segment_id": .double(bad), "speaker_id": .string("S1")])
            }
            #expect(segment.hasPrefix("Error: segment_id"))
            _ = try withStubbedApp(capturing: captured) {
                try UnmarkTool.run(params: ["meeting_id": .string("M1"), "mark_id": .double(bad)])
            }
            #expect(captured.params["mark_id"] == nil)
        }
        #expect(captured.value?.command != AppCommandName.updateSegment)
    }

    @Test("a negative limit is one row, not every row")
    func negativeLimit() throws {
        let db = try makeTestDB()
        for title in ["a", "b", "c"] { _ = try insertMeeting(db: db, title: title, status: "done") }
        let listed = try ListMeetingsTool.run(params: ["limit": .int(-1)], db: db)
        #expect(listed.contains("1. [") && !listed.contains("2. ["))
    }
}
