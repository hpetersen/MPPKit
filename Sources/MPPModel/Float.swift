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

/// Total float (Project's Total Slack) and the critical path, in working time.
///
/// Project's definition: total slack is the smaller of `late start − start` and
/// `late finish − finish`, measured in working time on the task's calendar, and
/// a task is critical when its total slack is at or below the project's
/// threshold (0 by default) — negative slack included, which is what marks a
/// broken deadline or constraint. Comparing clock times instead misses a
/// milestone that finishes Friday 17:00 with a late date of Monday 08:00:
/// 63 hours apart, no working time between them.
extension Project {
    /// Working time per calendar name, built once for a whole pass.
    public func workingTimes() -> (ProjectTask) -> WorkingTime {
        let projectTime = WorkingTime(calendar: calendar)
        var byName: [String: WorkingTime] = ["Standard": projectTime]
        if let c = calendar { byName[c.name] = projectTime }
        for c in calendars { byName[c.name] = WorkingTime(calendar: c) }
        return { task in task.calendar.flatMap { byName[$0] } ?? projectTime }
    }

    /// Total float of `task` in working minutes; negative when it is late.
    /// Once a task has started, Project measures its float at the finish only.
    public static func floatMinutes(_ task: ProjectTask, time: WorkingTime) -> Int? {
        let finishFloat = task.finish.flatMap { f in task.lateFinish.map { time.signedMinutes(from: f, to: $0) } }
        if task.actualStart != nil, let finishFloat { return finishFloat }
        guard let s = task.start, let ls = task.lateStart else { return finishFloat }
        let startFloat = time.signedMinutes(from: s, to: ls)
        return finishFloat.map { min(startFloat, $0) } ?? startFloat
    }

    /// Total float of the task in working minutes.
    public func totalFloatMinutes(uid: Int) -> Int? {
        guard let t = task(uid: uid) else { return nil }
        return Self.floatMinutes(t, time: workingTimes()(t))
    }

    /// Total float in working minutes for every task, in one pass.
    public func totalFloats() -> [Int: Int] {
        let time = workingTimes()
        var out: [Int: Int] = [:]
        out.reserveCapacity(tasks.count)
        for t in tasks { if let m = Self.floatMinutes(t, time: time(t)) { out[t.uid] = m } }
        return out
    }

    /// Whether one task is critical, by the same rule as `criticalUIDs`.
    public func isCritical(uid: Int) -> Bool {
        guard let t = task(uid: uid), t.percentComplete < 100, let m = totalFloatMinutes(uid: uid) else { return false }
        return m <= Int((criticalSlackDays * Double(minutesPerDay)).rounded())
    }

    /// The critical tasks: unfinished, with total float at or below the
    /// project's threshold.
    public func criticalUIDs() -> Set<Int> {
        let limit = Int((criticalSlackDays * Double(minutesPerDay)).rounded())
        let time = workingTimes()
        var out = Set<Int>()
        for t in tasks where t.percentComplete < 100 {
            if let m = Self.floatMinutes(t, time: time(t)), m <= limit { out.insert(t.uid) }
        }
        return out
    }
}

extension WorkingTime {
    /// Working minutes from `a` to `b`; negative when `b` is before `a`.
    public func signedMinutes(from a: Date, to b: Date) -> Int {
        b >= a ? minutes(from: a, to: b) : -minutes(from: b, to: a)
    }
}

extension Project {
    /// Whether `other` gives the scheduler exactly the same problem: the same
    /// tasks in the same outline, durations, constraints, deadlines, progress,
    /// calendars and links. Names, notes, custom fields, resources' names and
    /// the like are not inputs, so an edit to them must not recalculate — and
    /// so move — dates Project calculated.
    public func hasSameSchedulingInputs(as other: Project) -> Bool {
        guard start == other.start, minutesPerDay == other.minutesPerDay,
              calendar == other.calendar, calendars == other.calendars,
              relations == other.relations, tasks.count == other.tasks.count else { return false }
        for (a, b) in zip(tasks, other.tasks) {
            guard a.uid == b.uid, a.parentUID == b.parentUID, a.outlineLevel == b.outlineLevel,
                  a.durationDays == b.durationDays, a.durationUnits == b.durationUnits,
                  a.constraint == b.constraint, a.constraintDate == b.constraintDate,
                  a.deadline == b.deadline, a.percentComplete == b.percentComplete,
                  a.actualStart == b.actualStart, a.actualFinish == b.actualFinish,
                  a.manual == b.manual, a.calendar == b.calendar, a.splitMinutes == b.splitMinutes,
                  a.milestone == b.milestone else { return false }
            // A manual task's dates are typed in, so they are inputs too.
            if a.manual, a.start != b.start || a.finish != b.finish { return false }
        }
        return true
    }
}

extension Project {
    /// How many tasks a recalculation would move: rescheduled with MPPKit, the
    /// tasks whose start or finish differs by any working time from the saved
    /// dates. 0 for a file Project and MPPKit agree on.
    public func recalculationDrift() -> Int {
        var copy = self
        guard (try? Scheduler.schedule(&copy)) != nil else { return 0 }
        let time = workingTimes()
        var moved = 0
        for (a, b) in zip(tasks, copy.tasks) where !a.summary {
            guard let s0 = a.start, let f0 = a.finish, let s1 = b.start, let f1 = b.finish else { continue }
            let t = time(a)
            if t.signedMinutes(from: s0, to: s1) != 0 || t.signedMinutes(from: f0, to: f1) != 0 { moved += 1 }
        }
        return moved
    }
}

extension Project {
    /// Split tasks, as the saved dates show them: a task whose span is longer
    /// than its duration has idle time inside it (`splitMinutes`), which the
    /// scheduler keeps. Called by the readers.
    public mutating func inferSplitGaps() {
        let time = workingTimes()
        let summaries = Set(tasks.map(\.parentUID))
        for i in tasks.indices {
            let t = tasks[i]
            guard !summaries.contains(t.uid), !t.manual, !t.isElapsed, let s = t.start, let f = t.finish else { continue }
            let gap = time(t).minutes(from: s, to: f) - Int((t.durationDays * Double(minutesPerDay)).rounded())
            tasks[i].splitMinutes = gap > 1 ? gap : 0
        }
    }
}
