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
        var byCwdWeek: [String: TokenTotals] = [:]   // real project paths
        var dailyBuckets = Array(repeating: 0, count: 7)   // 0 = 6d ago, 6 = today
        var sessionsToday: [String: SessionAccum] = [:]
        var totalFilesScanned = 0

        // Message counts (any user or assistant turn) — what Claude Code's UI
        // labels "Messages".
        var messagesToday = 0
        var messagesWeek = 0
        var messagesMonth = 0
        // Peak hour: histogram of message local-hours over the last 30 days.
        var hourBuckets = Array(repeating: 0, count: 24)

        for url in files {
            if let mod = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               mod < scanCutoff { continue }
            totalFilesScanned += 1
            let fallbackName = Self.projectName(from: url)
            parseFile(url: url) { evt in
                let ts = evt.ts
                // --- message counting ---
                // Only real conversational turns count. Pure tool_result user
                // lines and pure tool_use assistant lines are machinery, not
                // messages — including them inflated the counter ~10× on
                // heavy tool-use days.
                if evt.isConversational {
                    if ts >= startOfToday { messagesToday += 1 }
                    if ts >= sevenDaysAgo { messagesWeek += 1 }
                    if ts >= startOfMonth { messagesMonth += 1 }
                }
                // --- peak hour histogram ---
                // Also restricted to conversational turns so the "Peak hour"
                // stat reflects when you actually talked to Claude, not when
                // the agent happened to be hammering tools.
                if evt.isConversational,
                   ts >= cal.date(byAdding: .day, value: -30, to: startOfToday)! {
                    let hr = cal.component(.hour, from: ts)
                    hourBuckets[hr] += 1
                }

                // Token roll-ups only apply to assistant lines (they carry usage).
                guard evt.kind == .assistant, let tot = evt.tokens else { return }
                let model = evt.model ?? "unknown"
                let sessionId = evt.sessionId ?? ""
                let project = evt.cwd ?? fallbackName

                if ts >= startOfMonth {
                    month += tot
                    byModelMonth[model, default: .init()] += tot
                }
                if ts >= sevenDaysAgo {
                    week += tot
                    byCwdWeek[project, default: .init()] += tot
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

        // Top 5 projects by billable tokens this week — keyed by real cwd path.
        let topProjects = byCwdWeek
            .filter { $0.value.billableTotal > 0 }
            .sorted { $0.value.billableTotal > $1.value.billableTotal }
            .prefix(5)
            .map { (path, totals) -> [String: Any] in
                [
                    "name": Self.prettyProject(path: path),
                    "path": path,
                    "tokens": Fmt.tokens(totals.billableTotal),
                    "raw": totals.billableTotal,
                ]
            }

        // Peak hour: bucket with the most messages in the last 30 days.
        let peakHourIdx = hourBuckets.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
        let peakHourLabel = Self.formatHour(peakHourIdx)

        // Per-model breakdown for the drawer: input vs output vs cache_write,
        // over the current month (matches what Claude Code's "Models" tab
        // displays). Values are raw ints so the web side can format freely.
        let modelBreakdown: [[String: Any]] = byModelMonth
            .filter { $0.value.billableTotal > 0 && !$0.key.contains("synthetic") }
            .sorted { $0.value.billableTotal > $1.value.billableTotal }
            .prefix(6)
            .map { (name, t) -> [String: Any] in
                [
                    "name":       prettyModel(name),
                    "raw":        name,
                    "input":      t.inputTokens,
                    "output":     t.outputTokens,
                    "cacheRead":  t.cacheReadTokens,
                    "cacheWrite": t.cacheWriteTokens,
                    "billable":   t.billableTotal,
                ]
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
            "messagesToday": "\(messagesToday)",
            "messagesWeek": "\(messagesWeek)",
            "messagesMonth": "\(messagesMonth)",
            "peakHour": peakHourLabel,
            "peakHourIdx": "\(peakHourIdx)",
            // Raw month totals for the "real consumption" breakdown in the
            // Cache tab. Claude Code's UI only shows input+output; these four
            // fields expose the full picture so subscription users can see
            // how much cache re-use the platform is doing under the hood.
            "monthInput":      "\(month.inputTokens)",
            "monthOutput":     "\(month.outputTokens)",
            "monthCacheRead":  "\(month.cacheReadTokens)",
            "monthCacheWrite": "\(month.cacheWriteTokens)",
        ]
        if !topProjects.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: topProjects),
           let s = String(data: data, encoding: .utf8) {
            extras["topProjects"] = s
        }
        if !modelBreakdown.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: modelBreakdown),
           let s = String(data: data, encoding: .utf8) {
            extras["modelBreakdown"] = s
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

    /// Fallback project name from the slug folder when a JSONL line has no
    /// `cwd` field. The slug encodes the absolute project path but separators
    /// and actual hyphens are both `-`, so this is lossy — prefer `cwd`.
    private static func projectName(from url: URL) -> String {
        let parent = url.deletingLastPathComponent().lastPathComponent
        if parent.isEmpty { return "—" }
        let parts = parent.split(separator: "-")
        if let last = parts.last, !last.isEmpty { return String(last) }
        return parent
    }

    /// Human-readable project label from an absolute cwd path.
    /// `/Users/you/Downloads/TokenDash` -> `~/Downloads/TokenDash`
    /// `/Users/you`                    -> `~`
    /// For very deep paths, we keep the last 3 components after `~`.
    static func prettyProject(path: String) -> String {
        let home = NSHomeDirectory()
        var p = path
        if p.hasPrefix(home) {
            p = "~" + p.dropFirst(home.count)
        }
        let parts = p.split(separator: "/").map(String.init)
        if parts.count <= 4 { return p }
        return "~/…/" + parts.suffix(2).joined(separator: "/")
    }

    /// Format a 24-hour bucket index as "10 AM", "3 PM" (local).
    static func formatHour(_ h: Int) -> String {
        let h = ((h % 24) + 24) % 24
        if h == 0 { return "12 AM" }
        if h < 12 { return "\(h) AM" }
        if h == 12 { return "12 PM" }
        return "\(h - 12) PM"
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

    // A single message from a JSONL file. Tokens are present only on
    // assistant lines that carry a usage block.
    struct ParsedEvent {
        enum Kind { case user, assistant, other }
        let ts: Date
        let kind: Kind
        let model: String?
        let sessionId: String?
        let cwd: String?
        let tokens: TokenTotals?
        // True iff this line represents a real conversational turn — a user
        // message the human typed, or an assistant reply that contains text
        // the user would have read. False for tool_result payloads (stored
        // as type:"user" in the JSONL but are machine-generated) and for
        // pure tool_use assistant lines (Claude calling grep/read/bash).
        // Used to power the "Messages today" counter, which otherwise
        // inflates 10×+ on heavy tool-use days.
        let isConversational: Bool
    }

    private func parseFile(url: URL, sink: (ParsedEvent) -> Void) {
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
                             sink: (ParsedEvent) -> Void) {
        guard !data.isEmpty else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let typeStr = (obj["type"] as? String) ?? ""
        // Ignore sidechain / bookkeeping entries (queue-operation, tool_use
        // summaries etc.) — only count real user / assistant turns.
        let kind: ParsedEvent.Kind
        switch typeStr {
        case "user": kind = .user
        case "assistant": kind = .assistant
        default: return
        }

        let tsStr = (obj["timestamp"] as? String) ?? ""
        let ts = iso.date(from: tsStr) ?? isoPlain.date(from: tsStr) ?? Date.distantPast
        guard ts != Date.distantPast else { return }

        let sessionId = obj["sessionId"] as? String
        let cwd = obj["cwd"] as? String
        // Skip sidechain lines — those inflate message counts without
        // representing a real turn.
        if (obj["isSidechain"] as? Bool) == true && kind == .user { return }

        var model: String? = nil
        var tokens: TokenTotals? = nil
        let message = obj["message"] as? [String: Any]
        if kind == .assistant, let message = message {
            model = message["model"] as? String
            if let usage = message["usage"] as? [String: Any] {
                tokens = TokenTotals(
                    inputTokens: (usage["input_tokens"] as? Int) ?? 0,
                    outputTokens: (usage["output_tokens"] as? Int) ?? 0,
                    cacheReadTokens: (usage["cache_read_input_tokens"] as? Int) ?? 0,
                    cacheWriteTokens: (usage["cache_creation_input_tokens"] as? Int) ?? 0,
                    reasoningTokens: 0
                )
            }
        }

        // Decide whether this line is a real "message" for the Messages-today
        // counter. Two failure modes we need to reject:
        //   - user lines that are just tool_result payloads (the bytes a
        //     tool produced flowing back into Claude) — these dominate
        //     agentic sessions and have nothing to do with what the user
        //     typed.
        //   - assistant lines that contain only tool_use blocks (Claude
        //     deciding to call a tool). These are not a message the user
        //     would have read.
        let isConversational: Bool = {
            guard let message = message else { return kind == .user }
            let content = message["content"]
            // String content = plain typed text (user) or plain reply (assistant).
            if content is String { return true }
            guard let blocks = content as? [[String: Any]] else { return false }
            if blocks.isEmpty { return false }
            switch kind {
            case .user:
                // Typed if ANY block is not a tool_result.
                return blocks.contains { ($0["type"] as? String) != "tool_result" }
            case .assistant:
                // Conversational if ANY block is text (ignore tool_use-only turns).
                return blocks.contains { ($0["type"] as? String) == "text" }
            case .other:
                return false
            }
        }()

        sink(ParsedEvent(
            ts: ts, kind: kind, model: model,
            sessionId: sessionId, cwd: cwd, tokens: tokens,
            isConversational: isConversational
        ))
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
