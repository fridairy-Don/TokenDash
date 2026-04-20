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
        let results: [ProviderSnapshot] = await withTaskGroup(of: (Int, ProviderSnapshot).self) { group in
            for (idx, p) in providers.enumerated() {
                group.addTask { (idx, await p.snapshot()) }
            }
            var indexed: [(Int, ProviderSnapshot)] = []
            for await r in group { indexed.append(r) }
            indexed.sort { $0.0 < $1.0 }
            return indexed.map { $0.1 }
        }
        self.snapshots = results
    }
}
