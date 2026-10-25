import Foundation

/// What a keep-awake session prevents.
public enum KeepAwakeMode: String, Codable, CaseIterable, Identifiable {
    /// Screens stay on (and so does the Mac).
    case display
    /// Screens may sleep; the Mac itself stays awake.
    case system

    public var id: String { rawValue }
}

/// Who asked for the Mac to stay awake. Several can be active at once; each
/// ends on its own, so an app quitting never cancels a manual session.
public enum KeepAwakeSource: Hashable, Codable {
    case manual
    case app(bundleID: String)
    case presentation

    /// Manual and app-triggered sessions stop when the battery runs low;
    /// presentation mode keeps its hold until it is turned off.
    public var endsOnLowBattery: Bool {
        switch self {
        case .manual, .app: return true
        case .presentation: return false
        }
    }
}

/// How long a manual session lasts.
public enum KeepAwakeDuration: Codable, Hashable {
    case minutes(Int)
    case indefinitely
    /// Until the next occurrence of this clock time (today, or tomorrow if it has passed).
    case until(hour: Int, minute: Int)

    public static let presets: [KeepAwakeDuration] = [
        .minutes(15), .minutes(30), .minutes(60), .minutes(120), .minutes(240), .indefinitely,
    ]

    /// Custom durations are limited to one minute ... one day.
    public static let customMinutesRange = 1 ... 24 * 60

    public static func custom(minutes: Int) -> KeepAwakeDuration {
        .minutes(min(max(minutes, customMinutesRange.lowerBound), customMinutesRange.upperBound))
    }

    /// When the session should end, or nil for "until turned off".
    public func deadline(from now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .indefinitely:
            return nil
        case .minutes(let m):
            return now.addingTimeInterval(TimeInterval(max(m, 1)) * 60)
        case .until(let hour, let minute):
            let parts = DateComponents(hour: min(max(hour, 0), 23), minute: min(max(minute, 0), 59), second: 0)
            return calendar.nextDate(after: now, matching: parts, matchingPolicy: .nextTime)
        }
    }

    public var label: String {
        switch self {
        case .indefinitely: return "Indefinitely"
        case .minutes(let m): return Self.describe(minutes: m)
        case .until(let hour, let minute): return String(format: "Until %02d:%02d", hour, minute)
        }
    }

    public static func describe(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        switch (h, m) {
        case (0, _): return "\(m) min"
        case (_, 0): return h == 1 ? "1 hour" : "\(h) hours"
        default: return "\(h) h \(m) min"
        }
    }
}

/// One active request to stay awake.
public struct KeepAwakeHold: Equatable {
    public var mode: KeepAwakeMode
    /// nil = until turned off.
    public var deadline: Date?

    public init(mode: KeepAwakeMode, deadline: Date?) {
        self.mode = mode
        self.deadline = deadline
    }
}

/// The set of active holds and the single power assertion they need.
/// Pure logic: the app turns `effectiveMode` into one IOKit assertion.
public struct KeepAwakeState: Equatable {
    public private(set) var holds: [KeepAwakeSource: KeepAwakeHold] = [:]

    public init() {}

    public var isActive: Bool { !holds.isEmpty }

    /// The strictest mode any hold needs: keeping the display on wins.
    public var effectiveMode: KeepAwakeMode? {
        guard !holds.isEmpty else { return nil }
        return holds.values.contains { $0.mode == .display } ? .display : .system
    }

    /// The earliest moment a hold expires, for scheduling one timer.
    public var nextDeadline: Date? { holds.values.compactMap(\.deadline).min() }

    public func hold(for source: KeepAwakeSource) -> KeepAwakeHold? { holds[source] }

    public func remaining(for source: KeepAwakeSource, now: Date) -> TimeInterval? {
        guard let deadline = holds[source]?.deadline else { return nil }
        return max(deadline.timeIntervalSince(now), 0)
    }

    public mutating func activate(_ source: KeepAwakeSource, mode: KeepAwakeMode, deadline: Date?) {
        holds[source] = KeepAwakeHold(mode: mode, deadline: deadline)
    }

    public mutating func deactivate(_ source: KeepAwakeSource) {
        holds[source] = nil
    }

    /// Changes the mode of every hold that follows the user's mode setting
    /// (manual and app-triggered); presentation mode always keeps the display on.
    public mutating func setUserMode(_ mode: KeepAwakeMode) {
        for (source, hold) in holds where source != .presentation {
            holds[source] = KeepAwakeHold(mode: mode, deadline: hold.deadline)
        }
    }

    /// Removes holds whose deadline has passed and returns their sources.
    @discardableResult
    public mutating func expire(now: Date) -> [KeepAwakeSource] {
        let expired = holds.filter { ($0.value.deadline.map { $0 <= now }) ?? false }.map(\.key)
        expired.forEach { holds[$0] = nil }
        return expired
    }

    /// Ends the holds that stop on low battery and returns their sources.
    @discardableResult
    public mutating func endForLowBattery() -> [KeepAwakeSource] {
        let ended = holds.keys.filter(\.endsOnLowBattery)
        ended.forEach { holds[$0] = nil }
        return ended
    }

    public mutating func removeAll() { holds.removeAll() }
}

/// Battery cut-off rule: only on battery power, strictly below the threshold.
public enum BatteryCutoff {
    public static let thresholdRange = 5 ... 95

    public static func shouldEnd(onBattery: Bool, percent: Int?, threshold: Int) -> Bool {
        guard onBattery, let percent else { return false }
        return percent < threshold
    }
}

/// "1:05:03" / "42:10" style countdowns for the menu.
public enum RemainingTime {
    public static func format(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds.rounded(.up)), 0)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
