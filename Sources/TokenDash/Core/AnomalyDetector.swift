import Foundation
import UserNotifications

// MARK: - AnomalyDetector
//
// Looks at today's observed value vs. the trailing 7-day baseline for each
// provider and raises a UNUserNotification when it exceeds median + 3*MAD
// (or 3x the baseline if MAD is near-zero, as a safety net).
//
// Deliberately conservative: we only alert once per provider per day to avoid
// alert fatigue, we require at least 5 days of history, and we require the
// absolute delta to matter in human terms (not "+500% of $0.003").

@MainActor
final class AnomalyDetector {
    static let shared = AnomalyDetector()

    private var lastAlertKey: [String: String] = [:]    // provider -> "YYYY-MM-DD"
    private var authorizationRequested = false

    func check(snapshots: [ProviderSnapshot]) {
        ensureAuthorization()
        for snap in snapshots where snap.state == .ok {
            evaluate(snap)
        }
    }

    private func evaluate(_ snap: ProviderSnapshot) {
        guard let (metric, unit, humanFloor) = metricFor(providerID: snap.id) else { return }
        var series = PersistentStore.shared.history(provider: snap.id, metric: metric, days: 8)
        guard series.count == 8 else { return }
        // OpenRouter stores cumulative spend; convert to daily deltas before
        // running the anomaly check so a steadily-growing total doesn't alert.
        series = maybeTransformToDeltas(series, providerID: snap.id)
        let baseline = Array(series.dropLast())  // 7 leading days
        let today = series.last ?? 0
        let nonZero = baseline.filter { $0 > 0 }
        guard nonZero.count >= 5 else { return }

        let median = percentile(nonZero, 0.5)
        let mad = medianAbsoluteDeviation(nonZero, median: median)
        // Fall back to 30% of median if MAD collapses to zero (e.g. perfectly
        // steady daily usage), otherwise any tiny variation would alert.
        let scale = max(mad, median * 0.3, 1)
        let threshold = median + 3 * scale
        let absDelta = abs(today - median)

        guard today > threshold, absDelta > humanFloor else { return }

        let dayKey = Self.dayKey(Date())
        if lastAlertKey[snap.id] == dayKey { return }
        lastAlertKey[snap.id] = dayKey

        let pct = Int((today / max(1, median) - 1) * 100)
        let body = "\(snap.title) is \(pct)% above its 7-day baseline (\(format(today, unit: unit)) vs \(format(median, unit: unit))). Check for runaway usage."
        post(title: "Usage spike detected", body: body)
    }

    // MARK: - Metric mapping

    private func metricFor(providerID: String) -> (PersistentStore.Metric, String, Double)? {
        switch providerID {
        case "claude_code", "codex":
            return (.billable, "tokens", 100_000)          // ignore sub-100K spikes
        case "elevenlabs":
            return (.reqs, "reqs", 10)
        case "openrouter":
            // OpenRouter stores cumulative spend; daily delta is what we want.
            // AnomalyDetector uses `.spend` history; we translate that into
            // deltas on the fly below.
            return (.spend, "usd", 0.5)
        default:
            return nil
        }
    }

    // Override: OpenRouter needs daily-delta series, not cumulative spend.
    // Stick with a single code path by transforming cumulative into deltas for
    // the detector only.
    private func maybeTransformToDeltas(_ values: [Double], providerID: String) -> [Double] {
        guard providerID == "openrouter" else { return values }
        var out = [Double](repeating: 0, count: values.count)
        for i in 1..<values.count {
            out[i] = max(0, values[i] - values[i - 1])
        }
        return out
    }

    // MARK: - Stats

    private func percentile(_ xs: [Double], _ p: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let sorted = xs.sorted()
        let idx = max(0, min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[idx]
    }

    private func medianAbsoluteDeviation(_ xs: [Double], median: Double) -> Double {
        let devs = xs.map { abs($0 - median) }
        return percentile(devs, 0.5)
    }

    // MARK: - Notification glue

    private func ensureAuthorization() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in /* silent ignore — best effort */ }
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    // MARK: - Helpers

    private func format(_ v: Double, unit: String) -> String {
        switch unit {
        case "usd": return String(format: "$%.2f", v)
        case "tokens": return Fmt.tokens(Int(v))
        case "reqs", "chars": return Fmt.int(Int(v))
        default: return "\(v)"
        }
    }

    private static func dayKey(_ d: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: d)
    }
}
