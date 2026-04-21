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

            // --- Derived "spent today" from PersistentStore history --------
            // Moonshot doesn't hand us a per-day usage feed, so reconstruct
            // it from balance deltas: yesterday-end minus today-current, if
            // positive. Across a whole week, the PersistentStore daily table
            // has one row per day with credits_usd = balance at that point,
            // which is good enough.
            let spendToday = await computeSpendToday(currentBalance: spend)
            let spendTodayLabel = spendToday > 0
                ? formatMoney(spendToday, currency: cur)
                : formatMoney(0, currency: cur)

            // --- Model list for the drawer --------------------------------
            // Group by context window parsed from the id suffix (e.g.
            // "moonshot-v1-32k" → 32k). Newer Kimi models encode the
            // context length the same way.
            let modelPayload: [[String: Any]] = models
                .sorted { Self.contextLengthBucket($0.id) < Self.contextLengthBucket($1.id) }
                .map { m -> [String: Any] in
                    [
                        "id":     m.id,
                        "name":   Self.prettyModelName(m.id),
                        "ctxK":   Self.contextLengthBucket(m.id),
                        "owner":  m.owned_by ?? "moonshot",
                    ]
                }

            var extras: [String: String] = [
                "region":          host.region,
                "currency":        cur,
                "availableLabel":  headline,
                "availableNum":    String(format: "%.4f", balance.available_balance),
                "cashLabel":       cashFmt,
                "voucherLabel":    vchFmt,
                "spentTodayLabel": spendTodayLabel,
                "spentTodayNum":   String(format: "%.4f", spendToday),
                "modelsCount":     "\(models.count)",
                "headline":        headline,
                // Fed to PersistentStore so we build up a balance-history
                // series that `computeSpendToday` can consume next refresh.
                "creditsUsd":      String(balance.available_balance),
            ]
            if pctUsed > 0 { extras["pct"] = "\(pctUsed)" }
            if !modelPayload.isEmpty,
               let data = try? JSONSerialization.data(withJSONObject: modelPayload),
               let s = String(data: data, encoding: .utf8) {
                extras["models"] = s
            }

            let note: String
            if models.isEmpty {
                note = "Cash \(cashFmt) · Voucher \(vchFmt)"
            } else {
                note = "Cash \(cashFmt) · \(models.count) models"
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
