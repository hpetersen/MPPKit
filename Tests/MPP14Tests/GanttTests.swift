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
import Foundation
import MPPKit

final class GanttTests: XCTestCase {

    // MARK: - Spatial index

    /// The R-tree must return exactly what a linear scan returns.
    func testSpatialIndexMatchesBruteForce() {
        var rng = SystemRandomNumberGenerator()
        for count in [0, 1, 15, 16, 17, 300, 5_000] {
            var entries: [(Rect, Int)] = []
            for i in 0..<count {
                let x = Double.random(in: 0...100_000, using: &rng), y = Double.random(in: 0...5_000, using: &rng)
                entries.append((Rect(minX: x, minY: y, maxX: x + .random(in: 0...3_000, using: &rng),
                                     maxY: y + .random(in: 0...20, using: &rng)), i))
            }
            let index = SpatialIndex(entries)
            XCTAssertEqual(index.count, count)
            for _ in 0..<50 {
                let x = Double.random(in: -1_000...100_000, using: &rng), y = Double.random(in: -10...5_000, using: &rng)
                let q = Rect(minX: x, minY: y, maxX: x + .random(in: 0...20_000, using: &rng),
                             maxY: y + .random(in: 0...60, using: &rng))
                let expected = Set(entries.filter { $0.0.intersects(q) }.map(\.1))
                XCTAssertEqual(Set(index.query(q)), expected, "count \(count)")
            }
        }
    }

    /// Building over 100 000 tasks and querying a screenful must be fast
    /// enough to do on every edit and every frame respectively.
    func testLargeProjectLayoutAndQueryPerformance() throws {
        var p = Project(title: "Big", start: MPPTime.date(2026, 1, 5, 8))
        p.tasks = (1...100_000).map { i in
            var t = ProjectTask(uid: i, name: "Task \(i)")
            t.start = MPPTime.date(2026, 1, 5, 8).addingTimeInterval(Double(i % 2_000) * 86_400)
            t.finish = t.start!.addingTimeInterval(Double(1 + i % 9) * 86_400)
            t.durationDays = Double(1 + i % 9)
            return t
        }
        p.relations = (1..<100_000).filter { $0 % 3 == 0 }.map { Relation(predUID: $0, succUID: $0 + 1) }
        let t0 = Date()
        let layout = GanttLayout(project: p)
        let built = Date().timeIntervalSince(t0)
        XCTAssertEqual(layout.rows.count, 100_000)
        let t1 = Date()
        var hits = 0
        for k in 0..<1_000 {
            let y = Double(k * 97 % 99_950)
            hits += layout.index.query(Rect(minX: 0, minY: y, maxX: 60 * 1_440, maxY: y + 50)).count
        }
        let perQuery = Date().timeIntervalSince(t1) / 1_000
        XCTAssertGreaterThan(hits, 0)
        XCTAssertLessThan(built, 10, "layout build took \(built)s")
        XCTAssertLessThan(perQuery, 0.002, "a screen query took \(perQuery * 1_000) ms")
        print("100k tasks: layout \(String(format: "%.0f", built * 1_000)) ms, query \(String(format: "%.3f", perQuery * 1_000)) ms")
    }

    // MARK: - Layout

    func testLayoutOfSampleProject() {
        let p = SampleProject.make()
        let layout = GanttLayout(project: p)
        XCTAssertEqual(layout.rows.map(\.uid), p.tasks.map(\.uid))
        let byUID = Dictionary(uniqueKeysWithValues: layout.rows.map { ($0.uid, $0) })
        XCTAssertEqual(byUID[1]?.kind, .summary)
        XCTAssertEqual(byUID[3]?.kind, .milestone)
        XCTAssertEqual(byUID[34]?.kind, .milestone, "a flagged milestone with a duration")
        XCTAssertEqual(byUID[5]?.progress ?? 0, 0.6, accuracy: 1e-9)
        XCTAssertTrue(byUID[19]?.isCritical == true, "Integration testing is on the critical path")
        XCTAssertFalse(byUID[13]?.isCritical == true, "Backend has slack")
        XCTAssertEqual(layout.links.count, p.relations.count)
        // Weekends and holidays are shaded: 1 January 2026 is a Thursday holiday.
        let newYear = layout.x(MPPTime.date(2026, 1, 1))
        XCTAssertTrue(layout.nonWorking.contains { $0.contains(newYear + 600) })
        let monday = layout.x(MPPTime.date(2026, 1, 5))
        XCTAssertFalse(layout.nonWorking.contains { $0.contains(monday + 600) })
        // Past the plan's range the ordinary week carries on, so the bands
        // fill a chart scrolled or zoomed out beyond it.
        // A Monday a month past the end (the epoch is a Monday).
        let beyond = ((layout.nonWorkingEnd / 1_440 / 7).rounded(.up) + 4) * 7 * 1_440
        let far = layout.nonWorking(in: beyond..<(beyond + 14 * 1_440))
        XCTAssertEqual(far.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }, 4 * 1_440, accuracy: 1e-6,
                       "two weekends in any fortnight")
        for span in far {
            let weekday = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(secondsFromGMT: 0)!,
                from: layout.epoch.addingTimeInterval(span.lowerBound * 60 + 600)).weekday!
            XCTAssertEqual(weekday, 7, "a weekend starts on a Saturday")
        }
        XCTAssertEqual(layout.nonWorking(in: 0..<layout.nonWorkingEnd), layout.nonWorking)
        // And before the plan, for a chart panned past its start.
        let before = layout.nonWorking(in: (-28 * 1_440)..<(-14 * 1_440))
        XCTAssertEqual(before.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }, 4 * 1_440, accuracy: 1e-6)
        XCTAssertEqual(before.first?.lowerBound, -23 * 1_440, "the Saturday three weeks before the epoch")
        // Bars and links are found where they are drawn.
        let backend = byUID[13]!
        let found = layout.index.query(Rect(minX: backend.start + 10, minY: Double(backend.index) + 0.5,
                                            maxX: backend.start + 10, maxY: Double(backend.index) + 0.5))
        XCTAssertTrue(found.contains(.bar(row: backend.index)))
    }

    func testCollapsingHidesChildrenAndRedirectsLinks() {
        let p = SampleProject.make()
        let layout = GanttLayout(project: p, collapsed: [4])           // Design
        XCTAssertFalse(layout.rows.contains { [5, 6, 7, 8, 9, 10, 11, 12].contains($0.uid) })
        XCTAssertTrue(layout.rows.first { $0.uid == 4 }?.isCollapsed == true)
        // Design review -> Backend now starts from the collapsed Design row.
        let design = layout.rowOfTask[4]!, backend = layout.rowOfTask[13]!
        XCTAssertTrue(layout.links.contains { $0.predRow == design && $0.succRow == backend })
    }

    // MARK: - Timescale

    func testTimescaleTiersFollowZoom() {
        let epoch = MPPTime.date(2025, 12, 29)                         // a Monday
        func scale(_ perDay: Double, days: Double) -> Timescale {
            Timescale(epoch: epoch, visible: 0..<(days * 1_440), pointsPerMinute: perDay / 1_440,
                      locale: Locale(identifier: "en_US"))
        }
        let days = scale(80, days: 14)
        XCTAssertEqual(days.minor, .day)
        XCTAssertEqual(days.bottom.count, 14)
        XCTAssertEqual(days.top.first?.x, 0, "weeks start on Monday")
        let weeks = scale(20, days: 60)
        XCTAssertEqual(weeks.minor, .week)
        XCTAssertTrue(weeks.top.contains { $0.label.contains("January 2026") }, "\(weeks.top.map(\.label))")
        let months = scale(4, days: 400)
        XCTAssertEqual(months.minor, .month)
        XCTAssertTrue(months.bottom.contains { $0.label == "Jan" })
        let quarters = scale(1, days: 800)
        XCTAssertEqual(quarters.minor, .quarter)
        XCTAssertTrue(quarters.bottom.contains { $0.label == "Q1" })
    }

    // MARK: - Editing

    func testEditingKeepsTheOutlineConsistent() throws {
        var p = SampleProject.make()
        let count = p.tasks.count

        let new = p.insertTask(after: 9, name: "Inserted")          // after the Interfaces subtree
        XCTAssertEqual(p.tasks.count, count + 1)
        let i = p.tasks.firstIndex { $0.uid == new }!
        XCTAssertEqual(p.tasks[i - 1].uid, 11, "after Interfaces' last child")
        XCTAssertEqual(p.tasks[i].outlineLevel, 3)
        XCTAssertEqual(p.tasks[i].parentUID, 6)

        XCTAssertTrue(p.indent(new))
        XCTAssertEqual(p.task(uid: new)?.parentUID, 9)
        XCTAssertTrue(p.outdent(new))
        XCTAssertEqual(p.task(uid: new)?.parentUID, 6)
        XCTAssertFalse(p.indent(1), "the first task has nothing above it")

        XCTAssertTrue(p.link(new, 12))
        XCTAssertFalse(p.link(12, 7), "would close a cycle: 7 → … → 12")
        XCTAssertFalse(p.link(6, 7), "a summary cannot link to its own child")

        p.deleteTask(6)                                              // Detailed design and its subtree
        XCTAssertNil(p.task(uid: 7))
        XCTAssertNil(p.task(uid: new))
        XCTAssertFalse(p.relations.contains { [6, 7, 8, 9, 10, 11, new].contains($0.predUID) || [6, 7, 8, 9, 10, 11, new].contains($0.succUID) })
        XCTAssertFalse(p.assignments.contains { $0.taskUID == 7 })
        XCTAssertEqual(p.tasks.map(\.rowID), Array(1...p.tasks.count))

        try Scheduler.schedule(&p)
        let writer = try? MPP14Writer(template: [UInt8](try Data(contentsOf: Fixture.url())))
        if let writer { XCTAssertNoThrow(try writer.build(p), "an edited project must still write") }
    }

    func testMovingABarConstrainsAutoTasksAndMovesManualOnes() throws {
        var p = SampleProject.make()
        let target = MPPTime.date(2026, 3, 2, 8)
        p.moveTask(21, toStart: target)                              // Smoke test, automatic
        try Scheduler.schedule(&p)
        XCTAssertEqual(p.task(uid: 21)?.constraint, "SNET")
        XCTAssertGreaterThanOrEqual(p.task(uid: 21)!.start!, target)

        let manual = p.task(uid: 18)!
        p.moveTask(18, toStart: target)
        XCTAssertEqual(p.task(uid: 18)?.start, target)
        XCTAssertEqual(p.task(uid: 18)!.finish!.timeIntervalSince(target),
                       manual.finish!.timeIntervalSince(manual.start!))
    }

    func testStartedTasksKeepTheirActualStart() throws {
        var p = SampleProject.make()
        let backend = p.task(uid: 13)!
        XCTAssertEqual(backend.actualStart, backend.start)
        // Removing Backend's constraint must not move work that has begun.
        let i = p.tasks.firstIndex { $0.uid == 13 }!
        p.tasks[i].constraint = nil
        try Scheduler.schedule(&p)
        XCTAssertEqual(p.task(uid: 13)?.start, backend.actualStart)
    }
}
