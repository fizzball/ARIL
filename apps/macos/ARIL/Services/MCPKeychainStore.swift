import Foundation
import Security

/// Keychain helper for MCP server secrets (managed-server bearer tokens + the API
/// keys the user enters for remote MCP servers).
///
/// All secrets live in a SINGLE generic-password item (service `com.aril.app.mcp`,
/// account `aril-mcp-tokens`) holding a JSON `{ serverUUID: secret }` map. Keeping
/// everything in one item means macOS asks for Keychain authorization at most once
/// per launch instead of once per server, and a small in-process cache ensures
/// repeated `load` calls within a launch never re-trigger the prompt.
///
/// Older builds stored one Keychain item per server UUID. Those legacy items are
/// migrated into the consolidated item the first time each is accessed, then
/// deleted — so no stored key is lost on upgrade.
enum MCPKeychainStore {
    private static let service = "com.aril.app.mcp"
    private static let consolidatedAccount = "aril-mcp-tokens"

    private static let lock = NSLock()
    /// In-process cache of the decoded secret map (nil = not read from Keychain yet).
    private static var cache: [String: String]?

    static func load(serverID: UUID) -> String {
        lock.lock()
        defer { lock.unlock() }

        let key = serverID.uuidString
        var map = ensureLoadedLocked()
        if let value = map[key], !value.isEmpty {
            return value
        }
        // One-time migration: pull a legacy per-UUID item into the consolidated map.
        if let legacy = legacyLoad(serverID: serverID),
           !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            map[key] = legacy
            cache = map
            writeConsolidated(map)
            legacyDelete(serverID: serverID)
            return legacy
        }
        return ""
    }

    static func save(serverID: UUID, apiKey: String) {
        lock.lock()
        defer { lock.unlock() }

        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var map = ensureLoadedLocked()
        if trimmed.isEmpty {
            map.removeValue(forKey: serverID.uuidString)
        } else {
            map[serverID.uuidString] = trimmed
        }
        cache = map
        writeConsolidated(map)
        // Drop any stale legacy copy so it can't resurface or re-prompt.
        legacyDelete(serverID: serverID)
    }

    static func delete(serverID: UUID) {
        lock.lock()
        defer { lock.unlock() }

        var map = ensureLoadedLocked()
        map.removeValue(forKey: serverID.uuidString)
        cache = map
        writeConsolidated(map)
        legacyDelete(serverID: serverID)
    }

    // MARK: - Consolidated item

    private static func ensureLoadedLocked() -> [String: String] {
        if let cache { return cache }
        let map = readConsolidated()
        cache = map
        return map
    }

    private static func readConsolidated() -> [String: String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: consolidatedAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return map
    }

    private static func writeConsolidated(_ map: [String: String]) {
        let data = (try? JSONEncoder().encode(map)) ?? Data("{}".utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: consolidatedAccount,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    // MARK: - Legacy per-server items (pre-consolidation)

    private static func legacyLoad(serverID: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func legacyDelete(serverID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: serverID.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
