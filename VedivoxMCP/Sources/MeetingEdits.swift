import Foundation

/// Split, trim, merge and their undo, shared by `vedivox meeting …` and the
/// MCP tools (cli-meeting-edit). The app does one edit per command, exactly
/// as its buttons do; several cut points or meetings become a chain of
/// those here, in one place, so the two interfaces cannot drift apart.
package enum MeetingEdits {
    package typealias Send = (AppCommandRequest) throws -> AppCommandResponse

    /// A link of a chain was refused; `done` names the links already made.
    package struct ChainStopped: Error {
        package let response: AppCommandResponse
        package let done: [String]
    }

    /// Why a split chain cannot be made, nil when it can — checked before the
    /// first cut so a bad point cannot leave the meeting half cut. The app
    /// checks each cut again (MeetingEditCheck): cuts at least 1 s inside
    /// what is left and from each other, every part with a line starting in it.
    package static func splitRefusal(at times: [Double], duration: Double, lineStarts: [Double]) -> String? {
        let cuts = Set(times).sorted()
        guard !cuts.isEmpty else { return "no cut point given" }
        let bounds = [0] + cuts + [duration]
        for (index, cut) in cuts.enumerated() where cut < 1 || bounds[index + 2] - cut < 1 || cut - bounds[index] < 1 {
            return "cut \(clock(cut)) is less than 1 s from the start, the end or another cut"
        }
        for part in splitParts(at: cuts, duration: duration, lineStarts: lineStarts) where part.lines == 0 {
            return "part \(clock(part.from))–\(clock(part.to)) would have no lines"
        }
        return nil
    }

    /// The parts a split would make: (from, to, number of lines starting in it).
    package static func splitParts(at times: [Double], duration: Double, lineStarts: [Double]) -> [(from: Double, to: Double, lines: Int)] {
        let bounds = [0] + Set(times).sorted() + [duration]
        return (0 ..< bounds.count - 1).map { index in
            let (from, to) = (bounds[index], bounds[index + 1])
            // The app moves a line by its start; the last part takes every later start.
            let upper = index == bounds.count - 2 ? Double.infinity : to
            return (from, to, lineStarts.filter { $0 >= from && $0 < upper }.count)
        }
    }

    /// Cuts from the last point back, each a split of the original meeting,
    /// so every point stays on the original timeline. Ids in time order.
    package static func split(meetingId: String, at times: [Double], send: Send) throws -> [String] {
        var tails: [String] = []
        var done: [String] = []
        for cut in Set(times).sorted(by: >) {
            let response = try send(AppCommandRequest(
                command: AppCommandName.splitMeeting, params: ["meeting_id": meetingId, "at": String(cut)]
            ))
            guard response.ok, let tail = ids(response, "meeting_ids").last else {
                throw ChainStopped(response: response, done: done)
            }
            tails.insert(tail, at: 0)
            done.append(response.message)
        }
        return [meetingId] + tails
    }

    /// Joins meetings pairwise in order of start, into the earliest one.
    /// Returns the meeting that stays and the ones merged into it.
    package static func merge(meetingIds orderedByStart: [String], send: Send) throws -> (meeting: String, merged: [String]) {
        guard var survivor = orderedByStart.first else { return ("", []) }
        var merged: [String] = []
        var done: [String] = []
        for next in orderedByStart.dropFirst() {
            let response = try send(AppCommandRequest(
                command: AppCommandName.mergeMeetings, params: ["first_id": survivor, "second_id": next]
            ))
            guard response.ok, let stays = response.data?["meeting_id"] else {
                throw ChainStopped(response: response, done: done)
            }
            survivor = stays
            merged.append(next)
            done.append(response.message)
        }
        return (survivor, merged)
    }

    package static func trim(meetingId: String, from: Double, to: Double, send: Send) throws -> AppCommandResponse {
        try send(AppCommandRequest(
            command: AppCommandName.trimMeeting,
            params: ["meeting_id": meetingId, "from": String(from), "to": String(to)]
        ))
    }

    package static let undoKinds = ["split", "trim", "merge"]

    package static func undo(_ kind: String, meetingId: String, send: Send) throws -> AppCommandResponse {
        try send(AppCommandRequest(
            command: AppCommandName.undoMeetingEdit, params: ["meeting_id": meetingId, "kind": kind]
        ))
    }

    /// The comma-separated ids an answer carries under `key`.
    package static func ids(_ response: AppCommandResponse, _ key: String) -> [String] {
        (response.data?[key] ?? "").split(separator: ",").map(String.init)
    }

    /// m:ss, as the transcript shows times.
    package static func clock(_ value: Double) -> String {
        let total = Int(value.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
