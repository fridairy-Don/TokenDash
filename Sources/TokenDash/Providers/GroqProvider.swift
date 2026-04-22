import Foundation

// MARK: - Groq
//
// Groq has no /balance, /usage, or /billing endpoint — confirmed by probing
// both documented and undocumented paths. The console.groq.com dashboard is
// cookie-gated and not reusable from an API key. The ONLY way to show live
// quota is to hit an inference endpoint and read the x-ratelimit-* response
// headers. Chat and audio have SEPARATE request buckets — a chat probe
// won't tell you anything about your Whisper quota.
//
// This provider monitors the AUDIO bucket (Whisper transcriptions) because
// that's the common Groq use case we care about here: voice-in-voice-out
// agents, speech-to-text pipelines, game voice commands. Empirically, the
// audio bucket on a typical dev-tier key is 2,000 requests/day.
//
// What we do per refresh:
//   1. GET  /openai/v1/models                       — free, validates key, gives catalog
//   2. POST /openai/v1/audio/transcriptions        — throttled to every 15 min;
//                                                    burns 1 req from the audio bucket
//                                                    (~96/day overhead at 15-min cadence).
//
// Between probes we reuse the cached headers and intraday delta — so the card
// still updates every 30s from the accumulated snapshot history, we just
// don't hammer the audio endpoint for fresh headers.
final class GroqProvider: UsageProvider {
    let id = "groq"
    let displayName = "Groq"

    private static let base = "https://api.groq.com/openai/v1"
    private static let probeModel = "whisper-large-v3-turbo"

    // The rate-limit probe is expensive(-ish) relative to a free GET, so we
    // only issue it every `probeInterval` seconds. Between probes the last
    // result is cached in memory and forwarded as "refreshed Xm ago".
    private actor ProbeCache {
        var lastRL: RateLimits?
        var lastProbe: Date?
        var lastError: String?
        func update(_ rl: RateLimits) { lastRL = rl; lastProbe = Date(); lastError = nil }
        func recordError(_ s: String) { lastError = s; lastProbe = Date() }
    }
    private static let cache = ProbeCache()
    // 15-min cadence = 96 probes/day = ~4.8% of a 2000/day audio bucket.
    // Intraday delta in PersistentStore fills in the minute-to-minute picture
    // between probes, so this is the right tradeoff: ≤5% quota overhead while
    // the dashboard still reflects real usage continuously.
    private static let probeInterval: TimeInterval = 15 * 60

    struct RateLimits {
        var limitReqs: Int?
        var remainReqs: Int?
        var resetReqs: TimeInterval?      // seconds until next request replenishes
    }

    func snapshot() async -> ProviderSnapshot {
        guard let key = KeyStore.load(account: id), !key.isEmpty else {
            return unconfigured()
        }

        // 1. Models — free call, validates the key, gets catalog.
        let modelIds: [String]
        do {
            modelIds = try await fetchModels(key: key)
        } catch {
            return ProviderSnapshot(
                id: id, title: displayName, subtitle: "Console",
                glyph: "G", accent: .slate, size: .compact,
                headline: "—", headlineCaption: "auth failed",
                state: .error,
                note: "Groq API rejected the key — check it at console.groq.com"
            )
        }

        // 2. Rate-limit probe (throttled to 5 min intervals).
        let shouldProbe: Bool
        if let last = await Self.cache.lastProbe {
            shouldProbe = Date().timeIntervalSince(last) > Self.probeInterval
        } else {
            shouldProbe = true
        }
        if shouldProbe {
            if let rl = try? await probeRateLimits(key: key) {
                await Self.cache.update(rl)
            } else {
                await Self.cache.recordError("probe failed")
            }
        }
        let rl = await Self.cache.lastRL
        let probeAt = await Self.cache.lastProbe

        let groups = Self.groupModels(modelIds)

        // ── Intraday usage from PersistentStore ────────────────────────────
        // Each probe writes `remainReqs` into snapshots.credits_usd, so the
        // diff between today's earliest snapshot and the latest is "requests
        // used today" — the actual number the user wants to see for their
        // kids-game whisper pipeline. This works even between probes because
        // every 30s refresh re-writes the cached `remainReqs` into the table.
        let current = Double(rl?.remainReqs ?? 0)
        let intraday = PersistentStore.shared.intradayCredits(provider: id)
        let (usedToday, sinceTs) = Self.usedFromIntraday(
            currentRemain: current,
            intraday: intraday
        )
        let burnPerHour = await Self.burnPerHour(provider: id, currentRemain: current)
        let (hourlyBalance, hourlyBurn) = Self.bucketHourly(
            intraday: intraday,
            currentRemain: current
        )

        // ── Headline / caption ─────────────────────────────────────────────
        // Headline = "used today" — the number that actually answers "how
        // much did my app talk to Whisper today?".
        let headline: String
        let headlineCaption: String
        if let lim = rl?.limitReqs, lim > 0 {
            headline = Self.compactInt(Int(usedToday))
            headlineCaption = "used today"
        } else {
            headline = "—"
            headlineCaption = probeAt == nil ? "probing…" : "no quota data"
        }

        // pct USED (0–100). Menu-bar dot warns as we approach the daily cap.
        let pctUsed: Int? = {
            guard let rem = rl?.remainReqs, let lim = rl?.limitReqs, lim > 0 else { return nil }
            return max(0, min(100, 100 - Int(Double(rem) / Double(lim) * 100)))
        }()

        // Subtitle — "12 today · 1,988 left · 3/hr".
        let note: String = {
            guard let rem = rl?.remainReqs, let lim = rl?.limitReqs, lim > 0 else {
                return "\(modelIds.count) models · quota probing"
            }
            let reqsLeft = Self.compactInt(rem)
            if burnPerHour > 0 {
                return "\(Self.compactInt(Int(usedToday))) used · \(reqsLeft) left · \(Self.compactInt(Int(burnPerHour.rounded())))/hr"
            }
            return "\(Self.compactInt(Int(usedToday))) used today · \(reqsLeft) left"
        }()

        let sinceLabel: String = {
            guard let ts = sinceTs else { return "" }
            let df = DateFormatter()
            df.dateFormat = "HH:mm"
            return "since \(df.string(from: ts))"
        }()

        var extras: [String: String] = [
            "modelsCount":    "\(modelIds.count)",
            "headline":       headline,
            "usedTodayNum":   "\(Int(usedToday))",
            "burnPerHourNum": "\(Int(burnPerHour.rounded()))",
            "sinceLabel":     sinceLabel,
            "hourlyBalance":  hourlyBalance.map { String(format: "%.0f", $0) }.joined(separator: ","),
            "hourlyBurn":     hourlyBurn.map    { String(format: "%.0f", $0) }.joined(separator: ","),
            // Store remainReqs as credits_usd so PersistentStore persists it
            // and the intraday helpers (shared with Moonshot) just work.
            "creditsUsd":     String(current),
        ]
        if let rem = rl?.remainReqs                 { extras["rpdRemain"] = "\(rem)" }
        if let lim = rl?.limitReqs                  { extras["rpdLimit"]  = "\(lim)" }
        if let rs  = rl?.resetReqs                  { extras["rpdReset"]  = "\(Int(rs))" }
        if let p   = pctUsed                        { extras["pct"]       = "\(p)" }
        if let probeAt = probeAt {
            extras["probedSecondsAgo"] = "\(Int(Date().timeIntervalSince(probeAt)))"
        }
        if !modelIds.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: modelIds),
           let s = String(data: data, encoding: .utf8) {
            extras["modelIds"] = s
        }
        if !groups.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: groups),
           let s = String(data: data, encoding: .utf8) {
            extras["modelGroups"] = s
        }

        return ProviderSnapshot(
            id: id, title: displayName,
            subtitle: "Console",
            glyph: "G", accent: .slate, size: .compact,
            headline: headline, headlineCaption: headlineCaption,
            state: .ok,
            note: note,
            extras: extras
        )
    }

    private func unconfigured() -> ProviderSnapshot {
        ProviderSnapshot(
            id: id, title: displayName, subtitle: "Console",
            glyph: "G", accent: .slate, size: .compact,
            headline: "Add key", headlineCaption: "to see quota",
            state: .unconfigured,
            note: "API key not configured"
        )
    }

    // MARK: - API

    private struct ModelsEnvelope: Decodable {
        let data: [ModelEntry]
    }
    private struct ModelEntry: Decodable {
        let id: String
        let active: Bool?
        let context_window: Int?
    }

    private func fetchModels(key: String) async throws -> [String] {
        guard let url = URL(string: "\(Self.base)/models") else { return [] }
        let env = try await APIClient.shared.getJSON(
            ModelsEnvelope.self, url: url,
            headers: ["Authorization": "Bearer \(key)"]
        )
        // Active-only so we don't show deprecated ids in the drawer.
        let active = env.data.filter { ($0.active ?? true) }
        return active.map { $0.id }.sorted()
    }

    /// Probe the AUDIO bucket by POSTing a 0.1-second silent WAV to
    /// /audio/transcriptions and reading x-ratelimit-*-requests headers. The
    /// audio endpoint has no tokens bucket (empirically verified — only the
    /// -requests headers are returned). Silent audio is 3244 bytes and Whisper
    /// processes it in <300ms; it typically transcribes as "" or "Thank you."
    /// (Whisper's well-known silence hallucination). Either way we just need
    /// the response headers.
    private func probeRateLimits(key: String) async throws -> RateLimits {
        guard let url = URL(string: "\(Self.base)/audio/transcriptions") else {
            throw APIError.invalidURL("audio/transcriptions")
        }
        let boundary = "----TokenDashGroqProbe\(UUID().uuidString)"
        let body = Self.buildMultipartAudioBody(
            boundary: boundary,
            model: Self.probeModel,
            wav: Self.makeSilenceWav()
        )
        let (_, http) = try await APIClient.shared.postWithHeaders(
            url: url, body: body,
            headers: [
                "Authorization": "Bearer \(key)",
                "Content-Type": "multipart/form-data; boundary=\(boundary)",
            ],
            timeout: 12
        )
        var rl = RateLimits()
        if let s = http.value(forHTTPHeaderField: "x-ratelimit-limit-requests") {
            rl.limitReqs = Int(s)
        }
        if let s = http.value(forHTTPHeaderField: "x-ratelimit-remaining-requests") {
            rl.remainReqs = Int(s)
        }
        if let s = http.value(forHTTPHeaderField: "x-ratelimit-reset-requests") {
            rl.resetReqs = Self.parseResetSeconds(s)
        }
        return rl
    }

    /// Build a multipart/form-data body carrying `file=<silence.wav>` and
    /// `model=<probeModel>`. Hand-rolled because we only need two fields.
    private static func buildMultipartAudioBody(
        boundary: String, model: String, wav: Data
    ) -> Data {
        var body = Data()
        let crlf = "\r\n"
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }

        append("--\(boundary)\(crlf)")
        append("Content-Disposition: form-data; name=\"model\"\(crlf)\(crlf)")
        append("\(model)\(crlf)")

        append("--\(boundary)\(crlf)")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"silence.wav\"\(crlf)")
        append("Content-Type: audio/wav\(crlf)\(crlf)")
        body.append(wav)
        append(crlf)

        append("--\(boundary)--\(crlf)")
        return body
    }

    /// 3244-byte WAV: 44-byte PCM header + 3200 bytes (100ms) of silence at
    /// 16 kHz / mono / 16-bit. Matches what Whisper expects and minimises
    /// network + server cost for a throwaway probe.
    private static func makeSilenceWav() -> Data {
        let sampleRate: UInt32 = 16_000
        let durationMs: UInt32 = 100
        let numSamples = sampleRate * durationMs / 1000   // 1600 samples
        let dataSize = numSamples * 2                     // 16-bit mono = 2 bytes/sample
        let fileSize = 36 + dataSize                      // header is 44 bytes; RIFF size = file - 8

        var d = Data()
        func u32le(_ v: UInt32) {
            d.append(UInt8(v & 0xff))
            d.append(UInt8((v >> 8) & 0xff))
            d.append(UInt8((v >> 16) & 0xff))
            d.append(UInt8((v >> 24) & 0xff))
        }
        func u16le(_ v: UInt16) {
            d.append(UInt8(v & 0xff))
            d.append(UInt8((v >> 8) & 0xff))
        }
        d.append("RIFF".data(using: .ascii)!)
        u32le(fileSize)
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!)
        u32le(16)           // PCM chunk size
        u16le(1)            // PCM format
        u16le(1)            // mono
        u32le(sampleRate)
        u32le(sampleRate * 2)   // byte rate = sampleRate * channels * bytesPerSample
        u16le(2)            // block align
        u16le(16)           // bits per sample
        d.append("data".data(using: .ascii)!)
        u32le(dataSize)
        d.append(Data(count: Int(dataSize)))    // 3200 zero bytes
        return d
    }

    // MARK: - Intraday helpers (mirrors MoonshotProvider; static so the
    // snapshot function can call them without shuttling state through self).

    /// Today-earliest − current = requests used today. Works from the second
    /// refresh of the day; returns 0 until then.
    static func usedFromIntraday(
        currentRemain: Double,
        intraday: [(ts: Date, credits: Double)]
    ) -> (used: Double, since: Date?) {
        guard let first = intraday.first else { return (0, nil) }
        // "credits" here is remainReqs. Earlier in the day => higher value.
        // Drop = requests consumed. Negative => quota reset (new day).
        let delta = first.credits - currentRemain
        return (max(0, delta), first.ts)
    }

    /// Burn over the last hour. Falls back to scaled-window rate when we don't
    /// yet have an hour of history.
    @MainActor
    static func burnPerHour(provider: String, currentRemain: Double) async -> Double {
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)
        if let past = PersistentStore.shared.creditsAt(provider: provider, atOrBefore: oneHourAgo) {
            return max(0, past - currentRemain)
        }
        let intraday = PersistentStore.shared.intradayCredits(provider: provider)
        guard let first = intraday.first else { return 0 }
        let hours = max(0.1, now.timeIntervalSince(first.ts) / 3600)
        return max(0, first.credits - currentRemain) / hours
    }

    /// 24 one-hour bins: `balance` = last remainReqs seen that hour (or 0),
    /// `burn` = drop from previous populated bin. Mirrors Moonshot's bucketing
    /// so the drawer chart code can be shared.
    static func bucketHourly(
        intraday: [(ts: Date, credits: Double)],
        currentRemain: Double
    ) -> (balance: [Double], burn: [Double]) {
        var balance = [Double](repeating: 0, count: 24)
        let cal = Calendar.current
        for (ts, credits) in intraday {
            let h = cal.component(.hour, from: ts)
            if h >= 0 && h < 24 { balance[h] = credits }
        }
        let currentHour = cal.component(.hour, from: Date())
        if currentHour < 24 { balance[currentHour] = currentRemain }

        var burn = [Double](repeating: 0, count: 24)
        var prev: Double = 0
        for h in 0..<24 {
            if balance[h] > 0 {
                if prev > 0 { burn[h] = max(0, prev - balance[h]) }
                prev = balance[h]
            }
        }
        return (balance, burn)
    }

    // MARK: - Helpers

    /// Groq's reset value is a duration like "17h45m6s" or "1m6s" or "300s".
    /// Returns the total in seconds. Returns 0 for unparseable input.
    private static func parseResetSeconds(_ s: String) -> TimeInterval {
        // Numeric only = plain seconds.
        if let n = TimeInterval(s) { return n }
        // Pattern: optional Nd, Nh, Nm, Ns components. We keep it permissive.
        var total: TimeInterval = 0
        var num = ""
        for ch in s {
            if ch.isNumber || ch == "." { num.append(ch); continue }
            guard let n = TimeInterval(num) else { num = ""; continue }
            switch ch.lowercased().first {
            case "d": total += n * 86400
            case "h": total += n * 3600
            case "m": total += n * 60
            case "s": total += n
            default:  break
            }
            num = ""
        }
        // Trailing digits with no unit → seconds.
        if !num.isEmpty, let n = TimeInterval(num) { total += n }
        return total
    }

    private static func compactInt(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 10_000    { return "\(n / 1000)k" }
        if n >= 1_000     { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }

    private static func relShort(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60       { return "\(s)s" }
        if s < 3600     { return "\(s / 60)m" }
        if s < 86400    { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }

    // Bucket models by family for the drawer list, same shape Moonshot uses.
    private static func groupModels(_ ids: [String]) -> [[String: Any]] {
        // Bucket keys in display order.
        let order: [(String, String)] = [
            ("llama",    "Llama"),
            ("mixtral",  "Mixtral"),
            ("gemma",    "Gemma"),
            ("qwen",     "Qwen"),
            ("deepseek", "DeepSeek"),
            ("kimi",     "Kimi"),
            ("whisper",  "Whisper"),
            ("guard",    "Safety"),
            ("other",    "Other"),
        ]
        var buckets: [String: [String]] = [:]
        for id in ids {
            let lower = id.lowercased()
            let key: String
            if      lower.contains("whisper")                 { key = "whisper" }
            else if lower.contains("guard")                   { key = "guard" }
            else if lower.contains("llama")                   { key = "llama" }
            else if lower.contains("mixtral")                 { key = "mixtral" }
            else if lower.contains("gemma")                   { key = "gemma" }
            else if lower.contains("qwen")                    { key = "qwen" }
            else if lower.contains("deepseek")                { key = "deepseek" }
            else if lower.contains("kimi") || lower.contains("moonshot") { key = "kimi" }
            else                                              { key = "other" }
            buckets[key, default: []].append(id)
        }
        var out: [[String: Any]] = []
        for (key, label) in order {
            guard let list = buckets[key], !list.isEmpty else { continue }
            out.append([
                "bucket": key,
                "label":  label,
                "ids":    list.sorted(),
            ])
        }
        return out
    }
}
