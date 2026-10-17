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

/// Structural edits, keeping the outline consistent: tasks stay in outline
/// (row) order, every `parentUID` matches the nearest preceding task one level
/// up, and links and assignments never point at deleted tasks.
///
/// None of these reschedule; call `Scheduler.schedule` afterwards.
extension Project {
    /// The rows a task's subtree occupies: the task and its descendants.
    public func subtree(of uid: Int) -> Range<Int>? {
        guard let i = tasks.firstIndex(where: { $0.uid == uid }) else { return nil }
        var end = i + 1
        while end < tasks.count, tasks[end].outlineLevel > tasks[i].outlineLevel { end += 1 }
        return i..<end
    }

    public func children(of uid: Int) -> [ProjectTask] { tasks.filter { $0.parentUID == uid } }

    public func isSummary(_ uid: Int) -> Bool { tasks.contains { $0.parentUID == uid } }

    public var nextTaskUID: Int { (tasks.map(\.uid).max() ?? 0) + 1 }

    /// Insert a task below `uid` (after its subtree, at its level), or at the
    /// end when `uid` is nil. Returns the new task's uid.
    @discardableResult
    public mutating func insertTask(after uid: Int?, name: String = "New task", durationDays: Double = 1) -> Int {
        var t = ProjectTask(uid: nextTaskUID, name: name)
        t.durationDays = durationDays
        t.milestone = durationDays == 0
        var at = tasks.count
        if let uid, let span = subtree(of: uid) {
            t.outlineLevel = tasks[span.lowerBound].outlineLevel
            at = span.upperBound
        }
        tasks.insert(t, at: at)
        normalizeOutline()
        return t.uid
    }

    /// Insert a task directly above `uid`, at its level. Returns the new uid.
    @discardableResult
    public mutating func insertTask(before uid: Int, name: String = "New task",
                                    durationDays: Double = 1) -> Int {
        var t = ProjectTask(uid: nextTaskUID, name: name)
        t.durationDays = durationDays
        t.milestone = durationDays == 0
        guard let i = tasks.firstIndex(where: { $0.uid == uid }) else {
            tasks.append(t)
            normalizeOutline()
            return t.uid
        }
        t.outlineLevel = tasks[i].outlineLevel
        tasks.insert(t, at: i)
        normalizeOutline()
        return t.uid
    }

    /// Remove every link into `uid`.
    public mutating func removePredecessors(of uid: Int) {
        relations.removeAll { $0.succUID == uid }
    }

    /// Delete a task, its subtree, and every link and assignment touching them.
    public mutating func deleteTask(_ uid: Int) {
        guard let span = subtree(of: uid) else { return }
        let gone = Set(tasks[span].map(\.uid))
        tasks.removeSubrange(span)
        relations.removeAll { gone.contains($0.predUID) || gone.contains($0.succUID) }
        assignments.removeAll { gone.contains($0.taskUID) }
        normalizeOutline()
    }

    /// Make a task (and its subtree) a child of the task above it.
    /// Returns false when there is no task above at the same level.
    @discardableResult
    public mutating func indent(_ uid: Int) -> Bool {
        guard let span = subtree(of: uid), span.lowerBound > 0 else { return false }
        let level = tasks[span.lowerBound].outlineLevel
        guard tasks[span.lowerBound - 1].outlineLevel >= level else { return false }
        for i in span { tasks[i].outlineLevel += 1 }
        normalizeOutline()
        return true
    }

    /// Move a task (and its subtree) up one outline level.
    @discardableResult
    public mutating func outdent(_ uid: Int) -> Bool {
        guard let span = subtree(of: uid), tasks[span.lowerBound].outlineLevel > 1 else { return false }
        // Later siblings now follow a task one level up, so the outline makes
        // them its children — as in Project.
        for i in span { tasks[i].outlineLevel -= 1 }
        normalizeOutline()
        return true
    }

    /// Add a link, replacing any existing one between the same two tasks.
    /// Refuses self-links, links within one subtree, and cycles.
    @discardableResult
    public mutating func link(_ pred: Int, _ succ: Int, type: String = "FS", lagDays: Double = 0) -> Bool {
        guard pred != succ, task(uid: pred) != nil, task(uid: succ) != nil else { return false }
        if let s = subtree(of: pred), tasks[s].contains(where: { $0.uid == succ }) { return false }
        if let s = subtree(of: succ), tasks[s].contains(where: { $0.uid == pred }) { return false }
        // The new link makes every task under `succ` depend on `pred`.
        let bound = subtree(of: succ).map { tasks[$0].map(\.uid) } ?? [succ]
        if bound.contains(where: { reaches(from: $0, to: pred) }) { return false }
        relations.removeAll { $0.predUID == pred && $0.succUID == succ }
        relations.append(Relation(predUID: pred, succUID: succ, type: type, lagDays: lagDays))
        return true
    }

    public mutating func unlink(_ pred: Int, _ succ: Int) {
        relations.removeAll { $0.predUID == pred && $0.succUID == succ }
    }

    /// Whether `to` depends on `from`, in the scheduler's terms: a link binds
    /// every task under a summary successor, and a summary waits for its
    /// children — so a link from a summary makes its successor depend on
    /// everything beneath it.
    /// Builds the graph for one question; ask many through `DependencyGraph`.
    public func reaches(from: Int, to: Int) -> Bool {
        DependencyGraph(self).reaches(from: from, to: to)
    }

    /// The resource with this name, ignoring case and surrounding spaces.
    public func resourceUID(named name: String) -> Int? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        return resources.first { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == key }?.uid
    }

    /// A new resource, as typing a name Project doesn't know adds one: a work
    /// resource at 100%, its initials from the name.
    @discardableResult
    public mutating func addResource(named name: String) -> Int {
        let uid = (resources.map(\.uid).max() ?? 0) + 1
        var r = Resource(uid: uid, name: name.trimmingCharacters(in: .whitespaces))
        r.rowID = resources.count + 1
        r.initials = String(r.name.split(separator: " ").prefix(3).compactMap(\.first)).uppercased()
        resources.append(r)
        return uid
    }

    /// Assigns exactly these resources to a task, by name, in this order. A
    /// name no resource has becomes a new resource; `units` nil keeps an
    /// existing assignment's units, or 100% for a new one.
    public mutating func setResources(_ entries: [(name: String, units: Double?)], of uid: Int) {
        guard tasks.contains(where: { $0.uid == uid }), !isSummary(uid) else { return }
        var keep: [Assignment] = []
        for (name, units) in entries where !name.trimmingCharacters(in: .whitespaces).isEmpty {
            let rid = resourceUID(named: name) ?? addResource(named: name)
            guard !keep.contains(where: { $0.resourceUID == rid }) else { continue }
            if var a = assignments.first(where: { $0.taskUID == uid && $0.resourceUID == rid }) {
                if let units { a.units = units }
                keep.append(a)
            } else {
                keep.append(Assignment(taskUID: uid, resourceUID: rid, units: units ?? 1))
            }
        }
        assignments.removeAll { $0.taskUID == uid }
        assignments.append(contentsOf: keep)
    }

    /// Move a task to start at `date`, the way dragging a bar does in Project:
    /// a manual task moves outright, an automatic one gets a "start no earlier
    /// than" constraint.
    public mutating func moveTask(_ uid: Int, toStart date: Date) {
        guard let i = tasks.firstIndex(where: { $0.uid == uid }), !isSummary(uid) else { return }
        if tasks[i].manual, let s = tasks[i].start, let f = tasks[i].finish {
            tasks[i].start = date
            tasks[i].finish = date.addingTimeInterval(f.timeIntervalSince(s))
        } else {
            tasks[i].constraint = "SNET"
            tasks[i].constraintDate = date
        }
    }

    /// Rebuild `parentUID` and `rowID` from the outline levels, clamping any
    /// level that rises by more than one.
    public mutating func normalizeOutline() {
        var stack: [(uid: Int, level: Int)] = []
        for i in tasks.indices {
            var level = max(1, tasks[i].outlineLevel)
            level = min(level, (stack.last?.level ?? 0) + 1)
            while let top = stack.last, top.level >= level { stack.removeLast() }
            tasks[i].outlineLevel = level
            tasks[i].parentUID = stack.last?.uid ?? 0
            tasks[i].rowID = i + 1
            stack.append((tasks[i].uid, level))
        }
        let summaries = Set(tasks.map(\.parentUID))
        for i in tasks.indices { tasks[i].summary = summaries.contains(tasks[i].uid) }
        // A summary cannot carry its own assignments.
        assignments.removeAll { summaries.contains($0.taskUID) }
    }
}

// MARK: - Presentation helpers
//
// Derived facts the interface needs but the file does not store. They live here
// rather than in the app so the outline and the chart cannot disagree about what
// "critical" or "which phase" means.

extension Project {

    /// Total float, in seconds of working time.
    ///
    /// The definition is the one `Scheduler`'s backward pass produces: how far a
    /// task's start can slip before it delays the project. Zero therefore *is*
    /// the critical path — which is why the interface can treat "no slack" and
    /// "critical" as the same statement rather than maintaining two flags.
    /// Total slack in working minutes (see `totalFloatMinutes`).
    public func totalSlack(uid: Int) -> Int? { totalFloatMinutes(uid: uid) }

    /// Which workstream (top-level phase) a task belongs to, as an index.
    ///
    /// Colour in this design answers "which part of the programme is this?", so
    /// the answer has to be stable: a task takes the pigment of its root
    /// ancestor, and every task in a phase therefore shares one hue. Summaries
    /// return their own root index so a collapsed phase can be coloured too.
    /// `outlinePhase` for every task in one pass: uid -> index of its top-level
    /// ancestor. Views that colour every row need this rather than one call per
    /// row, which walks the outline once per task and is quadratic.
    ///
    /// A phase is a top-level summary — a headline with tasks under it. A
    /// top-level task with nothing under it is not a phase: it takes index 0,
    /// as the project's own tasks.
    public func outlinePhases() -> [Int: Int] {
        var out: [Int: Int] = [:]
        out.reserveCapacity(tasks.count)
        let summaries = Set(tasks.map(\.parentUID))
        var phase = -1
        var current: Int?
        for t in tasks {
            if t.parentUID == 0 {
                if summaries.contains(t.uid) { phase += 1; current = phase } else { current = nil }
            }
            out[t.uid] = current ?? 0
        }
        return out
    }

    /// The top-level summaries, in outline order: the plan's phases.
    public var phaseRoots: [ProjectTask] {
        let summaries = Set(tasks.map(\.parentUID))
        return tasks.filter { $0.parentUID == 0 && summaries.contains($0.uid) }
    }

    public func outlinePhase(uid: Int) -> Int {
        let roots = phaseRoots
        guard let index = roots.firstIndex(where: { root in contains(root.uid, uid) }) else { return 0 }
        return index
    }

    /// Whether `ancestor` is `uid` or contains it.
    private func contains(_ ancestor: Int, _ uid: Int) -> Bool {
        var current = task(uid: uid)
        var guardCount = 0
        while let t = current, guardCount < 64 {
            if t.uid == ancestor { return true }
            current = t.parentUID == 0 ? nil : task(uid: t.parentUID)
            guardCount += 1
        }
        return false
    }
}

// MARK: - Constraint vocabulary

/// The names a scheduler uses for constraints.
///
/// These live beside the raw values rather than in the interface because they
/// are Microsoft Project's own vocabulary — the same words appear in Project's
/// Task Information dialog, and in the file's constraint field. Keeping them
/// here means the abbreviation stored on disk and the phrase shown to a user
/// can never drift apart.
extension ConstraintType {
    public var label: String {
        switch self {
        case .asSoonAsPossible: String(localized: "As Soon As Possible")
        case .asLateAsPossible: String(localized: "As Late As Possible")
        case .mustStartOn: String(localized: "Must Start On")
        case .mustFinishOn: String(localized: "Must Finish On")
        case .startNoEarlierThan: String(localized: "Start No Earlier Than")
        case .startNoLaterThan: String(localized: "Start No Later Than")
        case .finishNoEarlierThan: String(localized: "Finish No Earlier Than")
        case .finishNoLaterThan: String(localized: "Finish No Later Than")
        }
    }

    /// Whether the constraint pins a date, and so needs one beside it. Asking
    /// for a date when the constraint does not use one is the most common way a
    /// scheduling form confuses people.
    public var needsDate: Bool {
        self != .asSoonAsPossible && self != .asLateAsPossible
    }
}

// MARK: - Progress against the baseline

extension Project {
    /// Signed working days from `a` to `b` on the project calendar.
    private func workingDays(from a: Date, to b: Date) -> Double {
        let time = WorkingTime(calendar: calendar)
        let perDay = Double(max(1, minutesPerDay))
        return a <= b ? Double(time.minutes(from: a, to: b)) / perDay
                      : -Double(time.minutes(from: b, to: a)) / perDay
    }

    /// Project's Start Variance, in working days: how far a task now starts
    /// after (positive) or before (negative) its baselined start. The app calls
    /// it float — the delay drawn as a dashed bar ahead of the task.
    public func startVarianceDays(uid: Int, slot: Int = 0) -> Double? {
        guard let t = task(uid: uid), let s = t.start, let b = t.baselines[slot]?.start else { return nil }
        return workingDays(from: b, to: s)
    }

    /// Project's Finish Variance, in working days. Negative: finished early.
    public func finishVarianceDays(uid: Int, slot: Int = 0) -> Double? {
        guard let t = task(uid: uid), let f = t.finish, let b = t.baselines[slot]?.finish else { return nil }
        return workingDays(from: b, to: f)
    }

    /// Starts a task `days` working days after its baselined start, by giving
    /// it that actual start — the task moves, and its successors with it.
    public mutating func setStartVariance(uid: Int, days: Int, slot: Int = 0) {
        guard let i = tasks.firstIndex(where: { $0.uid == uid }),
              let b = tasks[i].baselines[slot]?.start else { return }
        let time = WorkingTime(calendar: calendar)
        let minutes = abs(days) * minutesPerDay
        let day = days == 0 ? b
            : days > 0 ? time.nextWorkingMoment(time.advance(b, minutes: minutes))
            : time.retreat(b, minutes: minutes)
        tasks[i].actualStart = day
    }

    /// Project's Actual Start: the task is pinned there. Nil while no progress
    /// is entered puts it back in the scheduler's hands.
    public mutating func setActualStart(uid: Int, _ date: Date?) {
        guard let i = tasks.firstIndex(where: { $0.uid == uid }) else { return }
        if date == nil, tasks[i].percentComplete > 0 { return }
        tasks[i].actualStart = date
    }

    /// Project's Actual Finish: the task is complete on that day, its duration
    /// what it took. Nil reopens a finished task.
    public mutating func setActualFinish(uid: Int, _ date: Date?) {
        guard let i = tasks.firstIndex(where: { $0.uid == uid }), let start = tasks[i].start else { return }
        guard let date else {
            tasks[i].actualFinish = nil
            if tasks[i].percentComplete == 100 { tasks[i].percentComplete = 0 }
            return
        }
        guard date >= start else { return }
        let minutes = WorkingTime(calendar: calendar).minutes(from: start, to: date)
        tasks[i].durationDays = Double(minutes) / Double(max(1, minutesPerDay))
        tasks[i].actualStart = tasks[i].actualStart ?? start
        tasks[i].actualFinish = date
        tasks[i].percentComplete = 100
    }

    /// The baselined span of the work: earliest baselined start to latest
    /// baselined finish. Nil when no task has a baseline.
    public func baselineSpan(slot: Int = 0) -> ClosedRange<Date>? {
        let leaves = tasks.filter { !$0.summary }
        guard let s = leaves.compactMap({ $0.baselines[slot]?.start }).min(),
              let f = leaves.compactMap({ $0.baselines[slot]?.finish }).max(), s <= f else { return nil }
        return s...f
    }

    /// Working days the project now finishes after (positive) or before
    /// (negative) its baselined finish.
    public func finishForecastDays(slot: Int = 0) -> Double? {
        guard let span = baselineSpan(slot: slot),
              let finish = tasks.filter({ !$0.summary }).compactMap(\.finish).max() else { return nil }
        return workingDays(from: span.upperBound, to: finish)
    }

    /// The project's % complete as Project rolls it up: each task's progress
    /// weighted by its duration.
    public func percentComplete() -> Double {
        let leaves = tasks.filter { !$0.summary }
        let total = leaves.reduce(0) { $0 + $1.durationDays }
        guard total > 0 else {
            return leaves.isEmpty ? 0 : leaves.reduce(0) { $0 + Double($1.percentComplete) } / Double(leaves.count)
        }
        return leaves.reduce(0) { $0 + $1.durationDays * Double($1.percentComplete) } / total
    }
}

// MARK: - Update Project

extension Project {
    /// Project's Update Project, "update work as complete through" `date`:
    /// every task scheduled to have started by then gets its actual start, and
    /// its % complete from the share of its duration that lies before `date`
    /// (`partial`), or 100% only once it should have finished (`!partial`, "0%
    /// or 100% complete only"). Tasks with progress already ahead are left alone.
    public mutating func updateProgress(through date: Date, partial: Bool = true) {
        let time = workingTimes()
        let summaries = Set(tasks.map(\.parentUID))
        for i in tasks.indices where !summaries.contains(tasks[i].uid) {
            let t = tasks[i]
            guard let s = t.start, let f = t.finish, s < date, t.percentComplete < 100 else { continue }
            let wt = time(t)
            let total = wt.minutes(from: s, to: f)
            let done = f <= date ? 100 : (total == 0 ? 100 : Int((Double(wt.minutes(from: s, to: date)) / Double(total) * 100).rounded(.down)))
            let pct = partial ? done : (done == 100 ? 100 : 0)
            guard pct > t.percentComplete else { continue }
            tasks[i].percentComplete = pct
            if tasks[i].actualStart == nil, pct > 0 { tasks[i].actualStart = s }
            if pct == 100, tasks[i].actualFinish == nil { tasks[i].actualFinish = f }
        }
        statusDate = date
    }

    /// Project's "reschedule uncompleted work to start after" `date`: an
    /// unstarted task that should already have begun is moved to start after
    /// the date, by a Start No Earlier Than constraint, as Project does. Work
    /// under way keeps its start (Project splits it; that is not modelled).
    /// Returns how many tasks moved.
    @discardableResult
    public mutating func rescheduleUncompletedWork(after date: Date) -> Int {
        let summaries = Set(tasks.map(\.parentUID))
        var moved = 0
        for i in tasks.indices where !summaries.contains(tasks[i].uid) {
            let t = tasks[i]
            guard !t.manual, t.percentComplete == 0, t.actualStart == nil, let s = t.start, s < date else { continue }
            tasks[i].constraint = "SNET"
            tasks[i].constraintDate = date
            moved += 1
        }
        statusDate = date
        return moved
    }
}
