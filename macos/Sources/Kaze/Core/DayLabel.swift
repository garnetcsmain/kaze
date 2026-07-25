import Foundation

/// The `YYYY-MM-DD` local-day string used as the key for digests, questions and journal
/// filenames — and the string SQLite produces for
/// `date(createdAt, 'unixepoch', 'localtime')`.
///
/// Pinned to `en_US_POSIX` and the Gregorian calendar on purpose. A `DateFormatter` with a
/// fixed `dateFormat` but no locale still resolves its era and numerals through the user's
/// locale, so under a Japanese or Buddhist calendar the same instant formats with a
/// different year. SQLite has no such notion and always emits proleptic Gregorian, so any
/// code comparing a formatted label against a queried one would silently stop matching —
/// week backfill would report nothing to do, and digests would be regenerated forever.
enum DayLabel {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    static func date(from label: String) -> Date? {
        formatter.date(from: label)
    }

    static var today: String { string(from: Date()) }
}
