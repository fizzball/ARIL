import Foundation

/// A model temporarily or permanently skipped after a first-token timeout (or user action).
struct BypassedModelEntry: Codable, Identifiable, Equatable {
    var id: String { modelID }
    let modelID: String
    let bypassedAt: Date
    /// `nil` means permanent until the user clears it.
    let expiresAt: Date?
    let reason: String

    var isPermanent: Bool { expiresAt == nil }

    var isActive: Bool {
        guard let expiresAt else { return true }
        return expiresAt > Date()
    }

    var statusLabel: String {
        if isPermanent { return "Permanent" }
        guard let expiresAt else { return "Permanent" }
        let remaining = expiresAt.timeIntervalSinceNow
        if remaining <= 0 { return "Expired" }
        let mins = Int(ceil(remaining / 60))
        if mins < 60 { return "\(mins)m left" }
        let hours = mins / 60
        let rem = mins % 60
        return rem == 0 ? "\(hours)h left" : "\(hours)h \(rem)m left"
    }
}

enum ModelBypassStore {
    static let enabledKey = "aril.modelBypassEnabled"
    static let minutesKey = "aril.modelBypassMinutes"
    static let permanentKey = "aril.modelBypassPermanentOnTimeout"
    static let entriesKey = "aril.modelBypassEntries"

    static let defaultMinutes = 15

    static func clampedMinutes(_ value: Int) -> Int {
        min(24 * 60, max(1, value))
    }

    static func loadEntries(from defaults: UserDefaults = .standard) -> [BypassedModelEntry] {
        guard let data = defaults.data(forKey: entriesKey),
              let decoded = try? JSONDecoder().decode([BypassedModelEntry].self, from: data)
        else { return [] }
        return decoded.filter(\.isActive)
    }

    static func saveEntries(_ entries: [BypassedModelEntry], to defaults: UserDefaults = .standard) {
        let active = entries.filter(\.isActive)
        if let data = try? JSONEncoder().encode(active) {
            defaults.set(data, forKey: entriesKey)
        }
    }
}
