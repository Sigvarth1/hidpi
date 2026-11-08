import Foundation

/// Coalesce dock events and retry only a bounded number of times as modes settle.
///
/// Requests merge their scope: a reconnect asks for just the added monitor(s), while startup,
/// wake, and explicit restores ask for every monitor (`nil`). A pending "all" absorbs subsets.
final class RestoreCoordinator {
    typealias Scheduler = (Double, @escaping () -> Void) -> Void
    typealias DisplayIDs = Set<UInt32>
    private var generation = 0
    private var pendingAll = false
    private var pendingIDs = DisplayIDs()
    private let runRestore: (DisplayIDs?) -> [RestoreResult]
    private let paused: () -> Bool
    private let switching: () -> Bool
    private let scheduler: Scheduler
    var onComplete: (([RestoreResult]) -> Void)?

    init(runRestore: @escaping (DisplayIDs?) -> [RestoreResult] = { Preferences.restoreAll(displayIDs: $0) },
         paused: @escaping () -> Bool = { Preferences.store.bool("pauseRestore") },
         switching: @escaping () -> Bool = { SafeSwitch.isActive },
         scheduler: @escaping Scheduler = { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }) {
        self.runRestore = runRestore; self.paused = paused; self.switching = switching; self.scheduler = scheduler
    }
    func cancel() { generation += 1; finish() }
    /// `displays == nil` restores every monitor.
    func schedule(displays: DisplayIDs? = nil) {
        if let displays { pendingIDs.formUnion(displays) } else { pendingAll = true }
        generation += 1
        enqueue(attempt: 0, token: generation)
    }
    private func finish() { pendingAll = false; pendingIDs.removeAll() }
    private func enqueue(attempt: Int, token: Int) {
        let delays: [Double] = [2, 3, 5]
        scheduler(delays[attempt]) { [weak self] in
            guard let self, self.generation == token else { return }
            guard !self.paused() else { self.finish(); return }
            if self.switching() {
                if attempt < 2 { self.enqueue(attempt: attempt + 1, token: token) } else { self.finish() }
                return
            }
            let results = self.runRestore(self.pendingAll ? nil : self.pendingIDs)
            if (results.isEmpty || results.contains(where: { $0.needsRetry })) && attempt < 2 {
                self.enqueue(attempt: attempt + 1, token: token)
            } else { self.finish(); self.onComplete?(results) }
        }
    }
}
