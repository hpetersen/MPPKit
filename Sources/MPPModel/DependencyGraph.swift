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

/// The scheduler's dependency graph, built once and searched many times.
///
/// Two kinds of node per task: the task itself, and "work under it" — what a
/// link onto it binds. A link onto a phase binds every task beneath, so the
/// phase's "under" node fans out to its children's; a phase waits for its
/// children, so each task points up to its parent. Building it is linear in
/// tasks plus links, where expanding every link to every pair of tasks under
/// two phases grew with the product of their sizes.
public struct DependencyGraph: Sendable {
    /// Node `2i` is task `i`; node `2i + 1` is the work under task `i`.
    private let edges: [[Int32]]
    private let index: [Int: Int]

    public init(_ project: Project) {
        let tasks = project.tasks
        var index: [Int: Int] = [:]
        index.reserveCapacity(tasks.count)
        for (i, t) in tasks.enumerated() { index[t.uid] = i }
        var edges = [[Int32]](repeating: [], count: tasks.count * 2)
        for (i, t) in tasks.enumerated() {
            // Under a task is the task itself; under a phase, its children's work.
            edges[2 * i + 1].append(Int32(2 * i))
            if t.parentUID != 0, let p = index[t.parentUID] {
                edges[2 * i].append(Int32(2 * p))              // the phase waits for it
                edges[2 * p + 1].append(Int32(2 * i + 1))      // a link onto the phase binds it
            }
        }
        for r in project.relations {
            guard let p = index[r.predUID], let s = index[r.succUID] else { continue }
            edges[2 * p].append(Int32(2 * s + 1))
        }
        self.edges = edges
        self.index = index
    }

    /// Whether `to` depends, directly or not, on `from`.
    public func reaches(from: Int, to: Int) -> Bool {
        guard let a = index[from], let b = index[to] else { return false }
        return search(from: [2 * a], target: 2 * b)
    }

    /// Whether linking `pred` → `succ` would close a loop: something bound by
    /// the new link already leads back to `pred`.
    public func wouldLoop(pred: Int, succ: Int) -> Bool {
        guard let p = index[pred], let s = index[succ] else { return false }
        return search(from: [2 * s + 1], target: 2 * p)
    }

    /// Every task that linking it as a predecessor of `succ` would loop
    /// back to: all that the work bound by such a link already leads to. One
    /// search, for offering only the valid choices in a list.
    public func loopingPredecessors(of succ: Int) -> Set<Int> {
        guard let s = index[succ] else { return [] }
        var seen = [Bool](repeating: false, count: edges.count)
        var stack = [2 * s + 1]
        while let u = stack.popLast() {
            if seen[u] { continue }
            seen[u] = true
            for v in edges[u] where !seen[Int(v)] { stack.append(Int(v)) }
        }
        var uids = Set<Int>()
        for (uid, i) in index where seen[2 * i] { uids.insert(uid) }
        return uids
    }

    private func search(from starts: [Int], target: Int) -> Bool {
        var seen = [Bool](repeating: false, count: edges.count)
        var stack = starts
        while let u = stack.popLast() {
            if u == target { return true }
            if seen[u] { continue }
            seen[u] = true
            for v in edges[u] where !seen[Int(v)] { stack.append(Int(v)) }
        }
        return false
    }
}
