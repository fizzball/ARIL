import Foundation
import Security

/// MCP server secrets in Application Support `ARIL/.env` (same file as OpenRouter).
///
/// Keys are `ARIL_MCP_<server-uuid>` (lowercase, hyphens kept). Existing
/// `OPENROUTER_API_KEY` and any other lines are preserved on write.
///
/// One-time migration: legacy Keychain items (`MCPKeychainStore` era) are copied
/// into `.env` the first time each server id is loaded, then deleted from Keychain.
enum MCPEnvStore {
    private static let lock = NSLock()
    private static var cache: [String: String]?
    private static let openRouterKey = "OPENROUTER_API_KEY"
    private static let mcpPrefix = "ARIL_MCP_"
    private static let legacyKeychainService = "com.aril.app.mcp"
    private static let legacyConsolidatedAccount = "aril-mcp-tokens"

    static func load(serverID: UUID) -> String {
        lock.lock()
        defer { lock.unlock() }

        let key = envKey(for: serverID)
        var map = ensureLoadedLocked()
        if let value = map[key], !value.isEmpty {
            return value
        }
        // One-time Keychain → .env migration for this server.
        if let legacy = legacyKeychainLoad(serverID: serverID),
           !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            map[key] = legacy
            cache = map
            persistLocked(map)
            legacyKeychainDelete(serverID: serverID)
            return legacy
        }
        return ""
    }

    static func save(serverID: UUID, apiKey: String) {
        lock.lock()
        defer { lock.unlock() }

        let key = envKey(for: serverID)
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var map = ensureLoadedLocked()
        if trimmed.isEmpty {
            map.removeValue(forKey: key)
        } else {
            map[key] = trimmed
        }
        cache = map
        persistLocked(map)
        legacyKeychainDelete(serverID: serverID)
    }

    static func delete(serverID: UUID) {
        lock.lock()
        defer { lock.unlock() }

        let key = envKey(for: serverID)
        var map = ensureLoadedLocked()
        map.removeValue(forKey: key)
        cache = map
        persistLocked(map)
        legacyKeychainDelete(serverID: serverID)
    }

    // MARK: - .env file

    private static func envKey(for serverID: UUID) -> String {
        mcpPrefix + serverID.uuidString.lowercased()
    }

    private static func envFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("ARIL", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(".env")
    }

    private static func ensureLoadedLocked() -> [String: String] {
        if let cache { return cache }
        let map = readEnvFile()
        cache = map
        return map
    }

    private static func readEnvFile() -> [String: String] {
        let url = envFileURL()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var map: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'"))
            {
                value = String(value.dropFirst().dropLast())
            }
            guard !name.isEmpty else { continue }
            map[name] = value
        }
        return map
    }

    private static func persistLocked(_ map: [String: String]) {
        // Re-read disk so we don't clobber OPENROUTER_API_KEY written by the gateway.
        var merged = readEnvFile()
        // Drop previous MCP keys, then apply current map's MCP (+ keep non-MCP from disk).
        for key in merged.keys where key.hasPrefix(mcpPrefix) {
            merged.removeValue(forKey: key)
        }
        for (key, value) in map where key.hasPrefix(mcpPrefix) {
            if value.isEmpty {
                merged.removeValue(forKey: key)
            } else {
                merged[key] = value
            }
        }
        // Also keep any non-MCP keys that were only in our cache (shouldn't happen).
        for (key, value) in map where !key.hasPrefix(mcpPrefix) {
            merged[key] = value
        }

        var lines: [String] = [
            "# ARIL local secrets — never commit this file",
            "# Managed MCP tokens rotate each time a managed server is enabled.",
        ]
        if let openRouter = merged[openRouterKey], !openRouter.isEmpty {
            lines.append("\(openRouterKey)=\(openRouter)")
        }
        let mcpKeys = merged.keys.filter { $0.hasPrefix(mcpPrefix) }.sorted()
        for key in mcpKeys {
            if let value = merged[key], !value.isEmpty {
                lines.append("\(key)=\(value)")
            }
        }
        // Preserve any other unknown keys (future-proof).
        for key in merged.keys.sorted() where key != openRouterKey && !key.hasPrefix(mcpPrefix) {
            if let value = merged[key], !value.isEmpty {
                lines.append("\(key)=\(value)")
            }
        }
        lines.append("")
        let text = lines.joined(separator: "\n")
        try? text.write(to: envFileURL(), atomically: true, encoding: .utf8)

        // Refresh cache to full merged view for MCP keys we care about.
        cache = merged
    }

    // MARK: - Legacy Keychain migration

    private static func legacyKeychainLoad(serverID: UUID) -> String? {
        // Consolidated map item first.
        if let map = legacyReadConsolidated(),
           let value = map[serverID.uuidString],
           !value.isEmpty
        {
            return value
        }
        // Per-UUID item.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecAttrAccount as String: serverID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func legacyReadConsolidated() -> [String: String]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecAttrAccount as String: legacyConsolidatedAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return nil }
        return map
    }

    private static func legacyKeychainDelete(serverID: UUID) {
        let perServer: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecAttrAccount as String: serverID.uuidString,
        ]
        SecItemDelete(perServer as CFDictionary)

        // Rewrite consolidated map without this server (or delete if empty).
        guard var map = legacyReadConsolidated() else { return }
        map.removeValue(forKey: serverID.uuidString)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyKeychainService,
            kSecAttrAccount as String: legacyConsolidatedAccount,
        ]
        if map.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = (try? JSONEncoder().encode(map)) ?? Data("{}".utf8)
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
