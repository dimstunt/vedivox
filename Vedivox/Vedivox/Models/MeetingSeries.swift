import Foundation
import GRDB

struct MeetingSeries: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "meeting_series"

    var id: String
    var name: String
    var calendarSeriesId: String?
    var createdAt: Date
    /// Persistent tile color (0..<360), same scale as speaker hues.
    var hue: Double?
    /// SF Symbol name for the series tile; nil → "link".
    var icon: String?
    var seriesDescription: String?
    /// Case-insensitive regex over meeting titles: matching meetings are
    /// auto-added to this series on rename (see SeriesAutoRule).
    var autoRulePattern: String?

    init(
        id: String = UUID().uuidString,
        name: String,
        calendarSeriesId: String? = nil,
        createdAt: Date = Date(),
        hue: Double? = nil,
        icon: String? = nil,
        seriesDescription: String? = nil,
        autoRulePattern: String? = nil
    ) {
        self.id = id
        self.name = name
        self.calendarSeriesId = calendarSeriesId
        self.createdAt = createdAt
        self.hue = hue
        self.icon = icon
        self.seriesDescription = seriesDescription
        self.autoRulePattern = autoRulePattern
    }
}

/// Auto-add rule matching. Pure logic, tested in VedivoxCoreTests.
enum SeriesAutoRule {
    /// First series whose regex matches the title (case-insensitive substring
    /// search semantics: the pattern may match anywhere in the title).
    /// Series with empty/invalid patterns are skipped.
    static func matchingSeries(title: String, in series: [MeetingSeries]) -> MeetingSeries? {
        for candidate in series {
            guard let pattern = candidate.autoRulePattern,
                  !pattern.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive]
            ) else { continue }
            let range = NSRange(title.startIndex..., in: title)
            if regex.firstMatch(in: title, range: range) != nil {
                return candidate
            }
        }
        return nil
    }

    /// Validation helper for the settings sheet.
    static func isValidPattern(_ pattern: String) -> Bool {
        !pattern.trimmingCharacters(in: .whitespaces).isEmpty
            && (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])) != nil
    }
}
