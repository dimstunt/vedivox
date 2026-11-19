import SwiftUI

/// Drift Alerts Banner: collapsible section above the
/// Speakers list showing canonical-embedding collisions from
/// `SpeakerDriftMonitor` — pairs of confirmed speakers whose voices are
/// suspiciously close (sim > 0.6, almost always a merged identity).
///
/// Actions per pair: merge (either direction, with confirmation) or ignore.
/// Ignored pairs are keyed in UserDefaults with the sim at ignore time and
/// resurface once sim grows by another 0.05. The Split wizard
/// is not built yet, so there is no Split button.
struct DriftAlertsBanner: View {
    let alerts: [SpeakerDriftMonitor.DriftAlert]
    /// Called after a merge so the parent reloads speakers and the monitor;
    /// carries the error text when the merge failed.
    let onMerged: (_ failure: String?) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.undoManager) private var undoManager
    @AppStorage("voxDriftBannerCollapsed") private var collapsed = false
    /// pairId → sim at the moment of ignoring.
    @State private var ignored: [String: Double] = Self.loadIgnored()
    @State private var mergeCandidate: SpeakerDriftMonitor.DriftAlert?

    private static let ignoredKey = "voxIgnoredDrifts"
    /// An ignored pair resurfaces when sim grows by this much.
    private static let resurfaceDelta: Double = 0.05
    /// Pairs at or above this sim are near-certain duplicates.
    private static let dangerThreshold: Float = 0.75

    static func pairId(_ alert: SpeakerDriftMonitor.DriftAlert) -> String {
        [alert.speakerAId, alert.speakerBId].sorted().joined(separator: "|")
    }

    private var visibleAlerts: [SpeakerDriftMonitor.DriftAlert] {
        alerts.filter { alert in
            guard let ignoredAt = ignored[Self.pairId(alert)] else { return true }
            return Double(alert.similarity) >= ignoredAt + Self.resurfaceDelta
        }
    }

    var body: some View {
        if !visibleAlerts.isEmpty {
            VedivoxBanner(
                .warning,
                title: "Similar voices",
                message: "Possibly the same person recorded twice.",
                collapsed: $collapsed
            ) {
                Image(systemName: "waveform.badge.exclamationmark")
            } trailing: {
                VedivoxCountBadge(count: visibleAlerts.count, warning: true)
            } detail: {
                // Cap the banner height — 17 pairs must not push the
                // speakers list off screen.
                ScrollView {
                    VStack(spacing: VedivoxSpace.s) {
                        ForEach(visibleAlerts, id: \.self) { alert in
                            DriftPairCard(
                                alert: alert,
                                isDanger: alert.similarity >= Self.dangerThreshold,
                                onMerge: { mergeCandidate = alert },
                                onIgnore: { ignore(alert) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 216)
            }
            .padding(.horizontal, VedivoxSpace.l)
            .padding(.top, VedivoxSpace.m)
            .confirmationDialog(
                mergeCandidate.map { "Merge “\($0.speakerAName)” and “\($0.speakerBName)”?" } ?? "",
                isPresented: Binding(
                    get: { mergeCandidate != nil },
                    set: { if !$0 { mergeCandidate = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let pair = mergeCandidate {
                    Button("Keep “\(pair.speakerAName)”") {
                        merge(target: pair.speakerAId, source: pair.speakerBId)
                    }
                    Button("Keep “\(pair.speakerBName)”") {
                        merge(target: pair.speakerBId, source: pair.speakerAId)
                    }
                    Button("Cancel", role: .cancel) { mergeCandidate = nil }
                }
            } message: {
                Text("The other speaker\u{2019}s segments and meetings move to the one you keep. Edit \u{2192} Undo (\u{2318}Z) puts them back.")
            }
        }
    }

    private func ignore(_ alert: SpeakerDriftMonitor.DriftAlert) {
        ignored[Self.pairId(alert)] = Double(alert.similarity)
        UserDefaults.standard.set(ignored, forKey: Self.ignoredKey)
    }

    private func merge(target: String, source: String) {
        mergeCandidate = nil
        Task {
            var failure: String?
            do {
                let undo = try await SpeakerUndo.capture(speakerIds: [source], rows: [target])
                try await SpeakerRepository().mergeSpeakers(targetId: target, sourceIds: [source])
                await undoManager?.registerSpeakerUndo(undo, named: "Merge Speakers") { failure in
                    if let failure { appState.speakerUndoFailure = failure }
                    await SpeakerHue.reload()
                    onMerged(nil)
                }
            } catch {
                Log.error("Drift merge \(source) → \(target) failed: \(error)")
                failure = "Merge failed: \(error.localizedDescription)"
            }
            await SpeakerHue.reload()
            onMerged(failure)
        }
    }

    private static func loadIgnored() -> [String: Double] {
        (UserDefaults.standard.dictionary(forKey: ignoredKey) as? [String: Double]) ?? [:]
    }
}

extension SpeakerDriftMonitor.DriftAlert: Hashable {
    func hash(into hasher: inout Hasher) {
        hasher.combine(speakerAId)
        hasher.combine(speakerBId)
    }
}

private struct DriftPairCard: View {
    let alert: SpeakerDriftMonitor.DriftAlert
    let isDanger: Bool
    let onMerge: () -> Void
    let onIgnore: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: VedivoxSpace.l) {
            Circle()
                .fill(isDanger ? Color.Vedivox.danger : Color.Vedivox.warning)
                .frame(width: VedivoxSize.dot, height: VedivoxSize.dot)
                .help(isDanger ? "Almost certainly a duplicate" : "Suspiciously similar")

            speakerChip(name: alert.speakerAName, id: alert.speakerAId)
            Text("↔")
                .vedivoxFont(.caption)
                .foregroundStyle(Color.Vedivox.fgSecondary)
            speakerChip(name: alert.speakerBName, id: alert.speakerBId)

            Text(String(format: "sim %.3f", alert.similarity))
                .vedivoxFont(.timecode)
                .foregroundStyle(isDanger ? Color.Vedivox.danger : Color.Vedivox.warning)

            Spacer()

            Button("Merge", action: onMerge)
                .buttonStyle(.vedivoxGhost)
            Button("Ignore", action: onIgnore)
                .buttonStyle(.plain)
                .vedivoxFont(.caption)
                .foregroundStyle(Color.Vedivox.fgSecondary)
        }
        .padding(.horizontal, VedivoxSpace.l)
        .padding(.vertical, VedivoxSpace.s)
        .background(RoundedRectangle(cornerRadius: VedivoxRadius.s).fill(Color.Vedivox.bgCard))
        .overlay(RoundedRectangle(cornerRadius: VedivoxRadius.s).strokeBorder(Color.Vedivox.lineSoft))
    }

    private func speakerChip(name: String, id: String) -> some View {
        HStack(spacing: VedivoxSpace.s) {
            Circle()
                .fill(Color.speaker(hue: SpeakerHue.for(id), scheme: scheme))
                .frame(width: VedivoxSize.dot, height: VedivoxSize.dot)
            Text(name)
                .vedivoxFont(.row)
                .foregroundStyle(Color.Vedivox.fg)
                .lineLimit(1)
        }
    }
}
