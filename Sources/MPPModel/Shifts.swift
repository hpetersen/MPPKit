// MPPKit: Microsoft Project (.mpp) files in Swift
// Copyright (C) 2026 Henrik Petersen
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License version 3 as
// published by the Free Software Foundation. It is distributed WITHOUT ANY
// WARRANTY; see the LICENSE file for details. https://mppstudio.com
//
// SPDX-License-Identifier: AGPL-3.0-only

#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

/// One of a calendar's up to three shifts: when it works, on which days.
///
/// Project has no shifts, only working ranges per weekday. A calendar's
/// shifts are the app's way of describing that week — Day, Evening, Night —
/// and `ProjectCalendar.applyShifts()` turns them into the ranges Project
/// reads. The shifts themselves are kept beside the file (see
/// `CalendarSetup`), so they come back as shifts rather than as ranges.
public struct Shift: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, CaseIterable, Comparable, Sendable {
        case day, evening, night

        public static func < (a: Kind, b: Kind) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }
    }

    public var kind: Kind
    public var isOn: Bool
    /// Minutes from midnight.
    public var start: Int
    /// Minutes from midnight. At or before `start`, the shift runs past
    /// midnight and ends the next morning.
    public var end: Int
    /// An unpaid break inside the shift, minutes from midnight.
    public var breakStart: Int?
    public var breakEnd: Int?
    /// The Foundation weekdays (`1` = Sunday) the shift *starts* on.
    public var weekdays: Set<Int>

    public var id: Kind { kind }

    public init(kind: Kind, isOn: Bool, start: Int, end: Int,
                breakStart: Int? = nil, breakEnd: Int? = nil, weekdays: Set<Int>) {
        self.kind = kind
        self.isOn = isOn
        self.start = start
        self.end = end
        self.breakStart = breakStart
        self.breakEnd = breakEnd
        self.weekdays = weekdays
    }

    /// Monday to Friday.
    public static let weekdaysMonFri: Set<Int> = [2, 3, 4, 5, 6]

    /// Project's own working day as a shift: 08:00–17:00 with lunch 12:00–13:00.
    public static let standardDay = Shift(kind: .day, isOn: true, start: 480, end: 1_020,
                                          breakStart: 720, breakEnd: 780, weekdays: weekdaysMonFri)

    /// Whether the shift runs past midnight.
    public var crossesMidnight: Bool { end <= start }

    /// The shift's end in minutes from the midnight it starts after: past
    /// 1440 for a shift that ends the next morning.
    private var endAbsolute: Int { crossesMidnight ? end + 1_440 : end }

    /// The break in the same terms as `endAbsolute`, when it lies inside the shift.
    private var breakAbsolute: ClosedRange<Int>? {
        guard var b = breakStart, var e = breakEnd else { return nil }
        if b < start { b += 1_440 }
        if e <= b { e += 1_440 }
        return (b > start && e < endAbsolute) ? b...e : nil
    }

    /// The break, when it lies inside the shift.
    public var breakRange: ClosedRange<Int>? {
        breakAbsolute.map { ($0.lowerBound % 1_440)...($0.upperBound % 1_440 == 0 ? 1_440 : $0.upperBound % 1_440) }
    }

    /// Working minutes in one occurrence of the shift, the break taken out.
    public var minutes: Int {
        endAbsolute - start - (breakAbsolute.map { $0.upperBound - $0.lowerBound } ?? 0)
    }

    /// The shift's working ranges, as (day offset from the day it starts,
    /// minutes) — offset 1 for the part of a night shift after midnight.
    public var segments: [(offset: Int, range: ClosedRange<Int>)] {
        var spans: [ClosedRange<Int>] = [start...endAbsolute]
        if let b = breakAbsolute {
            spans = [start...b.lowerBound, b.upperBound...endAbsolute]
        }
        var out: [(offset: Int, range: ClosedRange<Int>)] = []
        for span in spans where span.upperBound > span.lowerBound {
            if span.lowerBound < 1_440 {
                let hi = min(span.upperBound, 1_440)
                if hi > span.lowerBound { out.append((0, span.lowerBound...hi)) }
            }
            if span.upperBound > 1_440 {
                let lo = max(span.lowerBound, 1_440) - 1_440
                if span.upperBound - 1_440 > lo { out.append((1, lo...(span.upperBound - 1_440))) }
            }
        }
        return out
    }

    /// The default for a shift that is switched on for the first time, fitted
    /// around the shifts already there.
    public static func suggested(_ kind: Kind, after shifts: [Shift]) -> Shift {
        let day = shifts.first { $0.kind == .day } ?? standardDay
        let evening = shifts.first { $0.kind == .evening && $0.isOn }
        switch kind {
        case .day:
            return standardDay
        case .evening:
            let start = day.end
            return Shift(kind: .evening, isOn: true, start: start, end: min(start + 420, 1_380),
                         weekdays: day.weekdays)
        case .night:
            let start = evening?.end ?? 1_320
            return Shift(kind: .night, isOn: true, start: start % 1_440, end: day.start,
                         weekdays: day.weekdays)
        }
    }
}

/// What the app keeps about a calendar beyond what Project stores: its
/// shifts and the holiday sets it follows. Saved beside the file, keyed by
/// calendar name.
public struct CalendarSetup: Codable, Equatable, Sendable {
    public var shifts: [Shift]
    public var holidays: [HolidaySelection]

    public init(shifts: [Shift] = [], holidays: [HolidaySelection] = []) {
        self.shifts = shifts
        self.holidays = holidays
    }

    public var isEmpty: Bool { shifts.isEmpty && holidays.isEmpty }

    /// The whole document's setups, encoded for the file's own stream.
    public static func encode(_ setups: [String: CalendarSetup]) -> [UInt8]? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(setups)).map(Array.init)
    }

    public static func decode(_ bytes: [UInt8]) -> [String: CalendarSetup] {
        (try? JSONDecoder().decode([String: CalendarSetup].self, from: Data(bytes))) ?? [:]
    }
}

extension ProjectCalendar {
    /// The calendar's shifts, as set in the app, or worked out from its week
    /// when it has none: the working day becomes the Day shift, with its
    /// lunch break, and Evening and Night start off.
    public var effectiveShifts: [Shift] {
        var out: [Shift] = []
        let own = Dictionary(shifts.map { ($0.kind, $0) }, uniquingKeysWith: { a, _ in a })
        let inferred = inferredDayShift
        out.append(own[.day] ?? inferred)
        for kind in [Shift.Kind.evening, .night] {
            if let s = own[kind] { out.append(s) }
            else { var s = Shift.suggested(kind, after: out); s.isOn = false; out.append(s) }
        }
        return out
    }

    /// The Day shift that describes this calendar's week as Project stores it.
    var inferredDayShift: Shift {
        var counts: [[ClosedRange<Int>]: Int] = [:]
        var days: Set<Int> = []
        for weekday in 1...7 {
            let r = workingRanges(weekday: weekday)
            guard !r.isEmpty else { continue }
            days.insert(weekday)
            counts[r.sorted { $0.lowerBound < $1.lowerBound }, default: 0] += 1
        }
        guard let ranges = counts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key.count > $1.key.count) })?.key,
              let first = ranges.first, let last = ranges.last else {
            var s = Shift.standardDay
            s.weekdays = []
            return s
        }
        var s = Shift(kind: .day, isOn: true, start: first.lowerBound, end: last.upperBound % 1_440, weekdays: days)
        if ranges.count == 2 {
            s.breakStart = ranges[0].upperBound
            s.breakEnd = ranges[1].lowerBound
        }
        return s
    }

    /// The working ranges the shifts make, per Foundation weekday. A day may
    /// hold at most five ranges in Project; touching ranges are joined.
    public static func week(from shifts: [Shift]) -> [Int: [ClosedRange<Int>]?] {
        var byDay: [Int: [ClosedRange<Int>]] = [:]
        for shift in shifts where shift.isOn {
            for weekday in shift.weekdays {
                for part in shift.segments {
                    let day = (weekday - 1 + part.offset) % 7 + 1
                    byDay[day, default: []].append(part.range)
                }
            }
        }
        var week: [Int: [ClosedRange<Int>]?] = [:]
        for weekday in 1...7 {
            let merged = merge(byDay[weekday] ?? [])
            week[weekday] = merged.isEmpty ? .some(nil) : .some(Array(merged.prefix(5)))
        }
        return week
    }

    /// Sorted, with overlapping and touching ranges joined.
    static func merge(_ ranges: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, r.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// Weekdays whose shifts need more than the five working ranges a day
    /// can hold in Project; the extra ranges are dropped on save.
    public static func overfullDays(_ shifts: [Shift]) -> [Int] {
        var byDay: [Int: [ClosedRange<Int>]] = [:]
        for shift in shifts where shift.isOn {
            for weekday in shift.weekdays {
                for part in shift.segments {
                    byDay[(weekday - 1 + part.offset) % 7 + 1, default: []].append(part.range)
                }
            }
        }
        return byDay.filter { merge($0.value).count > 5 }.keys.sorted()
    }

    /// Pairs of shifts that overlap on some day.
    public static func overlaps(_ shifts: [Shift]) -> [(Shift.Kind, Shift.Kind)] {
        let on = shifts.filter(\.isOn)
        var out: [(Shift.Kind, Shift.Kind)] = []
        for i in on.indices {
            for j in on.indices where j > i {
                if overlap(on[i], on[j]) { out.append((on[i].kind, on[j].kind)) }
            }
        }
        return out
    }

    private static func overlap(_ a: Shift, _ b: Shift) -> Bool {
        func spans(_ s: Shift) -> [(Int, ClosedRange<Int>)] {
            s.weekdays.flatMap { w in s.segments.map { ((w - 1 + $0.offset) % 7, $0.range) } }
        }
        for (da, ra) in spans(a) {
            for (db, rb) in spans(b) where da == db {
                if ra.lowerBound < rb.upperBound && rb.lowerBound < ra.upperBound { return true }
            }
        }
        return false
    }

    /// Sets the working week from the shifts and keeps them.
    public mutating func setShifts(_ new: [Shift]) {
        shifts = new
        week = Self.week(from: new)
    }
}
