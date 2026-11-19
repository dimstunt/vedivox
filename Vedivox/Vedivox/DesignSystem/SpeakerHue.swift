import Foundation
import os

/// View-facing resolver for speaker colors.
///
/// Persistent hues live in the `speakers.hue` column; views resolve them
/// through the in-memory map loaded by `reload()`. Keys without a stored hue
/// (raw labels like "me", segments whose speaker record is gone) fall back to
/// the deterministic djb2 hue so colors stay stable either way.
enum SpeakerHue {
    // OSAllocatedUnfairLock (macOS 13+) instead of Mutex (macOS 15+): same
    // synchronous withLock API, keeps the deployment target at 14.4.
    /// speakerId → stored hue, loaded from DB. Refreshed by SidebarView /
    /// SpeakerManagementView loads and after hue edits.
    private static let stored = OSAllocatedUnfairLock<[String: Double]>(initialState: [:])

    static func `for`(_ key: String) -> Double {
        stored.withLock { $0[key] } ?? SpeakerHueMath.fallback(key)
    }

    static func set(_ hue: Double, for speakerId: String) {
        stored.withLock { $0[speakerId] = hue }
    }

    /// Reload the stored map from the database.
    static func reload() async {
        if let map = try? await SpeakerRepository().hueMap() {
            stored.withLock { $0 = map }
        }
    }
}
