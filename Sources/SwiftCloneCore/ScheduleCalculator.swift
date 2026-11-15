import Foundation

public enum ScheduleCalculator {
    /// The first scheduled time strictly after `date`, or nil for manual jobs.
    public static func nextRun(after date: Date, schedule: Schedule, calendar: Calendar = .current) -> Date? {
        var components = DateComponents()
        components.hour = min(max(schedule.hour, 0), 23)
        components.minute = min(max(schedule.minute, 0), 59)
        components.second = 0
        switch schedule.kind {
        case .manual: return nil
        case .daily: break
        case .weekly: components.weekday = min(max(schedule.weekday, 1), 7)
        }
        // .nextTime handles daylight-saving gaps by moving to the next valid time.
        return calendar.nextDate(after: date, matching: components, matchingPolicy: .nextTime)
    }
}
