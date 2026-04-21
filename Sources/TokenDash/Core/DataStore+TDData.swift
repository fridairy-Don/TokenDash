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
        // KeyStore. Covers built-in providers plus any user-added extras.
        var keyStatus: [String: Bool] = [:]
        for d in ProviderRegistry.descriptors where d.apiKeyHint != nil {
            keyStatus[d.type] = KeyStore.hasKey(account: d.type)
        }
        root["keyStatus"] = keyStatus

        // All provider descriptors + which extras are currently configured.
        // Settings UI uses these to render the picker + active-providers list.
        root["providerCatalog"] = ProviderRegistry.descriptors.map { d -> [String: Any] in
            var out: [String: Any] = [
                "type":        d.type,
                "displayName": d.displayName,
                "description": d.description,
                "isBuiltIn":   d.isBuiltIn,
                "needsKey":    d.apiKeyHint != nil,
            ]
            if let hint = d.apiKeyHint { out["keyHint"] = hint }
            if let url = d.docsURL     { out["docsUrl"] = url }
            return out
        }
        root["configuredExtras"] = ProviderRegistry.shared.configuredExtraTypes

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

        // M3 additions: cache hit rate + top projects (from extras)
        if let hit = s.extras["cacheHitRate"], let n = Int(hit) {
            out["cacheHitRate"] = n
        }
        if let cr = s.extras["cacheReadToday"]   { out["cacheReadToday"]  = cr }
        if let cw = s.extras["cacheWriteToday"]  { out["cacheWriteToday"] = cw }
        if let projectsJSON = s.extras["topProjects"],
           let data = projectsJSON.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            out["topProjects"] = arr
        }
        // M4 additions: message counts, peak hour, per-model in/out.
        if let m = s.extras["messagesToday"], let n = Int(m) { out["messagesToday"] = n }
        if let m = s.extras["messagesWeek"],  let n = Int(m) { out["messagesWeek"]  = n }
        if let m = s.extras["messagesMonth"], let n = Int(m) { out["messagesMonth"] = n }
        if let h = s.extras["peakHour"] { out["peakHour"] = h }
        if let mbJSON = s.extras["modelBreakdown"],
           let data = mbJSON.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            out["modelBreakdown"] = arr
        }
        // Month-level raw token breakdown for the Cache tab "real consumption"
        // bars. These are ints so the JS can format and compute ratios freely.
        if let v = s.extras["monthInput"],      let n = Int(v) { out["monthInput"]      = n }
        if let v = s.extras["monthOutput"],     let n = Int(v) { out["monthOutput"]     = n }
        if let v = s.extras["monthCacheRead"],  let n = Int(v) { out["monthCacheRead"]  = n }
        if let v = s.extras["monthCacheWrite"], let n = Int(v) { out["monthCacheWrite"] = n }
        attachHistory(snap: s, into: &out)

        return out
    }

    // Inject history7 / historyMax / historyTrend from extras into a payload dict
    // as real JSON values (array of numbers + string), so the JS side doesn't
    // need to parse CSV.
    private static func attachHistory(snap: ProviderSnapshot, into out: inout [String: Any]) {
        if let csv = snap.extras["history7"] {
            let nums = csv.split(separator: ",").compactMap { Double($0) }
            if !nums.isEmpty { out["history7"] = nums }
        }
        if let m = snap.extras["historyMax"], let n = Double(m) { out["historyMax"] = n }
        if let u = snap.extras["historyUnit"]   { out["historyUnit"] = u }
        if let t = snap.extras["historyTrend"]  { out["historyTrend"] = t }
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
        attachHistory(snap: s, into: &out)
        return out
    }

    private static func compactPayload(_ s: ProviderSnapshot) -> [String: Any] {
        let kind: String
        switch s.id {
        case "elevenlabs": kind = "eleven"
        case "openrouter": kind = "router"
        case "groq":       kind = "groq"
        case "moonshot":   kind = "moonshot"
        case "github":     kind = "github"
        case "vercel":     kind = "vercel"
        default:           kind = "generic"
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
        // InlineBar can render it without doing its own parseInt. history7 and
        // topModels/topProjects are expanded from their CSV/JSON string form.
        for (k, v) in s.extras {
            switch k {
            case "pct":
                if let n = Int(v) { out[k] = n } else { out[k] = v }
            case "history7":
                let nums = v.split(separator: ",").compactMap { Double($0) }
                if !nums.isEmpty { out["history7"] = nums }
            case "historyMax":
                if let n = Double(v) { out["historyMax"] = n }
            case "topModels", "topProjects", "topVoices", "allModels", "dailySpend", "rateBuckets":
                if let data = v.data(using: .utf8),
                   let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    out[k] = arr
                }
            case "hourBucketsReqs", "hourBucketsChars":
                let nums = v.split(separator: ",").compactMap { Int($0) }
                if !nums.isEmpty { out[k] = nums }
            case "anomalyHour", "anomalyHourReqs",
                 "peakHourIdx", "peakHourReqs",
                 "avgChars", "maxCharsReq",
                 "reqsToday", "reqs7d", "daysLeft",
                 "playSessions", "speechSeconds", "longestSessionSec",
                 "promptTokens7d", "completionTokens7d":
                if let n = Int(v) { out[k] = n } else { out[k] = v }
            default:
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
