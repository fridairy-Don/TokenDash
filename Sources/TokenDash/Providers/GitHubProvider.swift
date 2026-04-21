import Foundation

// MARK: - GitHub
//
// Surfaces the two numbers most developers actually care about:
//   1. API rate-limit remaining (core/graphql/search buckets)
//   2. Actions minutes used against the plan (if the token's scopes allow it)
//
// The card's headline is "X / 5000" for the core bucket — the one that's
// most visible when you're running gh-cli, github-copilot, or automated
// scripts. The drawer breaks down every bucket plus Actions minutes.
//
// Auth: fine-grained PAT works; classic PAT also works. For Actions
// minutes we hit /user/settings/billing/actions which requires a token
// with the `read:org` + `read:user` scope on personal accounts; if the
// request 403s we quietly skip that section.
final class GitHubProvider: UsageProvider {
    let id = "github"
    let displayName = "GitHub"

    func snapshot() async -> ProviderSnapshot {
        guard let key = KeyStore.load(account: id), !key.isEmpty else {
            return unconfigured()
        }
        do {
            async let limitsT = fetchRateLimit(key: key)
            async let userT   = fetchUser(key: key)
            async let actionsT = try? fetchActionsMinutes(key: key)

            let limits = try await limitsT
            let user   = try await userT
            let actions = await actionsT

            let core = limits.resources.core
            let pct = core.limit > 0 ? min(100, Int(round(Double(core.limit - core.remaining) / Double(core.limit) * 100))) : 0
            let resetAt = Date(timeIntervalSince1970: TimeInterval(core.reset))
            let resetIn = Self.shortETA(to: resetAt)

            let headline = "\(core.remaining)"
            let caption  = "of \(core.limit) core"

            // Per-bucket detail for the drawer
            let buckets: [[String: Any]] = [
                ["name": "core",    "remaining": core.remaining, "limit": core.limit, "reset": core.reset],
                ["name": "graphql", "remaining": limits.resources.graphql.remaining, "limit": limits.resources.graphql.limit, "reset": limits.resources.graphql.reset],
                ["name": "search",  "remaining": limits.resources.search.remaining,  "limit": limits.resources.search.limit,  "reset": limits.resources.search.reset],
            ]

            var extras: [String: String] = [
                "headline": headline,
                "caption":  caption,
                "resetIn":  resetIn,
                "login":    user.login,
                "name":     user.name ?? user.login,
                "avatarUrl": user.avatar_url ?? "",
                // Rate-limit buckets as JSON so the drawer renders a table.
                "pct":      "\(pct)",
            ]
            if let arr = try? JSONSerialization.data(withJSONObject: buckets),
               let s = String(data: arr, encoding: .utf8) {
                extras["rateBuckets"] = s
            }

            // Actions minutes — optional.
            if let a = actions {
                extras["actionsUsed"]      = "\(a.total_minutes_used)"
                extras["actionsIncluded"]  = "\(a.included_minutes)"
                if a.included_minutes > 0 {
                    let aPct = min(100, Int(round(Double(a.total_minutes_used) / Double(a.included_minutes) * 100)))
                    extras["actionsPct"] = "\(aPct)"
                }
            }

            return ProviderSnapshot(
                id: id, title: displayName, subtitle: "@\(user.login)",
                glyph: "G", accent: .ocean, size: .compact,
                headline: headline, headlineCaption: caption,
                secondaryValue: "resets \(resetIn)",
                state: .ok,
                note: "API rate limit",
                extras: extras
            )
        } catch {
            return ProviderSnapshot(
                id: id, title: displayName, subtitle: "GitHub",
                glyph: "G", accent: .ocean, size: .compact,
                headline: "—", headlineCaption: "api error",
                state: .error,
                note: "GitHub API error — check that the token has read:user"
            )
        }
    }

    private func unconfigured() -> ProviderSnapshot {
        ProviderSnapshot(
            id: id, title: displayName, subtitle: "GitHub",
            glyph: "G", accent: .ocean, size: .compact,
            headline: "Add key", headlineCaption: "to see rate limits",
            state: .unconfigured,
            note: "API key not configured"
        )
    }

    // MARK: - API

    private struct RateLimitResponse: Decodable {
        struct Resources: Decodable {
            let core: Bucket
            let graphql: Bucket
            let search: Bucket
        }
        struct Bucket: Decodable {
            let limit: Int
            let remaining: Int
            let reset: Int
        }
        let resources: Resources
    }
    private struct UserResponse: Decodable {
        let login: String
        let name: String?
        let avatar_url: String?
    }
    private struct ActionsBilling: Decodable {
        let total_minutes_used: Int
        let included_minutes: Int
    }

    private func fetchRateLimit(key: String) async throws -> RateLimitResponse {
        try await APIClient.shared.getJSON(
            RateLimitResponse.self,
            url: URL(string: "https://api.github.com/rate_limit")!,
            headers: ghHeaders(key: key)
        )
    }
    private func fetchUser(key: String) async throws -> UserResponse {
        try await APIClient.shared.getJSON(
            UserResponse.self,
            url: URL(string: "https://api.github.com/user")!,
            headers: ghHeaders(key: key)
        )
    }
    private func fetchActionsMinutes(key: String) async throws -> ActionsBilling? {
        let user = try await fetchUser(key: key)
        let url = URL(string: "https://api.github.com/users/\(user.login)/settings/billing/actions")!
        return try? await APIClient.shared.getJSON(
            ActionsBilling.self, url: url, headers: ghHeaders(key: key)
        )
    }

    private func ghHeaders(key: String) -> [String: String] {
        [
            "Authorization": "Bearer \(key)",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        ]
    }

    private static func shortETA(to date: Date) -> String {
        let secs = Int(date.timeIntervalSinceNow)
        if secs <= 0 { return "now" }
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        return "\(secs / 3600)h \((secs % 3600) / 60)m"
    }
}
