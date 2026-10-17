// MPPKit: Microsoft Project (.mpp) files in Swift
// Copyright (C) 2026 Henrik Petersen
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 3 as published
// by the Free Software Foundation. It is distributed WITHOUT ANY WARRANTY;
// see the LICENSE file for details. https://mppstudio.com
//
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

// Public holidays by country, kept as rules rather than dates: one Christmas,
// one Easter. The dates are worked out for whichever years a plan covers and
// written into the calendar as ordinary exceptions, so Project reads them as
// it reads any other day off.

/// How a holiday's date is found in a given year.
public enum HolidayRule: Equatable, Sendable {
    /// The same date every year.
    case fixed(month: Int, day: Int)
    /// Days from Easter Sunday (Western).
    case easter(Int)
    /// The `n`th given weekday of a month; `n == -1` is the last.
    case nthWeekday(month: Int, weekday: Int, n: Int)
    /// The first given weekday on or after a date.
    case weekdayOnOrAfter(month: Int, day: Int, weekday: Int)
    /// The last given weekday on or before a date.
    case weekdayOnOrBefore(month: Int, day: Int, weekday: Int)
    /// Ireland's St Brigid's Day: 1 February if a Friday, else the first
    /// Monday in February.
    case brigid

    /// The rule in a few words, for the list.
    public var summary: String {
        let months = ["January", "February", "March", "April", "May", "June", "July",
                      "August", "September", "October", "November", "December"]
        let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let ordinals = [1: "1st", 2: "2nd", 3: "3rd", 4: "4th", -1: "Last"]
        switch self {
        case .fixed(let m, let d): return "\(d) \(months[m - 1])"
        case .easter(let o):
            switch o {
            case 0: return "Easter Sunday"
            case -3: return "Thursday before Easter"
            case -2: return "Friday before Easter"
            case 1: return "Monday after Easter"
            case 39: return "39 days after Easter"
            case 49: return "Whit Sunday"
            case 50: return "Whit Monday"
            default: return o > 0 ? "\(o) days after Easter" : "\(-o) days before Easter"
            }
        case .nthWeekday(let m, let w, let n): return "\(ordinals[n] ?? "\(n)th") \(days[w - 1]) of \(months[m - 1])"
        case .weekdayOnOrAfter(let m, let d, let w): return "\(days[w - 1]) from \(d) \(months[m - 1])"
        case .weekdayOnOrBefore(let m, let d, let w): return "\(days[w - 1]) on or before \(d) \(months[m - 1])"
        case .brigid: return "1st Monday of February, or 1 Feb if a Friday"
        }
    }

    /// Whether the date moves from year to year.
    public var moves: Bool {
        if case .fixed = self { return false }
        return true
    }

    func date(in year: Int) -> Date {
        switch self {
        case .fixed(let m, let d):
            return MPPTime.date(year, m, d)
        case .easter(let offset):
            return MPPTime.adding(days: offset, to: Self.easterSunday(year))
        case .nthWeekday(let m, let w, let n):
            if n > 0 {
                let first = MPPTime.date(year, m, 1)
                let shift = (w - MPPTime.weekday(first) + 7) % 7
                return MPPTime.adding(days: shift + 7 * (n - 1), to: first)
            }
            let next = m == 12 ? MPPTime.date(year + 1, 1, 1) : MPPTime.date(year, m + 1, 1)
            let last = MPPTime.adding(days: -1, to: next)
            return MPPTime.adding(days: -((MPPTime.weekday(last) - w + 7) % 7), to: last)
        case .weekdayOnOrAfter(let m, let d, let w):
            let from = MPPTime.date(year, m, d)
            return MPPTime.adding(days: (w - MPPTime.weekday(from) + 7) % 7, to: from)
        case .weekdayOnOrBefore(let m, let d, let w):
            let from = MPPTime.date(year, m, d)
            return MPPTime.adding(days: -((MPPTime.weekday(from) - w + 7) % 7), to: from)
        case .brigid:
            let feb1 = MPPTime.date(year, 2, 1)
            return MPPTime.weekday(feb1) == 6 ? feb1
                : HolidayRule.nthWeekday(month: 2, weekday: 2, n: 1).date(in: year)
        }
    }

    /// Western Easter Sunday (the anonymous Gregorian algorithm).
    static func easterSunday(_ year: Int) -> Date {
        let a = year % 19, b = year / 100, c = year % 100
        let d = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let month = (h + l - 7 * m + 114) / 31
        let day = (h + l - 7 * m + 114) % 31 + 1
        return MPPTime.date(year, month, day)
    }
}

/// What happens when a holiday falls on a weekend.
public enum HolidayObservance: Sendable {
    /// Nothing: the day is lost.
    case none
    /// Saturday is observed on Friday, Sunday on Monday (United States).
    case nearestWeekday
    /// The next weekday that is not already a holiday (the UK's substitute days).
    case substitute
    /// Sunday is observed on Monday.
    case sundayToMonday
    /// Sunday is observed on Saturday (the Netherlands' King's Day).
    case sundayToSaturday
}

/// One day off in a country's calendar.
public struct HolidayDay: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let localName: String
    public let rule: HolidayRule
    public let observance: HolidayObservance
    /// Off for customary days — Christmas Eve in Sweden, New Year's Eve in
    /// Denmark — that are widely but not officially taken.
    public let defaultOn: Bool

    init(_ id: String, _ name: String, _ localName: String = "", _ rule: HolidayRule,
         _ observance: HolidayObservance = .none, on: Bool = true) {
        self.id = id
        self.name = name
        self.localName = localName
        self.rule = rule
        self.observance = observance
        self.defaultOn = on
    }
}

/// A holiday as a person thinks of it — Christmas, Easter — made of one or
/// more days.
public struct Holiday: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let localName: String
    public let days: [HolidayDay]

    init(_ id: String, _ name: String, _ localName: String = "", _ days: [HolidayDay]) {
        self.id = id
        self.name = name
        self.localName = localName
        self.days = days
    }

    /// A holiday of a single day, named after it.
    init(_ day: HolidayDay) {
        self.init(day.id, day.name, day.localName, [day])
    }
}

/// A country's (or region's) public holidays.
public struct HolidayCountry: Sendable, Identifiable {
    /// `DK`, `GB-SCT`.
    public let id: String
    /// Two letters, for the badge and the exception names: `DK`, `GB`.
    public let code: String
    public let name: String
    public let region: String?
    public let note: String
    public let holidays: [Holiday]

    public var title: String { region.map { "\(name) · \($0)" } ?? name }
    public var days: [HolidayDay] { holidays.flatMap(\.days) }
}

/// Which of a country's holidays a calendar keeps, and how.
public struct HolidaySelection: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// A `HolidayCountry.id`.
    public var country: String
    /// Days turned off that are on by default.
    public var off: Set<String> = []
    /// Days turned on that are off by default.
    public var on: Set<String> = []
    /// Days that are short days rather than days off: the first half of the
    /// Day shift is worked.
    public var short: Set<String> = []
    /// Shifts that carry on through these holidays.
    public var keepsWorking: Set<Shift.Kind> = []

    public var id: String { country }

    public init(country: String) { self.country = country }

    public func isOn(_ day: HolidayDay) -> Bool {
        day.defaultOn ? !off.contains(day.id) : on.contains(day.id)
    }

    public mutating func set(_ day: HolidayDay, on value: Bool) {
        if day.defaultOn {
            if value { off.remove(day.id) } else { off.insert(day.id) }
        } else {
            if value { on.insert(day.id) } else { on.remove(day.id) }
        }
    }
}

// MARK: - Dates

extension HolidayCountry {
    /// Each day's observed date in `year`, in the catalog's order.
    public func dates(in year: Int) -> [(day: HolidayDay, date: Date)] {
        var taken = Set<Int>()
        var out: [(HolidayDay, Date)] = []
        // Fixed days first, in date order, so a substitute lands after them.
        let ordered = days.map { ($0, $0.rule.date(in: year)) }.sorted { $0.1 < $1.1 }
        for (day, actual) in ordered {
            var date = actual
            let weekday = MPPTime.weekday(actual)
            switch day.observance {
            case .none: break
            case .nearestWeekday:
                if weekday == 7 { date = MPPTime.adding(days: -1, to: actual) }
                if weekday == 1 { date = MPPTime.adding(days: 1, to: actual) }
            case .sundayToMonday:
                if weekday == 1 { date = MPPTime.adding(days: 1, to: actual) }
            case .sundayToSaturday:
                if weekday == 1 { date = MPPTime.adding(days: -1, to: actual) }
            case .substitute:
                while [1, 7].contains(MPPTime.weekday(date)) || taken.contains(MPPTime.dayNumber(date)) {
                    date = MPPTime.adding(days: 1, to: date)
                }
            }
            taken.insert(MPPTime.dayNumber(date))
            out.append((day, date))
        }
        let order = Dictionary(uniqueKeysWithValues: days.enumerated().map { ($1.id, $0) })
        return out.sorted { order[$0.0.id]! < order[$1.0.id]! }.map { (day: $0.0, date: $0.1) }
    }

    /// The holiday a day belongs to.
    public func holiday(of day: HolidayDay) -> Holiday? {
        holidays.first { $0.days.contains { $0.id == day.id } }
    }
}

extension ProjectCalendar {
    /// The years a plan running from `start` to `finish` touches, and the
    /// year after, so a finish that slips over New Year is already covered.
    public static func holidayYears(start: Date, finish: Date?) -> ClosedRange<Int> {
        let first = Int(MPPTime.iso(start).prefix(4)) ?? 2026
        let last = Int(MPPTime.iso(finish ?? start).prefix(4)) ?? first
        return first...(max(first, last) + 1)
    }

    /// Whether an exception was made from a holiday set: named
    /// "Christmas (DK)" or "Easter (DK, GB)".
    public static func isHolidayException(_ x: CalendarException) -> Bool {
        guard x.name.hasSuffix(")"), let open = x.name.lastIndex(of: "(") else { return false }
        let codes = x.name[x.name.index(after: open)..<x.name.index(before: x.name.endIndex)]
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let known = Set(HolidayCatalog.all.map(\.code))
        guard !codes.isEmpty, codes.allSatisfy(known.contains) else { return false }
        let title = x.name[..<open].trimmingCharacters(in: .whitespaces)
        let names = Set(HolidayCatalog.all.flatMap { $0.holidays.map(\.name) })
        return title.split(separator: "/").allSatisfy { names.contains($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// The calendar's own exceptions: the ones not made from a holiday set.
    public var ownExceptions: [CalendarException] {
        exceptions.filter { !Self.isHolidayException($0) }
    }

    /// The exceptions the calendar's holiday sets make for `years`. A day
    /// already covered by one of the calendar's own exceptions is left to it;
    /// a day two sets share becomes one exception naming both.
    public func holidayExceptions(years: ClosedRange<Int>) -> [CalendarException] {
        let own = Set(ownExceptions.flatMap { x in
            (MPPTime.dayNumber(x.start)...max(MPPTime.dayNumber(x.start), MPPTime.dayNumber(x.lastDay))).map { $0 }
        })
        let shifts = effectiveShifts
        let day = shifts.first { $0.kind == .day }

        struct Entry { var names: [String]; var codes: [String]; var working: [ClosedRange<Int>]; var off: Bool }
        var byDay: [Int: Entry] = [:]
        for selection in holidays {
            guard let country = HolidayCatalog.country(selection.country) else { continue }
            for year in years {
                for (hday, date) in country.dates(in: year) where selection.isOn(hday) {
                    let n = MPPTime.dayNumber(date)
                    guard !own.contains(n) else { continue }
                    let weekday = MPPTime.weekday(date)
                    // What is still worked: shifts that carry on, and the
                    // first half of the Day shift on a short day.
                    var working: [ClosedRange<Int>] = []
                    for shift in shifts where shift.isOn && selection.keepsWorking.contains(shift.kind) {
                        working += Self.ranges(of: shift, on: weekday)
                    }
                    if selection.short.contains(hday.id), let day, day.isOn, day.weekdays.contains(weekday) {
                        let ranges = Self.ranges(of: day, on: weekday)
                        if let first = ranges.first {
                            let half = first.lowerBound + day.minutes / 2
                            working += ranges.compactMap { r in
                                r.lowerBound < half ? r.lowerBound...min(r.upperBound, half) : nil
                            }
                        }
                    }
                    let name = country.holiday(of: hday)?.name ?? hday.name
                    var e = byDay[n] ?? Entry(names: [], codes: [], working: working, off: working.isEmpty)
                    if !e.names.contains(name) { e.names.append(name) }
                    if !e.codes.contains(country.code) { e.codes.append(country.code) }
                    // Two sets on one day: the stricter wins.
                    if working.isEmpty { e.off = true; e.working = [] }
                    else if !e.off { e.working = Self.merge(e.working.filter { w in working.contains { $0.overlaps(w) } }) }
                    byDay[n] = e
                }
            }
        }

        // Consecutive days of the same holiday become one exception.
        var out: [CalendarException] = []
        for n in byDay.keys.sorted() {
            let e = byDay[n]!
            let name = "\(e.names.joined(separator: " / ")) (\(e.codes.joined(separator: ", ")))"
            let date = MPPTime.date(days: n, tenths: 0)
            if var last = out.last, last.name == name, last.working == e.working,
               MPPTime.dayNumber(last.lastDay) == n - 1 {
                last.finish = date
                out[out.count - 1] = last
            } else {
                out.append(CalendarException(start: date, name: name, working: e.working))
            }
        }
        return out
    }

    /// A shift's ranges on one weekday, including the morning end of a night
    /// shift that started the day before.
    static func ranges(of shift: Shift, on weekday: Int) -> [ClosedRange<Int>] {
        shift.weekdays.flatMap { start in
            shift.segments.filter { (start - 1 + $0.offset) % 7 + 1 == weekday }.map(\.range)
        }
    }

    /// Replaces the holiday exceptions with fresh ones for `years`, leaving
    /// the calendar's own exceptions alone.
    public mutating func syncHolidays(years: ClosedRange<Int>) {
        let generated = holidayExceptions(years: years)
        exceptions = ownExceptions + generated
    }
}

extension Project {
    /// Every base calendar's holiday exceptions, made again for the years the
    /// plan now covers.
    public mutating func syncHolidays() {
        let end = tasks.compactMap(\.finish).max() ?? finish
        let years = ProjectCalendar.holidayYears(start: start, finish: end)
        if calendar?.holidays.isEmpty == false || calendar?.exceptions.contains(where: ProjectCalendar.isHolidayException) == true {
            calendar?.syncHolidays(years: years)
        }
        for i in calendars.indices
        where !calendars[i].holidays.isEmpty || calendars[i].exceptions.contains(where: ProjectCalendar.isHolidayException) {
            calendars[i].syncHolidays(years: years)
        }
    }
}

// MARK: - Catalog

/// The countries and regions whose public holidays can be added to a calendar.
public enum HolidayCatalog {
    public static func country(_ id: String) -> HolidayCountry? { all.first { $0.id == id } }

    private typealias D = HolidayDay
    private typealias H = Holiday

    public static let all: [HolidayCountry] = [
        HolidayCountry(id: "DK", code: "DK", name: "Denmark", region: nil,
                       note: "Public holidays (helligdage), with the customary Christmas Eve and New Year’s Eve.",
                       holidays: [
            H("dk-newyear", "New Year", "Nytår", [
                D("dk-nye", "New Year’s Eve", "Nytårsaftensdag", .fixed(month: 12, day: 31), on: false),
                D("dk-nyd", "New Year’s Day", "Nytårsdag", .fixed(month: 1, day: 1)),
            ]),
            H("dk-easter", "Easter", "Påske", [
                D("dk-maundy", "Maundy Thursday", "Skærtorsdag", .easter(-3)),
                D("dk-goodfri", "Good Friday", "Langfredag", .easter(-2)),
                D("dk-eastersun", "Easter Sunday", "Påskedag", .easter(0)),
                D("dk-eastermon", "Easter Monday", "2. påskedag", .easter(1)),
            ]),
            H(D("dk-ascension", "Ascension Day", "Kristi himmelfartsdag", .easter(39))),
            H("dk-whitsun", "Whitsun", "Pinse", [
                D("dk-whitsun-sun", "Whit Sunday", "Pinsedag", .easter(49)),
                D("dk-whitsun-mon", "Whit Monday", "2. pinsedag", .easter(50)),
            ]),
            H(D("dk-constitution", "Constitution Day", "Grundlovsdag", .fixed(month: 6, day: 5), on: false)),
            H("dk-christmas", "Christmas", "Jul", [
                D("dk-xmaseve", "Christmas Eve", "Juleaftensdag", .fixed(month: 12, day: 24)),
                D("dk-xmas", "Christmas Day", "Juledag", .fixed(month: 12, day: 25)),
                D("dk-boxing", "Boxing Day", "2. juledag", .fixed(month: 12, day: 26)),
            ]),
        ]),
        HolidayCountry(id: "GB-ENG", code: "GB", name: "United Kingdom", region: "England and Wales",
                       note: "Bank holidays. One that falls on a weekend moves to the next weekday.",
                       holidays: [
            H(D("gb-nyd", "New Year’s Day", "", .fixed(month: 1, day: 1), .substitute)),
            H("gb-easter", "Easter", "", [
                D("gb-goodfri", "Good Friday", "", .easter(-2)),
                D("gb-eastermon", "Easter Monday", "", .easter(1)),
            ]),
            H(D("gb-earlymay", "Early May bank holiday", "", .nthWeekday(month: 5, weekday: 2, n: 1))),
            H(D("gb-spring", "Spring bank holiday", "", .nthWeekday(month: 5, weekday: 2, n: -1))),
            H(D("gb-summer", "Summer bank holiday", "", .nthWeekday(month: 8, weekday: 2, n: -1))),
            H("gb-christmas", "Christmas", "", [
                D("gb-xmas", "Christmas Day", "", .fixed(month: 12, day: 25), .substitute),
                D("gb-boxing", "Boxing Day", "", .fixed(month: 12, day: 26), .substitute),
            ]),
        ]),
        HolidayCountry(id: "GB-SCT", code: "GB", name: "United Kingdom", region: "Scotland",
                       note: "Bank holidays. One that falls on a weekend moves to the next weekday.",
                       holidays: [
            H("sc-newyear", "New Year", "", [
                D("sc-nyd", "New Year’s Day", "", .fixed(month: 1, day: 1), .substitute),
                D("sc-jan2", "2 January", "", .fixed(month: 1, day: 2), .substitute),
            ]),
            H(D("sc-goodfri", "Good Friday", "", .easter(-2))),
            H(D("sc-earlymay", "Early May bank holiday", "", .nthWeekday(month: 5, weekday: 2, n: 1))),
            H(D("sc-spring", "Spring bank holiday", "", .nthWeekday(month: 5, weekday: 2, n: -1))),
            H(D("sc-summer", "Summer bank holiday", "", .nthWeekday(month: 8, weekday: 2, n: 1))),
            H(D("sc-andrew", "St Andrew’s Day", "", .fixed(month: 11, day: 30), .substitute)),
            H("sc-christmas", "Christmas", "", [
                D("sc-xmas", "Christmas Day", "", .fixed(month: 12, day: 25), .substitute),
                D("sc-boxing", "Boxing Day", "", .fixed(month: 12, day: 26), .substitute),
            ]),
        ]),
        HolidayCountry(id: "GB-NIR", code: "GB", name: "United Kingdom", region: "Northern Ireland",
                       note: "Bank holidays. One that falls on a weekend moves to the next weekday.",
                       holidays: [
            H(D("ni-nyd", "New Year’s Day", "", .fixed(month: 1, day: 1), .substitute)),
            H(D("ni-patrick", "St Patrick’s Day", "", .fixed(month: 3, day: 17), .substitute)),
            H("ni-easter", "Easter", "", [
                D("ni-goodfri", "Good Friday", "", .easter(-2)),
                D("ni-eastermon", "Easter Monday", "", .easter(1)),
            ]),
            H(D("ni-earlymay", "Early May bank holiday", "", .nthWeekday(month: 5, weekday: 2, n: 1))),
            H(D("ni-spring", "Spring bank holiday", "", .nthWeekday(month: 5, weekday: 2, n: -1))),
            H(D("ni-boyne", "Battle of the Boyne", "", .fixed(month: 7, day: 12), .substitute)),
            H(D("ni-summer", "Summer bank holiday", "", .nthWeekday(month: 8, weekday: 2, n: -1))),
            H("ni-christmas", "Christmas", "", [
                D("ni-xmas", "Christmas Day", "", .fixed(month: 12, day: 25), .substitute),
                D("ni-boxing", "Boxing Day", "", .fixed(month: 12, day: 26), .substitute),
            ]),
        ]),
        HolidayCountry(id: "IE", code: "IE", name: "Ireland", region: nil,
                       note: "Public holidays.",
                       holidays: [
            H(D("ie-nyd", "New Year’s Day", "Lá Caille", .fixed(month: 1, day: 1))),
            H(D("ie-brigid", "St Brigid’s Day", "Lá Fhéile Bríde", .brigid)),
            H(D("ie-patrick", "St Patrick’s Day", "Lá Fhéile Pádraig", .fixed(month: 3, day: 17))),
            H(D("ie-eastermon", "Easter Monday", "Luan Cásca", .easter(1))),
            H(D("ie-may", "May bank holiday", "", .nthWeekday(month: 5, weekday: 2, n: 1))),
            H(D("ie-june", "June bank holiday", "", .nthWeekday(month: 6, weekday: 2, n: 1))),
            H(D("ie-august", "August bank holiday", "", .nthWeekday(month: 8, weekday: 2, n: 1))),
            H(D("ie-october", "October bank holiday", "", .nthWeekday(month: 10, weekday: 2, n: -1))),
            H("ie-christmas", "Christmas", "Nollaig", [
                D("ie-xmas", "Christmas Day", "Lá Nollag", .fixed(month: 12, day: 25)),
                D("ie-stephen", "St Stephen’s Day", "Lá Fhéile Stiofáin", .fixed(month: 12, day: 26)),
            ]),
        ]),
        HolidayCountry(id: "US", code: "US", name: "United States", region: "Federal",
                       note: "Federal holidays. One on a Saturday is observed on Friday, on a Sunday on Monday.",
                       holidays: [
            H(D("us-nyd", "New Year’s Day", "", .fixed(month: 1, day: 1), .nearestWeekday)),
            H(D("us-mlk", "Martin Luther King Jr. Day", "", .nthWeekday(month: 1, weekday: 2, n: 3))),
            H(D("us-washington", "Washington’s Birthday", "", .nthWeekday(month: 2, weekday: 2, n: 3))),
            H(D("us-memorial", "Memorial Day", "", .nthWeekday(month: 5, weekday: 2, n: -1))),
            H(D("us-juneteenth", "Juneteenth", "", .fixed(month: 6, day: 19), .nearestWeekday)),
            H(D("us-independence", "Independence Day", "", .fixed(month: 7, day: 4), .nearestWeekday)),
            H(D("us-labor", "Labor Day", "", .nthWeekday(month: 9, weekday: 2, n: 1))),
            H(D("us-columbus", "Columbus Day", "", .nthWeekday(month: 10, weekday: 2, n: 2))),
            H(D("us-veterans", "Veterans Day", "", .fixed(month: 11, day: 11), .nearestWeekday)),
            H(D("us-thanksgiving", "Thanksgiving Day", "", .nthWeekday(month: 11, weekday: 5, n: 4))),
            H(D("us-xmas", "Christmas Day", "", .fixed(month: 12, day: 25), .nearestWeekday)),
        ]),
        HolidayCountry(id: "CA", code: "CA", name: "Canada", region: "Federal",
                       note: "Federal statutory holidays. Provinces add their own.",
                       holidays: [
            H(D("ca-nyd", "New Year’s Day", "Jour de l’An", .fixed(month: 1, day: 1), .sundayToMonday)),
            H("ca-easter", "Easter", "Pâques", [
                D("ca-goodfri", "Good Friday", "Vendredi saint", .easter(-2)),
                D("ca-eastermon", "Easter Monday", "Lundi de Pâques", .easter(1)),
            ]),
            H(D("ca-victoria", "Victoria Day", "Fête de la Reine", .weekdayOnOrBefore(month: 5, day: 24, weekday: 2))),
            H(D("ca-canada", "Canada Day", "Fête du Canada", .fixed(month: 7, day: 1), .sundayToMonday)),
            H(D("ca-labour", "Labour Day", "Fête du Travail", .nthWeekday(month: 9, weekday: 2, n: 1))),
            H(D("ca-truth", "National Day for Truth and Reconciliation", "", .fixed(month: 9, day: 30))),
            H(D("ca-thanksgiving", "Thanksgiving", "Action de grâce", .nthWeekday(month: 10, weekday: 2, n: 2))),
            H(D("ca-remembrance", "Remembrance Day", "Jour du Souvenir", .fixed(month: 11, day: 11))),
            H("ca-christmas", "Christmas", "Noël", [
                D("ca-xmas", "Christmas Day", "Noël", .fixed(month: 12, day: 25), .substitute),
                D("ca-boxing", "Boxing Day", "Lendemain de Noël", .fixed(month: 12, day: 26), .substitute),
            ]),
        ]),
        HolidayCountry(id: "DE", code: "DE", name: "Germany", region: "Nationwide",
                       note: "The nine holidays every state keeps. States add their own.",
                       holidays: [
            H(D("de-nyd", "New Year’s Day", "Neujahr", .fixed(month: 1, day: 1))),
            H("de-easter", "Easter", "Ostern", [
                D("de-goodfri", "Good Friday", "Karfreitag", .easter(-2)),
                D("de-eastermon", "Easter Monday", "Ostermontag", .easter(1)),
            ]),
            H(D("de-labour", "Labour Day", "Tag der Arbeit", .fixed(month: 5, day: 1))),
            H(D("de-ascension", "Ascension Day", "Christi Himmelfahrt", .easter(39))),
            H(D("de-whitmon", "Whit Monday", "Pfingstmontag", .easter(50))),
            H(D("de-unity", "German Unity Day", "Tag der Deutschen Einheit", .fixed(month: 10, day: 3))),
            H("de-christmas", "Christmas", "Weihnachten", [
                D("de-xmas", "Christmas Day", "1. Weihnachtstag", .fixed(month: 12, day: 25)),
                D("de-boxing", "St Stephen’s Day", "2. Weihnachtstag", .fixed(month: 12, day: 26)),
            ]),
        ]),
        HolidayCountry(id: "SE", code: "SE", name: "Sweden", region: nil,
                       note: "Public holidays (helgdagar), with the eves most workplaces take off.",
                       holidays: [
            H(D("se-nyd", "New Year’s Day", "Nyårsdagen", .fixed(month: 1, day: 1))),
            H(D("se-epiphany", "Epiphany", "Trettondedag jul", .fixed(month: 1, day: 6))),
            H("se-easter", "Easter", "Påsk", [
                D("se-goodfri", "Good Friday", "Långfredagen", .easter(-2)),
                D("se-eastersun", "Easter Sunday", "Påskdagen", .easter(0)),
                D("se-eastermon", "Easter Monday", "Annandag påsk", .easter(1)),
            ]),
            H(D("se-may", "May Day", "Första maj", .fixed(month: 5, day: 1))),
            H(D("se-ascension", "Ascension Day", "Kristi himmelsfärdsdag", .easter(39))),
            H(D("se-national", "National Day", "Sveriges nationaldag", .fixed(month: 6, day: 6))),
            H(D("se-whitsun", "Whit Sunday", "Pingstdagen", .easter(49))),
            H("se-midsummer", "Midsummer", "Midsommar", [
                D("se-midsummer-eve", "Midsummer Eve", "Midsommarafton", .weekdayOnOrAfter(month: 6, day: 19, weekday: 6)),
                D("se-midsummer-day", "Midsummer Day", "Midsommardagen", .weekdayOnOrAfter(month: 6, day: 20, weekday: 7)),
            ]),
            H(D("se-allsaints", "All Saints’ Day", "Alla helgons dag", .weekdayOnOrAfter(month: 10, day: 31, weekday: 7))),
            H("se-christmas", "Christmas", "Jul", [
                D("se-xmaseve", "Christmas Eve", "Julafton", .fixed(month: 12, day: 24)),
                D("se-xmas", "Christmas Day", "Juldagen", .fixed(month: 12, day: 25)),
                D("se-boxing", "Boxing Day", "Annandag jul", .fixed(month: 12, day: 26)),
            ]),
            H(D("se-nye", "New Year’s Eve", "Nyårsafton", .fixed(month: 12, day: 31))),
        ]),
        HolidayCountry(id: "NO", code: "NO", name: "Norway", region: nil,
                       note: "Public holidays (helligdager).",
                       holidays: [
            H(D("no-nyd", "New Year’s Day", "Nyttårsdag", .fixed(month: 1, day: 1))),
            H("no-easter", "Easter", "Påske", [
                D("no-maundy", "Maundy Thursday", "Skjærtorsdag", .easter(-3)),
                D("no-goodfri", "Good Friday", "Langfredag", .easter(-2)),
                D("no-eastersun", "Easter Sunday", "Påskedag", .easter(0)),
                D("no-eastermon", "Easter Monday", "2. påskedag", .easter(1)),
            ]),
            H(D("no-labour", "Labour Day", "Arbeidernes dag", .fixed(month: 5, day: 1))),
            H(D("no-constitution", "Constitution Day", "Grunnlovsdag", .fixed(month: 5, day: 17))),
            H(D("no-ascension", "Ascension Day", "Kristi himmelfartsdag", .easter(39))),
            H("no-whitsun", "Whitsun", "Pinse", [
                D("no-whitsun-sun", "Whit Sunday", "Pinsedag", .easter(49)),
                D("no-whitsun-mon", "Whit Monday", "2. pinsedag", .easter(50)),
            ]),
            H("no-christmas", "Christmas", "Jul", [
                D("no-xmas", "Christmas Day", "Juledag", .fixed(month: 12, day: 25)),
                D("no-boxing", "Boxing Day", "2. juledag", .fixed(month: 12, day: 26)),
            ]),
        ]),
        HolidayCountry(id: "NL", code: "NL", name: "Netherlands", region: nil,
                       note: "Public holidays. Good Friday and Liberation Day are off only where agreed.",
                       holidays: [
            H(D("nl-nyd", "New Year’s Day", "Nieuwjaarsdag", .fixed(month: 1, day: 1))),
            H("nl-easter", "Easter", "Pasen", [
                D("nl-goodfri", "Good Friday", "Goede Vrijdag", .easter(-2), on: false),
                D("nl-eastersun", "Easter Sunday", "Eerste Paasdag", .easter(0)),
                D("nl-eastermon", "Easter Monday", "Tweede Paasdag", .easter(1)),
            ]),
            H(D("nl-king", "King’s Day", "Koningsdag", .fixed(month: 4, day: 27), .sundayToSaturday)),
            H(D("nl-liberation", "Liberation Day", "Bevrijdingsdag", .fixed(month: 5, day: 5), on: false)),
            H(D("nl-ascension", "Ascension Day", "Hemelvaartsdag", .easter(39))),
            H("nl-whitsun", "Whitsun", "Pinksteren", [
                D("nl-whitsun-sun", "Whit Sunday", "Eerste Pinksterdag", .easter(49)),
                D("nl-whitsun-mon", "Whit Monday", "Tweede Pinksterdag", .easter(50)),
            ]),
            H("nl-christmas", "Christmas", "Kerstmis", [
                D("nl-xmas", "Christmas Day", "Eerste Kerstdag", .fixed(month: 12, day: 25)),
                D("nl-boxing", "Boxing Day", "Tweede Kerstdag", .fixed(month: 12, day: 26)),
            ]),
        ]),
        HolidayCountry(id: "FR", code: "FR", name: "France", region: nil,
                       note: "Public holidays (jours fériés) in metropolitan France.",
                       holidays: [
            H(D("fr-nyd", "New Year’s Day", "Jour de l’an", .fixed(month: 1, day: 1))),
            H(D("fr-eastermon", "Easter Monday", "Lundi de Pâques", .easter(1))),
            H(D("fr-labour", "Labour Day", "Fête du Travail", .fixed(month: 5, day: 1))),
            H(D("fr-victory", "Victory in Europe Day", "Victoire 1945", .fixed(month: 5, day: 8))),
            H(D("fr-ascension", "Ascension Day", "Ascension", .easter(39))),
            H(D("fr-whitmon", "Whit Monday", "Lundi de Pentecôte", .easter(50))),
            H(D("fr-bastille", "Bastille Day", "Fête nationale", .fixed(month: 7, day: 14))),
            H(D("fr-assumption", "Assumption Day", "Assomption", .fixed(month: 8, day: 15))),
            H(D("fr-allsaints", "All Saints’ Day", "Toussaint", .fixed(month: 11, day: 1))),
            H(D("fr-armistice", "Armistice Day", "Armistice", .fixed(month: 11, day: 11))),
            H(D("fr-xmas", "Christmas Day", "Noël", .fixed(month: 12, day: 25))),
        ]),
        HolidayCountry(id: "ES", code: "ES", name: "Spain", region: "National",
                       note: "The national holidays. Regions and towns add their own.",
                       holidays: [
            H(D("es-nyd", "New Year’s Day", "Año Nuevo", .fixed(month: 1, day: 1))),
            H(D("es-epiphany", "Epiphany", "Epifanía del Señor", .fixed(month: 1, day: 6))),
            H(D("es-goodfri", "Good Friday", "Viernes Santo", .easter(-2))),
            H(D("es-labour", "Labour Day", "Fiesta del Trabajo", .fixed(month: 5, day: 1))),
            H(D("es-assumption", "Assumption Day", "Asunción de la Virgen", .fixed(month: 8, day: 15))),
            H(D("es-national", "National Day", "Fiesta Nacional de España", .fixed(month: 10, day: 12))),
            H(D("es-allsaints", "All Saints’ Day", "Todos los Santos", .fixed(month: 11, day: 1))),
            H(D("es-constitution", "Constitution Day", "Día de la Constitución", .fixed(month: 12, day: 6))),
            H(D("es-immaculate", "Immaculate Conception", "Inmaculada Concepción", .fixed(month: 12, day: 8))),
            H(D("es-xmas", "Christmas Day", "Navidad", .fixed(month: 12, day: 25))),
        ]),
    ]
}
