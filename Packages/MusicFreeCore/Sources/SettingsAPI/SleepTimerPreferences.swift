import Foundation

/// One recurring window that starts a sleep timer whenever playback begins in it.
public struct SleepTimerSchedule: Codable, Equatable, Hashable, Identifiable, Sendable {
    public static let minutesPerDay = 24 * 60
    public static let minimumDurationMinutes = 1
    public static let maximumDurationMinutes = 24 * 60

    public let id: UUID
    public let isEnabled: Bool
    public let startMinute: Int
    public let endMinute: Int
    public let durationMinutes: Int

    public init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        startMinute: Int,
        endMinute: Int,
        durationMinutes: Int
    ) throws {
        guard (0..<Self.minutesPerDay).contains(startMinute) else {
            throw SettingsError.invalidValue(
                field: "playback.sleepTimer.startMinute",
                reason: .outOfRange
            )
        }
        guard (0..<Self.minutesPerDay).contains(endMinute) else {
            throw SettingsError.invalidValue(
                field: "playback.sleepTimer.endMinute",
                reason: .outOfRange
            )
        }
        guard (Self.minimumDurationMinutes...Self.maximumDurationMinutes)
            .contains(durationMinutes)
        else {
            throw SettingsError.invalidValue(
                field: "playback.sleepTimer.durationMinutes",
                reason: .outOfRange
            )
        }

        self.id = id
        self.isEnabled = isEnabled
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.durationMinutes = durationMinutes
    }

    public func contains(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> Bool {
        guard isEnabled else { return false }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else { return false }
        let minuteOfDay = hour * 60 + minute

        if startMinute == endMinute {
            return true
        }
        if startMinute < endMinute {
            return startMinute <= minuteOfDay && minuteOfDay < endMinute
        }
        return minuteOfDay >= startMinute || minuteOfDay < endMinute
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case isEnabled
        case startMinute
        case endMinute
        case durationMinutes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            isEnabled: container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            startMinute: container.decode(Int.self, forKey: .startMinute),
            endMinute: container.decode(Int.self, forKey: .endMinute),
            durationMinutes: container.decode(Int.self, forKey: .durationMinutes)
        )
    }
}

public struct SleepTimerPreferences: Codable, Equatable, Hashable, Sendable {
    public let schedules: [SleepTimerSchedule]

    public init(schedules: [SleepTimerSchedule] = []) throws {
        guard Set(schedules.map(\.id)).count == schedules.count else {
            throw SettingsError.invalidValue(
                field: "playback.sleepTimer.schedules",
                reason: .duplicate
            )
        }
        self.schedules = schedules
    }

    private init(uncheckedSchedules schedules: [SleepTimerSchedule]) {
        self.schedules = schedules
    }

    public static let defaults = Self(uncheckedSchedules: [])

    public func activeSchedules(
        at date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [SleepTimerSchedule] {
        schedules.filter { $0.contains(date, calendar: calendar) }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(schedules: container.decode([SleepTimerSchedule].self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(schedules)
    }
}
