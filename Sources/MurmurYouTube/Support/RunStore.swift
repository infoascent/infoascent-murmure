import Foundation
import Observation

/// Live-updating store of past transcriptions, read by the History pane.
///
/// Owned by the app rather than regenerated as an HTML file on disk: one instance, always
/// current, nothing to refresh.
@MainActor
@Observable
final class RunStore {
    static let shared = RunStore()

    private(set) var runs: [DictationRun] = []

    private init() { reload() }

    func reload() {
        runs = RunLog.load()
    }
}
