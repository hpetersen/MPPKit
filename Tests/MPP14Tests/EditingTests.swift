// MPPKit: Microsoft Project (.mpp) files in Swift
// Copyright (C) 2026 Henrik Petersen
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License version 3 as
// published by the Free Software Foundation. It is distributed WITHOUT ANY
// WARRANTY; see the LICENSE file for details. https://mppstudio.com
//
// SPDX-License-Identifier: AGPL-3.0-only

import XCTest
import MPPModel

/// Editing commands added for working like Project: copy and paste, moving
/// rows, and Update Project.
final class EditingTests: XCTestCase {
    /// Phase A (1: 2, 3) and phase B (4: 5); 2 → 3 linked.
    private func plan() -> Project {
        var p = Project(title: "T", start: MPPTime.date(2026, 1, 5, 8))
        p.calendar = ProjectCalendar(name: "Standard")
        func t(_ uid: Int, _ level: Int) -> ProjectTask {
            var x = ProjectTask(uid: uid, name: "T\(uid)"); x.outlineLevel = level; x.durationDays = 2; return x
        }
        p.tasks = [t(1, 1), t(2, 2), t(3, 2), t(4, 1), t(5, 2)]
        p.relations = [Relation(predUID: 2, succUID: 3)]
        p.resources = [Resource(uid: 1, name: "Crew")]
        p.assignments = [Assignment(taskUID: 2, resourceUID: 1)]
        p.normalizeOutline()
        try! Scheduler.schedule(&p)
        return p
    }

    func testCopyPasteKeepsOutlineLinksAndAssignments() {
        var p = plan()
        let fragment = p.fragment([1])
        XCTAssertEqual(fragment.tasks.map(\.uid), [1, 2, 3])
        let new = p.paste(fragment, after: 5)
        XCTAssertEqual(new.count, 3)
        XCTAssertEqual(p.tasks.map(\.outlineLevel), [1, 2, 2, 1, 2, 2, 3, 3])
        XCTAssertTrue(p.relations.contains { $0.predUID == new[1] && $0.succUID == new[2] })
        XCTAssertTrue(p.assignments.contains { $0.taskUID == new[1] && $0.resourceUID == 1 })
        // Round-trips through the pasteboard's JSON.
        XCTAssertEqual(TaskFragment.decode(fragment.encoded()), fragment)
    }

    func testStartBeforeProjectStart() {
        var p = plan()
        let earlier = MPPTime.date(2025, 12, 29, 8)   // the Monday a week before
        p.moveTask(2, toStart: earlier)
        try! Scheduler.schedule(&p)
        XCTAssertEqual(p.task(uid: 2)?.start, earlier)
        XCTAssertEqual(p.task(uid: 1)?.start, earlier)   // its phase follows
        XCTAssertEqual(p.task(uid: 5)?.start, p.start)   // the rest stay put
    }

    func testSetResourcesByName() {
        var p = plan()
        p.setResources([("crew", 0.5), ("Electrician", nil)], of: 3)
        XCTAssertEqual(p.resources.map(\.name), ["Crew", "Electrician"])   // "crew" is the existing Crew
        XCTAssertEqual(p.resources.last?.initials, "E")
        let a = p.assignments.filter { $0.taskUID == 3 }
        XCTAssertEqual(a.map(\.resourceUID), [1, 2])
        XCTAssertEqual(a.map(\.units), [0.5, 1])
        p.setResources([], of: 3)
        XCTAssertTrue(p.assignments.filter { $0.taskUID == 3 }.isEmpty)
        p.setResources([("Crew", nil)], of: 1)                            // a phase takes none
        XCTAssertTrue(p.assignments.filter { $0.taskUID == 1 }.isEmpty)
    }

    func testMoveUpAndDown() {
        var p = plan()
        XCTAssertTrue(p.move([3], up: true))
        XCTAssertEqual(p.tasks.map(\.uid), [1, 3, 2, 4, 5])
        XCTAssertTrue(p.move([1], up: false))      // the phase with its tasks
        XCTAssertEqual(p.tasks.map(\.uid), [4, 5, 1, 3, 2])
        XCTAssertFalse(p.move([4], up: true))      // already first
    }

    func testDragMovesSubtreeToTargetLevel() {
        var p = plan()
        XCTAssertTrue(p.move([5], before: 2))
        XCTAssertEqual(p.tasks.map(\.uid), [1, 5, 2, 3, 4])
        XCTAssertEqual(p.task(uid: 5)?.parentUID, 1)
        XCTAssertFalse(p.move([1], before: 2))     // into its own subtree
    }

    func testUpdateProgressAndReschedule() {
        var p = plan()
        // Status Thursday 8 Jan 17:00: T2 (Mon–Tue) is done, T3 (Wed–Thu) too;
        // T5 (Mon–Tue) also. Nothing is half-way, so check a later start.
        p.updateProgress(through: MPPTime.date(2026, 1, 6, 17))
        XCTAssertEqual(p.task(uid: 2)?.percentComplete, 100)
        XCTAssertEqual(p.task(uid: 3)?.percentComplete, 0)
        XCTAssertEqual(p.statusDate, MPPTime.date(2026, 1, 6, 17))
        p.updateProgress(through: MPPTime.date(2026, 1, 7, 12))
        XCTAssertEqual(p.task(uid: 3)?.percentComplete, 25)   // 4 of 16 hours
        let moved = p.rescheduleUncompletedWork(after: MPPTime.date(2026, 1, 12, 8))
        XCTAssertEqual(moved, 0)   // everything has started
    }
}
