import Foundation
import SQLite3

// MARK: - PersistentStore
//
// A tiny, intentionally-small SQLite wrapper for TokenDash. Stores one row per
// provider per refresh, so we can later draw sparklines, detect anomalies,
// and answer "how does this week compare to last week?" questions.
//
// Schema is deliberately flat: every provider reports its own dimensions via
// the `extras` map (JSON), plus a few well-known numeric columns for fast
// aggregation without JSON parsing. We prefer a second numeric column over
// clever JSON extraction because macOS' built-in sqlite3 doesn't always ship
// with the JSON1 extension enabled.
//
// File lives at ~/Library/Application Support/TokenDash/usage.sqlite3.
// Retention: keep 180 days, prune older rows on every startup.

final class PersistentStore {
    static let shared = PersistentStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "tokendash.persistent", qos: .utility)
    private var openedOK = false

    private init() {
        queue.sync { self.open() }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: File path

    private static let dbPath: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("TokenDash", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("usage.sqlite3")
    }()

    var storeURL: URL { Self.dbPath }

    // MARK: Open + migrate

    private func open() {
        let path = Self.dbPath.path
        if sqlite3_open_v2(path, &db,
                           SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                           nil) != SQLITE_OK {
            FileHandle.standardError.write("PersistentStore: failed to open \(path)\n".data(using: .utf8)!)
            openedOK = false
            return
        }
        openedOK = true
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        migrate()
        prune(olderThanDays: 180)
    }

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS snapshots (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            provider    TEXT    NOT NULL,
            ts          INTEGER NOT NULL,
            state       TEXT    NOT NULL,
            headline    TEXT,
            billable    INTEGER,            -- tokens (Claude/Codex) or characters (ElevenLabs)
            spend_usd   REAL,               -- cumulative spend (OpenRouter)
            credits_usd REAL,               -- credits remaining (OpenRouter)
            pct         INTEGER,            -- 0..100 quota/usage pct
            extras_json TEXT
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_snapshots_provider_ts ON snapshots(provider, ts);")

        // Daily roll-up — one row per provider per local-day. Stores the final
        // value observed that day for numeric columns. Avoids scanning thousands
        // of per-refresh rows every time we draw a 7-day sparkline.
        exec("""
        CREATE TABLE IF NOT EXISTS daily (
            provider    TEXT    NOT NULL,
            day         TEXT    NOT NULL,   -- YYYY-MM-DD (local)
            billable    INTEGER,
            spend_usd   REAL,
            credits_usd REAL,
            pct         INTEGER,
            reqs        INTEGER,            -- e.g. ElevenLabs requests-today
            extras_json TEXT,
            PRIMARY KEY (provider, day)
        );
        """)
    }

    private func prune(olderThanDays days: Int) {
        let cutoff = Int(Date().timeIntervalSince1970) - days * 86400
        exec("DELETE FROM snapshots WHERE ts < \(cutoff);")
    }

    // MARK: - Writing

    /// Record one snapshot per provider.
    func record(snapshot: ProviderSnapshot) {
        queue.async { [weak self] in
            guard let self, self.openedOK else { return }

            let extras = snapshot.extras
            let billable = Int(extras["billable"] ?? "") ?? extras["billableRaw"].flatMap(Int.init)
                ?? (snapshot.todayRaw > 0 ? snapshot.todayRaw : nil)
            let spend = Self.parseMoney(extras["spendLabel"])
                ?? Double(extras["spendUsd"] ?? "")
            let credits = Self.parseMoney(extras["credits"])
                ?? Double(extras["creditsUsd"] ?? "")
            let pct = Int(extras["pct"] ?? "")
            let reqs = Int(extras["reqsToday"] ?? "")

            let json = (try? JSONSerialization.data(withJSONObject: extras, options: []))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

            var sb: OpaquePointer?
            let sql = """
            INSERT INTO snapshots
                (provider, ts, state, headline, billable, spend_usd, credits_usd, pct, extras_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
            if sqlite3_prepare_v2(self.db, sql, -1, &sb, nil) == SQLITE_OK {
                sqlite3_bind_text(sb, 1, snapshot.id, -1, Self.SQLITE_TRANSIENT)
                sqlite3_bind_int64(sb, 2, Int64(Date().timeIntervalSince1970))
                sqlite3_bind_text(sb, 3, Self.stateString(snapshot.state), -1, Self.SQLITE_TRANSIENT)
                sqlite3_bind_text(sb, 4, snapshot.headline, -1, Self.SQLITE_TRANSIENT)
                if let b = billable { sqlite3_bind_int64(sb, 5, Int64(b)) } else { sqlite3_bind_null(sb, 5) }
                if let s = spend    { sqlite3_bind_double(sb, 6, s)      } else { sqlite3_bind_null(sb, 6) }
                if let c = credits  { sqlite3_bind_double(sb, 7, c)      } else { sqlite3_bind_null(sb, 7) }
                if let p = pct      { sqlite3_bind_int(sb, 8, Int32(p))  } else { sqlite3_bind_null(sb, 8) }
                sqlite3_bind_text(sb, 9, json, -1, Self.SQLITE_TRANSIENT)
                _ = sqlite3_step(sb)
            }
            sqlite3_finalize(sb)

            // Daily upsert: the last value observed today wins.
            let day = Self.dayKey(Date())
            var up: OpaquePointer?
            let upSQL = """
            INSERT INTO daily (provider, day, billable, spend_usd, credits_usd, pct, reqs, extras_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(provider, day) DO UPDATE SET
                billable    = COALESCE(excluded.billable, daily.billable),
                spend_usd   = COALESCE(excluded.spend_usd, daily.spend_usd),
                credits_usd = COALESCE(excluded.credits_usd, daily.credits_usd),
                pct         = COALESCE(excluded.pct, daily.pct),
                reqs        = COALESCE(excluded.reqs, daily.reqs),
                extras_json = excluded.extras_json;
            """
            if sqlite3_prepare_v2(self.db, upSQL, -1, &up, nil) == SQLITE_OK {
                sqlite3_bind_text(up, 1, snapshot.id, -1, Self.SQLITE_TRANSIENT)
                sqlite3_bind_text(up, 2, day, -1, Self.SQLITE_TRANSIENT)
                if let b = billable { sqlite3_bind_int64(up, 3, Int64(b)) } else { sqlite3_bind_null(up, 3) }
                if let s = spend    { sqlite3_bind_double(up, 4, s)      } else { sqlite3_bind_null(up, 4) }
                if let c = credits  { sqlite3_bind_double(up, 5, c)      } else { sqlite3_bind_null(up, 5) }
                if let p = pct      { sqlite3_bind_int(up, 6, Int32(p))  } else { sqlite3_bind_null(up, 6) }
                if let r = reqs     { sqlite3_bind_int(up, 7, Int32(r))  } else { sqlite3_bind_null(up, 7) }
                sqlite3_bind_text(up, 8, json, -1, Self.SQLITE_TRANSIENT)
                _ = sqlite3_step(up)
            }
            sqlite3_finalize(up)
        }
    }

    // MARK: - Reading

    /// Last 7 days (today inclusive) of daily values for a given metric.
    /// Returns newest-first is unhelpful for charting, so we return oldest-first.
    /// Missing days are zero-filled.
    func history(provider: String, metric: Metric, days: Int = 7) -> [Double] {
        var result = [Double](repeating: 0, count: days)
        guard openedOK else { return result }

        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        var keyIndex: [String: Int] = [:]
        for i in 0..<days {
            if let d = cal.date(byAdding: .day, value: -(days - 1 - i), to: startOfToday) {
                keyIndex[Self.dayKey(d)] = i
            }
        }

        let col = metric.column
        let sql = "SELECT day, \(col) FROM daily WHERE provider = ? AND day >= ? ORDER BY day;"
        queue.sync { [db] in
            var sb: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &sb, nil) == SQLITE_OK {
                sqlite3_bind_text(sb, 1, provider, -1, Self.SQLITE_TRANSIENT)
                let earliest = cal.date(byAdding: .day, value: -(days - 1), to: startOfToday) ?? Date()
                sqlite3_bind_text(sb, 2, Self.dayKey(earliest), -1, Self.SQLITE_TRANSIENT)
                while sqlite3_step(sb) == SQLITE_ROW {
                    guard let dayCStr = sqlite3_column_text(sb, 0) else { continue }
                    let day = String(cString: dayCStr)
                    guard let idx = keyIndex[day] else { continue }
                    let type = sqlite3_column_type(sb, 1)
                    if type == SQLITE_NULL { continue }
                    if metric == .spend || metric == .credits {
                        result[idx] = sqlite3_column_double(sb, 1)
                    } else {
                        result[idx] = Double(sqlite3_column_int64(sb, 1))
                    }
                }
            }
            sqlite3_finalize(sb)
        }
        return result
    }

    /// Latest value for a provider (any state). Used to detect anomalies vs baseline.
    func latest(provider: String, metric: Metric) -> Double? {
        var out: Double?
        let col = metric.column
        let sql = "SELECT \(col) FROM snapshots WHERE provider = ? AND \(col) IS NOT NULL ORDER BY ts DESC LIMIT 1;"
        queue.sync { [db] in
            var sb: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &sb, nil) == SQLITE_OK {
                sqlite3_bind_text(sb, 1, provider, -1, Self.SQLITE_TRANSIENT)
                if sqlite3_step(sb) == SQLITE_ROW {
                    if metric == .spend || metric == .credits {
                        out = sqlite3_column_double(sb, 0)
                    } else {
                        out = Double(sqlite3_column_int64(sb, 0))
                    }
                }
            }
            sqlite3_finalize(sb)
        }
        return out
    }

    /// All intraday snapshots (ts, credits) for a provider since start-of-today.
    /// Oldest first. Used to compute "today's burn so far" and the 24h balance
    /// chart — we refresh every 30s so a full day has ~2,880 points.
    func intradayCredits(provider: String) -> [(ts: Date, credits: Double)] {
        guard openedOK else { return [] }
        let startOfToday = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
        let sql = """
        SELECT ts, credits_usd FROM snapshots
        WHERE provider = ? AND ts >= ? AND credits_usd IS NOT NULL
        ORDER BY ts ASC;
        """
        var out: [(Date, Double)] = []
        queue.sync { [db] in
            var sb: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &sb, nil) == SQLITE_OK {
                sqlite3_bind_text(sb, 1, provider, -1, Self.SQLITE_TRANSIENT)
                sqlite3_bind_int64(sb, 2, Int64(startOfToday))
                while sqlite3_step(sb) == SQLITE_ROW {
                    let ts = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(sb, 0)))
                    let credits = sqlite3_column_double(sb, 1)
                    out.append((ts, credits))
                }
            }
            sqlite3_finalize(sb)
        }
        return out
    }

    /// Credits snapshot closest to `t` going backward (most-recent sample at-or-before).
    /// Used for "1h ago" / "24h ago" baselines when computing burn rate.
    func creditsAt(provider: String, atOrBefore t: Date) -> Double? {
        guard openedOK else { return nil }
        let sql = """
        SELECT credits_usd FROM snapshots
        WHERE provider = ? AND credits_usd IS NOT NULL AND ts <= ?
        ORDER BY ts DESC LIMIT 1;
        """
        var out: Double?
        queue.sync { [db] in
            var sb: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &sb, nil) == SQLITE_OK {
                sqlite3_bind_text(sb, 1, provider, -1, Self.SQLITE_TRANSIENT)
                sqlite3_bind_int64(sb, 2, Int64(t.timeIntervalSince1970))
                if sqlite3_step(sb) == SQLITE_ROW {
                    out = sqlite3_column_double(sb, 0)
                }
            }
            sqlite3_finalize(sb)
        }
        return out
    }

    /// Per-day deltas for spend — computed on the fly because we store
    /// *cumulative* spend, and the sparkline wants daily burn.
    func dailySpendDeltas(provider: String, days: Int = 7) -> [Double] {
        // Pull the last (days+1) cumulative values so we can diff.
        let cumulative = history(provider: provider, metric: .spend, days: days + 1)
        var out = [Double](repeating: 0, count: days)
        for i in 0..<days {
            let today = cumulative[i + 1]
            let yday  = cumulative[i]
            if today <= 0 { out[i] = 0 }
            else if yday <= 0 { out[i] = 0 }    // first day — can't attribute
            else { out[i] = max(0, today - yday) }
        }
        return out
    }

    /// Per-day spend inferred from balance drops. For providers that only
    /// expose a running credit balance (Moonshot), this is the closest thing
    /// to "what did I spend each day": take balance drops day-to-day, clamp
    /// top-ups (balance went up) to zero, and return the series.
    func dailyBalanceSpend(provider: String, days: Int = 7) -> [Double] {
        let credits = history(provider: provider, metric: .credits, days: days + 1)
        var out = [Double](repeating: 0, count: days)
        for i in 0..<days {
            let yday  = credits[i]
            let today = credits[i + 1]
            if yday <= 0 || today <= 0 { out[i] = 0 }
            else { out[i] = max(0, yday - today) }   // drop = spend
        }
        return out
    }

    // MARK: - Helpers

    enum Metric {
        case billable, spend, credits, pct, reqs
        var column: String {
            switch self {
            case .billable: return "billable"
            case .spend:    return "spend_usd"
            case .credits:  return "credits_usd"
            case .pct:      return "pct"
            case .reqs:     return "reqs"
            }
        }
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK, let e = err {
            FileHandle.standardError.write("SQL error: \(String(cString: e))\n".data(using: .utf8)!)
            sqlite3_free(err)
        }
    }

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func stateString(_ s: ProviderState) -> String {
        switch s {
        case .ok: return "ok"
        case .empty: return "empty"
        case .error: return "error"
        case .unconfigured: return "unconfigured"
        }
    }

    private static func dayKey(_ d: Date) -> String {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: d)
    }

    /// Parse "$1.23" or "$1.23 spent" or "12,345" style strings into a Double.
    private static func parseMoney(_ s: String?) -> Double? {
        guard let s else { return nil }
        let digits = s.filter { "0123456789.".contains($0) }
        return Double(digits)
    }
}
