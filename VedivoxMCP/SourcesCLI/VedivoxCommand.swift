import ArgumentParser
import Foundation
import VedivoxMCPLib

/// Prints a core's stdout document, routing failures to stderr + exit code.
///
/// The single seam between command logic and the process: data goes to stdout
/// only, diagnostics to stderr only, and the exit code follows the CLI table
/// (0/1/2/3/64). ArgumentParser itself covers 64 for parse errors.
func executeCore(_ body: () throws -> String) throws {
    do {
        print(try body())
    } catch {
        let failure = cliFailure(from: error)
        if let output = failure.output { print(output) }
        FileHandle.standardError.write(Data(("vedivox: " + failure.message + "\n").utf8))
        throw ExitCode(failure.code)
    }
}

/// Same, for a command that reads the database: a missing or unreadable one is
/// reported like any other failure (code 3), once.
func executeCore(_ body: (DatabaseReader) throws -> String) throws {
    try executeCore { try body(DatabaseReader()) }
}

package struct VedivoxCommand: ParsableCommand {
    package static let configuration = CommandConfiguration(
        commandName: "vedivox",
        abstract: "Vedivox meetings from the command line.",
        subcommands: [
            List.self, Status.self, Transcript.self, Search.self,
            Show.self, Speakers.self, Series.self, Marks.self,
            Import.self, Transcribe.self, Reprocess.self, SpeakerCmd.self, MeetingCmd.self,
            Mark.self, Unmark.self, SegmentCmd.self, RecordCmd.self, Live.self, Queue.self,
            AudioCmd.self, Feedback.self, MuteDebug.self,
        ]
    )

    package init() {}
}

// MARK: - Wave 1: reading

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List meetings (done only by default)."
    )

    @Option(name: .customLong("status"), help: "Status filter, repeatable: recording, transcribing, diarizing, done, needsAttention, error.")
    var statuses: [String] = []

    @Option(name: .customLong("from"), help: "Start date (YYYY-MM-DD), inclusive.")
    var dateFrom: String?

    @Option(name: .customLong("to"), help: "End date (YYYY-MM-DD), inclusive.")
    var dateTo: String?

    @Option(help: "Filter by series name (partial match).")
    var series: String?

    @Option(help: "Filter by speaker name (partial match).")
    var speaker: String?

    @Option(help: "Max results.")
    var limit: Int = 20

    @Option(help: "Sort order: newest or oldest.")
    var sort: String = "newest"

    @Flag(help: "Machine output: one JSON array.")
    var json = false

    func run() throws {
        try executeCore { db in
            try CLICommands.list(
                statuses: statuses, dateFrom: dateFrom, dateTo: dateTo,
                series: series, speaker: speaker, limit: limit, sort: sort,
                json: json, db: db
            )
        }
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "What is recording or processing now, or the state of one meeting."
    )

    @Argument(help: "Meeting id or its unambiguous prefix. Omit for the overview.")
    var meetingId: String?

    @Flag(help: "Machine output: one JSON object.")
    var json = false

    func run() throws {
        try executeCore { db in
            if let meetingId {
                return try CLICommands.status(idPrefix: meetingId, json: json, db: db)
            }
            return try CLICommands.statusOverview(json: json, db: db)
        }
    }
}

struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "One meeting in full: metadata, series, speakers, stored description."
    )

    @Argument(help: "Meeting id or its unambiguous prefix.")
    var meetingId: String

    @Flag(help: "Machine output: one JSON object.")
    var json = false

    func run() throws {
        try executeCore { db in try CLICommands.show(idPrefix: meetingId, json: json, db: db) }
    }
}

struct Transcript: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcript",
        abstract: "Transcript of a meeting."
    )

    @Argument(help: "Meeting id or its unambiguous prefix.")
    var meetingId: String

    @Option(name: .customLong("from"), help: "Start time in seconds.")
    var from: Double?

    @Option(name: .customLong("to"), help: "End time in seconds.")
    var to: Double?

    @Flag(name: .customLong("include-excluded"), help: "Also show segments excluded from the transcript.")
    var includeExcluded = false

    @Flag(help: "Machine output: one JSON object.")
    var json = false

    func run() throws {
        try executeCore { db in
            try CLICommands.transcript(
                idPrefix: meetingId, from: from, to: to,
                includeExcluded: includeExcluded, json: json, db: db
            )
        }
    }
}

struct Search: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Find transcript lines that contain every word of the query.",
        discussion: """
            Words match as prefixes ("data" finds "dataset") and must all occur in one line; \
            titles and descriptions are not searched. With --meetings the search covers whole \
            meetings instead, like the app's sidebar: a meeting matches when every word occurs \
            somewhere in it — any line, its title or its description — and the output is the \
            meeting list of `list`.
            """
    )

    @Argument(help: "Search query.")
    var query: String

    @Option(help: "Max results.")
    var limit: Int = 20

    @Flag(name: .customLong("include-excluded"), help: "Also search excluded segments.")
    var includeExcluded = false

    @Flag(help: "Search whole meetings (lines, title, description); list the meetings found, newest first.")
    var meetings = false

    @Flag(help: "Machine output: one JSON array.")
    var json = false

    func run() throws {
        try executeCore { db in
            try CLICommands.search(
                query: query, limit: limit, includeExcluded: includeExcluded,
                meetings: meetings, json: json, db: db
            )
        }
    }
}

struct Speakers: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "speakers",
        abstract: "List speakers."
    )

    @Option(help: "Only speakers of this meeting (id or prefix).")
    var meeting: String?

    @Flag(help: "Machine output: one JSON array.")
    var json = false

    func run() throws {
        try executeCore { db in
            try CLICommands.speakers(meetingIdPrefix: meeting, json: json, db: db)
        }
    }
}

struct Series: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "series",
        abstract: "Meeting series: list (default), create, set, merge, delete or apply-rules.",
        subcommands: [
            ListSeries.self, CreateSeries.self, SetSeries.self, MergeSeries.self, DeleteSeries.self, ApplyRules.self,
        ],
        defaultSubcommand: ListSeries.self
    )

    struct ListSeries: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list", abstract: "List meeting series."
        )

        @Flag(help: "Machine output: one JSON array.") var json = false

        func run() throws {
            try executeCore { db in try CLICommands.series(json: json, db: db) }
        }
    }

    struct CreateSeries: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "create", abstract: "Create a series (run through the app)."
        )

        @Argument(help: "Series name.") var name: String
        @Option(name: .customLong("calendar-series-id"), help: "Calendar recurring event id to link.")
        var calendarSeriesId: String?

        func run() throws {
            try executeCore { try CLIActionCore.seriesCreate(name: name, calendarSeriesId: calendarSeriesId) }
        }
    }

    struct SetSeries: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set", abstract: "Rename a series, link its calendar event or set the title auto-rule."
        )

        @Argument(help: "Series id or its unambiguous prefix.") var seriesId: String
        @Option(help: "New name.") var name: String?
        @Option(name: .customLong("calendar-series-id"), help: "Calendar recurring event id (empty string unlinks).")
        var calendarSeriesId: String?
        @Option(
            name: .customLong("auto-rule"),
            help: "Case-insensitive regex over meeting titles; matching series-less meetings join at once (empty string clears)."
        )
        var autoRule: String?

        func run() throws {
            try executeCore { db in
                try CLIActionCore.seriesSet(
                    seriesId: seriesId, name: name, calendarSeriesId: calendarSeriesId, autoRule: autoRule, db: db
                )
            }
        }
    }

    struct ApplyRules: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "apply-rules",
            abstract: "Put every series-less meeting into the first series whose auto-rule matches its title."
        )

        @Flag(help: "Actually assign; without it the command only counts.") var yes = false

        func run() throws {
            try executeCore { try CLIActionCore.seriesApplyRules(confirmed: yes) }
        }
    }

    struct MergeSeries: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "merge",
            abstract: "Fold a duplicate series into another: its meetings move over, then it is deleted.",
            discussion: """
                The series that stays keeps its name, calendar link and auto-rule; where it has none, \
                it takes the merged series' one.
                """
        )

        @Argument(help: "The duplicate to merge away: id or its unambiguous prefix.") var sourceId: String
        @Argument(help: "The series that stays: id or its unambiguous prefix.") var targetId: String
        @Flag(help: "Actually merge; without it the command only says what would change.") var yes = false

        func run() throws {
            try executeCore { db in
                try CLIActionCore.seriesMerge(sourceId: sourceId, targetId: targetId, confirmed: yes, db: db)
            }
        }
    }

    struct DeleteSeries: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete", abstract: "Delete a series; its meetings stay and lose the link."
        )

        @Argument(help: "Series id or its unambiguous prefix.") var seriesId: String
        @Flag(help: "Actually delete; without it the command only names the series.") var yes = false

        func run() throws {
            try executeCore { db in try CLIActionCore.seriesDelete(seriesId: seriesId, confirmed: yes, db: db) }
        }
    }
}
