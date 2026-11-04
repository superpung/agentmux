import Foundation

/// Compact, deliberately approximate ETA labels in the viewing Mac's time zone.
public enum JobTimeLabel {
    public static func remaining(_ seconds: Int) -> String {
        let minutes = max(1, Int(ceil(Double(max(0, seconds)) / 60)))
        if minutes < 60 { return "≈ \(minutes)m" }
        let hours = minutes / 60, rest = minutes % 60
        if hours < 24 { return rest == 0 ? "≈ \(hours)h" : "≈ \(hours)h \(rest)m" }
        let days = hours / 24, remainingHours = hours % 24
        return remainingHours == 0 ? "≈ \(days)d" : "≈ \(days)d \(remainingHours)h"
    }

    public static func finish(_ timestamp: Double, relativeTo now: Double, calendar: Calendar = .current) -> String {
        let date = Date(timeIntervalSince1970: timestamp)
        let today = Date(timeIntervalSince1970: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        if calendar.isDate(date, inSameDayAs: today) {
            return "Today \(formatter.string(from: date))"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow \(formatter.string(from: date))"
        }
        formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: today)
            ? "MMM d, HH:mm" : "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
