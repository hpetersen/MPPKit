// MPPKit: Microsoft Project (.mpp) files in Swift
// Copyright (C) 2026 Henrik Petersen
//
// Portions are ported from pymppwriter, Copyright (c) Kevin McAleer,
// under the MIT License; see THIRD_PARTY_NOTICES.md.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 3 as published
// by the Free Software Foundation. It is distributed WITHOUT ANY WARRANTY;
// see the LICENSE file for details. https://mppstudio.com
//
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// A critical-path scheduler: the subset of Project's own scheduling needed
/// to give every task the dates Project gives it when it recalculates.
///
/// Handled: the four link types with lags and leads (working, elapsed or a
/// percentage of the predecessor), links on summary tasks (they bind every
/// task underneath), `SNET`, `MSO`, `FNET` and `MFO` constraints, deadlines,
/// task calendars with changed-hours exceptions, elapsed durations, split
/// tasks (their idle time is kept), milestones, manually scheduled tasks (left
/// where they are, but given late dates) and summary roll-up. Progress follows
/// Project: finished work has no float and holds nothing back; work under way
/// has its late start at its actual start and holds its predecessors only to
/// where its work has reached.
///
/// A backward pass then gives every task its late start and finish (and so
/// slack and the critical path), and as-late-as-possible tasks are moved to
/// their late dates. The "no later than" constraints (`SNLT`, `FNLT`) cap the
/// late dates; a schedule that breaks them is left to Project to report.
/// Resource levelling is not done.
public enum Scheduler {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case unknownTask(Int)
        case cycle([Int])
        case unknownCalendar(String)

        public var description: String {
            switch self {
            case .unknownTask(let uid): return "relation references unknown task uid \(uid)"
            case .cycle(let uids): return "dependency cycle: " + uids.map(String.init).joined(separator: " -> ")
            case .unknownCalendar(let name): return "task references unknown calendar \"\(name)\""
            }
        }
    }

    /// Recompute `start`, `finish` and summary durations in place.
    public static func schedule(_ project: inout Project) throws {
        let projectTime = WorkingTime(calendar: project.calendar)
        var calendars: [String: WorkingTime] = ["Standard": projectTime]
        if let std = project.calendar { calendars[std.name] = projectTime }
        for cal in project.calendars { calendars[cal.name] = WorkingTime(calendar: cal) }
        func time(for task: ProjectTask) throws -> WorkingTime {
            guard let name = task.calendar else { return projectTime }
            guard let t = calendars[name] else { throw Failure.unknownCalendar(name) }
            return t
        }

        let index = Dictionary(uniqueKeysWithValues: project.tasks.enumerated().map { ($1.uid, $0) })
        var children: [Int: [Int]] = [:]
        for t in project.tasks where t.parentUID != 0 { children[t.parentUID, default: []].append(t.uid) }
        var leafCache: [Int: [Int]] = [:]
        func leaves(under uid: Int) -> [Int] {
            guard let kids = children[uid] else { return [uid] }
            if let cached = leafCache[uid] { return cached }
            let out = kids.flatMap(leaves(under:))
            leafCache[uid] = out
            return out
        }

        // Predecessor links per leaf. A link onto a summary binds each leaf
        // under it; a link from a summary is evaluated on its rolled-up dates.
        var incoming: [Int: [Relation]] = [:]
        // Dependency graph: a node waits for its predecessors, a summary for
        // its children.
        var waitsFor: [Int: Set<Int>] = [:]
        for rel in project.relations {
            guard index[rel.predUID] != nil else { throw Failure.unknownTask(rel.predUID) }
            guard index[rel.succUID] != nil else { throw Failure.unknownTask(rel.succUID) }
            for leaf in leaves(under: rel.succUID) {
                incoming[leaf, default: []].append(rel)
                waitsFor[leaf, default: []].insert(rel.predUID)
            }
        }
        for (parent, kids) in children { waitsFor[parent, default: []].formUnion(kids) }

        // Kahn's algorithm, in row order so ties schedule predictably.
        var pending = waitsFor.mapValues(\.count)
        var dependents: [Int: [Int]] = [:]
        for (node, deps) in waitsFor { for d in deps { dependents[d, default: []].append(node) } }
        var ready = project.tasks.map(\.uid).filter { (pending[$0] ?? 0) == 0 }
        var order: [Int] = []
        order.reserveCapacity(project.tasks.count)
        var head = 0
        while head < ready.count {
            let uid = ready[head]
            head += 1
            order.append(uid)
            for next in dependents[uid] ?? [] {
                pending[next, default: 0] -= 1
                if pending[next] == 0 { ready.append(next) }
            }
        }
        if order.count < project.tasks.count {
            let done = Set(order)
            let stuck = project.tasks.map(\.uid).filter { !done.contains($0) }
            throw Failure.cycle(stuck)
        }

        let projectStart = projectTime.nextWorkingMoment(project.start)

        /// A task's duration in minutes: working minutes, or wall-clock ones
        /// for an elapsed duration.
        func durationMinutes(_ t: ProjectTask) -> Int {
            Int((t.durationDays * Double(project.minutesPerDay)).rounded())
        }
        /// `date` moved by a link's lag, forwards (`sign` 1) or backwards (-1),
        /// in the successor's working time — or wall-clock for an elapsed lag;
        /// a percentage lag is that share of the predecessor's duration.
        func lagged(_ date: Date, _ rel: Relation, sign: Int, wt: WorkingTime) -> Date {
            let minutes: Int
            if rel.lagIsPercent {
                let pred = project.tasks[index[rel.predUID]!]
                minutes = Int((rel.lagDays * Double(durationMinutes(pred))).rounded())
            } else {
                minutes = Int((rel.lagDays * Double(project.minutesPerDay)).rounded())
            }
            let m = minutes * sign
            if m == 0 { return date }
            if rel.lagIsElapsed { return date.addingTimeInterval(Double(m) * 60) }
            return m > 0 ? wt.advance(date, minutes: m) : wt.retreat(date, minutes: -m)
        }
        /// The finish `minutes` after `start`, and the start `minutes` before
        /// `finish`, for a task with this duration kind.
        func after(_ start: Date, _ minutes: Int, _ t: ProjectTask, _ wt: WorkingTime) -> Date {
            t.isElapsed ? start.addingTimeInterval(Double(minutes) * 60) : wt.advance(start, minutes: minutes)
        }
        func before(_ finish: Date, _ minutes: Int, _ t: ProjectTask, _ wt: WorkingTime) -> Date {
            t.isElapsed ? finish.addingTimeInterval(-Double(minutes) * 60) : wt.retreat(finish, minutes: minutes)
        }
        let leafOrder = order.filter { children[$0] == nil }

        /// Forward pass. `notBefore` holds starts imposed from outside the pass:
        /// as-late-as-possible tasks placed at their late start.
        func forward(notBefore: [Int: Date]) throws {
            for uid in order {
                var task = project.tasks[index[uid]!]
                if let kids = children[uid] {
                    let spans = kids.map { project.tasks[index[$0]!] }
                    task.start = spans.compactMap(\.start).min()
                    task.finish = spans.compactMap(\.finish).max()
                    if let s = task.start, let f = task.finish {
                        task.durationDays = Double(projectTime.minutes(from: s, to: f)) / Double(project.minutesPerDay)
                    }
                    task.summary = true
                    project.tasks[index[uid]!] = task
                    continue
                }
                task.summary = false
                if task.manual, task.start != nil, task.finish != nil { continue }

                let wt = try time(for: task)
                let minutes = durationMinutes(task)
                let isMilestone = minutes == 0
                let span = minutes + task.splitMinutes

                // A Start No Earlier Than replaces the project start as the
                // floor, so a task can be set to have begun before it — as in
                // Project, which warns about it but keeps the date.
                var start = projectStart
                if task.constraint == "SNET", let d = task.constraintDate { start = min(start, d) }
                var finishFloor: Date?
                for rel in incoming[uid] ?? [] {
                    let pred = project.tasks[index[rel.predUID]!]
                    guard let ps = pred.start, let pf = pred.finish else { continue }
                    switch rel.type {
                    case "SS": start = max(start, lagged(ps, rel, sign: 1, wt: wt))
                    case "FF": finishFloor = max(finishFloor ?? .distantPast, lagged(pf, rel, sign: 1, wt: wt))
                    case "SF": finishFloor = max(finishFloor ?? .distantPast, lagged(ps, rel, sign: 1, wt: wt))
                    default: start = max(start, lagged(pf, rel, sign: 1, wt: wt))
                    }
                }
                switch task.constraint {
                case "SNET": if let d = task.constraintDate { start = max(start, d) }
                case "MSO": if let d = task.constraintDate { start = d }
                case "FNET": if let d = task.constraintDate { finishFloor = max(finishFloor ?? .distantPast, d) }
                default: break
                }
                if let floor = notBefore[uid] { start = max(start, floor) }
                // Work that has begun stays where it began — as in Project, an
                // actual start pins the task even before any progress is entered.
                let started = task.actualStart
                if let a = started { start = a; finishFloor = nil }
                if !isMilestone, started == nil { start = wt.nextWorkingMoment(start) }
                var finish = isMilestone ? start : after(start, span, task, wt)
                if let floor = finishFloor {
                    let fromFinish = isMilestone ? floor : before(floor, span, task, wt)
                    if fromFinish > start {
                        // Driven by its finish: Project keeps the finish at
                        // the exact instant the link or constraint imposes
                        // (Monday 08:00 rather than the Friday evening before).
                        start = fromFinish
                        finish = floor
                    }
                }
                if task.constraint == "MFO", let d = task.constraintDate {
                    finish = d
                    start = isMilestone ? d : before(d, span, task, wt)
                }
                task.start = start
                task.finish = finish
                if task.percentComplete > 0, task.actualStart == nil { task.actualStart = start }
                if task.percentComplete == 100, task.actualFinish == nil { task.actualFinish = finish }
                project.tasks[index[uid]!] = task
            }
        }

        // Each leaf's outgoing links, by index: a link on a summary stands
        // for its leaves on both ends. The successor end is evaluated once per
        // link — the earliest late dates among its leaves — rather than once
        // per pair of leaves, which grew with the product of two phases' sizes.
        var outgoing: [Int: [Int]] = [:]
        for (i, rel) in project.relations.enumerated() {
            for p in leaves(under: rel.predUID) { outgoing[p, default: []].append(i) }
        }

        /// Backward pass: the latest each leaf can start and finish without
        /// delaying the project finish or breaking a constraint.
        func backward() throws {
            guard let projectFinish = leafOrder.compactMap({ project.tasks[index[$0]!].finish }).max() else { return }
            var stopDate: [Int: Date] = [:]
            /// Per link: the earliest late start (or stop date, for work under
            /// way) and late finish among the unfinished leaves it binds.
            var successorEnds: [Int: (start: Date?, finish: Date?)] = [:]
            func ends(of i: Int) -> (start: Date?, finish: Date?) {
                if let e = successorEnds[i] { return e }
                var start: Date?, finish: Date?
                for succ in leaves(under: project.relations[i].succUID) {
                    let s = project.tasks[index[succ]!]
                    // Finished work no longer waits for anything.
                    if s.percentComplete == 100 { continue }
                    guard let sls = s.lateStart, let slf = s.lateFinish else { continue }
                    // A successor under way holds its predecessors only up to
                    // where its own work has reached (its stop date).
                    let held = stopDate[succ] ?? sls
                    start = min(start ?? held, held)
                    finish = min(finish ?? slf, slf)
                }
                successorEnds[i] = (start, finish)
                return (start, finish)
            }
            for uid in leafOrder.reversed() {
                var task = project.tasks[index[uid]!]
                let wt = try time(for: task)
                // A manually scheduled task keeps its dates, but Project still
                // works out how late it could be: its float is real.
                let minutes = task.manual
                    ? (task.start.flatMap { s in task.finish.map { wt.minutes(from: s, to: $0) } } ?? 0)
                    : durationMinutes(task) + task.splitMinutes
                let isMilestone = minutes == 0
                var lf = projectFinish
                var startCap: Date?
                for i in outgoing[uid] ?? [] {
                    let rel = project.relations[i]
                    let e = ends(of: i)
                    guard let sls = e.start, let slf = e.finish else { continue }
                    switch rel.type {
                    case "SS": startCap = min(startCap ?? .distantFuture, lagged(sls, rel, sign: -1, wt: wt))
                    case "FF": lf = min(lf, lagged(slf, rel, sign: -1, wt: wt))
                    case "SF": startCap = min(startCap ?? .distantFuture, lagged(slf, rel, sign: -1, wt: wt))
                    default: lf = min(lf, lagged(sls, rel, sign: -1, wt: wt))
                    }
                }
                // A deadline is a late finish the plan has promised: Project
                // caps the late finish there, which is how a missed deadline
                // shows as negative float.
                if let deadline = task.deadline { lf = min(lf, deadline) }
                switch task.constraint {
                case "MFO": if let d = task.constraintDate { lf = d }
                case "FNLT": if let d = task.constraintDate { lf = min(lf, d) }
                case "MSO": if let d = task.constraintDate { startCap = d }
                case "SNLT": if let d = task.constraintDate { startCap = min(startCap ?? .distantFuture, d) }
                default: break
                }
                // Finished work has no float: Project sets its late dates to
                // the dates it happened on.
                if task.percentComplete == 100 {
                    task.lateStart = task.start
                    task.lateFinish = task.finish
                    project.tasks[index[uid]!] = task
                    continue
                }
                var ls = isMilestone ? lf : before(lf, minutes, task, wt)
                if let cap = startCap, cap < ls || task.constraint == "MSO" {
                    ls = cap
                    lf = isMilestone ? cap : after(cap, minutes, task, wt)
                }
                // Work under way can no longer start later: its late start is
                // the day it started, and only its finish has float.
                if task.actualStart != nil, let s = task.start {
                    ls = s
                    let done = Int((Double(minutes) * Double(task.percentComplete) / 100).rounded())
                    stopDate[uid] = after(s, done, task, wt)
                }
                task.lateStart = ls
                task.lateFinish = lf
                project.tasks[index[uid]!] = task
            }
            // Summaries span their children's late dates.
            for uid in order.reversed() where children[uid] != nil {
                let kids = leaves(under: uid).map { project.tasks[index[$0]!] }
                project.tasks[index[uid]!].lateStart = kids.compactMap(\.lateStart).min()
                project.tasks[index[uid]!].lateFinish = kids.compactMap(\.lateFinish).max()
            }
        }

        try forward(notBefore: [:])
        try backward()
        // As late as possible: an unstarted ALAP task moves to its late start,
        // and its successors follow on the next forward pass.
        var alap: [Int: Date] = [:]
        for uid in leafOrder {
            let t = project.tasks[index[uid]!]
            if t.constraint == "ALAP", !t.manual, t.percentComplete == 0, let ls = t.lateStart { alap[uid] = ls }
        }
        if !alap.isEmpty {
            try forward(notBefore: alap)
            try backward()
        }
        project.finish = project.tasks.compactMap(\.finish).max()
    }
}

extension Project {
    /// Save the current schedule into baseline `slot` (0 is `Baseline`, 1...10
    /// are `Baseline1`...`Baseline10`, 11 and up the app's own), as Project's Set Baseline does: start,
    /// finish, duration and work per task, summaries spanning their children
    /// and work rolled up from assignments; assignments get the same snapshot
    /// without a duration, and resources the work their assignments add up to.
    /// Gives every task without a baseline in `slot` one from its current
    /// dates, leaving the tasks that have one alone: the plan of a task is kept
    /// before tracking first moves it, never replaced.
    public mutating func keepPlan(slot: Int = 0) {
        guard tasks.contains(where: { $0.baselines[slot] == nil }) else { return }
        var snapshot = self
        snapshot.setBaseline(slot: slot)
        for i in tasks.indices where tasks[i].baselines[slot] == nil {
            tasks[i].baselines[slot] = snapshot.tasks[i].baselines[slot]
        }
        for i in assignments.indices where assignments[i].baselines[slot] == nil {
            assignments[i].baselines[slot] = snapshot.assignments[i].baselines[slot]
        }
    }

    public mutating func setBaseline(slot: Int = 0) {
        precondition(slot >= 0, "baseline slot must be >= 0")
        let hoursPerDay = Double(minutesPerDay) / 60
        var children: [Int: [Int]] = [:]
        for t in tasks { children[t.parentUID, default: []].append(t.uid) }
        var direct: [Int: Double] = [:]
        for a in assignments {
            guard let t = task(uid: a.taskUID) else { continue }
            direct[a.taskUID, default: 0] += t.durationDays * hoursPerDay * a.units
        }
        func work(_ uid: Int) -> Double {
            (direct[uid] ?? 0) + (children[uid] ?? []).reduce(0) { $0 + work($1) }
        }
        for i in tasks.indices {
            let t = tasks[i]
            tasks[i].baselines[slot] = Baseline(start: t.start, finish: t.finish,
                                                durationDays: t.durationDays,
                                                workHours: (work(t.uid) * 10_000).rounded() / 10_000)
        }
        var perResource: [Int: Double] = [:]
        for i in assignments.indices {
            guard let t = task(uid: assignments[i].taskUID) else { continue }
            let hours = (t.durationDays * hoursPerDay * assignments[i].units * 10_000).rounded() / 10_000
            assignments[i].baselines[slot] = Baseline(start: t.start, finish: t.finish, workHours: hours)
            perResource[assignments[i].resourceUID, default: 0] += hours
        }
        for i in resources.indices {
            resources[i].baselines[slot] = Baseline(workHours: perResource[resources[i].uid] ?? 0)
        }
    }

    /// Drop baseline `slot` everywhere.
    public mutating func clearBaseline(slot: Int = 0) {
        for i in tasks.indices { tasks[i].baselines[slot] = nil }
        for i in resources.indices { resources[i].baselines[slot] = nil }
        for i in assignments.indices { assignments[i].baselines[slot] = nil }
    }
}
