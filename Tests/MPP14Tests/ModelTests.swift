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

/// Tests that need no fixture: working time, scheduling, the calendar blob,
/// notes encoding, the container writer and property sets.
final class ModelTests: XCTestCase {
    private func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        MPPTime.date(y, m, day, h, min)
    }

    // MARK: - Working time

    func testWorkingTimeAdvancesAcrossLunchWeekendsAndHolidays() {
        var cal = ProjectCalendar()
        cal.exceptions = [CalendarException(start: d(2026, 1, 12, 0, 0), name: "Holiday")]   // a Monday
        let wt = WorkingTime(calendar: cal)
        // Friday 15:00 + 4h: 2h Friday, Monday is a holiday, 2h Tuesday.
        XCTAssertEqual(wt.advance(d(2026, 1, 9, 15, 0), minutes: 240), d(2026, 1, 13, 10, 0))
        // 11:00 + 2h crosses lunch.
        XCTAssertEqual(wt.advance(d(2026, 1, 13, 11, 0), minutes: 120), d(2026, 1, 13, 14, 0))
        XCTAssertEqual(wt.minutes(from: d(2026, 1, 9, 15, 0), to: d(2026, 1, 13, 10, 0)), 240)
        XCTAssertEqual(wt.retreat(d(2026, 1, 13, 10, 0), minutes: 240), d(2026, 1, 9, 15, 0))
        XCTAssertEqual(wt.nextWorkingMoment(d(2026, 1, 9, 17, 0)), d(2026, 1, 13, 8, 0))
        XCTAssertEqual(wt.nextWorkingMoment(d(2026, 1, 13, 12, 0)), d(2026, 1, 13, 13, 0))
        XCTAssertEqual(wt.previousWorkingMoment(d(2026, 1, 13, 8, 0)), d(2026, 1, 9, 17, 0))
        XCTAssertEqual(wt.minutesPerWeek, 2_400)
    }

    func testAdvanceAndRetreatAreInverse() {
        let wt = WorkingTime(calendar: SampleProject.standardCalendarForTests)
        var start = d(2026, 3, 30, 8, 0)
        for minutes in stride(from: 0, through: 10_000, by: 137) {
            let finish = wt.advance(start, minutes: minutes)
            XCTAssertEqual(wt.minutes(from: start, to: finish), minutes)
            if minutes > 0 { XCTAssertEqual(wt.retreat(finish, minutes: minutes), start) }
            start = wt.nextWorkingMoment(finish)
        }
    }

    // MARK: - Scheduler

    func testSchedulerHonoursEveryLinkType() throws {
        var p = Project(title: "Links", start: d(2026, 1, 5, 8))
        func task(_ uid: Int, _ days: Double) -> ProjectTask {
            var t = ProjectTask(uid: uid, name: "T\(uid)")
            t.durationDays = days
            return t
        }
        p.tasks = [task(1, 2), task(2, 1), task(3, 1), task(4, 1), task(5, 1)]
        p.relations = [
            Relation(predUID: 1, succUID: 2),                       // FS
            Relation(predUID: 1, succUID: 3, type: "SS", lagDays: 1),
            Relation(predUID: 1, succUID: 4, type: "FF"),
            Relation(predUID: 1, succUID: 5, type: "SF", lagDays: 3),
        ]
        try Scheduler.schedule(&p)
        let t = Dictionary(uniqueKeysWithValues: p.tasks.map { ($0.uid, $0) })
        XCTAssertEqual(t[1]?.finish, d(2026, 1, 6, 17))
        XCTAssertEqual(t[2]?.start, d(2026, 1, 7, 8))       // FS: the next morning
        XCTAssertEqual(t[3]?.start, d(2026, 1, 6, 8))       // SS + 1d
        XCTAssertEqual(t[4]?.finish, d(2026, 1, 6, 17))     // FF: finishes together
        XCTAssertEqual(t[5]?.finish, d(2026, 1, 7, 17))     // SF + 3d: finish ≥ start of 1 + 3d
        XCTAssertEqual(p.finish, d(2026, 1, 7, 17))
    }

    func testSchedulerRollsUpSummariesAndRejectsCycles() throws {
        var p = Project(title: "Outline", start: d(2026, 1, 5, 8))
        var s = ProjectTask(uid: 1, name: "Summary")
        var a = ProjectTask(uid: 2, name: "A"); a.outlineLevel = 2; a.parentUID = 1; a.durationDays = 3
        var b = ProjectTask(uid: 3, name: "B"); b.outlineLevel = 2; b.parentUID = 1; b.durationDays = 2
        s.durationDays = 99
        p.tasks = [s, a, b]
        p.relations = [Relation(predUID: 2, succUID: 3)]
        try Scheduler.schedule(&p)
        XCTAssertEqual(p.tasks[0].start, d(2026, 1, 5, 8))
        XCTAssertEqual(p.tasks[0].finish, d(2026, 1, 9, 17))
        XCTAssertEqual(p.tasks[0].durationDays, 5, accuracy: 1e-9)
        XCTAssertTrue(p.tasks[0].summary)

        p.relations.append(Relation(predUID: 3, succUID: 2))
        XCTAssertThrowsError(try Scheduler.schedule(&p))
    }

    func testSampleProjectSchedulesAsDocumented() {
        let p = SampleProject.make()
        let t = Dictionary(uniqueKeysWithValues: p.tasks.map { ($0.uid, $0) })
        // Backend: lead −2d is overridden by SNET 18 Feb; 12 days skip the 16–17 Feb offsite.
        XCTAssertEqual(t[13]?.start, d(2026, 2, 18, 8))
        XCTAssertEqual(t[13]?.finish, d(2026, 3, 5, 17))
        // Night batch import: 3 days × 8h on a 5h-a-night calendar.
        XCTAssertEqual(t[16]?.start, d(2026, 3, 5, 18))
        // Hypercare skips Easter.
        XCTAssertEqual(t[32]?.start, d(2026, 4, 13, 8))
        // Design review is pinned by MSO.
        XCTAssertEqual(t[12]?.start, d(2026, 2, 13, 17))
        // As late as possible, matched against Project's own recalculation:
        // Frontend finishes where Integration testing must start for Smoke
        // test to finish before Go-live's Must Finish On.
        XCTAssertEqual(t[14]?.start, d(2026, 3, 20, 15, 30))
        XCTAssertEqual(t[14]?.finish, d(2026, 4, 1, 15, 30))
        XCTAssertEqual(t[19]?.start, d(2026, 4, 1, 15, 30))
        XCTAssertEqual(t[21]?.finish, d(2026, 4, 10, 17))
        // A start-to-finish link keeps the exact finish it imposes.
        XCTAssertEqual(t[33]?.finish, d(2026, 4, 13, 8))
        // Critical tasks have no slack; Backend has some. Backend is under
        // way, so — as in Project — its late start is the day it started
        // and its float shows at the finish.
        XCTAssertEqual(t[19]?.lateStart, t[19]?.start)
        XCTAssertEqual(t[13]!.lateStart!, t[13]!.start!)
        XCTAssertGreaterThan(t[13]!.lateFinish!, t[13]!.finish!)
        XCTAssertGreaterThan(p.totalFloatMinutes(uid: 13)!, 0)
        // Every constraint type and link type is present.
        XCTAssertEqual(Set(p.tasks.compactMap(\.constraint)), Set(ConstraintType.allCases.map(\.rawValue)).subtracting(["ASAP"]))
        XCTAssertEqual(Set(p.relations.map(\.type)), Set(RelationType.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(p.tasks.map(\.durationUnits)), ["m", "h", "d", "w", "mo"])
        XCTAssertEqual(Set(p.tasks.map(\.taskType)), Set(TaskType.allCases.map(\.rawValue)))
    }

    // MARK: - Calendar blob

    func testCalendarDataRoundTrips() {
        var week: [Int: [ClosedRange<Int>]?] = [:]
        week[1] = .some(nil)
        week[2] = [480...720, 780...1_020]
        week[4] = [0...1_440]
        week[7] = [420...480, 500...560, 600...660, 700...760, 800...860]
        let exceptions = [
            CalendarException(start: d(2026, 1, 1), name: "New Year"),
            CalendarException(start: d(2026, 12, 24), finish: d(2026, 12, 26), name: "Ünïcødé 🎄"),
        ]
        let decoded = CalendarData.parse(CalendarData.build(week: week, exceptions: exceptions))
        XCTAssertEqual(decoded.week, week)
        XCTAssertEqual(decoded.exceptions, exceptions)
        XCTAssertEqual(CalendarData.parse(CalendarData.build(week: [:], exceptions: [])).week, [:])
    }

    // MARK: - Notes

    func testNotesRoundTripThroughRTF() {
        let text = "Line 1 {braces} \\ backslash\nÆøå — “quotes” 🚀 日本語"
        XCTAssertEqual(MPP14File.decodeRTFNotes(MPP14Writer.encodeRTFNotes(text)), text)
    }

    /// Notes as RichEdit (and so Project) actually writes them: a generator
    /// group, CRLFs between control words, `\\'hh` escapes in the document code
    /// page, `\\uN` with its fallback character, and a `\\par` before the end.
    func testNotesDecodeRichEditRTF() {
        let rtf = "{\\rtf1\\ansi\\ansicpg1252\\deff0\\nouicompat\\deflang1030{\\fonttbl{\\f0\\fnil\\fcharset0 Segoe UI;}}\r\n"
            + "{\\*\\generator Riched20 16.0.17928}\\viewkind4\\uc1 \r\n"
            + "\\pard\\f0\\fs20 Bl\\'e5b\\'e6r \\u8364?5\\par\r\nSecond\\tab line\\par\r\n}\r\n\u{0}"
        XCTAssertEqual(MPP14File.decodeRTFNotes(Array(rtf.utf8)), "Blåbær €5\nSecond\tline")
        XCTAssertEqual(MPP14File.decodeRTFNotes(Array("plain text\u{0}".utf8)), "plain text")
    }

    // MARK: - Container and property sets

    func testContainerWriterRoundTripsSyntheticStorage() throws {
        let root = CFBStorage()
        root.addStream("small", Array(repeating: 7, count: 100))
        root.addStream("exactly-cutoff", Array(repeating: 1, count: 4_096))
        root.setStream(path: "   114/TBkndTask/Var2Data", (0..<70_000).map { UInt8($0 % 251) })
        root.setStream(path: "   114/Props", [1, 2, 3])
        for i in 0..<40 { root.addStream("s\(i)", [UInt8(i)]) }
        let bytes = try CFBWriter.write(root: root, rootCLSID: CFBFile.projectRootCLSID)
        let back = try CFBFile(bytes: bytes)
        XCTAssertEqual(back.rootCLSID, CFBFile.projectRootCLSID)
        let a = Dictionary(uniqueKeysWithValues: root.walk().compactMap { e in e.node.streamBytes.map { (e.path, $0) } })
        let b = Dictionary(uniqueKeysWithValues: back.allStreams().map { ($0.path, $0.bytes) })
        XCTAssertEqual(a, b)
    }

    func testPropertySetStringUpdateKeepsOtherProperties() {
        // One section, code page 1252, an int and a string.
        var w = BinaryWriter()
        w.u16(0xFFFE); w.u16(0); w.u32(0x0002_0006)
        w.append([UInt8](repeating: 0, count: 16))
        w.u32(1)
        w.append([UInt8](repeating: 0xAB, count: 16)); w.u32(48)
        // section at 48: size, count 3, table, values
        let values: [(UInt32, [UInt8])] = [
            (1, [2, 0, 0, 0, 0xE4, 0x04, 0, 0]),                         // VT_I2 1252
            (9, [3, 0, 0, 0, 42, 0, 0, 0]),                              // VT_I4 42
            (4, [30, 0, 0, 0, 4, 0, 0, 0, 0x4F, 0x6C, 0x64, 0]),         // VT_LPSTR "Old"
        ]
        var body = BinaryWriter(), table = BinaryWriter()
        for (pid, v) in values { table.u32(pid); table.u32(UInt32(8 + 24 + body.count)); body.append(v) }
        w.u32(UInt32(8 + 24 + body.count)); w.u32(3); w.append(table.bytes); w.append(body.bytes)

        let updated = OLEPropertySet.updatingStrings(w.bytes, [4: "Zoë Ünïcødé", 18: "MPPKit"])
        let section = OLEPropertySet.parse(updated)[0]
        XCTAssertEqual(section?.string(4), "Zoë Ünïcødé")
        XCTAssertEqual(section?.string(18), "MPPKit")
        XCTAssertEqual(section?[9]?.intValue, 42)
    }
}

extension SampleProject {
    static var standardCalendarForTests: ProjectCalendar { make().calendar! }
}
