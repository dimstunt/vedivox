import Foundation

/// Runs a load outside the caller's cancellation.
///
/// A list is loaded for whoever shows it, not for the task that asked.
/// SwiftUI cancels a view's `.task` whenever it drops the view — the window
/// reopened during a slow launch, a section left while it loads — and GRDB
/// fails a read from a cancelled task with CancellationError. The caller then
/// logged an error and kept an empty list. An unstructured task does not
/// inherit that cancellation: the load runs to the end and is delivered.
func uncancelled<T: Sendable>(_ load: @escaping @Sendable () async throws -> T) async throws -> T {
    try await Task(operation: load).value
}
