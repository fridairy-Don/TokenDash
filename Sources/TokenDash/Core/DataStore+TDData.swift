import Foundation

// Produce the JSON payload consumed by Web/app.jsx's `window.TD_DATA`.
// Kept as a free static function so it doesn't pollute DataStore with view concerns.

extension DataStore {
    @MainActor
    static func encodeTDDataJSON(store: DataStore) -> String {
        var root: [String: Any] = [:]

        // Header subtitle — "Updated 12s ago · 2 active · 3 idle"
        let rel = store.lastRefreshed.map { Fmt.relative($0) } ?? "just now"
        let active = store.snapshots.filter { $0.state == .ok }.count
        let idle = store.snapshots.filter { $0.state != .ok }.count
        root["header"] = ["subtitle": "Updated \(rel) · \(active) active · \(idle) idle"]

        // Footer
        let nextIn = store.lastRefreshed.map { max(0, 30 - Int(Date().timeIntervalSince($0))) } ?? 0
        root["footer"] = [
            "providerCount": store.snapshots.count,
            "nextRefresh": "\(nextIn)s",
            "live": store.isRefreshing ? "refreshing" : "live",
        ]

        // Hero cards
        for snap in store.snapshots where snap.size == .hero {
            switch snap.id {
            case "claude_code":
                root["claude"] = claudePayload(snap)
            case "codex":
                root["codex"] = codexPayload(snap)
            default:
                break
            }
        }

        // Compact cards
        let compacts = store.snapshots.filter { $0.size == .compact }
        root["providers"] = compacts.map { compactPayload($0) }

        // Which API keys are stored — Settings UI uses this to render per-provider
        // rows. We only expose whether the key exists; the key itself never leaves
        // Keychain.
        root["keyStatus"] = [
            "elevenlabs": Keychain.hasKey(account: "elevenlabs"),
            "openrouter": Keychain.hasKey(account: "openrouter"),
            "groq":       Keychain.hasKey(account: "groq"),
        ]

        let data = (try? JSONSerialization.data(withJSONObject: root, options: [])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func claudePayload(_ s: ProviderSnapshot) -> [String: Any] {
        var out: [String: Any] = [
            "name": s.title,
            "pill": s.subtitle ?? "",
            "today": s.headline,
        ]
        if let trend = s.trendCaption { out["trend"] = trend }

        // Sparkline values in "M" units (kept for any future use; primary view now uses dayBuckets)
        out["spark"] = s.dailyBuckets.map { Double($0) / 1_000_000.0 }

        // Models
        out["models"] = s.modelMix.map { ["name": $0.name, "pct": percentOfMix($0, in: s.modelMix)] }

        // Drawer data
        let weekTotal = s.stats.first(where: { $0.label.contains("7-day") })?.value ?? "—"
        let monthTotal = s.stats.first(where: { $0.label.contains("Month") })?.value ?? "—"
        out["weekTotal"] = weekTotal
        out["monthTotal"] = monthTotal
        out["dayBuckets"] = s.dailyBuckets.map { Double($0) / 1_000_000.0 }
        out["dayLabels"] = s.dayLabels
        out["dayUnits"] = "M"
        out["weeklyAvg"] = Fmt.tokens(s.weeklyAverage)
        out["topSessions"] = s.topSessions.map { session -> [String: Any] in
            [
                "time": session.timeLabel,
                "tokens": Fmt.tokens(session.tokens),
                "duration": session.duration,
            ]
        }

        return out
    }

    private static func codexPayload(_ s: ProviderSnapshot) -> [String: Any] {
        var out: [String: Any] = [
            "name": s.title,
            "pill": s.subtitle ?? "",
            "today": s.headline,
        ]
        if let m = s.modelMix.first { out["model"] = m.name }
        out["quotas"] = s.quotas.map { q -> [String: Any] in
            [
                "label": q.label,
                "pct": round(q.percent * 1000) / 10,
                "resets": q.caption ?? "",
                "warn": q.percent >= 0.85,
            ]
        }
        // Drawer data — same shape as Claude so the drawer can render either hero.
        let weekTotal = s.stats.first(where: { $0.label.contains("7-day") })?.value ?? "—"
        let monthTotal = s.stats.first(where: { $0.label.contains("Month") })?.value ?? "—"
        out["weekTotal"] = weekTotal
        out["monthTotal"] = monthTotal
        out["dayBuckets"] = s.dailyBuckets.map { Double($0) / 1_000_000.0 }
        out["dayLabels"] = s.dayLabels
        out["dayUnits"] = "M"
        out["weeklyAvg"] = Fmt.tokens(s.weeklyAverage)
        out["models"] = s.modelMix.map { ["name": $0.name, "pct": percentOfMix($0, in: s.modelMix)] }
        out["topSessions"] = s.topSessions.map { session -> [String: Any] in
            [
                "time": session.timeLabel,
                "tokens": Fmt.tokens(session.tokens),
                "duration": session.duration,
            ]
        }
        return out
    }

    private static func compactPayload(_ s: ProviderSnapshot) -> [String: Any] {
        let kind: String
        switch s.id {
        case "elevenlabs": kind = "eleven"
        case "openrouter": kind = "router"
        case "groq":       kind = "groq"
        default:           kind = "groq"
        }
        var out: [String: Any] = [
            "id": s.id,
            "kind": kind,
            "name": s.title,
            "pill": s.subtitle ?? "",
            "state": stateString(s.state),
        ]
        if let note = s.note { out["note"] = note }

        // Forward everything in extras. Parse pct back to a number so the JS
        // InlineBar can render it without doing its own parseInt.
        for (k, v) in s.extras {
            if k == "pct", let n = Int(v) {
                out[k] = n
            } else {
                out[k] = v
            }
        }
        return out
    }

    private static func stateString(_ s: ProviderState) -> String {
        switch s {
        case .ok:            return "ok"
        case .empty:         return "empty"
        case .error:         return "error"
        case .unconfigured:  return "unconfigured"
        }
    }

    private static func percentOfMix(_ share: ModelShare, in shares: [ModelShare]) -> Int {
        let total = max(1, shares.reduce(0) { $0 + $1.tokens })
        return Int(round(Double(share.tokens) / Double(total) * 100))
    }
}
