import Foundation
import Testing

/// `scripts/cli_alias.sh`: the command keeps answering to `vox` after the
/// rename, but only where that name is free or already ours. Another program's
/// `vox` is never replaced.
@Suite("alias for the command's old name")
struct LegacyAliasTests {
    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/cli_alias.sh").path

    /// Runs the script on a bin directory that holds the new binary and whatever
    /// `prepare` put under the old name. Returns what it printed and the old name's path.
    private func alias(_ prepare: (URL) throws -> Void) throws -> (said: String, old: URL) {
        let bin = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("vox-alias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("new binary".utf8).write(to: bin.appendingPathComponent("vedi"))
        let old = bin.appendingPathComponent("vox")
        try prepare(old)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [Self.script, bin.path, "vedi", "vox"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let said = String(bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "a missing alias must not fail an install: \(said)")
        return (said, old)
    }

    private func linkTarget(_ url: URL) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    @Test("a free name becomes a link to the new command")
    func freeName() throws {
        let (said, old) = try alias { _ in }
        #expect(linkTarget(old) == "vedi")
        #expect(said.contains("vox → vedi"))
    }

    @Test("the binary of an install before the rename is replaced by the link")
    func ourOldBinary() throws {
        // Every build before the rename carried the old meeting-link scheme.
        let (_, old) = try alias { try Data("\u{0}\u{1}URL: vox://meeting/\u{0}".utf8).write(to: $0) }
        #expect(linkTarget(old) == "vedi")
    }

    @Test("our own link from an earlier install is refreshed")
    func ourLink() throws {
        let (_, old) = try alias {
            try FileManager.default.createSymbolicLink(atPath: $0.path, withDestinationPath: "vedi")
        }
        #expect(linkTarget(old) == "vedi")
    }

    @Test("another program's file under the old name is left alone, and the reason is said")
    func foreignFile() throws {
        let (said, old) = try alias { try Data("#!/bin/sh\necho someone else\n".utf8).write(to: $0) }
        #expect(linkTarget(old) == nil)
        #expect(try String(contentsOf: old, encoding: .utf8).contains("someone else"))
        #expect(said.contains("belongs to another program"))
    }

    @Test("a link to another program is left alone")
    func foreignLink() throws {
        let (said, old) = try alias {
            try FileManager.default.createSymbolicLink(atPath: $0.path, withDestinationPath: "/usr/bin/true")
        }
        #expect(linkTarget(old) == "/usr/bin/true")
        #expect(said.contains("left as it is"))
    }
}
