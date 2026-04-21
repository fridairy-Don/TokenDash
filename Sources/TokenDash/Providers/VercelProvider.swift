import Foundation

// MARK: - Vercel
//
// Built for the "my kid's English game is deployed on Vercel and I want to
// spot attacks / overage early" use case. The card headline is deployments
// in the last 24 hours; the drawer (if we can fetch it) shows bandwidth
// and per-project deployment counts.
//
// Auth: Vercel uses a bearer access token scoped to a user or team. Our
// key is stored under account "vercel" in KeyStore.
//
// Endpoints used:
//   GET /v2/user                     — who the token belongs to
//   GET /v9/projects?limit=20        — recent projects
//   GET /v6/deployments?limit=100    — recent deployments (24h window)
//
// Things we intentionally don't fetch:
//   /v1/teams/.../usage               — only on Pro/Enterprise + needs team id
//   Firewall events                   — only on Pro/Enterprise
// For hobby users we rely on deployment frequency + project count as the
// "is something weird happening" signal.
final class VercelProvider: UsageProvider {
    let id = "vercel"
    let displayName = "Vercel"

    func snapshot() async -> ProviderSnapshot {
        guard let key = KeyStore.load(account: id), !key.isEmpty else {
            return unconfigured()
        }
        do {
            async let userT        = fetchUser(key: key)
            async let projectsT    = fetchProjects(key: key)
            async let deploymentsT = fetchRecentDeployments(key: key)

            let user        = try await userT
            let projects    = (try? await projectsT) ?? []
            let deployments = (try? await deploymentsT) ?? []

            // Last-24h deployment analysis
            let cutoff = Int((Date().timeIntervalSince1970 - 86400) * 1000)
            let last24h = deployments.filter { $0.created >= cutoff }
            let failed24h = last24h.filter { ($0.state ?? "").uppercased() == "ERROR" }.count
            let headline = "\(last24h.count)"
            let caption  = "deployments · 24h"

            // Build hourly histogram for the drawer's 24-bar chart.
            var hourBuckets = Array(repeating: 0, count: 24)
            let cal = Calendar.current
            for d in last24h {
                let ts = TimeInterval(d.created) / 1000.0
                let hr = cal.component(.hour, from: Date(timeIntervalSince1970: ts))
                if hr >= 0 && hr < 24 { hourBuckets[hr] += 1 }
            }

            // Per-project deployment counts (last 24h) — a spike on one
            // project often means a stuck build loop or cache-bust attack.
            var byProject: [String: Int] = [:]
            for d in last24h {
                let name = d.name ?? "(unknown)"
                byProject[name, default: 0] += 1
            }
            let topProjects: [[String: Any]] = byProject
                .sorted { $0.value > $1.value }
                .prefix(5)
                .map { ["name": $0.key, "count": $0.value] }

            var extras: [String: String] = [
                "headline":        headline,
                "caption":         caption,
                "username":        user.user.username ?? user.user.name ?? "",
                "projectCount":    "\(projects.count)",
                "deployments24h":  "\(last24h.count)",
                "failed24h":       "\(failed24h)",
                "hourBucketsReqs": hourBuckets.map(String.init).joined(separator: ","),
            ]
            if let arr = try? JSONSerialization.data(withJSONObject: topProjects),
               let s = String(data: arr, encoding: .utf8) {
                extras["topProjects"] = s
            }
            // Failure-rate flag — surface via pct so the menu-bar dot
            // can go amber/red on high failure density.
            if last24h.count >= 10 {
                let failRatio = Double(failed24h) / Double(last24h.count)
                if failRatio >= 0.4 {
                    extras["pct"] = "95"
                } else if failRatio >= 0.2 {
                    extras["pct"] = "80"
                }
            }

            let note: String
            if last24h.isEmpty {
                note = "no deployments in the last 24h"
            } else if failed24h > 0 {
                note = "\(failed24h) failed · \(projects.count) projects"
            } else {
                note = "\(projects.count) projects · all green"
            }

            return ProviderSnapshot(
                id: id, title: displayName,
                subtitle: user.user.username.map { "@\($0)" } ?? "Vercel",
                glyph: "V", accent: .slate, size: .compact,
                headline: headline, headlineCaption: caption,
                state: .ok,
                note: note,
                extras: extras
            )
        } catch {
            return ProviderSnapshot(
                id: id, title: displayName, subtitle: "Vercel",
                glyph: "V", accent: .slate, size: .compact,
                headline: "—", headlineCaption: "api error",
                state: .error,
                note: "Vercel API error"
            )
        }
    }

    private func unconfigured() -> ProviderSnapshot {
        ProviderSnapshot(
            id: id, title: displayName, subtitle: "Vercel",
            glyph: "V", accent: .slate, size: .compact,
            headline: "Add key", headlineCaption: "to see deployments",
            state: .unconfigured,
            note: "API key not configured"
        )
    }

    // MARK: - API

    private struct UserEnvelope: Decodable {
        struct U: Decodable {
            let username: String?
            let name: String?
        }
        let user: U
    }
    private struct ProjectsEnvelope: Decodable {
        struct P: Decodable { let id: String; let name: String }
        let projects: [P]
    }
    private struct DeploymentsEnvelope: Decodable {
        let deployments: [Deployment]
    }
    private struct Deployment: Decodable {
        let uid: String?
        let name: String?
        let created: Int           // ms epoch
        let state: String?         // READY, ERROR, BUILDING, CANCELED, QUEUED
    }

    private func vercelHeaders(key: String) -> [String: String] {
        ["Authorization": "Bearer \(key)"]
    }

    private func fetchUser(key: String) async throws -> UserEnvelope {
        try await APIClient.shared.getJSON(
            UserEnvelope.self,
            url: URL(string: "https://api.vercel.com/v2/user")!,
            headers: vercelHeaders(key: key)
        )
    }
    private func fetchProjects(key: String) async throws -> [ProjectsEnvelope.P] {
        let env = try await APIClient.shared.getJSON(
            ProjectsEnvelope.self,
            url: URL(string: "https://api.vercel.com/v9/projects?limit=20")!,
            headers: vercelHeaders(key: key)
        )
        return env.projects
    }
    private func fetchRecentDeployments(key: String) async throws -> [Deployment] {
        let env = try await APIClient.shared.getJSON(
            DeploymentsEnvelope.self,
            url: URL(string: "https://api.vercel.com/v6/deployments?limit=100")!,
            headers: vercelHeaders(key: key)
        )
        return env.deployments
    }
}
