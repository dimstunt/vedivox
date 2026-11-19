import Foundation

struct DayGroup: Identifiable {
    let label: String
    let meetings: [Meeting]
    var id: String { label }
}

/// Groups meetings by calendar day.
/// Today and Yesterday get named labels; everything older is labelled by its formatted date
/// ("d MMMM" in ru_RU, with year if older than current year).
/// Sorted most-recent first. Within a group, meetings keep caller order.
func groupMeetingsByDay(_ meetings: [Meeting], now: Date = Date()) -> [DayGroup] {
    let calendar = Calendar.current
    let nowYear = calendar.component(.year, from: now)

    let dateFmtSameYear = DateFormatter()
    dateFmtSameYear.locale = Locale(identifier: "en_US")
    dateFmtSameYear.dateFormat = "d MMMM"

    let dateFmtWithYear = DateFormatter()
    dateFmtWithYear.locale = Locale(identifier: "en_US")
    dateFmtWithYear.dateFormat = "d MMMM yyyy"

    var order: [String] = []
    var buckets: [String: [Meeting]] = [:]

    for meeting in meetings {
        let label: String
        if calendar.isDate(meeting.startTime, inSameDayAs: now) {
            label = "Today"
        } else if calendar.isDateInYesterday(meeting.startTime) {
            label = "Yesterday"
        } else {
            let year = calendar.component(.year, from: meeting.startTime)
            label = year == nowYear
                ? dateFmtSameYear.string(from: meeting.startTime)
                : dateFmtWithYear.string(from: meeting.startTime)
        }
        if buckets[label] == nil {
            order.append(label)
        }
        buckets[label, default: []].append(meeting)
    }

    return order.map { DayGroup(label: $0, meetings: buckets[$0] ?? []) }
}
