import Foundation
import GRDB
import Testing
@testable import VedivoxMCPLib

/// `makeTestDB` writes the schema by hand, so a column the app renames or
/// drops would live on in the tests and they would keep passing against a
/// table the app no longer has. This replays the app's migrations as text —
/// the app target is out of reach of this package — and checks every
/// hand-written column still exists in the app.
@Suite("Test schema matches the app's migrations")
struct TestSchemaTests {

    /// Columns per table after all of `DatabaseManager`'s migrations.
    ///
    /// shortcut: reads only GRDB's builder calls (`create/alter/drop/rename
    /// table`, `column`, `add/drop/rename column`, primary keys); raw-SQL DDL
    /// in a migration would be missed — switch to a schema dump from the app
    /// tests if one appears.
    static func appColumns() throws -> [String: Set<String>] {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vedivox/Vedivox/Services/Storage/DatabaseManager.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let pattern = #"""
            (create|alter)\(table: "(\w+)"|create\(virtualTable: "(\w+)"|drop\(table: "(\w+)"|rename\(table: "(\w+)", to: "(\w+)"|(?:\.column\(|add\(column: |rimaryKey\()"(\w+)"|drop\(column: "(\w+)"|rename\(column: "(\w+)", to: "(\w+)"
            """#
        let regex = try NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        var tables: [String: Set<String>] = [:]
        var current: String?
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            func group(_ i: Int) -> String? {
                let range = match.range(at: i)
                return range.location == NSNotFound ? nil : ns.substring(with: range)
            }
            if let table = group(2) {
                current = table
                tables[table, default: []].formUnion([])
            } else if group(3) != nil {
                current = nil
            } else if let table = group(4) {
                tables[table] = nil
            } else if let from = group(5), let to = group(6) {
                tables[to] = tables.removeValue(forKey: from)
            } else if let column = group(7), let current {
                tables[current, default: []].insert(column)
            } else if let column = group(8), let current {
                tables[current]?.remove(column)
            } else if let from = group(9), let to = group(10), let current {
                tables[current]?.remove(from)
                tables[current]?.insert(to)
            }
        }
        return tables
    }

    @Test("every column of the hand-written test schema exists in the app's schema")
    func testHandSchemaColumnsExistInApp() throws {
        let app = try Self.appColumns()
        // The parser itself must have seen the schema, or the check below is vacuous.
        #expect(app["meetings"]?.contains("foreignVoiceDecision") == true)
        #expect(app["meetings"]?.contains("micMultiSpeaker") == false)

        let db = try makeTestDB()
        let test: [String: [String]] = try db.dbQueue.read { db in
            let names = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'transcript_fts%'
                """)
            return try Dictionary(uniqueKeysWithValues: names.map { name in
                (name, try db.columns(in: name).map(\.name))
            })
        }
        #expect(!test.isEmpty)
        for (table, columns) in test.sorted(by: { $0.key < $1.key }) {
            guard let appTable = app[table] else {
                Issue.record("test table \(table) does not exist in the app")
                continue
            }
            let stale = columns.filter { !appTable.contains($0) }
            #expect(stale.isEmpty, "\(table): columns the app does not have: \(stale)")
        }
    }
}
