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

// MARK: - Copy and paste of tasks

/// Tasks as they travel between documents: each copied task with its subtree,
/// outline levels counted from 1, the links among them and their assignments,
/// with the resources those name so a paste can match them by name.
public struct TaskFragment: Codable, Equatable, Sendable {
    public var tasks: [ProjectTask]
    public var relations: [Relation]
    public var assignments: [Assignment]
    public var resources: [Resource]
    /// Project days in the source, to carry durations into a document with a
    /// different working day.
    public var minutesPerDay: Int

    public static let pasteboardType = "com.oeskov.mppstudio.tasks"

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }
    public static func decode(_ data: Data) -> TaskFragment? { try? JSONDecoder().decode(TaskFragment.self, from: data) }
}

extension Project {
    /// The tasks `uids` with their subtrees, in row order, ready to paste.
    public func fragment(_ uids: [Int]) -> TaskFragment {
        var keep = Set<Int>()
        for uid in uids { if let span = subtree(of: uid) { for t in tasks[span] { keep.insert(t.uid) } } }
        var picked = tasks.filter { keep.contains($0.uid) }
        let base = (picked.map(\.outlineLevel).min() ?? 1) - 1
        for i in picked.indices {
            picked[i].outlineLevel -= base
            if !keep.contains(picked[i].parentUID) { picked[i].parentUID = 0 }
            // A copy is new work: it has not started, and has no plan of its own yet.
            picked[i].actualStart = nil
            picked[i].actualFinish = nil
            picked[i].percentComplete = 0
            picked[i].baselines = [:]
            picked[i].guid = []
        }
        let rels = relations.filter { keep.contains($0.predUID) && keep.contains($0.succUID) }
        let asg = assignments.filter { keep.contains($0.taskUID) }
        let used = Set(asg.map(\.resourceUID))
        return TaskFragment(tasks: picked, relations: rels, assignments: asg,
                            resources: resources.filter { used.contains($0.uid) }, minutesPerDay: minutesPerDay)
    }

    /// Paste `fragment` below `uid` (after its subtree, at its level), or at
    /// the end. Every task gets a new uid; links among the pasted tasks come
    /// along, and assignments where a resource of the same name exists here.
    /// Returns the new uids in row order.
    @discardableResult
    public mutating func paste(_ fragment: TaskFragment, after uid: Int?) -> [Int] {
        guard !fragment.tasks.isEmpty else { return [] }
        var at = tasks.count, level = 1
        if let uid, let span = subtree(of: uid) {
            at = span.upperBound
            level = tasks[span.lowerBound].outlineLevel
        }
        var next = nextTaskUID
        var map: [Int: Int] = [:]
        var block: [ProjectTask] = []
        let scale = Double(fragment.minutesPerDay) / Double(max(1, minutesPerDay))
        for var t in fragment.tasks {
            map[t.uid] = next
            t.uid = next
            next += 1
            t.outlineLevel += level - 1
            t.durationDays *= scale
            block.append(t)
        }
        tasks.insert(contentsOf: block, at: at)
        for r in fragment.relations {
            guard let p = map[r.predUID], let s = map[r.succUID] else { continue }
            var copy = r
            copy.predUID = p
            copy.succUID = s
            relations.append(copy)
        }
        for a in fragment.assignments {
            guard let t = map[a.taskUID],
                  let name = fragment.resources.first(where: { $0.uid == a.resourceUID })?.name,
                  let here = resources.first(where: { $0.name == name }) else { continue }
            var copy = a
            copy.uid = 0
            copy.taskUID = t
            copy.resourceUID = here.uid
            copy.baselines = [:]
            assignments.append(copy)
        }
        normalizeOutline()
        return block.map(\.uid)
    }

    /// Move each task (with its subtree) one sibling up or down, as Project's
    /// Move Task commands do. Returns false when nothing could move.
    @discardableResult
    public mutating func move(_ uids: [Int], up: Bool) -> Bool {
        var moved = false
        let ordered = up ? uids : uids.reversed()
        for uid in ordered {
            guard let span = subtree(of: uid) else { continue }
            let level = tasks[span.lowerBound].outlineLevel
            if up {
                // The previous sibling's subtree starts at the nearest row above
                // at this level, with nothing shallower in between.
                var i = span.lowerBound - 1
                while i >= 0, tasks[i].outlineLevel > level { i -= 1 }
                guard i >= 0, tasks[i].outlineLevel == level else { continue }
                let block = Array(tasks[span])
                tasks.removeSubrange(span)
                tasks.insert(contentsOf: block, at: i)
            } else {
                guard span.upperBound < tasks.count, tasks[span.upperBound].outlineLevel == level,
                      let sibling = subtree(of: tasks[span.upperBound].uid) else { continue }
                let block = Array(tasks[span])
                let after = sibling.upperBound - span.count
                tasks.removeSubrange(span)
                tasks.insert(contentsOf: block, at: after)
            }
            moved = true
        }
        if moved { normalizeOutline() }
        return moved
    }
}

extension Project {
    /// Drag to reorder: move the tasks `uids` (each with its subtree) to just
    /// above `target`, at its outline level. Refuses a drop onto a task inside
    /// one of the moved subtrees. Returns false when nothing moved.
    @discardableResult
    public mutating func move(_ uids: [Int], before target: Int) -> Bool {
        var moving = Set<Int>()
        var spans: [Range<Int>] = []
        for uid in uids {
            guard !moving.contains(uid), let span = subtree(of: uid) else { continue }
            spans.append(span)
            for t in tasks[span] { moving.insert(t.uid) }
        }
        guard !spans.isEmpty, !moving.contains(target),
              let targetLevel = tasks.first(where: { $0.uid == target })?.outlineLevel else { return false }
        var blocks: [[ProjectTask]] = []
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            var block = Array(tasks[span])
            let shift = targetLevel - block[0].outlineLevel
            for i in block.indices { block[i].outlineLevel += shift }
            blocks.append(block)
        }
        tasks.removeAll { moving.contains($0.uid) }
        guard let at = tasks.firstIndex(where: { $0.uid == target }) else { return false }
        tasks.insert(contentsOf: blocks.flatMap { $0 }, at: at)
        normalizeOutline()
        return true
    }
}
