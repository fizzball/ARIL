import Foundation

/// Per-calendar-day spend totals keyed by OpenRouter model id.
struct SpendDayRecord: Codable, Equatable {
    var totalUsd: Double
    var byModel: [String: Double]

    static let empty = SpendDayRecord(totalUsd: 0, byModel: [:])

    mutating func add(_ amount: Double, model: String?) {
        guard amount > 0 else { return }
        totalUsd += amount
        let key = SpendLedger.normalizeModel(model)
        byModel[key, default: 0] += amount
    }
}

/// Local day-keyed spend ledger (survives Learning-store FIFO retention).
final class SpendLedger {
    static let shared = SpendLedger()
    private static let defaultsKey = "aril.spend.ledger"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func normalizeModel(_ model: String?) -> String {
        let trimmed = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    func load() -> [String: SpendDayRecord] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: SpendDayRecord].self, from: data)
        else { return [:] }
        return decoded
    }

    func save(_ ledger: [String: SpendDayRecord]) {
        // Keep ~400 days so monthly/weekly views stay useful without unbounded growth.
        let pruned = prune(ledger, keepDays: 400)
        guard let data = try? JSONEncoder().encode(pruned) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    func add(amount: Double, model: String?, on dayKey: String) {
        guard amount > 0 else { return }
        var ledger = load()
        var day = ledger[dayKey] ?? .empty
        day.add(amount, model: model)
        ledger[dayKey] = day
        save(ledger)
    }

    private func prune(_ ledger: [String: SpendDayRecord], keepDays: Int) -> [String: SpendDayRecord] {
        let sorted = ledger.keys.sorted(by: >)
        guard sorted.count > keepDays else { return ledger }
        let keep = Set(sorted.prefix(keepDays))
        return ledger.filter { keep.contains($0.key) }
    }
}

/// Aggregated spend for the Spend analysis flyout.
struct SpendAnalysisSnapshot: Equatable {
    struct ModelRow: Identifiable, Equatable {
        let id: String
        let model: String
        let costUsd: Double
        let share: Double
    }

    var weeklyUsd: Double
    var monthlyUsd: Double
    var todayUsd: Double
    var models: [ModelRow]
    var weekLabel: String
    var monthLabel: String
    var sourceNote: String

    static let empty = SpendAnalysisSnapshot(
        weeklyUsd: 0,
        monthlyUsd: 0,
        todayUsd: 0,
        models: [],
        weekLabel: "Last 7 days",
        monthLabel: "",
        sourceNote: ""
    )

    static func build(
        storeRecords: [StoreRecordDTO],
        ledger: [String: SpendDayRecord],
        calendar: Calendar = .current,
        now: Date = .now
    ) -> SpendAnalysisSnapshot {
        var dayModel: [String: [String: Double]] = [:]

        for record in storeRecords where record.kind == "chat_transaction" {
            guard let cost = record.costUsd, cost > 0,
                  let day = dayKey(from: record.createdAt, calendar: calendar)
            else { continue }
            let model = SpendLedger.normalizeModel(record.model)
            dayModel[day, default: [:]][model, default: 0] += cost
        }

        for (day, rec) in ledger {
            let storeTotal = dayModel[day]?.values.reduce(0, +) ?? 0
            if rec.totalUsd > storeTotal + 0.000_000_1 || storeTotal == 0 {
                dayModel[day] = rec.byModel
            }
        }

        let todayKey = dayKey(from: now, calendar: calendar)
        let monthPrefix = String(todayKey.prefix(7)) // yyyy-MM
        let weekStart = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
            ?? now
        let weekKeys: Set<String> = {
            var keys = Set<String>()
            for offset in 0..<7 {
                if let d = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now)) {
                    keys.insert(dayKey(from: d, calendar: calendar))
                }
            }
            return keys
        }()

        var weekly = 0.0
        var monthly = 0.0
        var today = 0.0
        var modelTotals: [String: Double] = [:]

        for (day, models) in dayModel {
            let dayTotal = models.values.reduce(0, +)
            if weekKeys.contains(day) { weekly += dayTotal }
            if day.hasPrefix(monthPrefix) { monthly += dayTotal }
            if day == todayKey { today = dayTotal }
            for (model, cost) in models {
                // Model list is scoped to the calendar month (primary reporting window).
                if day.hasPrefix(monthPrefix) {
                    modelTotals[model, default: 0] += cost
                }
            }
        }

        // If the month is empty but we have weekly spend, still list models from the week.
        if modelTotals.isEmpty {
            for (day, models) in dayModel where weekKeys.contains(day) {
                for (model, cost) in models {
                    modelTotals[model, default: 0] += cost
                }
            }
        }

        let modelSum = modelTotals.values.reduce(0, +)
        let rows = modelTotals
            .map { key, cost in
                ModelRow(
                    id: key,
                    model: key,
                    costUsd: cost,
                    share: modelSum > 0 ? cost / modelSum : 0
                )
            }
            .sorted { lhs, rhs in
                if lhs.costUsd != rhs.costUsd { return lhs.costUsd > rhs.costUsd }
                return lhs.model.localizedCaseInsensitiveCompare(rhs.model) == .orderedAscending
            }

        let monthName: String = {
            let f = DateFormatter()
            f.locale = .current
            f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
            return f.string(from: now)
        }()

        let weekRange: String = {
            let f = DateFormatter()
            f.locale = .current
            f.setLocalizedDateFormatFromTemplate("MMM d")
            let start = f.string(from: weekStart)
            let end = f.string(from: now)
            return "\(start) – \(end)"
        }()

        let usedStore = storeRecords.contains { $0.kind == "chat_transaction" && ($0.costUsd ?? 0) > 0 }
        let usedLedger = !ledger.isEmpty
        var noteParts: [String] = []
        if usedLedger { noteParts.append("local spend ledger") }
        if usedStore { noteParts.append("Learning chat transactions") }
        let sourceNote = noteParts.isEmpty
            ? "No recorded spend yet — costs appear after replies with actual OpenRouter pricing."
            : "Based on \(noteParts.joined(separator: " + "))."

        return SpendAnalysisSnapshot(
            weeklyUsd: weekly,
            monthlyUsd: monthly,
            todayUsd: today,
            models: rows,
            weekLabel: "Last 7 days (\(weekRange))",
            monthLabel: monthName,
            sourceNote: sourceNote
        )
    }

    private static func dayKey(from date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func dayKey(from raw: String?, calendar: Calendar) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let date = parseAPIDate(raw) {
            return dayKey(from: date, calendar: calendar)
        }
        // Already a day key?
        if raw.count >= 10 {
            let prefix = String(raw.prefix(10))
            if prefix.contains("-") { return prefix }
        }
        return nil
    }

    private static func parseAPIDate(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: raw) { return date }
        // SQLite sometimes stores "yyyy-MM-dd HH:mm:ss"
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        local.dateFormat = "yyyy-MM-dd HH:mm:ss"
        if let date = local.date(from: String(raw.prefix(19))) { return date }
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return local.date(from: String(raw.prefix(19)))
    }
}
