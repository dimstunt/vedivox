import Foundation
import UniformTypeIdentifiers

enum FileImporter {
    static let supportedTypes: [UTType] = [
        .quickTimeMovie, // .mov
        .mpeg4Movie, // .mp4
        .mp3,
        .wav,
        .aiff,
        UTType("public.mpeg-4-audio")!, // .m4a
    ]

    static let supportedExtensions: Set<String> = [
        "mov", "mp4", "mp3", "wav", "aiff", "m4a", "webm", "ogg",
    ]

    /// Import a media file: copy to app storage, create meeting record, start transcription.
    /// `startTime` is when the call actually happened (e.g. the upload date a
    /// YouTube import carries); nil falls back to the file's creation date.
    static func importFile(
        url: URL,
        title: String? = nil,
        startTime: Date? = nil,
        language: String = "ru",
        appState: AppState,
        pipeline: TranscriptionPipeline
    ) async throws -> String {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            throw ImportError.unsupportedFormat(ext)
        }

        let meetingId = UUID().uuidString
        let meetingTitle = title ?? url.deletingPathExtension().lastPathComponent

        // Access security-scoped resource if needed
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing { url.stopAccessingSecurityScopedResource() }
        }

        guard await AudioConverter.hasAudioTrack(url) else {
            throw ImportError.noAudio(url.lastPathComponent)
        }

        // Meeting start: explicit caller-provided time wins, then the file's
        // creation date, then now.
        let fileStartTime: Date
        if let startTime {
            fileStartTime = startTime
        } else if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let creationDate = attrs[.creationDate] as? Date {
            fileStartTime = creationDate
        } else {
            fileStartTime = Date()
        }

        // Copy the file to app storage and create the meeting record; a
        // failure of either leaves nothing behind.
        let destURL = try await ImportRequest.stage(url, as: "original.\(ext)", meetingId: meetingId) { destURL in
            let meeting = Meeting(
                id: meetingId,
                title: meetingTitle,
                startTime: fileStartTime,
                source: .import,
                sourceFilePath: destURL.path,
                status: .transcribing
            )
            try await MeetingRepository().create(meeting)
        }
        await appState.loadMeetings()
        await MainActor.run {
            appState.selectedMeetingId = meetingId
        }

        // Start transcription in background
        Task { @MainActor in
            do {
                try await pipeline.processImportedFile(meetingId: meetingId, fileURL: destURL)
                appState.transcriptVersion += 1
                await appState.loadMeetings()
            } catch {
                Log.error("Import transcription failed: \(error)")
                appState.transcriptVersion += 1
                await appState.loadMeetings()
            }
        }

        return meetingId
    }

    enum ImportError: Error, LocalizedError {
        case unsupportedFormat(String)
        case noAudio(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let ext):
                "Unsupported file format: .\(ext). Supported: mov, mp4, mp3, wav, aiff, m4a"
            case .noAudio(let name):
                "No readable audio in \(name): the file is damaged or has no sound track"
            }
        }
    }
}
