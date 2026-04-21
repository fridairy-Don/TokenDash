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
            // Moonshot doesn't expose per-day usage, so everything is
            // reconstructed from balance deltas stored locally:
            //   spent today   = yesterday-end balance − today's balance
            //   avg $/day     = mean of non-zero daily deltas over 7 days
            //   days left     = current balance ÷ avg $/day
            let spendToday = await computeSpendToday(currentBalance: spend)
            let spendTodayLabel = formatMoney(max(0, spendToday), currency: cur)

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

            var extras: [String: String] = [
                "region":          host.region,
                "currency":        cur,
                "availableLabel":  headline,
                "availableNum":    String(format: "%.4f", balance.available_balance),
                "cashLabel":       cashFmt,
                "voucherLabel":    vchFmt,
                "spentTodayLabel": spendTodayLabel,
                "spentTodayNum":   String(format: "%.4f", max(0, spendToday)),
                "avgPerDayLabel":  avgPerDayLabel,
                "avgPerDayNum":    String(format: "%.4f", avgPerDay),
                "modelsCount":     "\(models.count)",
                "headline":        headline,
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

            // Subtitle note — kept short; busy drawer handles the details.
            let note: String
            if let daysLeft = daysLeft {
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

    /// Derive today's spend from balance deltas. The PersistentStore `daily`
    /// table carries credits_usd = balance as of the last refresh that day.
    /// If yesterday's end-balance > today's current balance, the difference
    /// is today's burn (plus any mid-day top-ups we can't see, but that's
    /// an acceptable approximation for a menubar tool).
    @MainActor
    private func computeSpendToday(currentBalance: Double) async -> Double {
        let history = PersistentStore.shared.history(provider: id, metric: .credits, days: 2)
        // history[0] = yesterday end, history[1] = today's earlier snapshot
        guard history.count >= 1 else { return 0 }
        let yesterday = history.first(where: { $0 > 0 }) ?? 0
        if yesterday <= 0 { return 0 }
        return max(0, yesterday - currentBalance)
    }

    private static func contextLengthBucket(_ modelId: String) -> Int {
        // Pull the trailing "8k" / "32k" / "128k" from the id. Default 0
        // for models without a context suffix — they sort first.
        let lower = modelId.lowercased()
        if let m = lower.range(of: #"(\d+)k"#, options: .regularExpression) {
            let s = lower[m].dropLast()
            return Int(s) ?? 0
        }
        return 0
    }

    private static func prettyModelName(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: " ")
    }
}
