// MPPKit: Microsoft Project (.mpp) files in Swift
// Copyright (C) 2026 Henrik Petersen
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 3 as published
// by the Free Software Foundation. It is distributed WITHOUT ANY WARRANTY;
// see the LICENSE file for details. https://mppstudio.com
//
// SPDX-License-Identifier: GPL-3.0-only

#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif
import MPPModel

/// The geometry of a Gantt chart, independent of how it is drawn.
///
/// World coordinates: **x is minutes** since `epoch` (a wall-clock Monday
/// before the project starts), **y is the row index**. A renderer maps these
/// to points with a zoom (points per minute) and a row height, which is why
/// nothing here depends on zoom: the layout and its spatial index are built
/// once per edit, not per frame.
public struct GanttLayout: Sendable {
    public enum Kind: UInt8, Sendable {
        case task, summary, milestone, projectSummary
    }

    public struct Row: Sendable, Identifiable {
        public var id: Int { uid }
        public let uid: Int
        /// Position in `rows`, which is the visual row.
        public let index: Int
        public let level: Int
        public let name: String
        public let kind: Kind
        public let start: Double
        public let finish: Double
        /// 0...1.
        public let progress: Double
        public let isCritical: Bool
        public let isManual: Bool
        public let hasChildren: Bool
        public let isCollapsed: Bool
        public let baselineStart: Double?
        public let baselineFinish: Double?
        public let deadline: Double?
    }

    public struct Link: Sendable {
        public let predRow: Int
        public let succRow: Int
        public let type: String
        /// The anchor on the predecessor (its start for SS/SF, else finish)
        /// and on the successor (its finish for FF/SF, else start).
        public let fromX: Double
        public let toX: Double
    }

    /// Spatial index payloads.
    public enum Item: Sendable, Equatable {
        case bar(row: Int)
        case link(Int)
    }

    public let epoch: Date
    public let rows: [Row]
    public let links: [Link]
    /// Whole non-working days (weekends, holidays) of the project calendar
    /// over the chart's range, as world x ranges.
    public let nonWorking: [Range<Double>]
    /// Where `nonWorking` stops. Past it the chart can still be scrolled or
    /// zoomed out to, and there the calendar's ordinary week carries on.
    public let nonWorkingEnd: Double
    /// The ordinary week, from the epoch's Monday: whether each of its seven
    /// days is off.
    public let weekOff: [Bool]
    /// The chart's horizontal extent: the project with a margin.
    public let range: Range<Double>
    public let index: SpatialIndex<Item>
    /// uid -> row.
    public let rowOfTask: [Int: Int]

    /// The non-working days overlapping `visible`: the plan's own (holidays
    /// included) over its range, and the ordinary week before and after it, so
    /// the bands reach every edge the chart can show.
    public func nonWorking(in visible: Range<Double>) -> [Range<Double>] {
        var out: [Range<Double>] = []
        let day = 1_440.0
        // The ordinary week, from day `first` (counted from the epoch) to `to`.
        func week(from first: Int, to: Double) {
            guard weekOff.contains(true) else { return }
            var k = first
            while Double(k) * day < to {
                let a = Double(k) * day
                if weekOff[((k % 7) + 7) % 7] {
                    if let last = out.last, last.upperBound == a {
                        out[out.count - 1] = last.lowerBound..<(a + day)
                    } else {
                        out.append(a..<(a + day))
                    }
                }
                k += 1
            }
        }
        let firstDay = Int((visible.lowerBound / day).rounded(.down))
        week(from: firstDay, to: min(visible.upperBound, 0))
        var lo = 0, hi = nonWorking.count
        while lo < hi { let m = (lo + hi) / 2; if nonWorking[m].upperBound < visible.lowerBound { lo = m + 1 } else { hi = m } }
        var i = lo
        while i < nonWorking.count, nonWorking[i].lowerBound < visible.upperBound {
            if let last = out.last, last.upperBound == nonWorking[i].lowerBound {
                out[out.count - 1] = last.lowerBound..<nonWorking[i].upperBound
            } else {
                out.append(nonWorking[i])
            }
            i += 1
        }
        week(from: max(firstDay, Int((nonWorkingEnd / day).rounded(.up))), to: visible.upperBound)
        return out
    }

    /// - Parameters:
    ///   - collapsed: summary uids whose children are hidden.
    ///   - focus: a task or phase to show on its own. `nil` — or a uid that is
    ///     not in the project — shows everything, and `0` is the project row.
    ///   - showProjectSummary: include the project summary as row 0. Ignored when
    ///     `focus` is set, because a focus *is* a summary of what it contains.
    public init(project: Project, collapsed: Set<Int> = [], focus: Int? = nil,
                showProjectSummary: Bool = false) {
        // What is on screen. Focusing a phase is a *filter*, and it has to happen
        // here rather than in the view: the chart's range, its row count, its
        // links and its hit testing all derive from this one list, and filtering
        // anywhere else would let them disagree — a lane whose labels name one
        // phase while its bars draw another.
        let focusSet = focus.flatMap { f in f == 0 ? nil : Self.subtree(project, of: f) }
        let tasks = focusSet.map { set in project.tasks.filter { set.contains($0.uid) } } ?? project.tasks
        let showsProjectRow = showProjectSummary || focus != nil

        let first = tasks.compactMap(\.start).min() ?? project.start
        let last = tasks.compactMap(\.finish).max() ?? first
        let epoch = Self.monday(MPPTime.adding(days: -14, to: first))
        self.epoch = epoch
        func x(_ d: Date?) -> Double? { d.map { $0.timeIntervalSince(epoch) / 60 } }

        // Visible rows: outline order, skipping descendants of collapsed rows.
        let parents = Set(tasks.map(\.parentUID))
        var rows: [Row] = []
        var hiddenBelow: Int? = nil
        let critical = Self.criticalTasks(project)
        if showsProjectRow, let s = x(first), let f = x(last) {
            // Row 0 is the whole plan, and it is named after whatever is being
            // shown: the project's own title, or the focused phase's.
            let title = focus.flatMap { $0 == 0 ? nil : project.task(uid: $0)?.name } ?? project.title
            rows.append(Row(uid: 0, index: 0, level: 0, name: title, kind: .projectSummary,
                            start: s, finish: f, progress: Self.progress(of: tasks), isCritical: false,
                            isManual: false, hasChildren: !tasks.isEmpty, isCollapsed: false,
                            baselineStart: nil, baselineFinish: nil, deadline: nil))
        }
        for t in tasks {
            if let h = hiddenBelow {
                if t.outlineLevel > h { continue }
                hiddenBelow = nil
            }
            guard let s = x(t.start), let f = x(t.finish) else { continue }
            let hasChildren = parents.contains(t.uid)
            let isCollapsed = hasChildren && collapsed.contains(t.uid)
            if isCollapsed { hiddenBelow = t.outlineLevel }
            let kind: Kind = hasChildren ? .summary : ((t.durationDays == 0 || t.milestone) ? .milestone : .task)
            rows.append(Row(uid: t.uid, index: rows.count, level: t.outlineLevel, name: t.name, kind: kind,
                            start: s, finish: f, progress: Double(t.percentComplete) / 100,
                            isCritical: critical.contains(t.uid), isManual: t.manual,
                            hasChildren: hasChildren, isCollapsed: isCollapsed,
                            baselineStart: x(t.baselines[0]?.start), baselineFinish: x(t.baselines[0]?.finish),
                            deadline: x(t.deadline)))
        }
        self.rows = rows
        var rowOfTask: [Int: Int] = [:]
        for r in rows { rowOfTask[r.uid] = r.index }
        self.rowOfTask = rowOfTask

        // Links between visible rows. A link into a collapsed subtree attaches
        // to the visible summary that hides it.
        var visibleAncestor: [Int: Int] = [:]
        do {
            var stack: [(uid: Int, level: Int)] = []
            for t in project.tasks {
                while let top = stack.last, top.level >= t.outlineLevel { stack.removeLast() }
                visibleAncestor[t.uid] = rowOfTask[t.uid] ?? stack.reversed().first { rowOfTask[$0.uid] != nil }.flatMap { rowOfTask[$0.uid] }
                stack.append((t.uid, t.outlineLevel))
            }
        }
        var links: [Link] = []
        for rel in project.relations {
            guard let p = visibleAncestor[rel.predUID], let s = visibleAncestor[rel.succUID], p != s else { continue }
            let pr = rows[p], sr = rows[s]
            let fromX = (rel.type == "SS" || rel.type == "SF") ? pr.start : pr.finish
            let toX = (rel.type == "FF" || rel.type == "SF") ? sr.finish : sr.start
            links.append(Link(predRow: p, succRow: s, type: rel.type, fromX: fromX, toX: toX))
        }
        self.links = links

        // Chart range and non-working days.
        let lo = 0.0
        let hi = (x(MPPTime.adding(days: 28, to: last)) ?? 0)
        self.range = lo..<max(hi, lo + 7 * 1_440)
        let time = WorkingTime(calendar: project.calendar)
        var spans: [Range<Double>] = []
        var day = epoch
        let end = MPPTime.adding(days: 28, to: last)
        while day < end {
            if time.ranges(on: day).isEmpty {
                let a = day.timeIntervalSince(epoch) / 60
                if let lastSpan = spans.last, lastSpan.upperBound == a {
                    spans[spans.count - 1] = lastSpan.lowerBound..<(a + 1_440)
                } else {
                    spans.append(a..<(a + 1_440))
                }
            }
            day = MPPTime.adding(days: 1, to: day)
        }
        self.nonWorking = spans
        self.nonWorkingEnd = end.timeIntervalSince(epoch) / 60
        // Day k after a Monday is Project's weekday (k + 1) % 7 + 1 (1 is Sunday).
        self.weekOff = (0..<7).map { (project.calendar ?? ProjectCalendar()).workingRanges(weekday: ($0 + 1) % 7 + 1).isEmpty }

        // Spatial index over everything drawn in the chart body.
        var entries: [(Rect, Item)] = []
        entries.reserveCapacity(rows.count + links.count)
        for r in rows {
            let pad = r.kind == .milestone ? 1_440.0 * 0.5 : 0      // a diamond is wider than a 0-minute bar
            // The baseline's dates too: the float drawn from them sits beside the bar.
            let lo = [r.start, r.finish, r.baselineStart, r.baselineFinish].compactMap { $0 }.min()!
            let hi = [r.start, r.finish, r.baselineStart, r.baselineFinish].compactMap { $0 }.max()!
            entries.append((Rect(minX: lo - pad, minY: Double(r.index),
                                 maxX: hi + pad, maxY: Double(r.index + 1)), .bar(row: r.index)))
        }
        for (i, l) in links.enumerated() {
            entries.append((Rect(minX: min(l.fromX, l.toX) - 1_440, minY: Double(min(l.predRow, l.succRow)),
                                 maxX: max(l.fromX, l.toX) + 1_440, maxY: Double(max(l.predRow, l.succRow) + 1)),
                            .link(i)))
        }
        self.index = SpatialIndex(entries)
    }

    public func x(_ date: Date) -> Double { date.timeIntervalSince(epoch) / 60 }
    public func date(_ x: Double) -> Date { epoch.addingTimeInterval(x * 60) }

    /// A task together with everything beneath it.
    ///
    /// Guarded against a malformed outline that points at itself, because a file
    /// with a cycle in its parent links would otherwise hang the app on open
    /// rather than showing it wrongly — and a wrong chart is recoverable.
    public static func subtree(_ project: Project, of uid: Int) -> Set<Int> {
        var out: Set<Int> = [uid]
        var frontier = [uid]
        var guardCount = 0
        while !frontier.isEmpty, guardCount < 10_000 {
            let next = project.tasks.filter { frontier.contains($0.parentUID) }.map(\.uid)
            let fresh = next.filter { !out.contains($0) }
            guard !fresh.isEmpty else { break }
            out.formUnion(fresh)
            frontier = fresh
            guardCount += fresh.count
        }
        return out
    }

    /// Duration-weighted progress over a set of tasks.
    ///
    /// Weighted by duration rather than by count, so a two-day task and a
    /// two-month one do not count the same — the figure is meant to answer "how
    /// far through the work are we", and counting tasks answers a different
    /// question.
    public static func progress(of tasks: [ProjectTask]) -> Double {
        let parents = Set(tasks.map(\.parentUID))
        let leaves = tasks.filter { !parents.contains($0.uid) }
        let total = leaves.reduce(0) { $0 + $1.durationDays }
        guard total > 0 else { return 0 }
        return leaves.reduce(0) { $0 + $1.durationDays * Double($1.percentComplete) / 100 } / total
    }

    /// Tasks whose total float, in working time, is at or below the
    /// project's threshold — negative float included.
    static func criticalTasks(_ project: Project) -> Set<Int> { project.criticalUIDs() }

    static func projectProgress(_ project: Project) -> Double {
        let leaves = project.tasks.filter { t in !project.tasks.contains { $0.parentUID == t.uid } }
        let total = leaves.reduce(0) { $0 + $1.durationDays }
        guard total > 0 else { return 0 }
        return leaves.reduce(0) { $0 + $1.durationDays * Double($1.percentComplete) / 100 } / total
    }

    static func monday(_ d: Date) -> Date {
        MPPTime.adding(days: -((MPPTime.weekday(d) + 5) % 7), to: MPPTime.startOfDay(d))
    }
}
