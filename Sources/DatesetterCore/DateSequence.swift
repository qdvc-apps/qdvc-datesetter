import Foundation

/// Calendar arithmetic on EXIF dates, without Foundation's calendar: EXIF
/// dates have no time zone, so a step is plain wall-clock time (no daylight-
/// saving jumps), on the proleptic Gregorian calendar (no Julian switch).
extension ExifDateTime {
    /// Seconds since 1970-01-01 00:00:00 of the same calendar.
    public var secondsSinceEpoch: Int {
        Self.daysFromCivil(year, month, day) * 86_400 + hour * 3_600 + minute * 60 + second
    }

    /// Nil outside years 1 to 9999.
    public init?(secondsSinceEpoch t: Int) {
        let days = t >= 0 ? t / 86_400 : -((-t + 86_399) / 86_400)
        let rest = t - days * 86_400
        let (y, m, d) = Self.civilFromDays(days)
        self.init(year: y, month: m, day: d, hour: rest / 3_600, minute: rest % 3_600 / 60, second: rest % 60)
    }

    /// This date moved on by `seconds` (or back, if negative); nil if that
    /// leaves years 1 to 9999.
    public func adding(seconds: Int) -> ExifDateTime? {
        let (t, overflow) = secondsSinceEpoch.addingReportingOverflow(seconds)
        return overflow ? nil : ExifDateTime(secondsSinceEpoch: t)
    }

    // Howard Hinnant's days-from-civil algorithms (public domain).

    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12                  // March = 0
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civilFromDays(_ days: Int) -> (Int, Int, Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        let year = yoe + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }
}

/// A fixed amount added to each next photo's date: the first photo gets
/// the start date, the second start + step, the third start + 2 × step...
public struct DateStep: Sendable, Hashable, CustomStringConvertible {
    public enum Unit: String, CaseIterable, Sendable {
        case seconds, minutes, hours, days

        public var seconds: Int {
            switch self {
            case .seconds: return 1
            case .minutes: return 60
            case .hours: return 3_600
            case .days: return 86_400
            }
        }

        func name(_ amount: Int) -> String {
            amount == 1 ? String(rawValue.dropLast()) : rawValue
        }
    }

    public static let maximumAmount = 999_999

    public let amount: Int
    public let unit: Unit

    /// `amount` is kept between 1 and `maximumAmount`.
    public init(amount: Int, unit: Unit) {
        self.amount = min(max(amount, 1), Self.maximumAmount)
        self.unit = unit
    }

    public var seconds: Int { amount * unit.seconds }

    /// "10 seconds", "1 minute".
    public var description: String { "\(amount) \(unit.name(amount))" }

    /// The dates of `count` photos starting at `start`, `step` apart (all
    /// `start` when `step` is nil). Nil if the sequence leaves years 1 to
    /// 9999.
    public static func sequence(from start: ExifDateTime, step: DateStep?, count: Int) -> [ExifDateTime]? {
        guard count > 0 else { return [] }
        guard let step else { return Array(repeating: start, count: count) }
        var dates: [ExifDateTime] = []
        dates.reserveCapacity(count)
        for i in 0..<count {
            let (offset, overflow) = i.multipliedReportingOverflow(by: step.seconds)
            guard !overflow, let date = start.adding(seconds: offset) else { return nil }
            dates.append(date)
        }
        return dates
    }
}
