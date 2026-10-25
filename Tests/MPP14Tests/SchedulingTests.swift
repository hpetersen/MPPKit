// MPPKit: Microsoft Project (.mpp) files in Swift
// Copyright (C) 2026 Henrik Petersen
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 3 as published
// by the Free Software Foundation. It is distributed WITHOUT ANY WARRANTY;
// see the LICENSE file for details. https://mppstudio.com
//
// SPDX-License-Identifier: GPL-3.0-only

import XCTest
@testable import MPP14
import MPPModel
import MPPKit

/// The scheduler against Microsoft Project itself, and the rules that make it
/// agree: working-time float, progress, deadlines, elapsed time, lag units,
/// calendars with changed working hours, and the graph used for link checks.
final class SchedulingTests: XCTestCase {
    private func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        MPPTime.date(y, m, day, h, min)
    }

    /// A Monday-to-Friday 08:00–12:00, 13:00–17:00 project starting Monday 5 Jan 2026.
    private func plan(_ tasks: [ProjectTask], _ relations: [Relation] = []) -> Project {
        var p = Project(title: "T", start: d(2026, 1, 5, 8))
        p.calendar = ProjectCalendar(name: "Standard")
        p.tasks = tasks
        for i in p.tasks.indices { p.tasks[i].rowID = i + 1 }
        p.relations = relations
        return p
    }

    private func task(_ uid: Int, _ days: Double, _ configure: (inout ProjectTask) -> Void = { _ in }) -> ProjectTask {
        var t = ProjectTask(uid: uid, name: "Task \(uid)")
        t.durationDays = days
        configure(&t)
        return t
    }

    // MARK: Against Project's saved results

    /// Every Project-saved file in `Fixtures/`, and any listed one per line in
    /// `MPPKIT_REFERENCE_LIST`: rescheduled with MPPKit, its dates and critical
    /// path must be the ones Project saved. Late dates are reported, not
    /// asserted — the few remaining differences there are listed in the README.
    func testScheduleMatchesProjectOnSavedFiles() throws {
        var files: [URL] = []
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = root.appendingPathComponent("Fixtures")
        files += ((try? FileManager.default.contentsOfDirectory(at: fixtures, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "mpp" }
        if let list = ProcessInfo.processInfo.environment["MPPKIT_REFERENCE_LIST"],
           let text = try? String(contentsOfFile: list, encoding: .utf8) {
            files += text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
        }
        guard !files.isEmpty else { throw XCTSkip("no Project-saved .mpp in Fixtures/ or MPPKIT_REFERENCE_LIST") }
        for url in files {
            let stored = try MPP14File(path: url.path).readProject()
            var mine = stored
            try Scheduler.schedule(&mine)
            let time = stored.workingTimes()
            var moved = 0, late = 0
            for (a, b) in zip(stored.tasks, mine.tasks) where !a.summary {
                let t = time(a)
                func off(_ x: Date?, _ y: Date?) -> Bool { x.flatMap { x in y.map { t.signedMinutes(from: x, to: $0) != 0 } } ?? false }
                if off(a.start, b.start) || off(a.finish, b.finish) { moved += 1 }
                if off(a.lateStart, b.lateStart) || off(a.lateFinish, b.lateFinish) { late += 1 }
            }
            let name = url.lastPathComponent
            print("\(name): \(moved) dates and \(late) late dates differ from Project")
            XCTAssertEqual(stored.criticalUIDs(), mine.criticalUIDs(), "critical path differs from Project's in \(name)")
            XCTAssertEqual(moved, 0, "\(moved) tasks' dates differ from Project's in \(name)")
        }
    }

    // MARK: Float and the critical path

    func testFloatIsWorkingTimeSoAWeekendIsNotFloat() {
        // A milestone finishing Friday 17:00 feeding a task that starts Monday
        // 08:00: 63 hours apart, no working time — critical.
        var p = plan([task(1, 5), task(2, 0), task(3, 2)],
                     [Relation(predUID: 1, succUID: 2), Relation(predUID: 2, succUID: 3)])
        try! Scheduler.schedule(&p)
        XCTAssertEqual(p.totalFloatMinutes(uid: 2), 0)
        XCTAssertEqual(p.criticalUIDs(), [1, 2, 3])
    }

    func testDeadlineCapsLateFinishAndGivesNegativeFloat() {
        // 10 days of work, due after 8: two days late, and critical.
        var p = plan([task(1, 10) { $0.deadline = self.d(2026, 1, 14, 17) }])
        try! Scheduler.schedule(&p)
        XCTAssertEqual(p.task(uid: 1)?.lateFinish, d(2026, 1, 14, 17))
        XCTAssertEqual(p.totalFloatMinutes(uid: 1), -2 * 480)
        XCTAssertTrue(p.isCritical(uid: 1))
    }

    func testProgressFollowsProject() {
        // Done work has no float and holds nothing back; work under way has its
        // late start at its start, and its float at the finish.
        var p = plan([task(1, 5) { $0.percentComplete = 100; $0.actualStart = self.d(2026, 1, 5, 8) },
                      task(2, 5) { $0.percentComplete = 40; $0.actualStart = self.d(2026, 1, 12, 8) },
                      task(3, 20)],
                     [Relation(predUID: 1, succUID: 2)])
        try! Scheduler.schedule(&p)
        let done = p.task(uid: 1)!, going = p.task(uid: 2)!
        XCTAssertEqual(done.lateStart, done.start)
        XCTAssertEqual(done.lateFinish, done.finish)
        XCTAssertFalse(p.isCritical(uid: 1))
        XCTAssertEqual(going.lateStart, going.start)
        XCTAssertGreaterThan(going.lateFinish!, going.finish!)
    }

    func testManualTaskGetsLateDates() {
        var p = plan([task(1, 2) { $0.manual = true; $0.start = self.d(2026, 1, 5, 8); $0.finish = self.d(2026, 1, 6, 17) },
                      task(2, 10)])
        try! Scheduler.schedule(&p)
        XCTAssertEqual(p.task(uid: 1)?.start, d(2026, 1, 5, 8))
        XCTAssertEqual(p.task(uid: 1)?.lateFinish, p.task(uid: 2)?.finish)
        XCTAssertFalse(p.isCritical(uid: 1))
    }

    // MARK: Units

    func testElapsedDurationRunsRoundTheClock() {
        // 3 elapsed days from Friday 08:00 end Monday 08:00, weekend included.
        var p = plan([task(1, 3 * 1_440 / 480.0) { $0.durationUnits = "ed"; $0.constraint = "SNET"; $0.constraintDate = self.d(2026, 1, 9, 8) }])
        try! Scheduler.schedule(&p)
        XCTAssertEqual(p.task(uid: 1)?.finish, d(2026, 1, 12, 8))
    }

    func testLagUnits() {
        // FS + 50% of a 4-day predecessor = 2 working days; FS + 2 elapsed days
        // from Friday 17:00 = Sunday 17:00, so the next working moment, Monday.
        var p = plan([task(1, 4), task(2, 1), task(3, 5), task(4, 1)],
                     [Relation(predUID: 1, succUID: 2, lagDays: 0.5, lagUnits: "%"),
                      Relation(predUID: 3, succUID: 4, lagDays: 2 * 1_440 / 480.0, lagUnits: "ed")])
        try! Scheduler.schedule(&p)
        XCTAssertEqual(p.task(uid: 2)?.start, d(2026, 1, 13, 8))
        XCTAssertEqual(p.task(uid: 4)?.start, d(2026, 1, 12, 8))
    }

    func testRelationLagUnitsRoundTripThroughTheWriter() throws {
        let template = try MPP14Template.neutralized(Fixture.bytes())
        var p = SampleProject.make()
        p.relations[0].lagUnits = "%"
        p.relations[0].lagDays = 0.25
        let bytes = try MPP14Writer(template: template).build(p)
        let back = try MPP14File(bytes: bytes).readProject()
        let r = back.relations.first { $0.predUID == p.relations[0].predUID && $0.succUID == p.relations[0].succUID }
        XCTAssertEqual(r?.lagUnits, "%")
        XCTAssertEqual(r?.lagDays ?? 0, 0.25, accuracy: 0.0001)
    }

    // MARK: Calendars

    func testWorkingExceptionAddsWorkingTime() {
        // A working Saturday (08:00–12:00) shortens a 3-day task started Thursday.
        var p = plan([task(1, 3) { $0.constraint = "SNET"; $0.constraintDate = self.d(2026, 1, 8, 8) }])
        p.calendar?.exceptions = [CalendarException(start: d(2026, 1, 10), name: "Saturday shift", working: [480...720])]
        try! Scheduler.schedule(&p)
        // Thu 8h + Fri 8h + Sat 4h + Mon 4h.
        XCTAssertEqual(p.task(uid: 1)?.finish, d(2026, 1, 12, 12))
    }

    func testWorkingExceptionRoundTripsThroughCalendarData() {
        let x = CalendarException(start: d(2026, 8, 30), name: "Sunday", working: [480...720, 780...1_020])
        let blob = CalendarData.build(week: [:], exceptions: [x])
        XCTAssertEqual(CalendarData.parse(blob).exceptions, [x])
    }

    // MARK: Reading

    func testFixedDataRecordsOutOfOrder() {
        // Project rewrites an edited record at the end of FixedData and leaves
        // the meta in row order: the middle record must still be found.
        func item(_ offset: UInt32) -> [UInt8] { [0, 0, 0, 0] + withUnsafeBytes(of: offset.littleEndian, Array.init) }
        let data: [UInt8] = Array(repeating: 1, count: 4) + Array(repeating: 3, count: 4) + Array(repeating: 2, count: 6)
        let recs = MPP.splitFixedData(data, metaItems: [item(0), item(8), item(4)])
        XCTAssertEqual(recs, [[1, 1, 1, 1], [2, 2, 2, 2, 2, 2], [3, 3, 3, 3]])
    }

    // MARK: Link checks

    func testDependencyGraphFindsLoopsThroughPhases() {
        // Phase 10 holds 11 and 12; 11 → 20; linking 20 → phase 10 would make
        // 11 wait for itself.
        var p = plan([task(10, 1), task(11, 1) { $0.parentUID = 10; $0.outlineLevel = 2 },
                      task(12, 1) { $0.parentUID = 10; $0.outlineLevel = 2 }, task(20, 1)],
                     [Relation(predUID: 11, succUID: 20)])
        p.tasks[0].outlineLevel = 1
        let g = DependencyGraph(p)
        XCTAssertTrue(g.wouldLoop(pred: 20, succ: 10))
        XCTAssertTrue(g.wouldLoop(pred: 20, succ: 11))
        XCTAssertFalse(g.wouldLoop(pred: 20, succ: 12))   // 12 leads nowhere near 20
        XCTAssertFalse(g.wouldLoop(pred: 12, succ: 20))
        XCTAssertTrue(g.reaches(from: 11, to: 20))
        XCTAssertTrue(g.reaches(from: 11, to: 10))   // the phase waits for its tasks
        // In one search, the same answers as asking `wouldLoop` of each.
        for succ in [10, 11, 12, 20] {
            let looping = g.loopingPredecessors(of: succ)
            for pred in [10, 11, 12, 20] where pred != succ {
                XCTAssertEqual(looping.contains(pred), g.wouldLoop(pred: pred, succ: succ), "\(pred) → \(succ)")
            }
        }
        XCTAssertTrue(g.loopingPredecessors(of: 11).contains(10))   // its own phase
    }

    // MARK: Edits that must not move dates

    func testTextEditsAreNotSchedulingInputs() {
        let p = plan([task(1, 2), task(2, 3)], [Relation(predUID: 1, succUID: 2)])
        var renamed = p
        renamed.tasks[0].name = "Renamed"
        renamed.tasks[1].notes = "A note"
        renamed.tasks[1].text[1] = "Level 3"
        renamed.fieldAliases["Text1"] = "Area"
        XCTAssertTrue(renamed.hasSameSchedulingInputs(as: p))
        var longer = p
        longer.tasks[0].durationDays = 4
        XCTAssertFalse(longer.hasSameSchedulingInputs(as: p))
    }
}
