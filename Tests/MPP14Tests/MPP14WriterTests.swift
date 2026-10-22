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

/// The writer, checked by writing the all-features sample over the fixture
/// template and reading it back. Skips without a fixture, like the reader tests.
final class MPP14WriterTests: XCTestCase {

    /// The fixture, neutralised, as a writer template — exactly what
    /// `mppdump sample` does.
    private func writeSample(template: [UInt8]? = nil) throws -> (Project, [UInt8]) {
        let source = try template ?? MPP14Template.neutralized(try Fixture.bytes())
        var options = MPP14Writer.Options()
        options.now = { MPPTime.date(2026, 1, 2, 9) }
        let project = SampleProject.make()
        let bytes = try MPP14Writer(template: source, options: options).build(project)
        return (project, bytes)
    }

    // MARK: - Round trip

    func testSampleRoundTripsEveryField() throws {
        let (expected, bytes) = try writeSample()
        let file = try MPP14File(bytes: bytes)
        XCTAssertTrue(file.hasProjectRootCLSID, "Project identifies .mpp files by the root CLSID")
        let actual = try file.readProject()
        assertSameProject(actual, expected)
    }

    /// A template made by `makeBlank` must serve as well as the original.
    func testBlankTemplateServesAsATemplate() throws {
        let blank = try MPP14Template.makeBlank(from: try Fixture.bytes())
        let blankProject = try MPP14File(bytes: blank).readProject()
        XCTAssertEqual(blankProject.tasks.map(\.name), ["Task 1", "Task 2", "Task 3"])
        XCTAssertEqual(blankProject.relations.count, 1)
        XCTAssertTrue(blankProject.resources.isEmpty)

        let (expected, bytes) = try writeSample(template: blank)
        assertSameProject(try MPP14File(bytes: bytes).readProject(), expected)
    }

    /// Durations and lags are stored in minutes but modelled in days of the
    /// file's own length. On a 7.5-hour day, a reader or writer that assumed
    /// 8 hours would return every duration 6% off.
    func testDaysFollowTheProjectDayLength() throws {
        var p = SampleProject.make()
        p.minutesPerDay = 450
        p.minutesPerWeek = 2_250
        var std = p.calendar!
        for d in 2...6 { std.week[d] = [480...720, 750...960] }      // 08–12, 12:30–16:00
        p.calendar = std
        for i in p.tasks.indices { p.tasks[i].baselines = [:] }
        try Scheduler.schedule(&p)
        let template = try MPP14Template.neutralized(try Fixture.bytes())
        let read = try MPP14File(bytes: try MPP14Writer(template: template).build(p)).readProject()
        XCTAssertEqual(read.minutesPerDay, 450)
        for (x, t) in zip(read.tasks, p.tasks) {
            XCTAssertEqual(x.durationDays, t.durationDays, accuracy: 1e-4, "task \(t.uid) duration")
            XCTAssertEqual(x.finish, t.finish, "task \(t.uid) finish")
        }
        XCTAssertEqual(read.relations, p.relations)
        XCTAssertEqual(read.task(uid: 13)?.durationDays ?? 0, 12, accuracy: 1e-4)
    }

    /// The outline's columns travel with the file; a file saved without any
    /// says nothing, and one resaved without a choice keeps what it had.
    /// A task started late, before any progress: its actual start moves it
    /// and its successors, and survives a save as Project keeps it.
    func testStartVarianceMovesTheTaskAndRoundTrips() throws {
        var p = SampleProject.make()
        try Scheduler.schedule(&p)
        p.setBaseline(slot: 0)
        guard let task = p.tasks.first(where: { !$0.summary && $0.percentComplete == 0 && !$0.manual
                                                && $0.durationDays > 0 && $0.baselines[0] != nil }) else {
            return XCTFail("the sample has an unstarted task")
        }
        let finishBefore = p.finish
        p.setStartVariance(uid: task.uid, days: 3)
        try Scheduler.schedule(&p)
        XCTAssertEqual(p.startVarianceDays(uid: task.uid) ?? 0, 3, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(p.finish ?? .distantPast, finishBefore ?? .distantFuture)

        let template = try MPP14Template.neutralized(try Fixture.bytes())
        let read = try MPP14File(bytes: try MPP14Writer(template: template).build(p)).readProject()
        let back = read.tasks.first { $0.uid == task.uid }
        XCTAssertEqual(back?.actualStart, p.task(uid: task.uid)?.actualStart)
        XCTAssertEqual(back?.start, p.task(uid: task.uid)?.start)
        XCTAssertEqual(back?.percentComplete, 0)
    }

    /// A custom field named in the app is written where Project keeps the
    /// name, so Project shows "Timeframe" rather than "Text1".
    func testFieldAliasesRoundTrip() throws {
        var p = SampleProject.make()
        try Scheduler.schedule(&p)
        p.fieldAliases = ["text1": "Timeframe", "number2": "Cost code"]
        let template = try MPP14Template.neutralized(try Fixture.bytes())
        let read = try MPP14File(bytes: try MPP14Writer(template: template).build(p)).readProject()
        XCTAssertEqual(read.fieldAliases, ["text1": "Timeframe", "number2": "Cost code"])

        p.fieldAliases = [:]
        let cleared = try MPP14File(bytes: try MPP14Writer(template: template).build(p)).readProject()
        XCTAssertEqual(cleared.fieldAliases, [:])
    }

    func testViewColumnsRoundTrip() throws {
        let blank = try MPP14Template.makeBlank(from: try Fixture.bytes())
        var p = try MPP14File(bytes: blank).readProject()
        // A file never saved by the app shows the columns of Project's own
        // Entry table.
        XCTAssertNotNil(p.viewColumns)
        p.viewColumns = ["id", "name", "text3", "resources"]
        let saved = try MPP14Writer(template: blank).build(p)
        var opened = try MPP14File(bytes: saved).readProject()
        XCTAssertEqual(opened.viewColumns, p.viewColumns)
        opened.viewColumns = nil
        let resaved = try MPP14Writer(template: saved).build(opened)
        XCTAssertEqual(try MPP14File(bytes: resaved).readProject().viewColumns, ["id", "name", "text3", "resources"])
    }

    /// Opening a file and saving it again writes over itself: its extra base
    /// calendars are in the template and in the project both, and must come
    /// back once each, with an edited one carrying its edit.
    func testResaveKeepsBaseCalendars() throws {
        let (expected, saved) = try writeSample()
        var opened = try MPP14File(bytes: saved).readProject()
        XCTAssertFalse(opened.calendars.isEmpty)
        let i = try XCTUnwrap(opened.calendars.firstIndex { $0.name == "Night Shift" })
        opened.calendars[i].week[7] = [1_200...1_440]
        let reread = try MPP14File(bytes: try MPP14Writer(template: saved).build(opened)).readProject()
        XCTAssertEqual(reread.calendars.map(\.name).sorted(), opened.calendars.map(\.name).sorted())
        XCTAssertEqual(reread.calendars.first { $0.name == "Night Shift" }?.week[7] ?? nil, [1_200...1_440])
        XCTAssertEqual(reread.tasks.map(\.calendar), expected.tasks.map(\.calendar))
    }

    /// Writing the same project twice with a fixed clock and GUID source must
    /// give identical bytes: no dictionary ordering leaks into the output.
    func testOutputIsDeterministic() throws {
        let template = try MPP14Template.neutralized(try Fixture.bytes())
        func build() throws -> [UInt8] {
            var options = MPP14Writer.Options()
            var counter: UInt8 = 0
            options.now = { MPPTime.date(2026, 1, 2, 9) }
            options.newGUID = { counter &+= 1; return [UInt8](repeating: counter, count: 16) }
            return try MPP14Writer(template: template, options: options).build(SampleProject.make())
        }
        XCTAssertEqual(try build(), try build())
    }

    private func assertSameProject(_ a: Project, _ e: Project, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.title, e.title, file: file, line: line)
        XCTAssertEqual(a.start, e.start)
        XCTAssertEqual(a.statusDate, e.statusDate)
        XCTAssertEqual(a.currencySymbol, e.currencySymbol)
        XCTAssertEqual(a.currencyCode, e.currencyCode)
        XCTAssertEqual(a.minutesPerDay, e.minutesPerDay)
        XCTAssertEqual(a.minutesPerWeek, e.minutesPerWeek)
        XCTAssertEqual(a.daysPerMonth, e.daysPerMonth)
        XCTAssertEqual(a.defaultStartTime, e.defaultStartTime)
        XCTAssertEqual(a.defaultFinishTime, e.defaultFinishTime)
        XCTAssertEqual(a.author, e.author)
        XCTAssertEqual(a.subject, e.subject)
        XCTAssertEqual(a.keywords, e.keywords)
        XCTAssertEqual(a.comments, e.comments)
        XCTAssertEqual(a.manager, e.manager)
        XCTAssertEqual(a.company, e.company)
        XCTAssertEqual(a.category, e.category)

        // Tasks, in row order.
        XCTAssertEqual(a.tasks.map(\.uid), e.tasks.map(\.uid), "task order")
        let parents = Set(e.tasks.map(\.parentUID))
        for (x, t) in zip(a.tasks, e.tasks) {
            let label = "task \(t.uid) \(t.name)"
            let isSummary = parents.contains(t.uid)
            XCTAssertEqual(x.name, t.name, label)
            XCTAssertEqual(x.outlineLevel, t.outlineLevel, label)
            XCTAssertEqual(x.parentUID, t.parentUID, label)
            XCTAssertEqual(x.rowID, e.tasks.firstIndex { $0.uid == t.uid }! + 1, label)
            XCTAssertEqual(x.start, t.start, "\(label) start")
            XCTAssertEqual(x.finish, t.finish, "\(label) finish")
            XCTAssertEqual(x.durationDays, t.durationDays, accuracy: 1e-4, "\(label) duration")
            XCTAssertEqual(x.summary, isSummary, "\(label) summary flag")
            XCTAssertEqual(x.guid.count, 16, "\(label) guid")
            if t.guid.count == 16 { XCTAssertEqual(x.guid, t.guid, "\(label) guid") }
            if !isSummary {
                XCTAssertEqual(x.durationUnits, t.durationUnits, "\(label) units")
                XCTAssertEqual(x.milestone, t.durationDays == 0 || t.milestone, "\(label) milestone flag")
                XCTAssertEqual(x.percentComplete, t.percentComplete, "\(label) percent complete")
            }
            XCTAssertEqual(x.estimated, t.estimated, "\(label) estimated")
            XCTAssertEqual(x.manual, t.manual, "\(label) manual")
            XCTAssertEqual(x.constraint, t.constraint, "\(label) constraint")
            if t.constraint != nil { XCTAssertEqual(x.constraintDate, t.constraintDate, "\(label) constraint date") }
            XCTAssertEqual(x.deadline, t.deadline, "\(label) deadline")
            XCTAssertEqual(x.priority, t.priority, "\(label) priority")
            XCTAssertEqual(x.taskType, t.taskType, "\(label) type")
            XCTAssertEqual(x.effortDriven, t.effortDriven, "\(label) effort driven")
            XCTAssertEqual(x.calendar, t.calendar, "\(label) calendar")
            XCTAssertEqual(x.notes, t.notes, "\(label) notes")
            XCTAssertEqual(x.wbs, t.wbs, "\(label) wbs")
            XCTAssertEqual(x.text, t.text, "\(label) text fields")
            XCTAssertEqual(x.numbers, t.numbers, "\(label) number fields")
            XCTAssertEqual(x.dateFields, t.dateFields, "\(label) date fields")
            XCTAssertEqual(x.flags, t.flags.filter(\.value), "\(label) flag fields")
            if t.percentComplete > 0 && !isSummary {
                XCTAssertEqual(x.actualStart, t.start, "\(label) actual start")
            }
            if t.percentComplete == 100 && !isSummary {
                XCTAssertEqual(x.actualFinish, t.finish, "\(label) actual finish")
            }
            XCTAssertEqual(Set(x.baselines.keys), Set(t.baselines.keys), "\(label) baseline slots")
            for (slot, b) in t.baselines {
                guard let y = x.baselines[slot] else { continue }
                XCTAssertEqual(y.start, b.start, "\(label) baseline \(slot) start")
                XCTAssertEqual(y.finish, b.finish, "\(label) baseline \(slot) finish")
                XCTAssertEqual(y.durationDays, b.durationDays, accuracy: 1e-4, "\(label) baseline \(slot) duration")
                XCTAssertEqual(y.workHours, b.workHours, accuracy: 1e-3, "\(label) baseline \(slot) work")
            }
        }
        // Baselines were taken before Backend slipped from 10 to 12 days.
        if let backend = a.task(uid: 13) {
            XCTAssertEqual(backend.durationDays, 12, accuracy: 1e-4)
            XCTAssertEqual(backend.baselines[0]?.durationDays ?? 0, 10, accuracy: 1e-4)
        }

        XCTAssertEqual(Set(a.tasks.map(\.guid)).count, a.tasks.count, "task GUIDs are unique")
        XCTAssertEqual(a.relations, e.relations, "links")

        XCTAssertEqual(a.resources.map(\.uid), e.resources.map(\.uid))
        for (x, r) in zip(a.resources, e.resources) {
            XCTAssertEqual(x.name, r.name)
            XCTAssertEqual(x.initials, r.initials)
            XCTAssertEqual(x.email, r.email)
            XCTAssertEqual(x.maxUnits, r.maxUnits, accuracy: 1e-6)
            XCTAssertEqual(x.guid.count, 16)
            XCTAssertNotNil(x.calendarUID, "resource \(r.uid) has its own calendar")
            XCTAssertEqual(x.baselines[0]?.workHours ?? 0, r.baselines[0]?.workHours ?? 0, accuracy: 1e-3)
        }

        XCTAssertEqual(a.assignments.count, e.assignments.count)
        for (x, s) in zip(a.assignments, e.assignments) {
            XCTAssertEqual(x.taskUID, s.taskUID)
            XCTAssertEqual(x.resourceUID, s.resourceUID)
            XCTAssertEqual(x.units, s.units, accuracy: 1e-6)
            let task = e.task(uid: s.taskUID)!
            XCTAssertEqual(x.workHours, task.durationDays * Double(e.minutesPerDay) / 60 * s.units, accuracy: 1e-3)
            XCTAssertEqual(x.start, task.start)
            XCTAssertEqual(x.finish, task.finish)
        }

        // Calendars.
        XCTAssertEqual(a.calendar?.week, e.calendar?.week, "Standard working week")
        XCTAssertEqual(a.calendar?.exceptions, e.calendar?.exceptions, "Standard exceptions")
        for cal in e.calendars {
            guard let read = a.calendars.first(where: { $0.name == cal.name }) else {
                XCTFail("calendar \(cal.name) missing"); continue
            }
            XCTAssertEqual(read.week, cal.week, "\(cal.name) week")
            XCTAssertEqual(read.exceptions, cal.exceptions, "\(cal.name) exceptions")
        }
        for r in e.resources {
            XCTAssertTrue(a.resourceCalendars.contains { $0.resourceUID == r.uid && $0.name == r.name },
                          "resource \(r.uid) calendar")
        }
        XCTAssertFalse(a.resourceCalendars.contains { ($0.resourceUID ?? 0) > 0 && a.resource(uid: $0.resourceUID!) == nil },
                       "a template resource's calendar was carried over")
    }

    /// Fields 387/1255/1250 record what drives each task's start. Project
    /// writes only certain combinations; this checks every written task
    /// against them.
    func testScheduleDriverMatchesWhatProjectWrites() throws {
        let (project, bytes) = try writeSample()
        let file = try MPP14File(bytes: bytes)
        let read = try file.readProject()
        let fm = Dictionary(MPP.parseFieldMap(file.props[MPP.PropsKey.taskFieldMap]!).filter(\.inFixed)
            .map { ($0.nativeID, $0) }, uniquingKeysWith: { a, _ in a })
        func rows(_ name: String, _ size: Int) throws -> [[UInt8]] {
            let meta = try MPP.parseFixedMetaAuto(try file.root.stream(path: "   114/TBkndTask/\(name)Meta"),
                                                  defaultItemSize: size)
            return MPP.splitFixedData(try file.root.stream(path: "   114/TBkndTask/\(name)Data"),
                                      metaItems: MPP.declaredItems(meta))
        }
        let r1 = try rows("Fixed", 47), r2 = try rows("Fixed2", 92)
        func src(_ i: Int, _ id: UInt32) -> ([UInt8], Int) {
            let it = fm[id]!
            return (it.block == 0 ? r1[i] : r2[i], it.offset)
        }
        var checked = 0
        for i in r1.indices where r1[i].count > 100 {
            let (u, uo) = src(i, MPP.TaskField.uniqueID)
            let uid = Int(BinaryReader(u).u32(at: uo)!)
            guard uid != 0, let t = read.task(uid: uid) else { continue }
            let (a, ao) = src(i, MPP.TaskField.summaryProgress)
            let (b, bo) = src(i, MPP.TaskField.summaryProgressPrior)
            let (c, co) = src(i, MPP.TaskField.scheduleDriver)
            let m387 = MPP.decodeTimestamp(a, offset: ao), m1255 = MPP.decodeTimestamp(b, offset: bo)
            let driver = MPP.ScheduleDriver(rawValue: BinaryReader(c).i32(at: co)!)
            let label = "task \(uid) \(t.name)"
            checked += 1
            switch driver {
            case .summary?:
                XCTAssertTrue(t.summary, label); XCTAssertNil(m387, label); XCTAssertNil(m1255, label)
            case .actuals?:
                XCTAssertGreaterThan(t.percentComplete, 0, label)
                if t.percentComplete == 100 { XCTAssertNil(m1255, label) } else { XCTAssertEqual(m387, m1255, label) }
                if t.milestone && t.percentComplete == 100 { XCTAssertNil(m387, label) }
            case .constraint?:
                XCTAssertEqual(t.percentComplete, 0, label); XCTAssertNil(m387, label); XCTAssertEqual(m1255, t.start, label)
            case .projectStart?:
                XCTAssertEqual(t.percentComplete, 0, label); XCTAssertEqual(m387, t.start, label); XCTAssertEqual(m1255, t.start, label)
            case .predecessor?:
                XCTAssertEqual(t.percentComplete, 0, label); XCTAssertEqual(m387, m1255, label)
                XCTAssertLessThanOrEqual(m387 ?? .distantFuture, t.start!, label)
            case nil:
                XCTFail("\(label): unknown schedule driver")
            }
            // An unstarted milestone must never carry a progress mark.
            if t.milestone && t.durationDays == 0 && t.percentComplete == 0 { XCTAssertNil(m387, label) }
        }
        XCTAssertEqual(checked, project.tasks.count)
    }

    /// Project keeps the meta "present" bit of fixed value fields set on
    /// every task whatever the value (% complete 0, no actual start, no
    /// deadline). Clearing them made unstarted milestones and constrained
    /// tasks open in Project as 100% complete.
    func testPresenceBitsStaySetOnEveryTask() throws {
        let (_, bytes) = try writeSample()
        let file = try MPP14File(bytes: bytes)
        let items = MPP.parseFieldMap(file.props[MPP.PropsKey.taskFieldMap]!)
        func meta(_ name: String, _ size: Int) throws -> [[UInt8]] {
            MPP.declaredItems(try MPP.parseFixedMetaAuto(
                try file.root.stream(path: "   114/TBkndTask/\(name)Meta"), defaultItemSize: size))
        }
        let m1 = try meta("Fixed", 47), m2 = try meta("Fixed2", 92)
        let data = MPP.splitFixedData(try file.root.stream(path: "   114/TBkndTask/FixedData"), metaItems: m1)
        let F = MPP.TaskField.self
        for id in [F.percentComplete, F.percentWorkComplete, F.actualDuration, F.actualStart, F.actualFinish,
                   F.constraintType, F.constraintDate, F.calendarUniqueID, F.deadline, F.stop, F.resume] {
            guard let bit = MPP.metaBits(items)[id] else { continue }
            for i in data.indices where data[i].count > 100 {
                XCTAssertEqual(MPP.metaBit(meta: m1[i], meta2: m2[i], bit), 1,
                               "row \(i): presence bit of field \(id) cleared")
            }
        }
    }

    /// Assignment booleans 41/42 record started/finished. Project derives
    /// milestones, manual and fixed-duration tasks from them, so a stray
    /// "finished" (cloned from a completed template row) opened every such
    /// task as 100% complete.
    func testAssignmentProgressFlagsFollowProgress() throws {
        let (project, bytes) = try writeSample()
        let file = try MPP14File(bytes: bytes)
        let items = MPP.parseFieldMap(file.props[MPP.PropsKey.assignmentFieldMap]!)
        func blk(_ n: String, _ size: Int) throws -> ([[UInt8]], [[UInt8]]) {
            let m = MPP.declaredItems(try MPP.parseFixedMetaAuto(
                try file.root.stream(path: "   114/TBkndAssn/\(n)Meta"), defaultItemSize: size))
            return (m, MPP.splitFixedData(try file.root.stream(path: "   114/TBkndAssn/\(n)Data"), metaItems: m))
        }
        let (m1, r1) = try blk("Fixed", 34), (m2, _) = try blk("Fixed2", 53)
        let taskIt = items.first { $0.nativeID == MPP.AssignmentField.taskUniqueID && $0.inFixed }!
        let bits = MPP.metaBits(items)
        guard let started = bits[MPP.AssignmentField.started],
              let finished = bits[MPP.AssignmentField.finished] else {
            throw XCTSkip("template has no assignment progress flags")
        }
        var checked = 0
        for i in r1.indices where r1[i].count > 30 {
            let uid = Int(BinaryReader(r1[i]).u32(at: taskIt.offset)!)
            guard let t = project.task(uid: uid) else { continue }
            checked += 1
            XCTAssertEqual(MPP.metaBit(meta: m1[i], meta2: m2[i], started) == 1, t.percentComplete > 0,
                           "task \(uid) \(t.name): started flag")
            XCTAssertEqual(MPP.metaBit(meta: m1[i], meta2: m2[i], finished) == 1, t.percentComplete == 100,
                           "task \(uid) \(t.name): finished flag")
        }
        XCTAssertGreaterThan(checked, 0)
    }

    // MARK: - Template data must not leak

    /// Nothing that identifies the template's own schedule may survive into a
    /// written file: its task, resource and calendar names, holidays, lookup
    /// values, field aliases, saved path and author.
    func testWrittenFileCarriesNoTemplateData() throws {
        let source = try Fixture.bytes()
        let template = try MPP14File(bytes: source)
        let original = try template.readProject()
        var secrets = Set<String>()
        secrets.formUnion(original.tasks.map(\.name))
        secrets.formUnion(original.resources.map(\.name))
        secrets.insert(original.title)
        for cal in [original.calendar].compactMap({ $0 }) + original.calendars {
            if cal.name != "Standard" { secrets.insert(cal.name) }
            secrets.formUnion(cal.exceptions.map(\.name))
        }
        for t in original.tasks { secrets.formUnion(t.text.values); if !t.notes.isEmpty { secrets.insert(t.notes) } }
        if let doc = OLEPropertySet.parse((try? template.root.stream("\u{5}SummaryInformation")) ?? [])[0] {
            for pid: UInt32 in [4, 7, 8] { if let s = doc.string(pid) { secrets.insert(s) } }
        }
        if let doc = OLEPropertySet.parse((try? template.root.stream("\u{5}DocumentSummaryInformation")) ?? [])[0] {
            for pid: UInt32 in [14, 15] { if let s = doc.string(pid) { secrets.insert(s) } }
        }
        let cfb = try CFBFile(bytes: source)
        for (path, bytes) in cfb.allStreams() where path.hasSuffix("TBkndOutlCode/Var2Data") || path == "Props14"
            || path.hasSuffix("TBkndTask/Props") {
            secrets.formUnion(utf16Strings(bytes))
        }
        // Words the localised user interface itself uses are not secrets.
        var interface = Set<String>()
        for (path, bytes) in cfb.allStreams() where path.contains("CV_iew") || path.contains("CTable")
            || path.contains("CFilter") || path.contains("CGrouping") || path.contains("BoardColumn")
            || path.contains("Sprint") {
            interface.formUnion(utf16Strings(bytes))
        }
        // What the sample itself says is not a leak either.
        let sample = SampleProject.make()
        let own = ([sample.title] + sample.tasks.flatMap { [$0.name, $0.notes] + Array($0.text.values) }
                   + sample.resources.map(\.name) + sample.calendars.map(\.name)).joined(separator: "\n")
        let checked = secrets.filter { s in
            // Real text: mostly Latin script with an ASCII letter. Binary
            // fields (GUIDs, numbers) also decode as "UTF-16", as CJK noise.
            let latin = s.unicodeScalars.filter { $0.value < 0x250 || (0x2000...0x206F).contains($0.value) }.count
            return s.count >= 5 && latin * 10 >= s.unicodeScalars.count * 9
                && s.unicodeScalars.contains { ("A"..."z").contains($0) }
                && !interface.contains { $0.contains(s) } && !own.contains(s)
        }
        XCTAssertGreaterThan(checked.count, 10, "the fixture should contribute plenty to look for")

        let (_, written) = try writeSample()
        let streams = try CFBFile(bytes: written).allStreams()
        for secret in checked {
            let wide = Array(secret.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
            let narrow = Array((secret.data(using: .windowsCP1252) ?? Data()))
            for (path, bytes) in streams {
                XCTAssertFalse(contains(bytes, wide), "\"\(secret)\" leaked into \(path.debugDescription)")
                if narrow.count >= 5 {
                    XCTAssertFalse(contains(bytes, narrow), "\"\(secret)\" leaked into \(path.debugDescription)")
                }
            }
        }
    }

    /// Where the neutraliser cannot rebuild a structure it must change text
    /// only: same length, and every changed byte inside a printable UTF-16
    /// unit, so no offset, size or count in the file moves.
    func testNeutraliserChangesOnlyText() throws {
        let source = try Fixture.bytes()
        let before = Dictionary(uniqueKeysWithValues: try CFBFile(bytes: source).allStreams().map { ($0.path, $0.bytes) })
        let after = Dictionary(uniqueKeysWithValues: try CFBFile(bytes: MPP14Template.neutralized(source))
            .allStreams().map { ($0.path, $0.bytes) })
        XCTAssertEqual(Set(before.keys), Set(after.keys))
        let rebuilt: Set<String> = ["   114/TBkndCal/VarMeta", "   114/TBkndCal/Var2Data", "   114/Props",
                                    "\u{5}SummaryInformation", "\u{5}DocumentSummaryInformation"]
        for (path, old) in before {
            guard let new = after[path], new != old, !rebuilt.contains(path) else { continue }
            XCTAssertEqual(new.count, old.count, "\(path.debugDescription) changed length")
            guard new.count == old.count else { continue }
            for i in 0..<old.count where old[i] != new[i] {
                let j = i - i % 2
                let a = UInt16(old[j]) | UInt16(old[j + 1]) << 8, b = UInt16(new[j]) | UInt16(new[j + 1]) << 8
                XCTAssertTrue(a >= 0x20 && b >= 0x20,
                              "\(path.debugDescription) byte \(i) changed outside text")
                if !(a >= 0x20 && b >= 0x20) { break }
            }
        }
        // The neutral template still reads, with its calendars renamed.
        let project = try MPP14File(bytes: MPP14Template.neutralized(source)).readProject()
        XCTAssertTrue(project.calendars.allSatisfy { $0.name.hasPrefix("Base Calendar ") })
        XCTAssertTrue(([project.calendar].compactMap { $0 } + project.calendars).allSatisfy { $0.exceptions.isEmpty })
        XCTAssertNil(project.author)
    }

    // MARK: - Validation

    func testWriterRejectsInvalidProjects() throws {
        let writer = try MPP14Writer(template: MPP14Template.neutralized(try Fixture.bytes()))
        func rejects(_ change: (inout Project) -> Void, _ message: String) {
            var p = SampleProject.make()
            change(&p)
            XCTAssertThrowsError(try writer.build(p), message)
        }
        rejects({ $0.tasks[0].uid = 0 }, "uid 0 is the project summary")
        rejects({ $0.tasks[1].uid = $0.tasks[2].uid }, "duplicate uid")
        rejects({ $0.tasks[1].outlineLevel = 3 }, "outline jumps a level")
        rejects({ $0.tasks[1].parentUID = 4 }, "parent does not match the outline")
        rejects({ $0.relations.append(Relation(predUID: 3, succUID: 2)) }, "dependency cycle")
        rejects({ $0.relations.append(Relation(predUID: 2, succUID: 999)) }, "unknown task")
        rejects({ $0.assignments.append(Assignment(taskUID: 2, resourceUID: 99)) }, "unknown resource")
        rejects({ $0.tasks[1].calendar = "Nope" }, "unknown calendar")
        rejects({ $0.tasks[1].text[31] = "x" }, "Text31 does not exist")
        rejects({ $0.tasks[1].constraint = "XYZ" }, "unknown constraint")
    }

    // MARK: - Helpers

    private func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        let first = needle[0]
        var i = 0
        while i <= haystack.count - needle.count {
            if haystack[i] == first, Array(haystack[i..<i + needle.count]) == needle { return true }
            i += 1
        }
        return false
    }

    /// Printable UTF-16 runs at either byte alignment.
    private func utf16Strings(_ bytes: [UInt8]) -> Set<String> {
        var out = Set<String>()
        for phase in 0..<2 {
            var units: [UInt16] = []
            var i = phase
            while i + 1 < bytes.count {
                let u = UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
                if u >= 0x20 && u != 0xFFFF && !(0xD800...0xDFFF).contains(u) { units.append(u) } else {
                    if units.count >= 4 { out.insert(String(decoding: units, as: UTF16.self)) }
                    units = []
                }
                i += 2
            }
            if units.count >= 4 { out.insert(String(decoding: units, as: UTF16.self)) }
        }
        return out
    }
}

/// Baselines past Project's eleven: slots 0...10 in Project's own fields, the
/// rest in the app's stream. Uses the committed blank template, so it runs
/// without a fixture.
final class ExtraBaselinesTests: XCTestCase {

    private func blankTemplate() throws -> [UInt8] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Samples/Blank-Template.mpp")
        return [UInt8](try Data(contentsOf: url))
    }

    private func project(slots: Range<Int>) -> Project {
        var p = SampleProject.make()
        for i in p.tasks.indices { p.tasks[i].baselines = [:] }
        for i in p.assignments.indices { p.assignments[i].baselines = [:] }
        for slot in slots {
            p.setBaseline(slot: slot)
            for i in p.tasks.indices {
                let start = p.tasks[i].start?.addingTimeInterval(TimeInterval(-86_400 * slot))
                p.tasks[i].baselines[slot]?.start = start
            }
        }
        return p
    }

    func testFiftyBaselinesRoundTrip() throws {
        let expected = project(slots: 0..<50)
        let bytes = try MPP14Writer(template: try blankTemplate()).build(expected)
        let actual = try MPP14File(bytes: bytes).readProject()
        for (a, e) in zip(actual.tasks, expected.tasks) {
            XCTAssertEqual(a.baselines.keys.sorted(), Array(0..<50), "task \(e.uid)")
            for slot in 0..<50 {
                XCTAssertEqual(a.baselines[slot]?.start, e.baselines[slot]?.start, "task \(e.uid) slot \(slot)")
            }
        }
        for (a, e) in zip(actual.assignments, expected.assignments) {
            XCTAssertEqual(a.baselines.keys.sorted(), e.baselines.keys.sorted())
        }
    }

    /// What Project sees: the file without the app's stream holds exactly
    /// Baseline...Baseline10.
    func testProjectSeesOnlyItsElevenSlots() throws {
        let bytes = try MPP14Writer(template: try blankTemplate()).build(project(slots: 0..<50))
        let file = try MPP14File(bytes: bytes)
        XCTAssertNotNil(try? file.root.stream(MPP.extraBaselinesStream))
        file.root.removeChild(MPP.extraBaselinesStream)
        let seen = try file.readProject()
        for t in seen.tasks { XCTAssertEqual(t.baselines.keys.sorted(), Array(0...10), "task \(t.uid)") }
    }

    /// Eleven or fewer: no stream, so the file is what it was before.
    func testNoStreamWithoutExtraSlots() throws {
        let bytes = try MPP14Writer(template: try blankTemplate()).build(project(slots: 0..<11))
        XCTAssertNil(try? MPP14File(bytes: bytes).root.stream(MPP.extraBaselinesStream))
    }
}
