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

            // --- Play session clustering --------------------------------
            // For a kid's TTS game, "a session" is a stretch of back-to-back
            // requests. Gaps ≥ 5 minutes start a new session. Gives parents
            // a "screen time" view they can't get from ElevenLabs' own UI.
            let gapSeconds = 5 * 60
            let sortedTs = h.todayTimestamps.sorted()
            var sessionCount = 0
            var sessionDurations: [Int] = []   // seconds
            if !sortedTs.isEmpty {
                sessionCount = 1
                var sessionStart = sortedTs[0]
                var prev = sortedTs[0]
                for ts in sortedTs.dropFirst() {
                    if ts - prev >= gapSeconds {
                        sessionDurations.append(prev - sessionStart)
                        sessionCount += 1
                        sessionStart = ts
                    }
                    prev = ts
                }
                sessionDurations.append(prev - sessionStart)
            }
            let longestSessionSec = sessionDurations.max() ?? 0
            // Speech time estimate: ElevenLabs voices average ~14 chars/sec
            // at natural cadence. That's a rough-but-useful approximation
            // for "how many minutes of audio did the kid listen to today".
            let speechSeconds = h.charsToday / 14

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
            // Play-session metrics (screen-time view for the kid-game use case)
            extras["playSessions"]      = "\(sessionCount)"
            extras["speechSeconds"]     = "\(speechSeconds)"
            extras["longestSessionSec"] = "\(longestSessionSec)"
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
        var todayTimestamps: [Int] = []                           // unix seconds, for session clustering
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
                    h.todayTimestamps.append(ts)
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
            // OpenRouter restricts /activity to "management keys" — inference
            // keys (sk-or-v1-…) get a 403 with the message:
            //   "Only management keys can fetch activity for an account"
            // That's the common case, so we distinguish "unavailable" (403)
            // from "empty" and fall back to intraday-delta math derived from
            // total_usage, which we snapshot every 30s.
            var activity = ActivityAggregate()
            var activityUnavailable = false
            do {
                activity = try await fetchActivity(key: key)
            } catch let APIError.httpStatus(code, _) where code == 403 || code == 401 {
                activityUnavailable = true
            } catch {
                // Transient/decode errors — treat as empty but not as a
                // permanent "unavailable" so we don't tell the user to go
                // rotate a key when it's really just a flaky network.
            }
            // Full per-model list (drawer shows up to 8); card still uses top 3.
            let topModels: [[String: Any]] = activity.byModel.prefix(3).map { entry in
                [
                    "name":  entry.name,
                    "spend": String(format: "$%.2f", entry.spend),
                    "reqs":  entry.requests,
                ]
            }
            let modelsAll: [[String: Any]] = activity.byModel.prefix(8).map { entry -> [String: Any] in
                let totalTokens = entry.promptTokens + entry.completionTokens
                let avgPerReq = entry.requests > 0 ? entry.spend / Double(entry.requests) : 0
                // Dollars per million tokens — the apples-to-apples "which
                // model is the cheapest on this workload" metric.
                let perMillion: Double = totalTokens > 0
                    ? entry.spend / (Double(totalTokens) / 1_000_000.0)
                    : 0
                return [
                    "name":         entry.name,
                    "spend":        String(format: "$%.2f", entry.spend),
                    "spendUsd":     entry.spend,
                    "reqs":         entry.requests,
                    "promptTokens": entry.promptTokens,
                    "completionTokens": entry.completionTokens,
                    "totalTokens":  totalTokens,
                    "avgPerReq":    avgPerReq,      // raw number; JS formats
                    "perMillion":   perMillion,     // raw number; JS formats
                ]
            }
            // 7-day daily spend for the Activity tab chart (raw numbers +
            // ISO date strings; JS side formats).
            let df = DateFormatter()
            df.dateFormat = "MMM d"
            df.locale = Locale(identifier: "en_US_POSIX")
            let dailySpend: [[String: Any]] = activity.byDay.map { bucket in
                [
                    "label": df.string(from: bucket.date),
                    "spend": bucket.spend,
                    "reqs":  bucket.requests,
                ]
            }

            // Fallback today-spend + 7d-spend, derived from the cumulative
            // spend series we record ourselves. total_usage is monotonic, so
            // delta against earliest-today sample = today's burn; delta
            // against 7-day-ago sample = last week's burn. This activates
            // from the second refresh of the day for `spendToday`, and from
            // day 8 for `spend7d` — strictly better than showing 0s.
            let intraday = PersistentStore.shared.intradaySpend(provider: id)
            let spendTodayFallback: Double = {
                guard let first = intraday.first else { return 0 }
                return max(0, c.total_usage - first.spend)
            }()
            let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
            let spend7dFallback: Double = {
                guard let past = PersistentStore.shared.spendAt(provider: id, atOrBefore: sevenDaysAgo) else {
                    return 0
                }
                return max(0, c.total_usage - past)
            }()

            // Prefer real activity when we have it; otherwise fall back.
            let spendTodayFinal = activity.spendToday > 0 ? activity.spendToday : spendTodayFallback
            let spend7dFinal    = activity.totalSpend7d > 0 ? activity.totalSpend7d : spend7dFallback

            // Burn rate averages the 7-day window; on day 1 just extrapolates
            // today's spend, rounded up so daysLeft isn't wildly optimistic.
            let burnPerDay: Double = spend7dFinal > 0
                ? spend7dFinal / 7.0
                : spendTodayFinal
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
                "spendToday":   String(format: "$%.2f", spendTodayFinal),
                "reqsToday":    "\(activity.reqsToday)",
                "spend7d":      String(format: "$%.2f", spend7dFinal),
                "reqs7d":       "\(activity.totalReqs7d)",
                "burnPerDay":   String(format: "$%.2f", burnPerDay),
            ]
            if activityUnavailable {
                // UI uses this to hide request counts / model breakdown and
                // surface a one-liner explaining why a management key is
                // needed for granular data.
                extras["activityUnavailable"] = "true"
            }
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
            // 7-day daily spend buckets
            if !dailySpend.isEmpty,
               let data = try? JSONSerialization.data(withJSONObject: dailySpend),
               let s = String(data: data, encoding: .utf8) {
                extras["dailySpend"] = s
            }
            // 7-day aggregate token totals (across all models)
            extras["promptTokens7d"] = "\(activity.totalPromptTokens7d)"
            extras["completionTokens7d"] = "\(activity.totalCompletionTokens7d)"
            // Biggest-day insight for the Activity tab
            if let big = activity.biggestDay {
                let fmt = DateFormatter()
                fmt.dateFormat = "MMM d"
                fmt.locale = Locale(identifier: "en_US_POSIX")
                extras["biggestDayLabel"] = fmt.string(from: big.date)
                extras["biggestDaySpend"] = String(format: "$%.2f", big.spend)
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

    // OpenRouter /api/v1/activity returns per-day rows with model + spend +
    // (sometimes) prompt/completion token counts. We collapse by model and
    // by day over the last 7 days. The endpoint may 404 on some accounts —
    // that's fine, we treat it as "no breakdown available".
    struct ActivityEntry {
        var name: String
        var spend: Double
        var requests: Int
        var promptTokens: Int = 0
        var completionTokens: Int = 0
    }
    struct DayBucket {
        let date: Date     // start-of-day
        var spend: Double = 0
        var requests: Int = 0
    }
    struct ActivityAggregate {
        var byModel: [ActivityEntry] = []
        var byDay: [DayBucket] = []          // 7 entries, oldest → newest
        var totalSpend7d: Double = 0
        var totalReqs7d: Int = 0
        var totalPromptTokens7d: Int = 0
        var totalCompletionTokens7d: Int = 0
        var spendToday: Double = 0
        var reqsToday: Int = 0
        // Most expensive day in the 7-day window (for the Activity tab insight).
        var biggestDay: (date: Date, spend: Double)? = nil
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
        let sevenDaysAgo = cal.date(byAdding: .day, value: -6, to: startOfToday)!
        let iso = ISO8601DateFormatter()

        var agg = ActivityAggregate()
        var byModel: [String: ActivityEntry] = [:]
        var byDayDict: [Date: DayBucket] = [:]

        for row in rows {
            // Accept either "date" (YYYY-MM-DD) or "timestamp".
            let dateStr = (row["date"] as? String)
                ?? (row["timestamp"] as? String)
                ?? ""
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            df.locale = Locale(identifier: "en_US_POSIX")
            let d = df.date(from: dateStr) ?? iso.date(from: dateStr)
            guard let rowDate = d else { continue }
            if rowDate < sevenDaysAgo { continue }
            let dayStart = cal.startOfDay(for: rowDate)

            let model = (row["model"] as? String)
                ?? (row["model_permaslug"] as? String)
                ?? "unknown"
            let spend = (row["usage"] as? Double)
                ?? (row["cost"] as? Double)
                ?? (row["total_cost"] as? Double)
                ?? 0
            let reqs = (row["requests"] as? Int) ?? (row["total_requests"] as? Int) ?? 1
            // Token counts — OpenRouter uses a few field names depending on
            // endpoint version; try all of them and keep whichever matches.
            let promptTokens = (row["prompt_tokens"] as? Int)
                ?? (row["tokens_prompt"] as? Int)
                ?? (row["input_tokens"] as? Int)
                ?? 0
            let completionTokens = (row["completion_tokens"] as? Int)
                ?? (row["tokens_completion"] as? Int)
                ?? (row["output_tokens"] as? Int)
                ?? 0

            var e = byModel[model, default: .init(name: Self.prettyModel(model),
                                                  spend: 0, requests: 0)]
            e.spend += spend
            e.requests += reqs
            e.promptTokens += promptTokens
            e.completionTokens += completionTokens
            byModel[model] = e

            var bucket = byDayDict[dayStart, default: .init(date: dayStart)]
            bucket.spend += spend
            bucket.requests += reqs
            byDayDict[dayStart] = bucket

            agg.totalSpend7d += spend
            agg.totalReqs7d += reqs
            agg.totalPromptTokens7d += promptTokens
            agg.totalCompletionTokens7d += completionTokens
            if cal.isDate(dayStart, inSameDayAs: startOfToday) {
                agg.spendToday += spend
                agg.reqsToday += reqs
            }
        }
        agg.byModel = byModel.values.sorted { $0.spend > $1.spend }

        // Fill in any missing days as zero buckets so the 7-day chart
        // always has 7 bars (otherwise an idle day disappears).
        var filledDays: [DayBucket] = []
        for i in 0..<7 {
            let d = cal.date(byAdding: .day, value: -(6 - i), to: startOfToday)!
            filledDays.append(byDayDict[d, default: .init(date: d)])
        }
        agg.byDay = filledDays
        if let biggest = filledDays.max(by: { $0.spend < $1.spend }), biggest.spend > 0 {
            agg.biggestDay = (date: biggest.date, spend: biggest.spend)
        }
        return agg
    }

    private static func prettyModel(_ raw: String) -> String {
        // "anthropic/claude-3.5-sonnet" → "claude 3.5 sonnet"
        let last = raw.split(separator: "/").last.map(String.init) ?? raw
        return last.replacingOccurrences(of: "-", with: " ")
    }
}

// GroqProvider has moved to Providers/GroqProvider.swift — it's no longer a
// stub now that it actually fetches rate-limit headers and the model catalog.
