import EventKit
import Foundation

/// EventKit integration: calendar permission, and event matching.
///
/// `EKEventStore` and `EKEvent` are not `Sendable`. Actor isolation ensures
/// single-threaded access to the store. A `Sendable` DTO (`CalendarEvent`)
/// is used for values that cross the actor boundary.
actor CalendarService {

    // MARK: - Sendable DTO

    /// Lightweight, Sendable representation of an EKEvent for use outside the actor.
    struct CalendarEvent: Sendable {
        let title: String
        let startDate: Date
        let endDate: Date
        let calendarItemIdentifier: String
        let hasRecurrenceRules: Bool
    }

    // MARK: - Types

    enum AuthStatus: Sendable {
        case notDetermined
        case authorized
        case denied
    }

    // MARK: - Properties

    private let eventStore = EKEventStore()

    // MARK: - Authorization

    /// Current calendar authorization status (synchronous check).
    nonisolated var authorizationStatus: AuthStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .notDetermined
        case .fullAccess, .authorized: .authorized
        default: .denied
        }
    }

    /// Request full calendar access. Returns `true` if granted.
    func requestAccess() async -> Bool {
        do {
            return try await eventStore.requestFullAccessToEvents()
        } catch {
            Log.error("Access request failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Calendar Listing

    /// Fetch user-visible calendars as `(id, title)` pairs.
    func availableCalendars() -> [(id: String, title: String)] {
        eventStore.calendars(for: .event).map { ($0.calendarIdentifier, $0.title) }
    }

    // MARK: - Event Matching

    /// Find the closest calendar event within +/-15 min of now, filtered to watched calendar IDs.
    /// Returns a `Sendable` DTO so callers don't hold a non-Sendable `EKEvent`.
    func matchCurrentEvent(watchedCalendarIDs: [String]) -> CalendarEvent? {
        let now = Date()
        let windowStart = now.addingTimeInterval(-15 * 60)
        let windowEnd = now.addingTimeInterval(15 * 60)

        let calendars = eventStore.calendars(for: .event).filter {
            watchedCalendarIDs.contains($0.calendarIdentifier)
        }
        guard !calendars.isEmpty else { return nil }

        let predicate = eventStore.predicateForEvents(
            withStart: windowStart,
            end: windowEnd,
            calendars: calendars
        )
        let matched = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay }

        guard let closest = matched.min(by: {
            abs($0.startDate.timeIntervalSince(now)) < abs($1.startDate.timeIntervalSince(now))
        }) else {
            return nil
        }

        return CalendarEvent(
            title: closest.title ?? "Untitled",
            startDate: closest.startDate,
            endDate: closest.endDate,
            calendarItemIdentifier: closest.calendarItemIdentifier,
            hasRecurrenceRules: closest.hasRecurrenceRules
        )
    }
}
