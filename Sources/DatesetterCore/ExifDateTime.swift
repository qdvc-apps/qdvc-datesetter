import Foundation

/// An EXIF date and time: a wall-clock reading with no time zone, exactly as
/// EXIF stores it ("YYYY:MM:DD HH:MM:SS"). Keeping it as plain fields avoids
/// any time-zone or daylight-saving conversion between what the user types
/// and what is written.
public struct ExifDateTime: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int
    public let hour: Int
    public let minute: Int
    public let second: Int

    /// Nil unless every field is in range and the day exists in that month.
    public init?(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0, second: Int = 0) {
        guard (1...9999).contains(year),
              (1...12).contains(month),
              (1...Self.daysIn(month: month, year: year)).contains(day),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second)
        else { return nil }
        self.init(unchecked: year, month, day, hour, minute, second)
    }

    private init(unchecked year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) {
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
    }

    /// The wall-clock reading of `date` in `timeZone`.
    public init(date: Date, in timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        self.init(unchecked: min(max(c.year ?? 1, 1), 9999), c.month ?? 1, c.day ?? 1,
                  c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    /// Reads a date typed by the user or stored in EXIF. Accepted:
    ///
    ///     2024-05-01 14:30:00     2024-05-01 14:30     2024-05-01
    ///     2024:05:01 14:30:00     2024/05/01 14:30:00  2024.05.01 14:30:00
    ///     2024-05-01T14:30:00
    ///
    /// The year has four digits; the other parts one or two. Missing time
    /// parts are zero. Returns nil for anything else, including dates that
    /// don't exist (2023-02-29) and EXIF's blank "    :  :     :  :  ".
    public static func parse(_ input: String) -> ExifDateTime? {
        var groups: [String] = []
        var separators: [String] = []
        var digits = ""
        var separator = ""
        for ch in input.trimmingCharacters(in: .whitespacesAndNewlines) {
            if let ascii = ch.asciiValue, ascii >= 48, ascii <= 57 {
                if digits.isEmpty && !groups.isEmpty {
                    separators.append(separator)
                    separator = ""
                }
                digits.append(ch)
            } else {
                if !digits.isEmpty {
                    groups.append(digits)
                    digits = ""
                }
                if groups.isEmpty { return nil }
                separator.append(ch)
            }
        }
        guard !digits.isEmpty else { return nil }
        groups.append(digits)

        guard [3, 5, 6].contains(groups.count),
              groups[0].count == 4,
              groups.dropFirst().allSatisfy({ (1...2).contains($0.count) }),
              separators.count == groups.count - 1
        else { return nil }
        let dateSeparators: Set<String> = ["-", ":", "/", "."]
        guard dateSeparators.contains(separators[0]), separators[1] == separators[0] else { return nil }
        if groups.count > 3 {
            let middle = separators[2].trimmingCharacters(in: .whitespaces)
            guard middle.isEmpty || middle == "T" || middle == "t" else { return nil }
            guard separators[3...].allSatisfy({ $0 == ":" }) else { return nil }
        }
        let n = groups.compactMap { Int($0) }
        guard n.count == groups.count else { return nil }
        return ExifDateTime(year: n[0], month: n[1], day: n[2],
                            hour: n.count > 3 ? n[3] : 0,
                            minute: n.count > 4 ? n[4] : 0,
                            second: n.count > 5 ? n[5] : 0)
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let s = String(value)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }

    /// "YYYY:MM:DD HH:MM:SS", the 19 characters EXIF stores.
    public var exifString: String {
        "\(Self.pad(year, 4)):\(Self.pad(month, 2)):\(Self.pad(day, 2)) "
            + "\(Self.pad(hour, 2)):\(Self.pad(minute, 2)):\(Self.pad(second, 2))"
    }

    /// "YYYY-MM-DD HH:MM:SS", as shown and typed in the app.
    public var displayString: String {
        "\(Self.pad(year, 4))-\(Self.pad(month, 2))-\(Self.pad(day, 2)) "
            + "\(Self.pad(hour, 2)):\(Self.pad(minute, 2)):\(Self.pad(second, 2))"
    }

    public var description: String { displayString }

    /// This wall-clock reading in `timeZone`, as an absolute date.
    public func date(in timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day,
                                                  hour: hour, minute: minute, second: second))
    }

    public static func < (a: ExifDateTime, b: ExifDateTime) -> Bool {
        [a.year, a.month, a.day, a.hour, a.minute, a.second]
            .lexicographicallyPrecedes([b.year, b.month, b.day, b.hour, b.minute, b.second])
    }
}

/// EXIF's OffsetTime tags ("+10:00", "-05:30").
public enum OffsetTime {
    public static func timeZone(from text: String) -> TimeZone? {
        let t = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        guard t.count == 6, let sign = t.first, sign == "+" || sign == "-" else { return nil }
        let parts = t.dropFirst().split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), h <= 14, m < 60 else { return nil }
        let seconds = (h * 3600 + m * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }
}
