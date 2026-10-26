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
@testable import MPPModel
import MPP14
import MPPKit

/// Microsoft Project XML: what goes out comes back.
final class MSPDITests: XCTestCase {
    private func assertRoundTrip(_ p: Project, file: StaticString = #filePath, line: UInt = #line) throws {
        let back = try MSPDI.project(from: MSPDI.data(p))
        XCTAssertEqual(back.title, p.title, file: file, line: line)
        XCTAssertEqual(back.tasks.count, p.tasks.count, file: file, line: line)
        for (a, b) in zip(p.tasks, back.tasks) {
            XCTAssertEqual(a.uid, b.uid, file: file, line: line)
            XCTAssertEqual(a.name, b.name, file: file, line: line)
            XCTAssertEqual(a.outlineLevel, b.outlineLevel, "\(a.name)", file: file, line: line)
            XCTAssertEqual(a.parentUID, b.parentUID, "\(a.name)", file: file, line: line)
            XCTAssertEqual(a.start, b.start, "\(a.name)", file: file, line: line)
            XCTAssertEqual(a.finish, b.finish, "\(a.name)", file: file, line: line)
            XCTAssertEqual(a.durationDays, b.durationDays, accuracy: 0.001, "\(a.name)", file: file, line: line)
            XCTAssertEqual(a.durationUnits, b.durationUnits, "\(a.name)", file: file, line: line)
            XCTAssertEqual(a.constraint, b.constraint, "\(a.name)", file: file, line: line)
            XCTAssertEqual(a.constraintDate, b.constraintDate, "\(a.name)", file: file, line: line)
            XCTAssertEqual(a.deadline, b.deadline, "\(a.name)", file: file, line: line)
            XCTAssertEqual(a.percentComplete, b.percentComplete, "\(a.name)", file: file, line: line)
            XCTAssertEqual(a.manual, b.manual, "\(a.name)", file: file, line: line)
            XCTAssertEqual(a.text, b.text, "\(a.name)", file: file, line: line)
            XCTAssertEqual(a.baselines[0]?.start, b.baselines[0]?.start, "\(a.name)", file: file, line: line)
        }
        XCTAssertEqual(Set(p.relations.map { "\($0.predUID)>\($0.succUID) \($0.type) \($0.lagUnits)" }),
                       Set(back.relations.map { "\($0.predUID)>\($0.succUID) \($0.type) \($0.lagUnits)" }), file: file, line: line)
        for (a, b) in zip(p.relations.sorted { ($0.predUID, $0.succUID) < ($1.predUID, $1.succUID) },
                          back.relations.sorted { ($0.predUID, $0.succUID) < ($1.predUID, $1.succUID) }) {
            XCTAssertEqual(a.lagDays, b.lagDays, accuracy: 0.001, file: file, line: line)
        }
        XCTAssertEqual(back.resources.map(\.name), p.resources.map(\.name), file: file, line: line)
        XCTAssertEqual(back.assignments.count, p.assignments.count, file: file, line: line)
        XCTAssertEqual(back.calendar?.exceptions.count, p.calendar?.exceptions.count, file: file, line: line)
        XCTAssertEqual(back.fieldAliases, p.fieldAliases, file: file, line: line)
        // Same plan, same schedule.
        var x = p, y = back
        try Scheduler.schedule(&x)
        try Scheduler.schedule(&y)
        XCTAssertEqual(x.tasks.map(\.finish), y.tasks.map(\.finish), file: file, line: line)
    }

    func testSampleProjectRoundTrips() throws {
        var p = SampleProject.make()
        p.fieldAliases["text1"] = "Area"
        p.tasks[3].text[1] = "Level 3"
        p.tasks[4].deadline = MPPTime.date(2026, 3, 20, 17)
        p.relations[0].lagUnits = "ed"
        p.calendar?.exceptions.append(CalendarException(start: MPPTime.date(2026, 5, 2), name: "Saturday", working: [480...720]))
        try assertRoundTrip(p)
    }

    func testProjectSavedFileRoundTrips() throws {
        let p = try MPP14File(bytes: Fixture.bytes()).readProject()
        try assertRoundTrip(p)
    }

    func testDurationText() {
        XCTAssertEqual(MSPDI.duration(minutes: 480), "PT8H0M0S")
        XCTAssertEqual(MSPDI.parseDuration("PT8H30M0S"), 510)
        XCTAssertEqual(MSPDI.parseDuration("-PT2H0M0S"), -120)
        XCTAssertEqual(MSPDI.textFieldID(1), 188_743_731)
        XCTAssertEqual(MSPDI.textNumber(188_744_016), 30)
    }
}
