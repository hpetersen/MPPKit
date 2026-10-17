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

/// Resource loading: how much work each person is carrying, week by week.
///
/// This lives in the model rather than in a view because two places need the same
/// answer — the Resources screen draws it, and the schedule's status bar reports
/// how many people are over capacity. A figure that decides whether someone is
/// double-booked must be computed once: two implementations that disagree by a
/// rounding step would put "0 over-allocated" on one screen and a red bar on
/// another, and the user would be right to trust neither.
public extension Project {

    /// How much of a week one person can work, in assignment units.
    ///
    /// A resource at 100% units who works a five-day calendar can absorb 1.0 unit
    /// of concurrent assignment; someone at 50% can absorb 0.5. Their own maximum,
    /// not the project's, so a part-time person is not permanently shown as idle.
    func capacity(of resource: Resource) -> Double {
        max(0.01, resource.maxUnits)
    }

    /// Load per week for one resource, as a multiple of *their own* capacity.
    ///
    /// Weeks are calendar weeks starting from the resource's first assignment, so
    /// the series is comparable between people: 1.0 means full, 1.6 means booked
    /// six tenths beyond what they have.
    func weeklyLoad(of resource: Resource, limit: Int = 260) -> [Double] {
        let assignments = assignments.filter { $0.resourceUID == resource.uid }
        guard !assignments.isEmpty else { return [] }
        let byUID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.uid, $0) })
        let starts = assignments.compactMap { byUID[$0.taskUID]?.start }
        let finishes = assignments.compactMap { byUID[$0.taskUID]?.finish }
        guard let first = starts.min(), let last = finishes.max() else { return [] }

        let calendar = Calendar(identifier: .gregorian)
        var week = calendar.dateInterval(of: .weekOfYear, for: first)?.start ?? first
        var out: [Double] = []
        while week <= last, out.count < limit {
            let end = calendar.date(byAdding: .day, value: 7, to: week) ?? last
            let loaded = assignments.reduce(0.0) { sum, assignment in
                guard let task = byUID[assignment.taskUID],
                      let start = task.start, let finish = task.finish else { return sum }
                let from = max(start, week), to = min(finish, end)
                guard to > from else { return sum }
                // Spread the assignment evenly across its task's span, then take
                // the part of that span falling inside this week.
                let share = to.timeIntervalSince(from) / 7 / 86_400
                return sum + share * assignment.units
            }
            out.append(loaded)
            week = end
        }
        return out
    }

    /// The busiest week for a resource, as a multiple of their capacity.
    func peakLoad(of resource: Resource) -> Double {
        weeklyLoad(of: resource).max() ?? 0
    }

    /// Whether anyone is booked beyond their capacity.
    func isOverAllocated(_ resource: Resource) -> Bool {
        peakLoad(of: resource) > capacity(of: resource) + 0.001
    }

    /// How many people are over-allocated, and by how much at the worst.
    ///
    /// Returns the count and the highest load seen, so a caller can say "2 over
    /// capacity" without recomputing. The count is what belongs on the schedule's
    /// status bar: a plan whose dates are fine and whose people are double-booked
    /// is not a plan that can be executed, and nothing else on that screen says so.
    func allocationSummary() -> (over: Int, peak: Double) {
        guard !resources.isEmpty else { return (0, 0) }
        var over = 0
        var peak = 0.0
        for resource in resources {
            let load = peakLoad(of: resource) / capacity(of: resource)
            peak = max(peak, load)
            if load > 1.001 { over += 1 }
        }
        return (over, peak)
    }
}
