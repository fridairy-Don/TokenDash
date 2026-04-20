import Foundation

final class ClaudeCodeProvider: UsageProvider {
    let id = "claude_code"
    let displayName = "Claude Code"

    private struct SessionAccum {
        var firstTs: Date = .distantFuture
        var lastTs: Date = .distantPast
        var totalBillable: Int = 0
    }

    func snapshot() async -> ProviderSnapshot {
        let root = Paths.claudeProjects
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else {
            return emptyState(note: "No ~/.claude/projects directory yet.")
        }

        let enumerator = fm.enumerator(at: root,
                                       includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                                       options: [.skipsHiddenFiles])
        var files: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "jsonl" { files.append(url) }
        }
        if files.isEmpty { return emptyState(note: "No Claude Code sessions found.") }

        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        let startOfYesterday = cal.date(byAdding: .day, value: -1, to: startOfToday)!
        let startOfMonth = cal.startOfMonth(for: now)
        let sevenDaysAgo = cal.date(byAdding: .day, value: -7, to: startOfToday)!
        let scanCutoff = cal.date(byAdding: .day, value: -45, to: now)!

        var today = TokenTotals()
        var yesterday = TokenTotals()
        var month = TokenTotals()
        var week = TokenTotals()
        var byModelMonth: [String: TokenTotals] = [:]
        var byModelToday: [String: TokenTotals] = [:]
        var byProjectWeek: [String: TokenTotals] = [:]
        var dailyBuckets = Array(repeating: 0, count: 7)   // 0 = 6d ago, 6 = today
        var sessionsToday: [String: SessionAccum] = [:]
        var totalFilesScanned = 0

        for url in files {
            if let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               mod < scanCutoff { continue }
            totalFilesScanned += 1
            let projectName = Self.projectName(from: url)
            parseFile(url: url) { ts, model, sessionId, tot in
                if ts >= startOfMonth {
                    month += tot
                    byModelMonth[model, default: .init()] += tot
                }
                if ts >= sevenDaysAgo {
                    week += tot
                    byProjectWeek[projectName, default: .init()] += tot
                    let dayStart = cal.startOfDay(for: ts)
                    let daysAgo = cal.dateComponents([.day], from: dayStart, to: startOfToday).day ?? 0
                    let idx = 6 - daysAgo
                    if idx >= 0 && idx < 7 { dailyBuckets[idx] += tot.billableTotal }
                }
                if ts >= startOfToday {
                    today += tot
                    byModelToday[model, default: .init()] += tot
                    var acc = sessionsToday[sessionId, default: .init()]
                    if ts < acc.firstTs { acc.firstTs = ts }
                    if ts > acc.lastTs { acc.lastTs = ts }
                    acc.totalBillable += tot.billableTotal
                    sessionsToday[sessionId] = acc
                }
                if ts >= startOfYesterday && ts < startOfToday {
                    yesterday += tot
                }
            }
        }

        let mixSource = byModelToday.isEmpty ? byModelMonth : byModelToday
        let mix = topModelShares(from: mixSource)

        let stats: [StatLine] = [
            StatLine("7-day", Fmt.tokens(week.billableTotal)),
            StatLine("Month", Fmt.tokens(month.billableTotal)),
            StatLine("Sessions", "\(sessionsToday.count)"),
        ]

        // Day labels (M/T/W/T/F/S/S shifted so today is rightmost)
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.dateFormat = "EEEEE"   // single-letter weekday
        var dayLabels: [String] = []
        for i in 0..<7 {
            let daysAgo = 6 - i
            if let d = cal.date(byAdding: .day, value: -daysAgo, to: startOfToday) {
                dayLabels.append(weekdayFormatter.string(from: d))
            }
        }

        let weeklyAvg = dailyBuckets.reduce(0, +) / max(1, dailyBuckets.count)

        // Top 3 sessions today
        let topSessions = sessionsToday.values
            .filter { $0.totalBillable > 0 }
            .sorted { $0.totalBillable > $1.totalBillable }
            .prefix(3)
            .map { acc -> SessionSummary in
                let tf = DateFormatter()
                tf.dateFormat = "h:mm a"
                let minutes = max(1, Int(acc.lastTs.timeIntervalSince(acc.firstTs) / 60))
                let duration = minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
                return SessionSummary(
                    timeLabel: tf.string(from: acc.firstTs),
                    tokens: acc.totalBillable,
                    duration: duration
                )
            }

        let detail: [StatLine] = [
            StatLine("Cache reads today", Fmt.tokens(today.cacheReadTokens), muted: true),
            StatLine("Cache writes today", Fmt.tokens(today.cacheWriteTokens), muted: true),
            StatLine("Output tokens today", Fmt.tokens(today.outputTokens), muted: true),
            StatLine("Input tokens today", Fmt.tokens(today.inputTokens), muted: true),
            StatLine("Scanned files", "\(totalFilesScanned)", muted: true),
        ]

        let state: ProviderState = (today.billableTotal == 0 && month.billableTotal == 0) ? .empty : .ok

        // Top 5 projects by billable tokens this week.
        let topProjects = byProjectWeek
            .filter { $0.value.billableTotal > 0 }
            .sorted { $0.value.billableTotal > $1.value.billableTotal }
            .prefix(5)
            .map { (name, totals) -> [String: Any] in
                ["name": name, "tokens": Fmt.tokens(totals.billableTotal), "raw": totals.billableTotal]
            }

        // Cache hit rate = cacheRead / (cacheRead + input + cacheWrite).
        // High rate => you're getting discount reads; low rate => you might be
        // breaking cache with frequent prompt changes or long idle gaps.
        let effectiveInput = today.inputTokens + today.cacheWriteTokens + today.cacheReadTokens
        let cacheHitRate: Int = effectiveInput > 0
            ? Int(round(Double(today.cacheReadTokens) / Double(effectiveInput) * 100))
            : 0

        var extras: [String: String] = [
            "billable": "\(today.billableTotal)",
            "cacheHitRate": "\(cacheHitRate)",
            "cacheReadToday": Fmt.tokens(today.cacheReadTokens),
            "cacheWriteToday": Fmt.tokens(today.cacheWriteTokens),
        ]
        if !topProjects.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: topProjects),
           let s = String(data: data, encoding: .utf8) {
            extras["topProjects"] = s
        }

        return ProviderSnapshot(
            id: id,
            title: displayName,
            subtitle: "Max",
            glyph: "A",
            accent: .coral,
            size: .hero,
            headline: Fmt.tokens(today.billableTotal),
            headlineCaption: "tokens today",
            trendCaption: Fmt.trend(from: yesterday.billableTotal, to: today.billableTotal),
            quotas: [],
            stats: stats,
            modelMix: mix,
            dailyBuckets: dailyBuckets,
            dayLabels: dayLabels,
            weeklyAverage: weeklyAvg,
            topSessions: Array(topSessions),
            todayRaw: today.billableTotal,
            detail: detail,
            warningLevel: 0,
            state: state,
            note: state == .empty ? "No billable tokens this month." : nil,
            extras: extras
        )
    }

    /// Extract a human-friendly project name from a Claude Code session path.
    /// Claude stores sessions under `~/.claude/projects/<slug>/<session>.jsonl`
    /// where <slug> is the escaped absolute project path. We take the last
    /// component after slash escapes.
    private static func projectName(from url: URL) -> String {
        let parent = url.deletingLastPathComponent().lastPathComponent
        if parent.isEmpty { return "—" }
        // Slugs look like "-Users-xiaoxiannv-Downloads-TokenDash".
        // Take the trailing segment.
        let parts = parent.split(separator: "-")
        if let last = parts.last, !last.isEmpty {
            return String(last)
        }
        return parent
    }

    private func topModelShares(from dict: [String: TokenTotals]) -> [ModelShare] {
        // Filter BEFORE prefix so zero-token synthetic entries don't displace real models.
        let sorted = dict
            .filter { $0.value.billableTotal > 0 && !$0.key.contains("synthetic") }
            .sorted { $0.value.billableTotal > $1.value.billableTotal }
            .prefix(4)
        var result: [ModelShare] = []
        for (i, (name, tot)) in sorted.enumerated() {
            result.append(ModelShare(name: prettyModel(name), tokens: tot.billableTotal, color: i))
        }
        return result
    }

    private func parseFile(url: URL, sink: (_ ts: Date, _ model: String, _ sessionId: String, _ tot: TokenTotals) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter(); isoPlain.formatOptions = [.withInternetDateTime]

        var buffer = Data()
        let chunkSize = 128 * 1024
        while true {
            let chunk = (try? handle.read(upToCount: chunkSize)) ?? Data()
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: 0..<nl)
                buffer.removeSubrange(0...nl)
                processLine(lineData, iso: iso, isoPlain: isoPlain, sink: sink)
            }
        }
        if !buffer.isEmpty { processLine(buffer, iso: iso, isoPlain: isoPlain, sink: sink) }
    }

    private func processLine(_ data: Data,
                             iso: ISO8601DateFormatter,
                             isoPlain: ISO8601DateFormatter,
                             sink: (Date, String, String, TokenTotals) -> Void) {
        guard !data.isEmpty else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard (obj["type"] as? String) == "assistant" else { return }
        guard let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return }
        let model = (message["model"] as? String) ?? "unknown"
        let sessionId = (obj["sessionId"] as? String) ?? ""
        let tsStr = (obj["timestamp"] as? String) ?? ""
        let ts = iso.date(from: tsStr) ?? isoPlain.date(from: tsStr) ?? Date.distantPast
        let tot = TokenTotals(
            inputTokens: (usage["input_tokens"] as? Int) ?? 0,
            outputTokens: (usage["output_tokens"] as? Int) ?? 0,
            cacheReadTokens: (usage["cache_read_input_tokens"] as? Int) ?? 0,
            cacheWriteTokens: (usage["cache_creation_input_tokens"] as? Int) ?? 0,
            reasoningTokens: 0
        )
        sink(ts, model, sessionId, tot)
    }

    private func prettyModel(_ raw: String) -> String {
        let s = raw.lowercased()
        func ver(_ r: String) -> String {
            if let m = r.range(of: #"\d+-\d+"#, options: .regularExpression) {
                return String(r[m]).replacingOccurrences(of: "-", with: ".")
            }
            return ""
        }
        if s.contains("opus") { return "Opus \(ver(s))".trimmingCharacters(in: .whitespaces) }
        if s.contains("sonnet") { return "Sonnet \(ver(s))".trimmingCharacters(in: .whitespaces) }
        if s.contains("haiku") { return "Haiku \(ver(s))".trimmingCharacters(in: .whitespaces) }
        return raw
    }

    private func emptyState(note: String) -> ProviderSnapshot {
        ProviderSnapshot(
            id: id, title: displayName, subtitle: "Max", glyph: "A", accent: .coral, size: .hero,
            headline: "—", headlineCaption: "no data yet",
            trendCaption: nil, quotas: [], stats: [], modelMix: [],
            dailyBuckets: Array(repeating: 0, count: 7),
            dayLabels: ["M","T","W","T","F","S","S"], weeklyAverage: 0, topSessions: [],
            detail: [], warningLevel: 0, state: .empty, note: note
        )
    }
}
