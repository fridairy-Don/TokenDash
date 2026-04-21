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
        guard let key = KeyStore.load(account: id), !key.isEmpty else {
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
            let h = (try? await fetchRequestCounts(key: key,
                                                    todayStart: startOfToday,
                                                    yesterdayStart: startOfYesterday))
                ?? ElevenHistory()
            let reqTrend = Fmt.trend(from: h.yesterday, to: h.today) ?? ""

            // --- Derived stats for the drawer ------------------------------
            let avgChars = h.today > 0 ? h.charsToday / h.today : 0
            // Abuse detector: a single hour carrying much more than the
            // active-hour average is suspicious for a kid's TTS game.
            let nonZeroHours = h.hourBuckets.filter { $0 > 0 }
            let hourMean = nonZeroHours.isEmpty ? 0 : nonZeroHours.reduce(0, +) / nonZeroHours.count
            let maxHourIdx = h.hourBuckets.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
            let maxHour = h.hourBuckets[maxHourIdx]
            // Flag only when today has a meaningful burst (≥5x the non-zero
            // hour mean AND absolute >30 requests in one hour) — hand-tuned
            // to not false-positive on a typical 10-req play session.
            let anomalyHour: Int? = (maxHour >= max(30, hourMean * 5) && hourMean > 0) ? maxHourIdx : nil

            // Top voices (by request count, today)
            let topVoices = h.byVoice
                .sorted { $0.value.reqs > $1.value.reqs }
                .prefix(5)
                .map { (name, v) -> [String: Any] in
                    [
                        "name":  name,
                        "reqs":  v.reqs,
                        "chars": v.chars,
                    ]
                }

            var extras: [String: String] = [
                "pct": "\(pct)",
                "usedLabel": used_s,
                "totalLabel": total_s,
                "resets": resetText,
                "reqsToday": "\(h.today)",
                "reqsYesterday": "\(h.yesterday)",
                "reqTrend": reqTrend,
                "charsToday": Fmt.int(h.charsToday),
                "avgChars": "\(avgChars)",
                "maxCharsReq": "\(h.maxCharsInSingleReq)",
                "peakHourIdx": "\(maxHourIdx)",
                "peakHourReqs": "\(maxHour)",
                // For PersistentStore: billable = cycle character usage,
                // useful as a secondary metric for char-consumption sparklines.
                "billable": "\(used)",
            ]
            if let anomalyHour = anomalyHour {
                extras["anomalyHour"] = "\(anomalyHour)"
                extras["anomalyHourReqs"] = "\(maxHour)"
            }
            // Hour bucket arrays as CSV — DataStore+TDData expands to real JS arrays.
            extras["hourBucketsReqs"]  = h.hourBuckets.map(String.init).joined(separator: ",")
            extras["hourBucketsChars"] = h.charBuckets.map(String.init).joined(separator: ",")
            if !topVoices.isEmpty,
               let data = try? JSONSerialization.data(withJSONObject: topVoices),
               let s = String(data: data, encoding: .utf8) {
                extras["topVoices"] = s
            }

            return ProviderSnapshot(
                id: id, title: displayName, subtitle: tier,
                glyph: "E", accent: .sand, size: .compact,
                headline: "\(pct)%", headlineCaption: resetText,
                secondaryValue: "\(used_s) / \(total_s)",
                state: .ok,
                note: resetText,
                extras: extras
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

    // Rich ElevenLabs history aggregate: 2-day request counts + today's
    // hourly distribution + per-voice breakdown + character statistics, so
    // the drawer can render a monitoring view useful for:
    //   - kid's TTS game (which voice/animal is popular right now)
    //   - detecting credential leak / abuse bursts (off-hours spikes,
    //     abnormally long per-request chars, concentration on one voice)
    struct ElevenHistory {
        var today: Int = 0
        var yesterday: Int = 0
        var charsToday: Int = 0
        var hourBuckets: [Int] = Array(repeating: 0, count: 24)   // reqs per local hour today
        var charBuckets: [Int] = Array(repeating: 0, count: 24)   // chars per local hour today
        var byVoice: [String: (reqs: Int, chars: Int)] = [:]      // today only
        var maxCharsInSingleReq: Int = 0
        var charSamplesToday: [Int] = []                          // for stddev / histogram
    }

    private func fetchRequestCounts(key: String,
                                    todayStart: Int,
                                    yesterdayStart: Int) async throws -> ElevenHistory {
        var h = ElevenHistory()
        var startAfter: String? = nil
        let cal = Calendar.current
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
                let chars: Int
                if let from = item["character_count_change_from"] as? Int,
                   let to = item["character_count_change_to"] as? Int {
                    chars = max(0, to - from)
                } else {
                    chars = 0
                }
                if ts >= todayStart {
                    h.today += 1
                    h.charsToday += chars
                    let hour = cal.component(.hour, from: Date(timeIntervalSince1970: TimeInterval(ts)))
                    if hour >= 0 && hour < 24 {
                        h.hourBuckets[hour] += 1
                        h.charBuckets[hour] += chars
                    }
                    if chars > h.maxCharsInSingleReq { h.maxCharsInSingleReq = chars }
                    if chars > 0 { h.charSamplesToday.append(chars) }
                    let voice = (item["voice_name"] as? String) ?? "Unknown"
                    var v = h.byVoice[voice, default: (0, 0)]
                    v.reqs += 1
                    v.chars += chars
                    h.byVoice[voice] = v
                } else if ts >= yesterdayStart {
                    h.yesterday += 1
                } else {
                    hitOld = true
                }
            }
            if hitOld { break }
            guard let hasMore = obj["has_more"] as? Bool, hasMore else { break }
            guard let next = obj["last_history_item_id"] as? String, !next.isEmpty else { break }
            startAfter = next
        }
        return h
    }
}

// MARK: - OpenRouter ---------------------------------------------------------

final class OpenRouterProvider: UsageProvider {
    let id = "openrouter"
    let displayName = "OpenRouter"

    func snapshot() async -> ProviderSnapshot {
        guard let key = KeyStore.load(account: id), !key.isEmpty else {
            return unconfigured()
        }
        do {
            let c = try await fetchCredits(key: key)
            let remaining = max(0, c.total_credits - c.total_usage)
            let headline = String(format: "$%.2f", remaining)
            let spend = String(format: "$%.2f spent", c.total_usage)

            // Activity: per-model breakdown + today/7-day spend and reqs.
            // The endpoint may 404 on some accounts — we silently skip.
            let activity = (try? await fetchActivity(key: key)) ?? ActivityAggregate()
            // Full per-model list (drawer shows up to 8); card still uses top 3.
            let topModels: [[String: Any]] = activity.byModel.prefix(3).map { entry in
                [
                    "name":  entry.name,
                    "spend": String(format: "$%.2f", entry.spend),
                    "reqs":  entry.requests,
                ]
            }
            let modelsAll: [[String: Any]] = activity.byModel.prefix(8).map { entry in
                [
                    "name":     entry.name,
                    "spend":    String(format: "$%.2f", entry.spend),
                    "spendUsd": entry.spend,
                    "reqs":     entry.requests,
                ]
            }

            // Burn rate math — only meaningful if activity responded.
            let burnPerDay = activity.totalSpend7d / 7.0
            let daysLeft: Int? = burnPerDay > 0.001
                ? Int((remaining / burnPerDay).rounded(.down))
                : nil

            // pct of credits consumed — fed into StatusBarState.aggregate so
            // the menu-bar dot turns amber/red when the account is close to
            // empty, matching how ElevenLabs character quota drives the dot.
            let pctUsed: Int = c.total_credits > 0
                ? min(100, Int(round(c.total_usage / c.total_credits * 100)))
                : 0

            var extras: [String: String] = [
                "credits": headline,
                "spendLabel": spend,
                "spendUsd": String(c.total_usage),
                "creditsUsd": String(remaining),
                "spendToday":   String(format: "$%.2f", activity.spendToday),
                "reqsToday":    "\(activity.reqsToday)",
                "spend7d":      String(format: "$%.2f", activity.totalSpend7d),
                "reqs7d":       "\(activity.totalReqs7d)",
                "burnPerDay":   String(format: "$%.2f", burnPerDay),
            ]
            // Only emit pct when we actually have a budget to compare
            // against (credits > 0). Prevents pay-as-you-go-with-no-cap
            // accounts from showing a misleading 0% or 100% in the dot.
            if c.total_credits > 0 {
                extras["pct"] = "\(pctUsed)"
            }
            if let daysLeft = daysLeft {
                extras["daysLeft"] = "\(daysLeft)"
            }
            if !topModels.isEmpty,
               let data = try? JSONSerialization.data(withJSONObject: topModels),
               let s = String(data: data, encoding: .utf8) {
                extras["topModels"] = s
            }
            if !modelsAll.isEmpty,
               let data = try? JSONSerialization.data(withJSONObject: modelsAll),
               let s = String(data: data, encoding: .utf8) {
                extras["allModels"] = s
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
    struct ActivityAggregate {
        var byModel: [ActivityEntry] = []
        var totalSpend7d: Double = 0
        var totalReqs7d: Int = 0
        var spendToday: Double = 0
        var reqsToday: Int = 0
    }

    private func fetchActivity(key: String) async throws -> ActivityAggregate {
        let data = try await APIClient.shared.getData(
            url: URL(string: "https://openrouter.ai/api/v1/activity")!,
            headers: ["Authorization": "Bearer \(key)"]
        )
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["data"] as? [[String: Any]] else { return ActivityAggregate() }

        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        let cutoff = cal.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let iso = ISO8601DateFormatter()

        var agg = ActivityAggregate()
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

            agg.totalSpend7d += spend
            agg.totalReqs7d += reqs
            if let d, cal.isDate(d, inSameDayAs: startOfToday) {
                agg.spendToday += spend
                agg.reqsToday += reqs
            }
        }
        agg.byModel = byModel.values.sorted { $0.spend > $1.spend }
        return agg
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
        let hasKey = KeyStore.hasKey(account: id)
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
