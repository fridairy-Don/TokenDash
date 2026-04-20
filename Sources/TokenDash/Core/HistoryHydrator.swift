import Foundation

// MARK: - HistoryHydrator
//
// Pulls the last 7 days of values from PersistentStore for each provider and
// stuffs them into ProviderSnapshot.extras as a comma-joined string so the
// existing JSON codec forwards them without changes.
//
// Keys produced (all optional, only attached if data exists):
//   history7     — 7 daily values, oldest first, comma-separated
//   historyMax   — the max value in history7 (for normalizing bars in JS)
//   historyUnit  — "tokens" | "usd" | "chars" | "reqs"
//   historyTrend — "+23%" / "-14%" / "flat" (today vs 7-day avg excluding today)

enum HistoryHydrator {
    static func attachHistory(to snap: ProviderSnapshot) -> ProviderSnapshot {
        var s = snap
        guard let (values, unit) = seriesForProvider(id: snap.id) else { return s }
        let maxV = values.max() ?? 0
        guard maxV > 0 else { return s }

        s.extras["history7"] = values.map { formatNumber($0) }.joined(separator: ",")
        s.extras["historyMax"] = formatNumber(maxV)
        s.extras["historyUnit"] = unit

        // Trend vs the 6-day leading average (exclude today to avoid trivial
        // correlation).
        let today = values.last ?? 0
        let leading = values.dropLast()
        let avgLeading = leading.isEmpty ? 0 : leading.reduce(0, +) / Double(leading.count)
        if avgLeading > 0 {
            let delta = (today - avgLeading) / avgLeading
            if abs(delta) < 0.05 {
                s.extras["historyTrend"] = "flat"
            } else {
                let sign = delta > 0 ? "+" : "-"
                s.extras["historyTrend"] = "\(sign)\(Int(abs(delta) * 100))%"
            }
        }
        return s
    }

    /// Returns (series, unitLabel) — picks the right metric per provider.
    private static func seriesForProvider(id: String) -> ([Double], String)? {
        let store = PersistentStore.shared
        switch id {
        case "claude_code", "codex":
            let v = store.history(provider: id, metric: .billable, days: 7)
            return (v, "tokens")
        case "elevenlabs":
            let v = store.history(provider: id, metric: .reqs, days: 7)
            // Fall back to billable (char count) if requests aren't tracked.
            if v.reduce(0, +) == 0 {
                return (store.history(provider: id, metric: .billable, days: 7), "chars")
            }
            return (v, "reqs")
        case "openrouter":
            let v = store.dailySpendDeltas(provider: id, days: 7)
            return (v, "usd")
        default:
            return nil
        }
    }

    private static func formatNumber(_ v: Double) -> String {
        if v == floor(v), abs(v) < 1e15 {
            return String(Int64(v))
        }
        return String(format: "%.4f", v)
    }
}
