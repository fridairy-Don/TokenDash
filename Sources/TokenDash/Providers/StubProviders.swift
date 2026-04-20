import Foundation

// Human-friendly short count: 100000 -> "100K", 1_250_000 -> "1.25M"
private func compactCount(_ n: Int) -> String {
    let d = Double(n)
    switch n {
    case ..<1_000: return "\(n)"
    case ..<1_000_000:
        return n % 1000 == 0 ? "\(n / 1000)K" : String(format: "%.1fK", d / 1_000)
    default:
        return String(format: "%.2fM", d / 1_000_000)
    }
}

// Real API providers for ElevenLabs, OpenRouter, Groq.
// API keys are fetched from Keychain on each snapshot; if absent the provider
// renders as .unconfigured so the compact card shows the "add key" hint.

// MARK: - ElevenLabs ---------------------------------------------------------

final class ElevenLabsProvider: UsageProvider {
    let id = "elevenlabs"
    let displayName = "ElevenLabs"

    func snapshot() async -> ProviderSnapshot {
        guard let key = Keychain.load(account: id), !key.isEmpty else {
            return unconfigured()
        }
        do {
            let sub = try await fetchSubscription(key: key)
            let used = sub.character_count
            let total = sub.character_limit
            let pct = total > 0 ? min(100, Int(round(Double(used) / Double(total) * 100))) : 0
            let resetText: String
            if let reset = sub.next_character_count_reset_unix, reset > 0 {
                let d = Date(timeIntervalSince1970: TimeInterval(reset))
                let df = DateFormatter()
                df.dateFormat = "MMM d"
                resetText = "resets \(df.string(from: d))"
            } else {
                resetText = ""
            }
            let tier = (sub.tier ?? "Creator").capitalized
            let used_s = Fmt.int(used)
            let total_s = compactCount(total)
            return ProviderSnapshot(
                id: id, title: displayName, subtitle: tier,
                glyph: "E", accent: .sand, size: .compact,
                headline: "\(pct)%", headlineCaption: resetText,
                secondaryValue: "\(used_s) / \(total_s)",
                state: .ok,
                note: resetText,
                extras: [
                    "pct": "\(pct)",
                    "usedLabel": used_s,
                    "totalLabel": total_s,
                    "resets": resetText,
                ]
            )
        } catch {
            return ProviderSnapshot(
                id: id, title: displayName, subtitle: "Creator",
                glyph: "E", accent: .sand, size: .compact,
                headline: "—", headlineCaption: "api error",
                state: .error,
                note: "ElevenLabs API error"
            )
        }
    }

    private func unconfigured() -> ProviderSnapshot {
        ProviderSnapshot(
            id: id, title: displayName, subtitle: "Creator",
            glyph: "E", accent: .sand, size: .compact,
            headline: "Add key", headlineCaption: "to see character usage",
            state: .unconfigured,
            note: "API key not configured"
        )
    }

    private struct SubscriptionResponse: Decodable {
        let tier: String?
        let character_count: Int
        let character_limit: Int
        let next_character_count_reset_unix: Int?
    }

    private func fetchSubscription(key: String) async throws -> SubscriptionResponse {
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/user/subscription")!)
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(SubscriptionResponse.self, from: data)
    }
}

// MARK: - OpenRouter ---------------------------------------------------------

final class OpenRouterProvider: UsageProvider {
    let id = "openrouter"
    let displayName = "OpenRouter"

    func snapshot() async -> ProviderSnapshot {
        guard let key = Keychain.load(account: id), !key.isEmpty else {
            return unconfigured()
        }
        do {
            let c = try await fetchCredits(key: key)
            let remaining = max(0, c.total_credits - c.total_usage)
            let headline = String(format: "$%.2f", remaining)
            let spend = String(format: "$%.2f spent", c.total_usage)
            return ProviderSnapshot(
                id: id, title: displayName, subtitle: "Pay-as-you-go",
                glyph: "O", accent: .ocean, size: .compact,
                headline: headline, headlineCaption: "credits left",
                state: .ok,
                note: spend,
                extras: [
                    "credits": headline,
                    "spendLabel": spend,
                ]
            )
        } catch {
            return ProviderSnapshot(
                id: id, title: displayName, subtitle: "Pay-as-you-go",
                glyph: "O", accent: .ocean, size: .compact,
                headline: "—", headlineCaption: "api error",
                state: .error,
                note: "OpenRouter API error"
            )
        }
    }

    private func unconfigured() -> ProviderSnapshot {
        ProviderSnapshot(
            id: id, title: displayName, subtitle: "Pay-as-you-go",
            glyph: "O", accent: .ocean, size: .compact,
            headline: "Add key", headlineCaption: "to see credits & spend",
            state: .unconfigured,
            note: "API key not configured"
        )
    }

    private struct CreditsEnvelope: Decodable { let data: CreditsData }
    private struct CreditsData: Decodable {
        let total_credits: Double
        let total_usage: Double
    }

    private func fetchCredits(key: String) async throws -> CreditsData {
        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/credits")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try JSONDecoder().decode(CreditsEnvelope.self, from: data)).data
    }
}

// MARK: - Groq ---------------------------------------------------------------
//
// Groq has no public quota/usage endpoint. We just acknowledge the stored key
// and let the user know the card will light up once we add proxy logging (M3+).

final class GroqProvider: UsageProvider {
    let id = "groq"
    let displayName = "Groq"

    func snapshot() async -> ProviderSnapshot {
        let hasKey = Keychain.hasKey(account: id)
        return ProviderSnapshot(
            id: id, title: displayName, subtitle: "Free tier",
            glyph: "G", accent: .slate, size: .compact,
            headline: "—",
            headlineCaption: hasKey ? "key stored" : "no usage API",
            state: .unconfigured,
            note: hasKey
                ? "key stored — Groq has no usage API yet"
                : "no usage API — key not stored"
        )
    }
}
