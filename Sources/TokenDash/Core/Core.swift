import Foundation

// MARK: - Token totals

struct TokenTotals: Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var reasoningTokens: Int = 0

    var billableTotal: Int { inputTokens + outputTokens + cacheWriteTokens + reasoningTokens }
    var grandTotal: Int { inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens + reasoningTokens }

    static func + (a: TokenTotals, b: TokenTotals) -> TokenTotals {
        TokenTotals(
            inputTokens: a.inputTokens + b.inputTokens,
            outputTokens: a.outputTokens + b.outputTokens,
            cacheReadTokens: a.cacheReadTokens + b.cacheReadTokens,
            cacheWriteTokens: a.cacheWriteTokens + b.cacheWriteTokens,
            reasoningTokens: a.reasoningTokens + b.reasoningTokens
        )
    }
    static func += (lhs: inout TokenTotals, rhs: TokenTotals) { lhs = lhs + rhs }
}

// MARK: - Display primitives

struct StatLine: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let muted: Bool
    init(_ label: String, _ value: String, muted: Bool = false) {
        self.label = label; self.value = value; self.muted = muted
    }
}

struct QuotaBar: Identifiable {
    let id = UUID()
    let label: String
    let percent: Double  // 0...1
    let caption: String?
}

struct ModelShare: Identifiable {
    let id = UUID()
    let name: String
    let tokens: Int
    let color: Int  // palette index 0...5
}

struct SessionSummary: Identifiable {
    let id = UUID()
    let timeLabel: String   // "2:14 PM"
    let tokens: Int         // billable total
    let duration: String    // "38m" or "1h 14m"
}

// MARK: - Provider snapshot

enum ProviderState { case ok, empty, error, unconfigured }

enum CardSize { case hero, compact }

struct ProviderSnapshot {
    var id: String
    var title: String
    var subtitle: String?          // "Max", "Plus"
    var glyph: String = "•"        // single letter for round glyph
    var accent: SnapshotAccent = .coral
    var size: CardSize = .hero
    var headline: String           // big number
    var headlineCaption: String    // e.g. "tokens today"
    var secondaryValue: String? = nil   // for compact cards — e.g. "48,213 / 100K"
    var trendCaption: String?      // e.g. "↗ 23% vs yesterday"
    var quotas: [QuotaBar] = []
    var stats: [StatLine] = []
    var modelMix: [ModelShare] = []        // optional
    var dailyBuckets: [Int] = []           // length 7, oldest first
    var dayLabels: [String] = ["M", "T", "W", "T", "F", "S", "S"]
    var weeklyAverage: Int = 0             // avg of dailyBuckets
    var topSessions: [SessionSummary] = [] // top 3 sessions today, sorted desc by tokens
    var sparkline: [Double]? = nil         // last-7-days values for the hero sparkline
    var trendCaptionGreen: Bool = true     // for app.jsx trend color hint
    var todayRaw: Int = 0                  // raw billable count (before formatting)
    var detail: [StatLine] = []            // extra lines shown when expanded
    var warningLevel: Int = 0              // 0=none 1=warn 2=danger
    var state: ProviderState = .ok
    var note: String? = nil
    var extras: [String: String] = [:]     // structured payload for JS (e.g. pct, used, total)
    var lastUpdated: Date = Date()
}

enum SnapshotAccent {
    case coral, sage, ocean, sand, slate
}

// MARK: - Provider protocol

protocol UsageProvider: AnyObject {
    var id: String { get }
    var displayName: String { get }
    func snapshot() async -> ProviderSnapshot
}

// MARK: - Formatters

enum Fmt {
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fK", d / 1_000)
        case ..<1_000_000_000: return String(format: "%.2fM", d / 1_000_000)
        default: return String(format: "%.2fB", d / 1_000_000_000)
        }
    }
    static func int(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: n as NSNumber) ?? "\(n)"
    }
    static func percent(_ p: Double) -> String { "\(Int((p * 100).rounded()))%" }
    static func relative(_ date: Date) -> String {
        let secs = Int(-date.timeIntervalSinceNow)
        switch secs {
        case ..<5: return "just now"
        case ..<60: return "\(secs)s ago"
        case ..<3600: return "\(secs / 60)m ago"
        case ..<86400: return "\(secs / 3600)h ago"
        default: return "\(secs / 86400)d ago"
        }
    }
    static func untilReset(_ resetAt: Date) -> String {
        let secs = Int(resetAt.timeIntervalSinceNow)
        if secs <= 0 { return "resets soon" }
        let d = secs / 86400
        let h = (secs % 86400) / 3600
        let m = (secs % 3600) / 60
        if d > 0 { return "resets in \(d)d \(h)h" }
        if h > 0 { return "resets in \(h)h \(m)m" }
        return "resets in \(m)m"
    }
    static func trend(from old: Int, to new: Int) -> String? {
        guard old > 0 else { return nil }
        let delta = Double(new - old) / Double(old)
        if abs(delta) < 0.02 { return "flat vs yesterday" }
        let arrow = delta > 0 ? "↗" : "↘"
        return "\(arrow) \(Int(abs(delta) * 100))% vs yesterday"
    }
}

// MARK: - Date helpers

extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        let comps = dateComponents([.year, .month], from: date)
        return self.date(from: comps) ?? date
    }
}

// MARK: - Path helpers

enum Paths {
    static var home: URL { URL(fileURLWithPath: NSHomeDirectory()) }
    static var claudeProjects: URL { home.appendingPathComponent(".claude/projects") }
    static var codexSessions: URL { home.appendingPathComponent(".codex/sessions") }
}
