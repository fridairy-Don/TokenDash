import Foundation

// MARK: - Moonshot (Kimi)
//
// Two different hosts depending on where the account was registered:
//   - api.moonshot.cn  — platform.moonshot.cn     (China mainland)
//   - api.moonshot.ai  — platform.kimi.ai / .ai   (international)
// Same path, same auth, same payload shape. We try whichever host succeeds.
//
// Balance endpoint returns three numbers:
//   available_balance — what you can actually spend right now
//   voucher_balance   — promo credits
//   cash_balance      — paid top-ups
//
// Subscription/quota isn't exposed so the card is quota-free: it just
// shows your spendable balance and flags when it crosses a low-water mark.
final class MoonshotProvider: UsageProvider {
    let id = "moonshot"
    let displayName = "Moonshot (Kimi)"

    // Stable ordering: .ai first because platform.kimi.ai traffic is more
    // likely to hit .ai; a .cn key trying .ai returns 401 quickly and we
    // fall through.
    private static let hosts = [
        "https://api.moonshot.ai",
        "https://api.moonshot.cn",
    ]

    func snapshot() async -> ProviderSnapshot {
        guard let key = KeyStore.load(account: id), !key.isEmpty else {
            return unconfigured()
        }
        do {
            let b = try await fetchBalance(key: key)
            let spend = max(0, b.available_balance)
            let headline = String(format: "¥%.2f", spend)
            let cashFmt  = String(format: "¥%.2f", b.cash_balance)
            let vchFmt   = String(format: "¥%.2f", b.voucher_balance)
            // Low-balance flag — nudge the menu-bar icon toward warn/danger
            // when spendable drops below a common top-up amount. Moonshot
            // doesn't give us a "total" so we pick a pragmatic threshold.
            var extras: [String: String] = [
                "headline":       headline,
                "availableRmb":   String(format: "%.2f", b.available_balance),
                "voucherRmb":     String(format: "%.2f", b.voucher_balance),
                "cashRmb":        String(format: "%.2f", b.cash_balance),
                "cashLabel":      cashFmt,
                "voucherLabel":   vchFmt,
            ]
            // Translate absolute balance into a rough "pct-used" so the
            // global dot aggregator can flag it. Anything under ¥10 is
            // warn-level; under ¥2 is danger.
            let pctUsed: Int
            if spend < 2      { pctUsed = 95 }
            else if spend < 10 { pctUsed = 80 }
            else                { pctUsed = 0 }
            if pctUsed > 0 { extras["pct"] = "\(pctUsed)" }

            return ProviderSnapshot(
                id: id, title: displayName, subtitle: "Pay-as-you-go",
                glyph: "M", accent: .slate, size: .compact,
                headline: headline, headlineCaption: "available",
                state: .ok,
                note: "Cash \(cashFmt) · Voucher \(vchFmt)",
                extras: extras
            )
        } catch {
            return ProviderSnapshot(
                id: id, title: displayName, subtitle: "Pay-as-you-go",
                glyph: "M", accent: .slate, size: .compact,
                headline: "—", headlineCaption: "api error",
                state: .error,
                note: "Moonshot API error"
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

    private func fetchBalance(key: String) async throws -> BalanceData {
        var lastError: Error = NSError(domain: "Moonshot", code: -1,
                                       userInfo: [NSLocalizedDescriptionKey: "no hosts tried"])
        for host in Self.hosts {
            guard let url = URL(string: "\(host)/v1/users/me/balance") else { continue }
            do {
                let env = try await APIClient.shared.getJSON(
                    BalanceEnvelope.self, url: url,
                    headers: ["Authorization": "Bearer \(key)"]
                )
                return env.data
            } catch {
                lastError = error
                continue   // try next host
            }
        }
        throw lastError
    }
}
