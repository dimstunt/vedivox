import Foundation

/// MCP tool: import_youtube — downloads a YouTube recording's audio track via
/// yt-dlp and hands it to the app through the same import_file command as
/// the import_file tool. Meant for recorded work calls (unlisted Zoom uploads etc.) —
/// the app processes it as a single-track import: no mic track, no "me"
/// linking, speakers recognized via voice enrollment where possible.
package enum ImportYouTubeTool {

    package static let definition: AnyCodable = .object([
        "name": .string("import_youtube"),
        "description": .string(
            "Import a recorded call from YouTube by URL (works for unlisted link-access videos). "
            + "Downloads the audio track with yt-dlp (requires: brew install yt-dlp ffmpeg), then Vedivox "
            + "transcribes and diarizes it like a regular imported file. The meeting date defaults "
            + "to the video's upload date. Single videos only — playlists and channels are rejected. "
            + "Intended for recorded meetings/calls, not for general knowledge videos — every "
            + "imported voice enters the global speaker database."
        ),
        "inputSchema": .object([
            "type": .string("object"),
            "properties": .object([
                "url": .object([
                    "type": .string("string"),
                    "description": .string("YouTube video URL (youtube.com/watch, shorts, live, or youtu.be)"),
                ]),
                "title": .object([
                    "type": .string("string"),
                    "description": .string("Meeting title. Defaults to the video title."),
                ]),
                "date": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Meeting date, YYYY-MM-DD or ISO8601 (the call date, not the import date). "
                        + "Defaults to the video's upload date."
                    ),
                ]),
            ]),
            "required": .array([.string("url")]),
        ]),
    ])

    // MARK: - URL validation

    /// True only for single-video URLs. Playlist/channel pages must be
    /// rejected up front: `--no-playlist` only strips the list param from
    /// watch URLs — a pure playlist/channel URL would download EVERY video
    /// while the tool imports just the first one.
    package static func isVideoURL(_ urlString: String) -> Bool {
        guard let components = URLComponents(string: urlString),
              let host = components.host?.lowercased() else { return false }
        let path = components.path

        if host == "youtu.be" {
            return path.count > 1 // "/<videoId>"
        }
        guard host == "youtube.com" || host.hasSuffix(".youtube.com") else {
            return false
        }
        if path == "/watch" {
            return components.queryItems?.contains { $0.name == "v" && !($0.value ?? "").isEmpty } == true
        }
        return path.hasPrefix("/shorts/") || path.hasPrefix("/live/")
    }

    // MARK: - yt-dlp plumbing (injectable for tests)

    package struct DownloadResult {
        package let filePath: String
        package let videoTitle: String
        /// yt-dlp upload_date ("YYYYMMDD"); nil when unavailable.
        package let uploadDate: String?
        /// The per-download folder fetchAudio made; removed by `discard()`.
        package fileprivate(set) var directory: URL?

        package init(filePath: String, videoTitle: String, uploadDate: String?) {
            self.filePath = filePath
            self.videoTitle = videoTitle
            self.uploadDate = uploadDate
        }

        /// Call once the app has answered: by then it has copied (import) or
        /// read (transcribe) the file — the socket reply comes after that.
        package func discard() {
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }
    }

    package struct DownloadError: Error, CustomStringConvertible {
        package let message: String
        package var description: String { message }
        package init(_ message: String) { self.message = message }
    }

    private static func locateExecutable(_ name: String) -> String? {
        var candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        candidates += path.split(separator: ":").map { "\($0)/\(name)" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Injectable locators so tests can simulate missing dependencies.
    /// ffmpeg is as hard a dependency as yt-dlp: the forced m4a conversion
    /// runs through it, and without the preflight a missing ffmpeg would
    /// surface only AFTER the full download as a raw postprocessing error.
    package nonisolated(unsafe) static var locateYtDlp: @Sendable () -> String? = { locateExecutable("yt-dlp") }
    package nonisolated(unsafe) static var locateFfmpeg: @Sendable () -> String? = { locateExecutable("ffmpeg") }

    /// Injectable downloader. The default shells out to yt-dlp, forcing m4a:
    /// AVFoundation can't reliably decode the webm/opus tracks YouTube serves
    /// otherwise (the conversion needs ffmpeg, checked upfront in run()).
    /// Arguments: yt-dlp path, video URL, this download's own folder.
    package nonisolated(unsafe) static var download: @Sendable (String, String, URL) throws -> DownloadResult = { ytDlp, url, tmpDir in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytDlp)
        process.arguments = [
            "-f", "bestaudio[ext=m4a]/bestaudio",
            "-x", "--audio-format", "m4a",
            "--no-playlist",
            "--quiet", "--no-progress", "--no-warnings",
            "--no-simulate",
            // All three print in the after_move stage (the info dict is
            // complete there), one line each, in argument order.
            "--print", "after_move:%(filepath)s",
            "--print", "after_move:%(title)s",
            "--print", "after_move:%(upload_date)s",
            "-o", tmpDir.appendingPathComponent("%(id)s.%(ext)s").path,
            url,
        ]
        // yt-dlp resolves ffmpeg via PATH; MCP servers often start without
        // the Homebrew dirs, so prepend them.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env
        // yt-dlp reads `yt-dlp.conf` from its working directory, and a config
        // line like `--exec` runs a command. The caller's directory can be a
        // cloned repository; the download folder is ours and empty.
        process.currentDirectoryURL = tmpDir
        // In the MCP server stdin is the JSON-RPC stream: not the child's to read.
        process.standardInput = FileHandle.nullDevice

        // stderr goes to a temp FILE, not a pipe: yt-dlp error/retry lines are
        // not silenced by --quiet, and two sequentially-drained pipes can
        // deadlock once one side outgrows the 64KB pipe buffer.
        let stderrURL = tmpDir.appendingPathComponent("stderr.log")
        // Not FileManager.createFile: it writes atomically through a scratch
        // file in the system temp dir and only returns false when that fails.
        try Data().write(to: stderrURL)

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = try FileHandle(forWritingTo: stderrURL)
        try process.run()
        // With --quiet stdout is just the three printed lines — safe to drain
        // to EOF before waiting.
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrText = (try? String(contentsOf: stderrURL, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw DownloadError(stderrText.isEmpty
                ? "yt-dlp exited with code \(process.terminationStatus)"
                : String(stderrText.suffix(500)))
        }

        let lines = String(data: outData, encoding: .utf8)?
            .split(separator: "\n").map(String.init) ?? []
        guard lines.count >= 3 else {
            throw DownloadError("unexpected yt-dlp output: \(lines.joined(separator: " | "))")
        }
        return DownloadResult(
            filePath: lines[0],
            videoTitle: lines[1],
            uploadDate: lines[2] == "NA" ? nil : lines[2]
        )
    }

    static let downloadPrefix = "vedivox-youtube"

    /// A private folder for one download, `<$TMPDIR>/vedivox-youtube.XXXXXX`.
    /// Sweeps first what earlier runs left behind (a crash, a killed process).
    package static func makeDownloadDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws(DownloadError) -> URL {
        purgeStaleDownloads(in: ScratchDirectory.base(environment: environment))
        do {
            return try ScratchDirectory.make(prefix: downloadPrefix, environment: environment)
        } catch {
            throw DownloadError(error.message)
        }
    }

    /// Each download removes its own folder; this only catches leftovers older
    /// than a day — a bare `vedivox-youtube` without the suffix included.
    private static func purgeStaleDownloads(in base: URL, olderThan age: TimeInterval = 24 * 3600) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-age)
        for entry in entries where entry.lastPathComponent.hasPrefix(downloadPrefix) {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified < cutoff {
                try? fm.removeItem(at: entry)
            }
        }
    }

    /// Validates a single-video URL and downloads its audio track. The thrown
    /// message is what callers report after "Error: " — shared by `import_youtube`
    /// and `vedivox transcribe`.
    package static func fetchAudio(_ urlString: String) throws(DownloadError) -> DownloadResult {
        guard let host = URLComponents(string: urlString)?.host?.lowercased(),
              host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com") else {
            throw DownloadError("not a YouTube URL: \(urlString)")
        }
        guard isVideoURL(urlString) else {
            throw DownloadError("expected a single video URL (watch/shorts/live or youtu.be link); "
                + "playlists and channels are not supported: \(urlString)")
        }
        guard let ytDlp = locateYtDlp() else {
            throw DownloadError("yt-dlp not found. Install it with: brew install yt-dlp")
        }
        guard locateFfmpeg() != nil else {
            throw DownloadError("ffmpeg not found (needed to convert the audio track to m4a). "
                + "Install it with: brew install ffmpeg")
        }
        let dir = try makeDownloadDirectory()
        do {
            var result = try download(ytDlp, urlString, dir)
            result.directory = dir
            return result
        } catch let error as DownloadError {
            try? FileManager.default.removeItem(at: dir)
            throw DownloadError("yt-dlp failed — \(error.message)")
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw DownloadError("failed to run yt-dlp at \(ytDlp) — \(error.localizedDescription)")
        }
    }

    // MARK: - Tool entry

    package static func run(params: [String: AnyCodable]) throws -> String {
        guard let urlString = params["url"]?.value as? String, !urlString.isEmpty else {
            return "Error: url is required"
        }

        // Validate an explicit date BEFORE the (potentially long) download —
        // and never echo a date the app would silently drop.
        let explicitDate = (params["date"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 }
        if let explicitDate, !ImportFileTool.isValidDate(explicitDate) {
            return "Error: invalid date \"\(explicitDate)\" — use YYYY-MM-DD or ISO8601"
        }

        let result: DownloadResult
        do {
            result = try fetchAudio(urlString)
        } catch {
            return "Error: \(error.message)"
        }
        defer { result.discard() }

        let title = (params["title"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? result.videoTitle

        // Meeting date: explicit param wins, else the video's upload date
        // (YYYYMMDD → YYYY-MM-DD). Without one the app would fall back to the
        // downloaded file's creation date — i.e. "today", wrong for a call
        // uploaded earlier — so always try to send one.
        var date = explicitDate
        if date == nil, let raw = result.uploadDate, raw.count == 8 {
            date = "\(raw.prefix(4))-\(raw.dropFirst(4).prefix(2))-\(raw.suffix(2))"
        }

        // Hand the downloaded file to import_file: one place builds and
        // validates the import_file command.
        var fileParams: [String: AnyCodable] = [
            "file_path": .string(result.filePath),
            "title": .string(title),
        ]
        if let date {
            fileParams["date"] = .string(date)
        }
        let importResult = try ImportFileTool.run(params: fileParams)
        if importResult.hasPrefix("Error") {
            return importResult
        }

        var message = "Downloaded \"\(result.videoTitle)\"."
        if let date { message += " Meeting date: \(date)." }
        return message + " " + importResult
    }
}
