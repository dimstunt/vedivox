/// One meeting edit at a time — split, trim, merge and their undo, from the
/// window or the socket, and none before the launch recovery of an
/// interrupted merge is done (cli-meeting-edit, review 3, 4, 6). The
/// window's sheet is modal, the socket is not: two commands, or a command
/// and a button, wrote the same temporary files. Taken before the first await.
struct MeetingEditLock {
    /// Taken from launch until the recovery lets it go.
    private(set) var busy = true
    /// The meetings the running edit touches: reprocess leaves them alone.
    private(set) var meetingIds: Set<String> = []

    mutating func begin(_ ids: [String]) -> Bool {
        guard !busy else { return false }
        busy = true
        meetingIds = Set(ids)
        return true
    }

    mutating func add(_ ids: [String]) { meetingIds.formUnion(ids) }

    mutating func end() {
        busy = false
        meetingIds = []
    }
}
