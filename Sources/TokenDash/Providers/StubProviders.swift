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

            // Request counts from /v1/history (TTS generations).
            let cal = Calendar.current
            let startOfToday = Int(cal.startOfDay(for: Date()).timeIntervalSince1970)
            let startOfYesterday = Int(cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date()))!.timeIntervalSince1970)
            let counts = (try? await fetchRequestCounts(key: key,
                                                       todayStart: startOfToday,
                                                       yesterdayStart: startOfYesterday))
                ?? (today: 0, yesterday: 0, charsToday: 0)
            let reqTrend = Fmt.trend(from: counts.yesterday, to: counts.today) ?? ""

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
                    "reqsToday": "\(counts.today)",
                    "reqsYesterday": "\(counts.yesterday)",
                    "reqTrend": reqTrend,
                    "charsToday": Fmt.int(counts.charsToday),
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
        let voice_slots_used: Int?
        let voice_limit: Int?
    }

    private func fetchSubscription(key: String) async throws -> SubscriptionResponse {
        try await APIClient.shared.getJSON(
            SubscriptionResponse.self,
            url: URL(string: "https://api.elevenlabs.io/v1/user/subscription")!,
            headers: ["xi-api-key": key]
        )
    }

    // Paginate through /v1/history and count TTS requests in the last 2 days.
    // Also sums character_count for "today" bucket so we can show per-day chars
    // (more useful than cycle total for bursty voice-game workloads).
    private func fetchRequestCounts(key: String,
                                    todayStart: Int,
                                    yesterdayStart: Int) async throws -> (today: Int, yesterday: Int, charsToday: Int) {
        var today = 0
        var yesterday = 0
        var charsToday = 0
        var startAfter: String? = nil
        for _ in 0..<5 {   // hard cap: 5 pages × 1000 = 5000 items
            var urlStr = "https://api.elevenlabs.io/v1/history?page_size=1000"
            if let sa = startAfter {
                urlStr += "&start_after_history_item_id=\(sa)"
            }
            guard let url = URL(string: urlStr) else { break }
            let data = try await APIClient.shared.getData(url: url, headers: ["xi-api-key": key])
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = obj["history"] as? [[String: Any]] else { break }
            var hitOld = false
            for item in items {
                guard let ts = item["date_unix"] as? Int else { continue }
                if ts >= todayStart {
                    today += 1
                    if let from = item["character_count_change_from"] as? Int,
                       let to = item["character_count_change_to"] as? Int {
                        charsToday += max(0, to - from)
                    }
                } else if ts >= yesterdayStart {
                    yesterday += 1
                } else {
                    hitOld = true
                }
            }
            if hitOld { break }
            guard let hasMore = obj["has_more"] as? Bool, hasMore else { break }
            guard let next = obj["last_history_item_id"] as? String, !next.isEmpty else { break }
            startAfter = next
        }
        return (today, yesterday, charsToday)
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

            // Top models over the last 7 days, best-effort. This endpoint needs
            // additional OAuth scopes in some accounts — failure is silent, the
            // card still shows credits.
            var topModels: [[String: Any]] = []
            if let activity = try? await fetchActivity(key: key) {
                topModels = activity.prefix(3).map { entry in
                    [
                        "name":   entry.name,
                        "spend":  String(format: "$%.2f", entry.spend),
                        "reqs":   entry.requests,
                    ]
                }
            }

            var extras: [String: String] = [
                "credits": headline,
                "spendLabel": spend,
                "spendUsd": String(c.total_usage),
                "creditsUsd": String(remaining),
            ]
            if !topModels.isEmpty,
               let data = try? JSONSerialization.data(withJSONObject: topModels),
               let s = String(data: data, encoding: .utf8) {
                extras["topModels"] = s
            }

            return ProviderSnapshot(
                id: id, title: displayName, subtitle: "Pay-as-you-go",
                glyph: "O", accent: .ocean, size: .compact,
                headline: headline, headlineCaption: "credits left",
                state: .ok,
                note: spend,
                extras: extras
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
        let envelope = try await APIClient.shared.getJSON(
            CreditsEnvelope.self,
            url: URL(string: "https://openrouter.ai/api/v1/credits")!,
            headers: ["Authorization": "Bearer \(key)"]
        )
        return envelope.data
    }

    // MARK: Activity breakdown

    // OpenRouter /api/v1/activity returns per-day rows with model + spend.
    // We collapse by model over the last 7 days. This endpoint may 404 on
    // some accounts — that's fine, we treat it as "no breakdown available".
    struct ActivityEntry {
        var name: String
        var spend: Double
        var requests: Int
    }

    private func fetchActivity(key: String) async throws -> [ActivityEntry] {
        let data = try await APIClient.shared.getData(
            url: URL(string: "https://openrouter.ai/api/v1/activity")!,
            headers: ["Authorization": "Bearer \(key)"]
        )
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["data"] as? [[String: Any]] else { return [] }

        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let iso = ISO8601DateFormatter()

        var byModel: [String: ActivityEntry] = [:]
        for row in rows {
            // Accept either "date" (YYYY-MM-DD) or "timestamp".
            let dateStr = (row["date"] as? String)
                ?? (row["timestamp"] as? String)
                ?? ""
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            df.locale = Locale(identifier: "en_US_POSIX")
            let d = df.date(from: dateStr) ?? iso.date(from: dateStr)
            if let d, d < cutoff { continue }

            let model = (row["model"] as? String)
                ?? (row["model_permaslug"] as? String)
                ?? "unknown"
            let spend = (row["usage"] as? Double)
                ?? (row["cost"] as? Double)
                ?? (row["total_cost"] as? Double)
                ?? 0
            let reqs = (row["requests"] as? Int) ?? (row["total_requests"] as? Int) ?? 1

            var e = byModel[model, default: .init(name: Self.prettyModel(model), spend: 0, requests: 0)]
            e.spend += spend
            e.requests += reqs
            byModel[model] = e
        }
        return byModel.values.sorted { $0.spend > $1.spend }
    }

    private static func prettyModel(_ raw: String) -> String {
        // "anthropic/claude-3.5-sonnet" → "claude 3.5 sonnet"
        let last = raw.split(separator: "/").last.map(String.init) ?? raw
        return last.replacingOccurrences(of: "-", with: " ")
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
