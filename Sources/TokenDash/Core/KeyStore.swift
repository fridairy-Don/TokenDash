import Foundation
import Security

// MARK: - KeyStore
//
// Local-file storage for provider API keys, replacing the Keychain-based
// flow. We switched because ad-hoc code signing (`codesign --sign -`)
// changes the binary's signature on every rebuild, which makes Keychain's
// ACL reject the "new" app and prompt the user for their login password —
// multiple times per rebuild. For a local menubar dev tool that's untenable.
//
// File path: ~/Library/Application Support/TokenDash/keys.plist
// Permissions: 0600 (owner read/write only)
// Format: binary plist — a string:string dictionary keyed by provider id.
//
// Security model: user-level isolation. Another user on the Mac can't read
// your keys. Another app running as you could, but so could any app read a
// Keychain-stored item once you've clicked "Always Allow" — which is what
// most users do anyway. The honest tradeoff is: Keychain offers stronger
// isolation in principle, but ad-hoc signing defeats it in practice. A
// file with proper POSIX permissions is equivalent in practice and never
// interrupts you with password prompts.
//
// Migration: on first launch after upgrade, we pull existing values from
// Keychain (one last prompt), write them into the file, then delete them
// from Keychain so we never go back.

enum KeyStore {
    // MARK: - Paths

    private static var storeURL: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TokenDash", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("keys.plist")
    }

    // MARK: - Core API (mirrors old Keychain API)

    static func save(_ value: String, account: String) {
        var dict = loadAll()
        dict[account] = value
        write(dict)
    }

    static func load(account: String) -> String? {
        let dict = loadAll()
        if let v = dict[account], !v.isEmpty { return v }
        // Fallback: first-run migration. A fresh install will have neither
        // file nor Keychain entry, so this is cheap.
        if let legacy = LegacyKeychain.load(account: account), !legacy.isEmpty {
            save(legacy, account: account)
            LegacyKeychain.delete(account: account)
            return legacy
        }
        return nil
    }

    static func delete(account: String) {
        var dict = loadAll()
        dict.removeValue(forKey: account)
        write(dict)
        LegacyKeychain.delete(account: account)   // belt and suspenders
    }

    static func hasKey(account: String) -> Bool {
        load(account: account) != nil
    }

    // MARK: - Upfront migration (optional)
    //
    // Called once at launch. For each known provider id we copy any
    // Keychain value into the file and then wipe the Keychain entry, so
    // the user sees at most one password prompt per key rather than a
    // drip of prompts as each provider's snapshot fires.

    static func migrateFromKeychainIfNeeded(accounts: [String]) {
        var dict = loadAll()
        var changed = false
        for account in accounts where dict[account] == nil {
            if let legacy = LegacyKeychain.load(account: account), !legacy.isEmpty {
                dict[account] = legacy
                LegacyKeychain.delete(account: account)
                changed = true
            }
        }
        if changed { write(dict) }
    }

    // MARK: - Internals

    private static func loadAll() -> [String: String] {
        guard let data = try? Data(contentsOf: storeURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: String]
        else { return [:] }
        return dict
    }

    private static func write(_ dict: [String: String]) {
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
            try data.write(to: storeURL, options: [.atomic])
            // Tighten perms to owner-only. atomic write recreates the file
            // with default umask, so re-apply every time.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: storeURL.path
            )
        } catch {
            NSLog("TokenDash KeyStore write failed: %@", "\(error)")
        }
    }
}

// MARK: - LegacyKeychain (migration source only)
//
// Renamed from the old `Keychain` enum. All live code calls KeyStore
// now; this namespace only exists to drain existing users' Keychain
// entries into the file store.

enum LegacyKeychain {
    private static let service = "TokenDash"

    static func load(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
