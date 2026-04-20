import Foundation

final class CodexProvider: UsageProvider {
    let id = "codex"
    let displayName = "Codex CLI"

    func snapshot() async -> ProviderSnapshot {
        let root = Paths.codexSessions
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else {
            return empty(note: "No ~/.codex/sessions directory yet.")
        }

        let enumerator = fm.enumerator(at: root,
                                       includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                                       options: [.skipsHiddenFiles])
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "jsonl", url.lastPathComponent.hasPrefix("rollout-") {
                files.append(url)
            }
        }
        if files.isEmpty { return empty(note: "No Codex sessions found.") }

        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let startOfYesterday = cal.date(byAdding: .day, value: -1, to: startOfToday)!
        let startOfMonth = cal.startOfMonth(for: now)
        let sevenDaysAgo = cal.date(byAdding: .day, value: -7, to: startOfToday)!
        let cutoff = cal.date(byAdding: .day, value: -45, to: now)!

        var today = TokenTotals()
        var yesterday = TokenTotals()
        var week = TokenTotals()
        var month = TokenTotals()
        var dailyBuckets = Array(repeating: 0, count: 7)

        var latestRL: (primary: Double?, secondary: Double?, primaryReset: Date?, secondaryReset: Date?, plan: String?)
            = (nil, nil, nil, nil, nil)
        var latestRLAt: Date = .distantPast

        var byModelMonth: [String: Int] = [:]
        var topSessionsToday: [SessionSummary] = []
        var sessionsTodayCount = 0

        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter(); isoPlain.formatOptions = [.withInternetDateTime]
        let tf = DateFormatter(); tf.dateFormat = "h:mm a"

        for url in files {
            if let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               mod < cutoff { continue }

            var sessionFirstTs: Date = .distantFuture
            var sessionLastTs: Date = .distantPast
            var sessionLastTotal: TokenTotals? = nil
            var sessionModel: String? = nil

            forEachLine(url: url) { data in
                guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                guard let type = obj["type"] as? String else { return }
                let tsStr = (obj["timestamp"] as? String) ?? ""
                let ts = iso.date(from: tsStr) ?? isoPlain.date(from: tsStr) ?? Date.distantPast
                if ts < sessionFirstTs { sessionFirstTs = ts }

                if type == "turn_context", let payload = obj["payload"] as? [String: Any] {
                    if sessionModel == nil, let m = payload["model"] as? String { sessionModel = m }
                }
                if type == "event_msg",
                   let payload = obj["payload"] as? [String: Any],
                   (payload["type"] as? String) == "token_count" {
                    if let info = payload["info"] as? [String: Any],
                       let tot = info["total_token_usage"] as? [String: Any] {
                        sessionLastTotal = TokenTotals(
                            inputTokens: (tot["input_tokens"] as? Int) ?? 0,
                            outputTokens: (tot["output_tokens"] as? Int) ?? 0,
                            cacheReadTokens: (tot["cached_input_tokens"] as? Int) ?? 0,
                            cacheWriteTokens: 0,
                            reasoningTokens: (tot["reasoning_output_tokens"] as? Int) ?? 0
                        )
                        sessionLastTs = ts
                    }
                    if ts > latestRLAt, let rl = payload["rate_limits"] as? [String: Any] {
                        latestRLAt = ts
                        let primary = rl["primary"] as? [String: Any]
                        let secondary = rl["secondary"] as? [String: Any]
                        latestRL.primary = (primary?["used_percent"] as? Double).map { $0 / 100 }
                        latestRL.secondary = (secondary?["used_percent"] as? Double).map { $0 / 100 }
                        if let r = primary?["resets_at"] as? Double { latestRL.primaryReset = Date(timeIntervalSince1970: r) }
                        if let r = secondary?["resets_at"] as? Double { latestRL.secondaryReset = Date(timeIntervalSince1970: r) }
                        latestRL.plan = rl["plan_type"] as? String
                    }
                }
            }

            if let tot = sessionLastTotal {
                if sessionLastTs >= startOfMonth {
                    month += tot
                    if let m = sessionModel { byModelMonth[m, default: 0] += tot.billableTotal }
                }
                if sessionLastTs >= sevenDaysAgo {
                    week += tot
                    let dayStart = cal.startOfDay(for: sessionLastTs)
                    let daysAgo = cal.dateComponents([.day], from: dayStart, to: startOfToday).day ?? 0
                    let idx = 6 - daysAgo
                    if idx >= 0 && idx < 7 { dailyBuckets[idx] += tot.billableTotal }
                }
                if sessionLastTs >= startOfToday {
                    today += tot
                    sessionsTodayCount += 1
                    if tot.billableTotal > 0 {
                        let minutes = max(1, Int(sessionLastTs.timeIntervalSince(sessionFirstTs) / 60))
                        let duration = minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
                        topSessionsToday.append(SessionSummary(
                            timeLabel: tf.string(from: sessionFirstTs),
                            tokens: tot.billableTotal,
                            duration: duration
                        ))
                    }
                }
                if sessionLastTs >= startOfYesterday && sessionLastTs < startOfToday {
                    yesterday += tot
                }
            }
        }

        var quotas: [QuotaBar] = []
        if let p = latestRL.primary {
            quotas.append(QuotaBar(label: "5h window",
                                   percent: p,
                                   caption: latestRL.primaryReset.map { Fmt.untilReset($0) }))
        }
        if let s = latestRL.secondary {
            quotas.append(QuotaBar(label: "Weekly",
                                   percent: s,
                                   caption: latestRL.secondaryReset.map { Fmt.untilReset($0) }))
        }

        var warningLevel = 0
        let hottest = max(latestRL.primary ?? 0, latestRL.secondary ?? 0)
        if hottest >= 0.85 { warningLevel = 2 }
        else if hottest >= 0.6 { warningLevel = 1 }

        // Primary model from most-used-today (for the top-right model chip)
        let primaryModel = byModelMonth.max(by: { $0.value < $1.value })?.key
        var mix: [ModelShare] = []
        if let m = primaryModel { mix.append(ModelShare(name: prettyModel(m), tokens: 1, color: 0)) }

        // JSX shows 2 stats for Codex (7-day, Month). Claude hero shows 3.
        let stats: [StatLine] = [
            StatLine("7-day", Fmt.tokens(week.billableTotal)),
            StatLine("Month", Fmt.tokens(month.billableTotal)),
        ]

        // Day labels shifted so today is rightmost
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.dateFormat = "EEEEE"
        var dayLabels: [String] = []
        for i in 0..<7 {
            let daysAgo = 6 - i
            if let d = cal.date(byAdding: .day, value: -daysAgo, to: startOfToday) {
                dayLabels.append(weekdayFormatter.string(from: d))
            }
        }
        let weeklyAvg = dailyBuckets.reduce(0, +) / max(1, dailyBuckets.count)

        let detail: [StatLine] = [
            StatLine("Reasoning tokens today", Fmt.tokens(today.reasoningTokens), muted: true),
            StatLine("Cached input today", Fmt.tokens(today.cacheReadTokens), muted: true),
            StatLine("Output tokens today", Fmt.tokens(today.outputTokens), muted: true),
            StatLine("Rate limits refreshed", Fmt.relative(latestRLAt), muted: true),
        ]

        let plan = latestRL.plan?.capitalized ?? "Plus"
        let state: ProviderState = (today.billableTotal == 0 && month.billableTotal == 0) ? .empty : .ok

        // Keep top 3 sessions
        let top3 = topSessionsToday.sorted { $0.tokens > $1.tokens }.prefix(3)

        return ProviderSnapshot(
            id: id,
            title: displayName,
            subtitle: plan,
            glyph: "C",
            accent: .sage,
            size: .hero,
            headline: Fmt.tokens(today.billableTotal),
            headlineCaption: "tokens today",
            trendCaption: Fmt.trend(from: yesterday.billableTotal, to: today.billableTotal),
            quotas: quotas,
            stats: stats,
            modelMix: mix,
            dailyBuckets: dailyBuckets,
            dayLabels: dayLabels,
            weeklyAverage: weeklyAvg,
            topSessions: Array(top3),
            todayRaw: today.billableTotal,
            detail: detail,
            warningLevel: warningLevel,
            state: state,
            note: state == .empty ? "No sessions recorded yet this month." : nil
        )
    }

    private func forEachLine(url: URL, _ body: (Data) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var buffer = Data()
        let chunkSize = 128 * 1024
        while true {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: 0..<nl)
                buffer.removeSubrange(0...nl)
                if !lineData.isEmpty { body(lineData) }
            }
        }
        if !buffer.isEmpty { body(buffer) }
    }

    private func prettyModel(_ raw: String) -> String {
        if raw.lowercased().hasPrefix("gpt") { return "GPT" + raw.dropFirst(3) }
        return raw
    }

    private func empty(note: String) -> ProviderSnapshot {
        ProviderSnapshot(
            id: id, title: displayName, subtitle: "Plus", glyph: "C", accent: .sage, size: .hero,
            headline: "—", headlineCaption: "no data yet",
            trendCaption: nil, quotas: [], stats: [], modelMix: [],
            dailyBuckets: Array(repeating: 0, count: 7),
            dayLabels: ["M","T","W","T","F","S","S"], weeklyAverage: 0, topSessions: [],
            detail: [], warningLevel: 0, state: .empty, note: note
        )
    }
}
