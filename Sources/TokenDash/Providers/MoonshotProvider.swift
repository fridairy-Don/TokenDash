import Foundation

// MARK: - Moonshot (Kimi)
//
// Two different hosts depending on where the account was registered:
//   - api.moonshot.ai  — platform.kimi.ai / international   (USD)
//   - api.moonshot.cn  — platform.moonshot.cn / China       (RMB)
// Keys are region-locked; we try .ai first (fits the international kimi.ai
// platform), fall back to .cn, and remember which succeeded so we can
// label balances with the right currency.
//
// What we surface:
//   - Card headline: available balance in the account's native currency.
//   - Drawer tiles: cash · voucher · spent today · models count.
//   - Drawer model list: what the key can actually invoke, grouped by
//     context length (k8 / k32 / k128) — handy when you're rotating
//     between model sizes for agent workloads.
//   - Spent-today is derived locally (balance(yesterday) − balance(now))
//     because Moonshot doesn't expose a per-day usage endpoint.
final class MoonshotProvider: UsageProvider {
    let id = "moonshot"
    let displayName = "Moonshot (Kimi)"

    // Stable ordering: .ai first because platform.kimi.ai traffic is more
    // likely to hit .ai; a .cn key trying .ai returns 401 quickly and we
    // fall through.
    private struct Host {
        let base: String
        let currency: String     // "$" or "¥"
        let region: String       // "international" or "china"
    }
    private static let hosts: [Host] = [
        Host(base: "https://api.moonshot.ai", currency: "$", region: "international"),
        Host(base: "https://api.moonshot.cn", currency: "¥", region: "china"),
    ]

    func snapshot() async -> ProviderSnapshot {
        guard let key = KeyStore.load(account: id), !key.isEmpty else {
            return unconfigured()
        }
        do {
            // Try each host until one answers, remember which worked.
            let (balance, host) = try await fetchBalance(key: key)
            // Same host for models — currency-correct and avoids another
            // round of host detection.
            let models = (try? await fetchModels(key: key, host: host)) ?? []

            let spend = max(0, balance.available_balance)
            let cur = host.currency
            let headline = formatMoney(spend, currency: cur)
            let cashFmt  = formatMoney(balance.cash_balance, currency: cur)
            let vchFmt   = formatMoney(balance.voucher_balance, currency: cur)

            // Low-balance flag for the menu-bar dot. Thresholds differ by
            // currency — ¥10 ≈ $1.40, so we need per-region values rather
            // than a single hard-coded number.
            let (warnAt, dangerAt): (Double, Double) = cur == "$"
                ? (2, 0.5)       // $2 = amber, $0.50 = red
                : (10, 2)        // ¥10 = amber, ¥2 = red
            let pctUsed: Int =
                spend < dangerAt ? 95 :
                spend < warnAt   ? 80 :
                0

            // --- Derived spend metrics from PersistentStore balance history ---
            // Moonshot has no usage endpoint, so everything comes from balance
            // deltas we record ourselves. Prefer intraday deltas (first snapshot
            // today vs current) over day-boundary deltas — that way "spent
            // today" is non-zero from the first hour of use, not from day 2.
            //   spent today    = balance(first snapshot today) − current
            //   burn per hour  = balance(1h ago) − current, clipped to window
            //   avg $/day      = mean of non-zero daily deltas over 7 days
            //   days left      = current balance ÷ avg $/day
            let intraday = await loadIntraday()
            let (spendToday, sinceTs) = computeIntradaySpend(
                current: spend, intraday: intraday
            )
            let fallbackSpend = await computeSpendFromYesterday(currentBalance: spend)
            let spendTodayFinal = max(spendToday, fallbackSpend)
            let spendTodayLabel = formatMoney(max(0, spendTodayFinal), currency: cur)

            let burnPerHour = await computeBurnPerHour(current: spend)
            let burnPerHourLabel = formatMoney(max(0, burnPerHour), currency: cur) + "/hr"

            // Hour buckets for the 24h chart — balance at end of each hour
            // (0 = no snapshot in that hour). `hourlyBurn` is the $ drop in
            // each hour, clipped to zero (covers top-ups).
            let (hourlyBalance, hourlyBurn) = bucketHourly(
                intraday: intraday, currentBalance: spend
            )
            let sinceLabel: String = {
                guard let ts = sinceTs else { return "" }
                let df = DateFormatter()
                df.dateFormat = "HH:mm"
                return "since \(df.string(from: ts))"
            }()

            let history = PersistentStore.shared.dailyBalanceSpend(provider: id, days: 7)
            let nonZero = history.filter { $0 > 0 }
            let avgPerDay = nonZero.isEmpty ? 0 : nonZero.reduce(0, +) / Double(nonZero.count)
            let avgPerDayLabel = formatMoney(avgPerDay, currency: cur)
            let daysLeft: Int? = avgPerDay > 0.001
                ? Int((spend / avgPerDay).rounded(.down))
                : nil

            // Model list: only the ids; the drawer renders them as a
            // collapsible footer, not the main content. Agent operators
            // usually care about cost, not model catalog.
            let modelIds = models.map { $0.id }
            let groups = Self.groupModels(modelIds)

            // Balance trajectory: last 7 days of absolute balance snapshots.
            // Unlike spend deltas (history7), this has at least today's point
            // on day one — so the chart isn't empty while data accumulates.
            let balance7 = PersistentStore.shared.history(provider: id, metric: .credits, days: 7)

            var extras: [String: String] = [
                "region":          host.region,
                "currency":        cur,
                "availableLabel":  headline,
                "availableNum":    String(format: "%.4f", balance.available_balance),
                "cashLabel":       cashFmt,
                "voucherLabel":    vchFmt,
                "spentTodayLabel": spendTodayLabel,
                "spentTodayNum":   String(format: "%.4f", max(0, spendTodayFinal)),
                "sinceLabel":      sinceLabel,
                "burnPerHourLabel": burnPerHourLabel,
                "burnPerHourNum":   String(format: "%.4f", max(0, burnPerHour)),
                "avgPerDayLabel":  avgPerDayLabel,
                "avgPerDayNum":    String(format: "%.4f", avgPerDay),
                "modelsCount":     "\(models.count)",
                "headline":        headline,
                // Hourly arrays for the 24h drawer chart. Comma-separated so the
                // existing CSV decoder in DataStore+TDData can forward them.
                "hourlyBalance":   hourlyBalance.map { String(format: "%.4f", $0) }.joined(separator: ","),
                "hourlyBurn":      hourlyBurn.map { String(format: "%.4f", $0) }.joined(separator: ","),
                // Fed to PersistentStore so the daily table accumulates the
                // balance series that everything above reads from.
                "creditsUsd":      String(balance.available_balance),
            ]
            if pctUsed > 0 { extras["pct"] = "\(pctUsed)" }
            if let daysLeft = daysLeft {
                extras["daysLeft"] = "\(daysLeft)"
            }
            if !modelIds.isEmpty,
               let data = try? JSONSerialization.data(withJSONObject: modelIds),
               let s = String(data: data, encoding: .utf8) {
                extras["modelIds"] = s
            }
            if !groups.isEmpty,
               let data = try? JSONSerialization.data(withJSONObject: groups),
               let s = String(data: data, encoding: .utf8) {
                extras["modelGroups"] = s
            }
            // balance7 is always emitted (may be mostly zeros on day 1) so the
            // drawer can render "today's dot" immediately, without waiting for
            // 7 days of history. JS treats 0 as "no snapshot that day".
            extras["balance7"] = balance7.map { String(format: "%.4f", $0) }.joined(separator: ",")

            // Subtitle note — front-loads the question "did I burn money today?".
            // Falls back to cash/voucher breakdown when we don't have intraday data
            // yet (first minute after install).
            let note: String
            if spendTodayFinal > 0.0001 {
                if burnPerHour > 0.0001 {
                    note = "\(spendTodayLabel) today · \(burnPerHourLabel)"
                } else if let daysLeft = daysLeft {
                    note = "\(spendTodayLabel) today · ~\(daysLeft > 365 ? "365+" : "\(daysLeft)")d left"
                } else {
                    note = "\(spendTodayLabel) today"
                }
            } else if let daysLeft = daysLeft {
                note = "\(avgPerDayLabel)/day · ~\(daysLeft > 365 ? "365+" : "\(daysLeft)")d left"
            } else {
                note = "Cash \(cashFmt)"
            }

            return ProviderSnapshot(
                id: id, title: displayName,
                subtitle: host.region == "international" ? "Kimi · international" : "Kimi · CN",
                glyph: "M", accent: .slate, size: .compact,
                headline: headline, headlineCaption: "available",
                state: .ok,
                note: note,
                extras: extras
            )
        } catch {
            return ProviderSnapshot(
                id: id, title: displayName, subtitle: "Pay-as-you-go",
                glyph: "M", accent: .slate, size: .compact,
                headline: "—", headlineCaption: "api error",
                state: .error,
                note: "Moonshot API error — check that the key matches the platform (platform.kimi.ai vs platform.moonshot.cn)"
            )
        }
    }

    private func unconfigured() -> ProviderSnapshot {
        ProviderSnapshot(
            id: id, title: displayName, subtitle: "Pay-as-you-go",
            glyph: "M", accent: .slate, size: .compact,
            headline: "Add key", headlineCaption: "to see balance",
            state: .unconfigured,
            note: "API key not configured"
        )
    }

    // MARK: - API

    private struct BalanceEnvelope: Decodable {
        let data: BalanceData
    }
    private struct BalanceData: Decodable {
        let available_balance: Double
        let voucher_balance:   Double
        let cash_balance:      Double
    }

    private struct ModelsEnvelope: Decodable {
        let data: [ModelEntry]
    }
    private struct ModelEntry: Decodable {
        let id: String
        let owned_by: String?
    }

    private func fetchBalance(key: String) async throws -> (BalanceData, Host) {
        var lastError: Error = NSError(domain: "Moonshot", code: -1,
                                       userInfo: [NSLocalizedDescriptionKey: "no hosts tried"])
        for host in Self.hosts {
            guard let url = URL(string: "\(host.base)/v1/users/me/balance") else { continue }
            do {
                let env = try await APIClient.shared.getJSON(
                    BalanceEnvelope.self, url: url,
                    headers: ["Authorization": "Bearer \(key)"]
                )
                return (env.data, host)
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    private func fetchModels(key: String, host: Host) async throws -> [ModelEntry] {
        guard let url = URL(string: "\(host.base)/v1/models") else { return [] }
        let env = try await APIClient.shared.getJSON(
            ModelsEnvelope.self, url: url,
            headers: ["Authorization": "Bearer \(key)"]
        )
        return env.data
    }

    // MARK: - Helpers

    private func formatMoney(_ v: Double, currency: String) -> String {
        // Small balances need more precision (four-decimal for $ under $1),
        // otherwise 2 decimals is the norm for wallet displays.
        if currency == "$" && v > 0 && v < 1 {
            return String(format: "$%.4f", v)
        }
        return "\(currency)\(String(format: "%.2f", v))"
    }

    /// Load today's intraday balance snapshots off the DB queue.
    @MainActor
    private func loadIntraday() async -> [(ts: Date, credits: Double)] {
        PersistentStore.shared.intradayCredits(provider: id)
    }

    /// Today's burn = earliest-snapshot-today's balance − current balance.
    /// This makes the number non-zero from the second refresh of the day,
    /// instead of waiting until tomorrow for day-boundary deltas to work.
    /// Top-ups mid-day register as 0 (we can't disambiguate spend vs top-up
    /// from balance alone without finer intraday sampling — acceptable).
    private func computeIntradaySpend(
        current: Double,
        intraday: [(ts: Date, credits: Double)]
    ) -> (spent: Double, since: Date?) {
        guard let first = intraday.first else { return (0, nil) }
        // If first snapshot is lower than current, user topped up — no burn yet.
        let delta = first.credits - current
        return (max(0, delta), first.ts)
    }

    /// Last-hour burn rate. Looks for a snapshot ≥ 1h old; if the app only
    /// just launched today, scales down to whatever window we have.
    @MainActor
    private func computeBurnPerHour(current: Double) async -> Double {
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)
        guard let past = PersistentStore.shared.creditsAt(provider: id, atOrBefore: oneHourAgo) else {
            // Not enough history — scale from the earliest intraday snapshot.
            let intraday = PersistentStore.shared.intradayCredits(provider: id)
            guard let first = intraday.first else { return 0 }
            let hours = max(0.1, now.timeIntervalSince(first.ts) / 3600)
            let delta = first.credits - current
            return max(0, delta) / hours
        }
        return max(0, past - current)
    }

    /// Yesterday-end − today's current, used as a fallback for "spent today"
    /// when there's already a closed yesterday bucket but no intraday data
    /// (first launch of the day).
    @MainActor
    private func computeSpendFromYesterday(currentBalance: Double) async -> Double {
        let history = PersistentStore.shared.history(provider: id, metric: .credits, days: 2)
        let yesterday = history.first(where: { $0 > 0 }) ?? 0
        if yesterday <= 0 { return 0 }
        return max(0, yesterday - currentBalance)
    }

    /// Bucket today's snapshots into 24 one-hour bins. Each bin holds the
    /// last credit value seen during that hour (or 0 for empty bins). The
    /// "burn" series is the drop from the previous populated bin — this is
    /// what the drawer's hourly bar chart renders.
    private func bucketHourly(
        intraday: [(ts: Date, credits: Double)],
        currentBalance: Double
    ) -> (balance: [Double], burn: [Double]) {
        var balance = [Double](repeating: 0, count: 24)
        let cal = Calendar.current
        for (ts, credits) in intraday {
            let h = cal.component(.hour, from: ts)
            if h >= 0 && h < 24 {
                balance[h] = credits   // last write wins — end-of-hour balance
            }
        }
        // Fill empty trailing bins with the current hour's balance, so the
        // chart reads as a flat balance (not zero) across quiet hours.
        let currentHour = cal.component(.hour, from: Date())
        if currentHour < 24 { balance[currentHour] = currentBalance }

        // Compute per-hour burn as drop from previous populated bin.
        var burn = [Double](repeating: 0, count: 24)
        var prev: Double = 0
        for h in 0..<24 {
            if balance[h] > 0 {
                if prev > 0 {
                    burn[h] = max(0, prev - balance[h])
                }
                prev = balance[h]
            }
        }
        return (balance, burn)
    }

    // Group model ids by context-window tier so the drawer can show them as
    // "8k / 32k / 128k / auto / other" buckets — which is what an agent
    // operator actually wants to know: "can this key talk to kimi-k2 1m?".
    // Returns a stable-ordered array of {bucket, label, ids}.
    private static func groupModels(_ ids: [String]) -> [[String: Any]] {
        // Bucket key → (displayLabel, sortOrder)
        let order: [(String, String, Int)] = [
            ("8k",    "8k",     1),
            ("32k",   "32k",    2),
            ("128k",  "128k",   3),
            ("256k",  "256k",   4),
            ("1m",    "1M",     5),
            ("auto",  "auto",   6),
            ("latest","latest", 7),
            ("vision","vision", 8),
            ("think", "thinking", 9),
            ("other", "other",  99),
        ]
        var buckets: [String: [String]] = [:]
        for id in ids {
            let lower = id.lowercased()
            let key: String
            if lower.contains("vision") { key = "vision" }
            else if lower.contains("think") { key = "think" }
            else if lower.contains("latest") { key = "latest" }
            else if lower.contains("auto") { key = "auto" }
            else if lower.range(of: #"1m\b"#, options: .regularExpression) != nil { key = "1m" }
            else if lower.contains("256k") { key = "256k" }
            else if lower.contains("128k") { key = "128k" }
            else if lower.contains("32k") { key = "32k" }
            else if lower.contains("8k") { key = "8k" }
            else { key = "other" }
            buckets[key, default: []].append(id)
        }
        var out: [[String: Any]] = []
        for (key, label, _) in order {
            guard let list = buckets[key], !list.isEmpty else { continue }
            out.append([
                "bucket": key,
                "label":  label,
                "ids":    list.sorted(),
            ])
        }
        return out
    }
}
