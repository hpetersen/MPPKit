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

/// Wall-clock date arithmetic for the MPP format.
///
/// `.mpp` stores dates as a day count plus tenths of a minute with **no
/// timezone**: a 07:00 project start means 07:00 wherever the file is opened.
/// Foundation's `Date` is an absolute instant, so every conversion here goes
/// through a UTC calendar, which makes the wall-clock value round-trip exactly
/// and keeps comparisons stable regardless of the device's locale.
public enum MPPTime {
    /// The MPP day zero: 1983-12-31 00:00 wall-clock.
    public static let epoch: Date = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal.date(from: DateComponents(year: 1983, month: 12, day: 31))!
    }()

    private static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    /// Build a wall-clock date from the wire representation.
    /// - Parameters:
    ///   - days: days since 1983-12-31
    ///   - tenths: tenths of a minute since midnight
    public static func date(days: Int, tenths: Int) -> Date {
        epoch.addingTimeInterval(Double(days) * 86_400 + Double(tenths) * 6)
    }

    /// The wire representation of a wall-clock date.
    public static func wire(from date: Date) -> (days: Int, tenths: Int) {
        let delta = date.timeIntervalSince(epoch)
        let whole = delta.rounded(.down)
        let days = Int(whole / 86_400)
        let secondsIntoDay = whole - Double(days) * 86_400
        return (days, Int(secondsIntoDay / 6))
    }

    // Wall-clock dates are UTC instants with no daylight saving, so a day is
    // always 86 400 seconds: start of day, weekday and minute of day are
    // arithmetic. They used to go through `Calendar`, and the working-time
    // maths calls them for every day it steps over.

    /// Whole days since 2001-01-01 (a Monday), the reference date.
    @inline(__always) static func dayIndex(_ date: Date) -> Int {
        Int((date.timeIntervalSinceReferenceDate / 86_400).rounded(.down))
    }

    /// Midnight on the day containing `date`, in wall-clock terms.
    public static func startOfDay(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: Double(dayIndex(date)) * 86_400)
    }

    /// A wall-clock date from its components, e.g. `MPPTime.date(2026, 3, 2, 8)`.
    public static func date(_ year: Int, _ month: Int, _ day: Int,
                            _ hour: Int = 0, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day,
                                      hour: hour, minute: minute))!
    }

    /// Minutes since wall-clock midnight.
    public static func minuteOfDay(_ date: Date) -> Int {
        let t = date.timeIntervalSinceReferenceDate
        return Int(((t - Double(dayIndex(date)) * 86_400) / 60).rounded(.down))
    }

    /// Foundation weekday of the wall-clock date: `1` = Sunday ... `7` = Saturday.
    public static func weekday(_ date: Date) -> Int {
        // Day index 0 is a Monday, Foundation's weekday 2.
        ((dayIndex(date) % 7 + 7) % 7 + 1) % 7 + 1
    }

    /// Whole days since the MPP epoch — the day number calendar exceptions use.
    public static func dayNumber(_ date: Date) -> Int {
        dayIndex(date) - epochIndex
    }
    private static let epochIndex = dayIndex(epoch)

    /// `date` moved by whole wall-clock days.
    public static func adding(days: Int, to date: Date) -> Date {
        date.addingTimeInterval(Double(days) * 86_400)
    }

    /// `yyyy-MM-dd` in wall-clock terms — the format Project itself displays.
    public static func iso(_ date: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// `yyyy-MM-dd HH:mm` in wall-clock terms.
    public static func isoMinute(_ date: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }
}


// MARK: - Project model

/// One saved snapshot of a task's schedule. Slot 0 is `Baseline`, 1...10 are
/// `Baseline1`...`Baseline10`; 11 and up are the app's own (`ExtraBaselines`).
public struct Baseline: Equatable, Sendable {
    public var start: Date?
    public var finish: Date?
    public var durationDays: Double = 0
    public var workHours: Double = 0
    /// In the file's own cost units; the scale is not established.
    public var cost: Double = 0

    public init(start: Date? = nil, finish: Date? = nil, durationDays: Double = 0,
                workHours: Double = 0, cost: Double = 0) {
        self.start = start
        self.finish = finish
        self.durationDays = durationDays
        self.workHours = workHours
        self.cost = cost
    }
}

/// How a task's duration, work and units relate when one of them changes.
public enum TaskType: String, CaseIterable, Sendable {
    case fixedUnits = "fixed_units"
    case fixedDuration = "fixed_duration"
    case fixedWork = "fixed_work"
}

/// Scheduling constraints, in the order Project numbers them.
public enum ConstraintType: String, CaseIterable, Sendable {
    /// As Soon As Possible — the default, so it is never stored on a `Task`.
    case asSoonAsPossible = "ASAP"
    case asLateAsPossible = "ALAP"
    case mustStartOn = "MSO"
    case mustFinishOn = "MFO"
    case startNoEarlierThan = "SNET"
    case startNoLaterThan = "SNLT"
    case finishNoEarlierThan = "FNET"
    case finishNoLaterThan = "FNLT"
}

/// Dependency types.
public enum RelationType: String, CaseIterable, Sendable {
    case finishToFinish = "FF"
    case finishToStart = "FS"
    case startToFinish = "SF"
    case startToStart = "SS"
}

public struct ProjectTask: Identifiable, Equatable, Sendable {
    public var uid: Int
    /// Project's `ID` column: the row number, assigned in outline order.
    public var rowID: Int = 0
    public var name: String
    public var start: Date?
    public var finish: Date?
    /// In project days (`Project.minutesPerDay`). Ignored by the writer for
    /// summary tasks, whose duration rolls up from their children.
    public var durationDays: Double = 1
    public var outlineLevel: Int = 1
    /// 0 means the project summary task.
    public var parentUID: Int = 0
    /// Display units: `m`, `h`, `d`, `w`, `mo`, or the elapsed `em`, `eh`,
    /// `ed`, `ew`, `emo`. An elapsed duration is wall-clock time, round the
    /// clock; `durationDays` then holds its minutes divided by
    /// `Project.minutesPerDay`, as the file stores it.
    public var durationUnits: String = "d"

    /// Duration counted in wall-clock time rather than working time.
    public var isElapsed: Bool { durationUnits.hasPrefix("e") }
    /// Shows the duration with a trailing `?`.
    public var estimated: Bool = false
    /// Read from the file. The writer derives it from the outline instead.
    public var summary: Bool = false
    /// Zero-duration tasks are always milestones; set this to flag a task with
    /// a duration as a milestone too.
    public var milestone: Bool = false
    /// The name of the task's own calendar, if it has one.
    public var calendar: String?
    public var notes: String = ""
    /// A custom WBS code; `nil` lets Project derive outline numbers.
    public var wbs: String?
    /// `ASAP`, `ALAP`, `MSO`, `MFO`, `SNET`, `SNLT`, `FNET` or `FNLT`; `nil` is ASAP.
    public var constraint: String?
    public var constraintDate: Date?
    public var deadline: Date?
    public var percentComplete: Int = 0
    public var actualStart: Date?
    public var actualFinish: Date?
    /// The latest dates the task can have without delaying the project, from
    /// `Scheduler`'s backward pass (or the file). Equal to start and finish on
    /// the critical path.
    public var lateStart: Date?
    public var lateFinish: Date?
    /// Total work, in hours.
    public var workHours: Double = 0
    /// 0...1000, where 500 is normal.
    public var priority: Int = 500
    /// `fixed_units`, `fixed_duration` or `fixed_work`.
    public var taskType: String = "fixed_units"
    public var effortDriven: Bool = false
    /// Manually scheduled rather than calculated by Project.
    public var manual: Bool = false
    /// Working minutes inside the task where no work happens: a task split in
    /// Project spans longer than its duration. Taken from the saved dates when
    /// the file is read, and kept by the scheduler so the task's span stays
    /// what Project showed. (Where in the span the gaps fall is not modelled.)
    public var splitMinutes: Int = 0
    public var created: Date?
    /// Text1...Text30, keyed by field number.
    public var text: [Int: String] = [:]
    /// Number1...Number20, keyed by field number.
    public var numbers: [Int: Double] = [:]
    /// Date1...Date10, keyed by field number.
    public var dateFields: [Int: Date] = [:]
    /// Flag1...Flag20, keyed by field number.
    public var flags: [Int: Bool] = [:]
    /// Outline codes such as `Outline Code1`, keyed by field number.
    public var outlineCodes: [Int: String] = [:]
    public var baselines: [Int: Baseline] = [:]
    /// 16 bytes in on-disk (little-endian) order; empty lets the writer mint one.
    public var guid: [UInt8] = []

    public var id: Int { uid }

    public init(uid: Int, name: String = "", start: Date? = nil, finish: Date? = nil) {
        self.uid = uid
        self.name = name
        self.start = start
        self.finish = finish
    }
}

public struct Relation: Equatable, Sendable {
    public var predUID: Int
    public var succUID: Int
    /// `FF`, `FS`, `SF` or `SS`.
    public var type: String = "FS"
    /// In project days; negative is a lead. With elapsed `lagUnits` it is
    /// wall-clock minutes divided by `Project.minutesPerDay`; with `%` or `e%`
    /// it is a fraction of the predecessor's duration (0.5 is 50%).
    public var lagDays: Double = 0
    /// The units the lag is shown and counted in: `m`, `h`, `d`, `w`, `mo`,
    /// the elapsed `em`...`emo`, or `%` / `e%`.
    public var lagUnits: String = "d"

    public init(predUID: Int, succUID: Int, type: String = "FS", lagDays: Double = 0, lagUnits: String = "d") {
        self.predUID = predUID
        self.succUID = succUID
        self.type = type
        self.lagDays = lagDays
        self.lagUnits = lagUnits
    }

    /// The lag counts wall-clock time.
    public var lagIsElapsed: Bool { lagUnits.hasPrefix("e") }
    /// The lag is a share of the predecessor's duration.
    public var lagIsPercent: Bool { lagUnits.hasSuffix("%") }
}

/// A run of days in a calendar, both ends inclusive, that are non-working or
/// have their own working hours.
public struct CalendarException: Equatable, Sendable {
    /// Wall-clock midnight of the first day.
    public var start: Date
    /// Wall-clock midnight of the last day; `nil` means the same as `start`.
    public var finish: Date?
    public var name: String = ""
    /// Working hours on these days, as `startMinute...endMinute` ranges; empty
    /// for a non-working exception (a holiday).
    public var working: [ClosedRange<Int>] = []

    public init(start: Date, finish: Date? = nil, name: String = "", working: [ClosedRange<Int>] = []) {
        self.start = start
        self.finish = finish
        self.name = name
        self.working = working
    }

    /// A holiday rather than changed working hours.
    public var isNonWorking: Bool { working.isEmpty }

    public var lastDay: Date { finish ?? start }
}

/// A working-week definition.
///
/// `week` maps a Foundation weekday (`1` = Sunday ... `7` = Saturday) to `nil`
/// for a non-working day or to a list of `startMinute...endMinute` ranges.
/// A weekday absent from the map keeps Project's built-in default
/// (Monday–Friday 08:00–12:00 and 13:00–17:00).
///
/// Deliberately not named `Calendar`: that would shadow `Foundation.Calendar`,
/// which this package's own date arithmetic depends on.
public struct ProjectCalendar: Equatable, Sendable {
    public var name: String = "Standard"
    public var week: [Int: [ClosedRange<Int>]?] = [:]
    public var exceptions: [CalendarException] = []
    /// The calendar's unique id in the file; the writer assigns its own.
    public var uid: Int = 0
    /// For a resource calendar, the resource it belongs to.
    public var resourceUID: Int?
    /// For a resource calendar, the base calendar it derives from.
    public var baseCalendarUID: Int?
    public var guid: [UInt8] = []
    /// The app's shifts for this calendar; empty when the week came from
    /// Project and has not been edited as shifts. `week` is what is saved.
    public var shifts: [Shift] = []
    /// The holiday sets the calendar follows. Their days are written into
    /// `exceptions` (see `syncHolidays`).
    public var holidays: [HolidaySelection] = []

    public init(name: String = "Standard",
                week: [Int: [ClosedRange<Int>]?] = [:],
                exceptions: [CalendarException] = []) {
        self.name = name
        self.week = week
        self.exceptions = exceptions
    }

    /// Project's built-in working day: 08:00–12:00 and 13:00–17:00.
    public static let defaultWorkingDay: [ClosedRange<Int>] = [480...720, 780...1020]

    /// The working ranges actually in force on `weekday`, with Project's
    /// defaults filled in for weekdays the calendar leaves unset.
    public func workingRanges(weekday: Int) -> [ClosedRange<Int>] {
        if let entry = week[weekday] { return entry ?? [] }
        return (2...6).contains(weekday) ? Self.defaultWorkingDay : []
    }

    /// Whether the wall-clock day containing `date` is covered by an exception.
    public func isException(_ date: Date) -> Bool {
        let day = MPPTime.dayNumber(date)
        return exceptions.contains {
            MPPTime.dayNumber($0.start) <= day && day <= MPPTime.dayNumber($0.lastDay)
        }
    }
}

public struct Resource: Identifiable, Equatable, Sendable {
    public var uid: Int
    /// Project's `ID` column.
    public var rowID: Int = 0
    public var name: String
    public var initials: String = ""
    public var email: String = ""
    /// 1.0 means 100%.
    public var maxUnits: Double = 1.0
    /// `work`, `material` or `cost`. Only `work` is written.
    public var type: String = "work"
    /// Custom WBS-style code for the resource.
    public var code: String = ""
    /// Group name, as used for grouping in views.
    public var group: String = ""
    /// The resource's own calendar uid, as read from the file.
    public var calendarUID: Int?
    public var guid: [UInt8] = []
    /// Text1...Text30, keyed by field number.
    public var text: [Int: String] = [:]
    /// Number1...Number20, keyed by field number.
    public var numbers: [Int: Double] = [:]
    /// Date1...Date10, keyed by field number.
    public var dateFields: [Int: Date] = [:]
    /// Flag1...Flag20, keyed by field number.
    public var flags: [Int: Bool] = [:]
    public var baselines: [Int: Baseline] = [:]

    public var id: Int { uid }

    public init(uid: Int, name: String = "") {
        self.uid = uid
        self.name = name
    }
}

public struct Assignment: Equatable, Sendable {
    /// Assigned by the writer; read back from the file.
    public var uid: Int = 0
    public var taskUID: Int
    public var resourceUID: Int
    /// 1.0 means 100%.
    public var units: Double = 1.0
    /// Read from the file; the writer derives work from the task's duration.
    public var workHours: Double = 0
    public var start: Date?
    public var finish: Date?
    public var baselines: [Int: Baseline] = [:]

    public init(taskUID: Int, resourceUID: Int, units: Double = 1.0) {
        self.taskUID = taskUID
        self.resourceUID = resourceUID
        self.units = units
    }
}

/// A whole project, independent of which file format it came from.
public struct Project: Sendable, Equatable {
    public var title: String
    public var start: Date
    /// Read from the file; the writer computes it from the tasks.
    public var finish: Date?
    public var tasks: [ProjectTask] = []
    public var relations: [Relation] = []
    public var resources: [Resource] = []
    public var assignments: [Assignment] = []
    /// The Standard calendar. The writer applies any week or exception edits.
    public var calendar: ProjectCalendar?
    /// Additional base calendars.
    public var calendars: [ProjectCalendar] = []
    /// Per-resource calendars, as read from the file.
    public var resourceCalendars: [ProjectCalendar] = []
    /// The project calendar's name; `Standard` unless changed.
    public var defaultCalendar: String?
    /// Base calendars read from the file and since deleted, by uid: the
    /// writer drops their rows.
    public var removedCalendarUIDs: Set<Int> = []

    // Calendar options. Durations in the model are in *project* days, so these
    // decide what "one day" means on disk.
    public var minutesPerDay: Int = 480
    public var minutesPerWeek: Int = 2_400
    public var daysPerMonth: Int = 20
    /// Default start and finish time of a working day, minutes from midnight.
    public var defaultStartTime: Int = 480
    public var defaultFinishTime: Int = 1_020

    // Document metadata, from the OLE property sets.
    public var author: String?
    public var subject: String?
    public var keywords: String?
    public var comments: String?
    public var manager: String?
    public var company: String?
    public var category: String?

    public var statusDate: Date?
    /// Project's "Tasks are critical if slack is less than or equal to", in
    /// days. 0 is Project's default.
    public var criticalSlackDays: Double = 0
    /// e.g. `"£"`.
    public var currencySymbol: String?
    /// e.g. `"GBP"`.
    public var currencyCode: String?
    /// The names given to task custom fields in Project ("UE / Sub" for Text1),
    /// keyed "text1", "number3", "date2", "flag10".
    public var fieldAliases: [String: String] = [:]
    /// The outline columns the file was last saved with, as the app names them
    /// ("id", "name", "text3"). Nil when the file does not say — a new
    /// document, or one last saved by Project — and the app picks its default.
    public var viewColumns: [String]?

    public init(title: String, start: Date) {
        self.title = title
        self.start = start
    }

    /// Tenths of a minute in one project day — the unit every on-disk duration
    /// and lag is counted in.
    public var tenthsPerDay: Int { minutesPerDay * 10 }

    public func task(uid: Int) -> ProjectTask? { tasks.first { $0.uid == uid } }
    public func resource(uid: Int) -> Resource? { resources.first { $0.uid == uid } }
}

// Codable, for copying tasks between documents (`TaskFragment`). Declared
// here because Swift synthesises the conformance only in the declaring file.
extension ProjectTask: Codable {}
extension Relation: Codable {}
extension Assignment: Codable {}
extension Baseline: Codable {}
extension Resource: Codable {}
