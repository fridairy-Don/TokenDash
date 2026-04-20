import Foundation
import Combine

@MainActor
final class DataStore: ObservableObject {
    @Published private(set) var snapshots: [ProviderSnapshot] = []
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var lastRefreshed: Date? = nil

    private let providers: [UsageProvider]
    private var timer: Timer?

    init() {
        self.providers = [
            ClaudeCodeProvider(),
            CodexProvider(),
            ElevenLabsProvider(),
            OpenRouterProvider(),
            GroqProvider(),
        ]
        Task { await self.refreshAll() }
    }

    func startAutoRefresh(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { [weak self] in await self?.refreshAll() }
        }
    }

    func refreshAll() async {
        if isRefreshing { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefreshed = Date()
        }

        let providers = self.providers
        var results: [ProviderSnapshot] = await withTaskGroup(of: (Int, ProviderSnapshot).self) { group in
            for (idx, p) in providers.enumerated() {
                group.addTask { (idx, await p.snapshot()) }
            }
            var indexed: [(Int, ProviderSnapshot)] = []
            for await r in group { indexed.append(r) }
            indexed.sort { $0.0 < $1.0 }
            return indexed.map { $0.1 }
        }

        // Persist every non-error snapshot so we can draw sparklines and
        // detect anomalies. Errors/unconfigured are skipped so a transient
        // outage doesn't nuke the baseline.
        for snap in results where snap.state == .ok {
            PersistentStore.shared.record(snapshot: snap)
        }

        // Hydrate each snapshot with its 7-day history from the DB so the JSON
        // payload can carry sparklines without the UI having to fetch them.
        for i in results.indices {
            results[i] = HistoryHydrator.attachHistory(to: results[i])
        }

        // Anomaly detection — raises a UNUserNotification if today's value is
        // statistically far from the per-provider baseline.
        AnomalyDetector.shared.check(snapshots: results)

        self.snapshots = results
    }
}
