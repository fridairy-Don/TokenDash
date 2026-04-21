import Foundation

// MARK: - ProviderRegistry
//
// Manages which providers are instantiated at runtime. The app ships with
// five "always-on" providers (Claude Code, Codex, ElevenLabs, OpenRouter,
// Groq). Additional providers live in a user-editable registry so people
// can add the ones they care about (Moonshot, GitHub, Vercel, ...) without
// us needing to ship a code update.
//
// Persistence: ~/Library/Application Support/TokenDash/providers.json
//   [
//     { "type": "moonshot" },
//     { "type": "github" },
//     { "type": "vercel" }
//   ]
//
// The API key for each registered provider lives in KeyStore (keys.plist)
// under account == type string. That way this file is just "which
// providers are active" and doesn't carry secrets.

@MainActor
final class ProviderRegistry {
    static let shared = ProviderRegistry()

    struct Entry: Codable, Equatable {
        let type: String          // e.g. "moonshot", "github", "vercel"
    }

    // All provider types that can be added. Built-ins are listed too so
    // the Settings UI can show them in the picker, but they're filtered
    // out of "addable" if already present.
    struct Descriptor {
        let type: String               // stable id, matches provider.id
        let displayName: String        // "Moonshot (Kimi)"
        let description: String        // one-line blurb for picker
        let apiKeyHint: String?        // placeholder for key input
        let isBuiltIn: Bool            // built-ins are always instantiated
        let docsURL: String?           // where to create an API key
    }

    // Keep this in one place so both the picker UI and DataStore agree.
    // When we add a provider, we add to this table.
    static let descriptors: [Descriptor] = [
        .init(type: "claude_code",  displayName: "Claude Code",
              description: "Reads ~/.claude/projects/**/*.jsonl locally — no key needed.",
              apiKeyHint: nil, isBuiltIn: true, docsURL: nil),
        .init(type: "codex",        displayName: "Codex",
              description: "Reads ~/.codex/sessions/**/*.jsonl locally — no key needed.",
              apiKeyHint: nil, isBuiltIn: true, docsURL: nil),
        .init(type: "elevenlabs",   displayName: "ElevenLabs",
              description: "TTS character quota + per-voice usage + abuse detection.",
              apiKeyHint: "xi-... (from elevenlabs.io → Account → API Keys)",
              isBuiltIn: true,
              docsURL: "https://elevenlabs.io/app/settings/api-keys"),
        .init(type: "openrouter",   displayName: "OpenRouter",
              description: "Credits + per-model spend + 7-day activity.",
              apiKeyHint: "sk-or-... (from openrouter.ai/keys)",
              isBuiltIn: true,
              docsURL: "https://openrouter.ai/keys"),
        .init(type: "groq",         displayName: "Groq",
              description: "Key presence only — Groq has no public usage API yet.",
              apiKeyHint: "gsk_... (from console.groq.com)",
              isBuiltIn: true,
              docsURL: "https://console.groq.com/keys"),
        .init(type: "moonshot",     displayName: "Moonshot (Kimi)",
              description: "Cash balance + voucher balance remaining.",
              apiKeyHint: "sk-... (from platform.moonshot.cn)",
              isBuiltIn: false,
              docsURL: "https://platform.moonshot.cn/console/api-keys"),
        .init(type: "github",       displayName: "GitHub",
              description: "API rate limits + authenticated user info.",
              apiKeyHint: "ghp_... or github_pat_...",
              isBuiltIn: false,
              docsURL: "https://github.com/settings/tokens"),
        .init(type: "vercel",       displayName: "Vercel",
              description: "Deployments, bandwidth, and firewall events for your projects.",
              apiKeyHint: "Vercel access token",
              isBuiltIn: false,
              docsURL: "https://vercel.com/account/tokens"),
    ]

    // Built-in descriptors that should always have a provider instance.
    static var builtInTypes: [String] {
        descriptors.filter { $0.isBuiltIn }.map { $0.type }
    }

    // All add-able types (non-built-in).
    static var addableTypes: [String] {
        descriptors.filter { !$0.isBuiltIn }.map { $0.type }
    }

    static func descriptor(for type: String) -> Descriptor? {
        descriptors.first { $0.type == type }
    }

    // MARK: - Persistence

    private var entries: [Entry] = []

    private init() {
        entries = readFromDisk()
    }

    private var fileURL: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenDash", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("providers.json")
    }

    private func readFromDisk() -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func writeToDisk() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("TokenDash ProviderRegistry write failed: %@", "\(error)")
        }
    }

    // MARK: - Public API

    /// The set of extra (non-built-in) provider types the user has configured.
    var configuredExtraTypes: [String] {
        entries.map { $0.type }
    }

    /// Add a provider to the registry and persist its API key.
    /// Returns true if something actually changed.
    @discardableResult
    func add(type: String, apiKey: String) -> Bool {
        guard Self.descriptor(for: type) != nil,
              Self.addableTypes.contains(type) else { return false }
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        KeyStore.save(trimmed, account: type)
        if !entries.contains(where: { $0.type == type }) {
            entries.append(Entry(type: type))
            writeToDisk()
        }
        return true
    }

    /// Remove an extra provider and its API key. Built-ins can't be removed.
    @discardableResult
    func remove(type: String) -> Bool {
        guard Self.addableTypes.contains(type) else { return false }
        KeyStore.delete(account: type)
        let before = entries.count
        entries.removeAll { $0.type == type }
        if entries.count != before {
            writeToDisk()
            return true
        }
        return false
    }

    /// Instantiate every active provider: built-ins (always on) plus any
    /// extras the user added. Order matches descriptors for deterministic
    /// UI arrangement.
    func instantiateAllProviders() -> [UsageProvider] {
        var out: [UsageProvider] = []
        for d in Self.descriptors {
            if d.isBuiltIn {
                if let p = Self.makeProvider(type: d.type) { out.append(p) }
            } else if entries.contains(where: { $0.type == d.type }) {
                if let p = Self.makeProvider(type: d.type) { out.append(p) }
            }
        }
        return out
    }

    // MARK: - Factory
    //
    // Central place where "provider type string → Swift class" mapping
    // lives. Adding a new provider means: a new class + a row in
    // descriptors + a case here.

    static func makeProvider(type: String) -> UsageProvider? {
        switch type {
        case "claude_code": return ClaudeCodeProvider()
        case "codex":       return CodexProvider()
        case "elevenlabs":  return ElevenLabsProvider()
        case "openrouter":  return OpenRouterProvider()
        case "groq":        return GroqProvider()
        case "moonshot":    return MoonshotProvider()
        case "github":      return GitHubProvider()
        case "vercel":      return VercelProvider()
        default:            return nil
        }
    }
}
