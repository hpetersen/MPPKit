// MPPKit: Microsoft Project (.mpp) files in Swift
// Copyright (C) 2026 Henrik Petersen
//
// Portions are ported from pymppwriter, Copyright (c) Kevin McAleer,
// under the MIT License; see THIRD_PARTY_NOTICES.md.
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

/// Working-time arithmetic over a `ProjectCalendar`, in wall-clock minutes.
///
/// This is what turns "3 days starting Friday 13:00" into a finish date, and
/// what rolls a summary task's duration up from its children. All dates are
/// wall-clock (see `MPPTime`), so the arithmetic is independent of the
/// device's time zone.
public struct WorkingTime: Sendable {
    /// Working ranges per Foundation weekday (`1` = Sunday), sorted.
    public let windows: [Int: [ClosedRange<Int>]]
    /// Days (since the MPP epoch) whose hours an exception sets; an empty
    /// list is a non-working day.
    public let exceptionDays: [Int: [ClosedRange<Int>]]
    /// Non-working day numbers from exceptions.
    public var nonWorkingDays: Set<Int> { Set(exceptionDays.filter { $0.value.isEmpty }.keys) }

    /// A safety bound on day-by-day scans: a calendar with no working time at
    /// all must not loop forever.
    private static let scanLimit = 36_600

    public init(calendar: ProjectCalendar?) {
        let cal = calendar ?? ProjectCalendar()
        var windows: [Int: [ClosedRange<Int>]] = [:]
        for weekday in 1...7 {
            let ranges = cal.workingRanges(weekday: weekday).sorted { $0.lowerBound < $1.lowerBound }
            if !ranges.isEmpty { windows[weekday] = ranges }
        }
        self.windows = windows
        var days: [Int: [ClosedRange<Int>]] = [:]
        for x in cal.exceptions {
            let first = MPPTime.dayNumber(x.start), last = MPPTime.dayNumber(x.lastDay)
            guard first <= last else { continue }
            let ranges = x.working.sorted { $0.lowerBound < $1.lowerBound }
            for d in first...last { days[d] = ranges }
        }
        self.exceptionDays = days
    }

    /// The working ranges of the wall-clock day containing `day`.
    public func ranges(on day: Date) -> [ClosedRange<Int>] {
        if let ranges = exceptionDays[MPPTime.dayNumber(day)] { return ranges }
        return windows[MPPTime.weekday(day)] ?? []
    }

    /// Working minutes in a normal week.
    public var minutesPerWeek: Int {
        windows.values.joined().reduce(0) { $0 + $1.upperBound - $1.lowerBound }
    }

    /// Working minutes between two instants.
    public func minutes(from start: Date, to finish: Date) -> Int {
        guard finish > start else { return 0 }
        var total = 0
        var day = MPPTime.startOfDay(start)
        let lastDay = MPPTime.startOfDay(finish)
        let startMinute = MPPTime.minuteOfDay(start), finishMinute = MPPTime.minuteOfDay(finish)
        var guardCount = 0
        while day <= lastDay, guardCount < Self.scanLimit {
            for r in ranges(on: day) {
                let lo = day == MPPTime.startOfDay(start) ? max(r.lowerBound, startMinute) : r.lowerBound
                let hi = day == lastDay ? min(r.upperBound, finishMinute) : r.upperBound
                if hi > lo { total += hi - lo }
            }
            day = MPPTime.adding(days: 1, to: day)
            guardCount += 1
        }
        return total
    }

    /// The instant reached after `minutes` of working time from `start`.
    /// The result may sit on the end of a working range.
    public func advance(_ start: Date, minutes: Int) -> Date {
        var remaining = max(0, minutes)
        var day = MPPTime.startOfDay(start)
        let startDay = day, startMinute = MPPTime.minuteOfDay(start)
        for _ in 0..<Self.scanLimit {
            for r in ranges(on: day) {
                let lo = day == startDay ? max(r.lowerBound, startMinute) : r.lowerBound
                guard r.upperBound > lo else { continue }
                if remaining <= r.upperBound - lo {
                    return day.addingTimeInterval(Double(lo + remaining) * 60)
                }
                remaining -= r.upperBound - lo
            }
            day = MPPTime.adding(days: 1, to: day)
        }
        return start
    }

    /// The instant `minutes` of working time before `finish`. The result may
    /// sit on the start of a working range.
    public func retreat(_ finish: Date, minutes: Int) -> Date {
        var remaining = max(0, minutes)
        var day = MPPTime.startOfDay(finish)
        let finishDay = day, finishMinute = MPPTime.minuteOfDay(finish)
        for _ in 0..<Self.scanLimit {
            for r in ranges(on: day).reversed() {
                let hi = day == finishDay ? min(r.upperBound, finishMinute) : r.upperBound
                guard hi > r.lowerBound else { continue }
                if remaining <= hi - r.lowerBound {
                    return day.addingTimeInterval(Double(hi - remaining) * 60)
                }
                remaining -= hi - r.lowerBound
            }
            day = MPPTime.adding(days: -1, to: day)
        }
        return finish
    }

    /// The first instant at or after `point` that work can start. The end of a
    /// range is not one: Project rolls 12:00 on to 13:00, and the end of the
    /// day on to the next morning.
    public func nextWorkingMoment(_ point: Date) -> Date {
        var day = MPPTime.startOfDay(point)
        let pointDay = day, pointMinute = MPPTime.minuteOfDay(point)
        for _ in 0..<Self.scanLimit {
            for r in ranges(on: day) {
                let lo = day == pointDay ? max(r.lowerBound, pointMinute) : r.lowerBound
                if lo < r.upperBound { return day.addingTimeInterval(Double(lo) * 60) }
            }
            day = MPPTime.adding(days: 1, to: day)
        }
        return point
    }

    /// The last working instant at or before `point` — the end of the most
    /// recent range that has finished by then.
    public func previousWorkingMoment(_ point: Date) -> Date? {
        var day = MPPTime.startOfDay(point)
        let pointDay = day, pointMinute = MPPTime.minuteOfDay(point)
        for _ in 0..<3_700 {
            let ends = ranges(on: day).map(\.upperBound).filter { day < pointDay || $0 <= pointMinute }
            if let m = ends.max() { return day.addingTimeInterval(Double(m) * 60) }
            day = MPPTime.adding(days: -1, to: day)
        }
        return nil
    }

    /// Whether `point` falls inside a working range (end points excluded).
    public func isWorking(_ point: Date) -> Bool {
        let minute = MPPTime.minuteOfDay(point)
        return ranges(on: point).contains { $0.lowerBound <= minute && minute < $0.upperBound }
    }
}
