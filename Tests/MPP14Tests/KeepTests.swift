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
import Foundation
import MPPKit

/// A file saved over itself keeps what the model does not carry: costs and
/// rates, hyperlinks, outline codes, recurrence, split work, Cost1-10 and the
/// rest stay as Project wrote them. Checked on files Project saved (the
/// corpus from `Tools/ci/fetch-corpus.sh`); skips without one.
final class KeepTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func corpus(_ name: String) throws -> [UInt8] {
        let dir = ProcessInfo.processInfo.environment["MPP_CORPUS"].map { URL(fileURLWithPath: $0) }
            ?? Self.root.appendingPathComponent("Corpus")
        let url = dir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("no \(name) in \(dir.path) — run Tools/ci/fetch-corpus.sh")
        }
        return [UInt8](data)
    }

    private func save(_ project: Project, over bytes: [UInt8]) throws -> [UInt8] {
        var options = MPP14Writer.Options()
        options.scrubTemplateIdentity = false
        return try MPP14Writer(template: bytes, options: options).build(project)
    }

    /// Var data per record: uid (for assignments, task uid × 1 000 000 +
    /// resource uid, since the writer numbers assignments afresh; 999 999 for
    /// no resource) → field → payload.
    private func vars(_ bytes: [UInt8], _ storage: String) throws -> [Int: [UInt32: [UInt8]]] {
        let file = try MPP14File(bytes: bytes)
        let base = "\(MPP.projectStorage)/\(storage)"
        let meta = MPP.parseVarMeta(try file.root.stream(path: "\(base)/VarMeta"))
        let data = try file.root.stream(path: "\(base)/Var2Data")
        var out: [Int: [UInt32: [UInt8]]] = [:]
        for (uid, fields) in meta.table {
            for (field, offset) in fields { out[uid, default: [:]][field] = MPP.readVar(data, offset: offset) }
        }
        guard storage == "TBkndAssn" else { return out }
        // Assignment rows, placeholders for tasks without a resource included.
        let A = MPP.AssignmentField.self
        var fm: [UInt32: MPP.FieldItem] = [:]
        for item in MPP.parseFieldMap(file.props[MPP.PropsKey.assignmentFieldMap] ?? []) where item.inFixed {
            if fm[item.nativeID] == nil { fm[item.nativeID] = item }
        }
        let fixedMeta = try MPP.parseFixedMetaAuto(try file.root.stream(path: "\(base)/FixedMeta"),
                                                   defaultItemSize: MPP.assignmentMetaSize)
        let rows = MPP.splitFixedData(try file.root.stream(path: "\(base)/FixedData"),
                                      metaItems: MPP.declaredItems(fixedMeta))
        var keyed: [Int: [UInt32: [UInt8]]] = [:]
        for row in rows where row.count > 50 {
            let r = BinaryReader(row)
            guard let uid = fm[A.uniqueID].flatMap({ r.u32(at: $0.offset) }),
                  let task = fm[A.taskUniqueID].flatMap({ r.u32(at: $0.offset) }),
                  let resource = fm[A.resourceUniqueID].flatMap({ r.i32(at: $0.offset) }) else { continue }
            // Project's placeholder resource (no one assigned) is -65535.
            keyed[Int(task) * 1_000_000 + (resource < 0 ? 999_999 : Int(resource))] = out[Int(uid)]
        }
        return keyed
    }

    /// Asserts that every `field` the source has on a record comes back
    /// byte for byte, and that the source has at least one.
    private func assertKept(_ source: [UInt8], _ saved: [UInt8], _ storage: String, _ fields: [UInt32],
                            _ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try vars(source, storage), after = try vars(saved, storage)
        var seen = 0
        for (uid, values) in before {
            for field in fields {
                guard let payload = values[field] else { continue }
                seen += 1
                XCTAssertEqual(after[uid]?[field], payload, "\(what): \(storage) \(uid) field \(field)",
                               file: file, line: line)
            }
        }
        XCTAssertGreaterThan(seen, 0, "\(what): the file has none to check", file: file, line: line)
    }

    func testUnchangedSaveKeepsWhatTheModelDoesNotCarry() throws {
        let file = try corpus("mpp14task.mpp")
        let saved = try save(try MPP14File(bytes: file).readProject(), over: file)
        // Hyperlink, Contact, Duration1-3, Cost1-3, Outline Code1-10.
        try assertKept(file, saved, "TBkndTask", [215, 112, 103, 104, 105, 106, 107, 108]
                       + stride(from: 417, through: 435, by: 2).map { $0 }, "task fields")
        // Cost rate table A.
        try assertKept(file, saved, "TBkndRsc", [61], "resource rates")
    }

    func testRecurringTasksKeepTheirPattern() throws {
        let file = try corpus("mpp14recurring.mpp")
        let saved = try save(try MPP14File(bytes: file).readProject(), over: file)
        try assertKept(file, saved, "TBkndTask", [202, 203], "recurrence")
    }

    func testResourceDataIsKept() throws {
        for (name, fields) in [("mpp14costratetable.mpp", [61, 62, 63, 64, 65]),
                               ("mpp14availability.mpp", [276]), ("mpp14resource.mpp", [3, 20])] as [(String, [UInt32])] {
            let file = try corpus(name)
            let saved = try save(try MPP14File(bytes: file).readProject(), over: file)
            try assertKept(file, saved, "TBkndRsc", fields, name)
        }
    }

    func testAssignmentCustomFieldsAreKept() throws {
        let file = try corpus("mpp14assignmentcustom.mpp")
        let saved = try save(try MPP14File(bytes: file).readProject(), over: file)
        try assertKept(file, saved, "TBkndAssn", Array(88...118), "assignment fields")
    }

    /// A split task's work is laid out in its assignment's timephased data;
    /// it is kept while the task is unchanged and rebuilt once it is edited.
    func testSplitTasksKeepTheirSplitsUntilEdited() throws {
        let file = try corpus("mpp14splittask.mpp")
        var project = try MPP14File(bytes: file).readProject()
        try assertKept(file, try save(project, over: file), "TBkndAssn", [49, 50], "split work")

        project.tasks[0].durationDays += 1
        project.tasks[0].start = nil
        try Scheduler.schedule(&project)
        let edited = try save(project, over: file)
        let uid = project.tasks[0].uid
        let before = try vars(file, "TBkndAssn"), after = try vars(edited, "TBkndAssn")
        let key = try XCTUnwrap(before.keys.first { $0 / 1_000_000 == uid })
        XCTAssertNotNil(after[key]?[49])
        XCTAssertNotEqual(after[key]?[49], before[key]?[49], "an edited task's work is laid out afresh")
        XCTAssertEqual(after[key]?[49].flatMap { BinaryReader($0).u16(at: 0) }, 0, "in one piece")
        XCTAssertTrue(try MPP14File(bytes: edited).conformanceIssues().isEmpty)
    }

    /// Names and definitions of task fields the model does not name stay as
    /// they were: outline codes, Cost1-10 and value lists on Text fields.
    func testFieldDefinitionsAreKept() throws {
        for name in ["mpp14task.mpp", "mpp14graphind.mpp", "mpp14filter.mpp"] {
            let file = try corpus(name)
            let saved = try save(try MPP14File(bytes: file).readProject(), over: file)
            let path = "\(MPP.projectStorage)/TBkndTask/Props"
            let before = MPP.parseProps(try MPP14File(bytes: file).root.stream(path: path))
            let after = MPP.parseProps(try MPP14File(bytes: saved).root.stream(path: path))
            XCTAssertEqual(after.values[0x0440_0001], before.values[0x0440_0001], name)
        }
    }

    /// Edits after opening: a task added, one removed, one made a summary.
    /// The file still keeps Project's rules, and untouched tasks keep their data.
    func testEditedPlanKeepsTheRestAndConforms() throws {
        let file = try corpus("mpp14graphind.mpp")
        var project = try MPP14File(bytes: file).readProject()
        let nextUID = (project.tasks.map(\.uid).max() ?? 0) + 1
        let removed = project.tasks.removeLast()
        project.relations.removeAll { $0.predUID == removed.uid || $0.succUID == removed.uid }
        project.assignments.removeAll { $0.taskUID == removed.uid }
        let leaf = project.tasks.last { !$0.summary }!
        var child = ProjectTask(uid: nextUID, name: "Added under a leaf")
        child.outlineLevel = leaf.outlineLevel + 1
        child.parentUID = leaf.uid
        project.tasks.insert(child, at: project.tasks.firstIndex { $0.uid == leaf.uid }! + 1)
        project.relations.removeAll { $0.predUID == leaf.uid || $0.succUID == leaf.uid }
        project.assignments.removeAll { $0.taskUID == leaf.uid }
        for i in project.tasks.indices { project.tasks[i].start = nil; project.tasks[i].finish = nil }
        try Scheduler.schedule(&project)
        let saved = try save(project, over: file)

        XCTAssertTrue(try MPP14File(bytes: saved).conformanceIssues().isEmpty)
        let back = try MPP14File(bytes: saved).readProject()
        XCTAssertEqual(back.tasks.map(\.name), project.tasks.map(\.name))
        let before = try vars(file, "TBkndTask"), after = try vars(saved, "TBkndTask")
        XCTAssertNil(after[removed.uid])
        var seen = 0
        for t in project.tasks where t.uid != leaf.uid && t.uid != child.uid {
            for field: UInt32 in [103, 106] {     // Duration1, Cost1
                guard let value = before[t.uid]?[field] else { continue }
                seen += 1
                XCTAssertEqual(after[t.uid]?[field], value, "task \(t.uid) field \(field)")
            }
        }
        XCTAssertGreaterThan(seen, 0)
    }

    /// Resources number their custom fields on their own (Text1 is 8, not
    /// the task's 51). `mpp14resource.mpp` has Text1-3 "1", "2", "3".
    func testResourceCustomFieldsReadAndSave() throws {
        let file = try corpus("mpp14resource.mpp")
        var project = try MPP14File(bytes: file).readProject()
        let first = try XCTUnwrap(project.resources.first { !$0.text.isEmpty })
        XCTAssertEqual(first.text[1], "1")
        XCTAssertEqual(first.text[2], "2")
        XCTAssertEqual(first.text[3], "3")
        XCTAssertEqual(first.numbers[1], 1)
        try assertKept(file, try save(project, over: file), "TBkndRsc", [8, 9, 30, 112, 113, 173, 174],
                       "resource custom fields")

        let i = project.resources.firstIndex { $0.uid == first.uid }!
        project.resources[i].text[2] = "Changed"
        project.resources[i].text[30] = "Last"
        project.resources[i].numbers[20] = 42.5
        project.resources[i].dateFields[10] = MPPTime.date(2026, 3, 2, 8)
        project.resources[i].flags[10] = true
        project.resources[i].flags[1] = true
        let saved = try save(project, over: file)
        XCTAssertTrue(try MPP14File(bytes: saved).conformanceIssues().isEmpty)
        let back = try XCTUnwrap(try MPP14File(bytes: saved).readProject().resource(uid: first.uid))
        XCTAssertEqual(back.text, project.resources[i].text)
        XCTAssertEqual(back.numbers, project.resources[i].numbers)
        XCTAssertEqual(back.dateFields, project.resources[i].dateFields)
        XCTAssertEqual(back.flags.filter(\.value), project.resources[i].flags.filter(\.value))
    }

    /// The same on a new plan over the blank template, which needs no corpus.
    func testResourceCustomFieldsOnANewPlan() throws {
        let template = [UInt8](try Data(contentsOf: Self.root.appendingPathComponent("Samples/Blank-Template.mpp")))
        var project = SampleProject.make()
        project.resources[0].text = [1: "Crane", 12: "Site B"]
        project.resources[0].numbers = [1: 12.5]
        project.resources[0].flags = [2: true]
        let back = try MPP14File(bytes: try MPP14Writer(template: template).build(project)).readProject()
        let r = try XCTUnwrap(back.resource(uid: project.resources[0].uid))
        XCTAssertEqual(r.text, [1: "Crane", 12: "Site B"])
        XCTAssertEqual(r.numbers, [1: 12.5])
        XCTAssertEqual(r.flags.filter(\.value), [2: true])
        XCTAssertTrue(back.resources.dropFirst().allSatisfy { $0.text.isEmpty && $0.numbers.isEmpty })
    }

    /// Another file used as the template lends nothing to a task that only
    /// shares its uid: records match on uid and GUID.
    func testAnotherTemplateLendsNothing() throws {
        let template = try corpus("mpp14task.mpp")
        var project = try MPP14File(bytes: try corpus("mpp14recurring.mpp")).readProject()
        project.tasks = project.tasks.filter { $0.parentUID == 0 }.map {
            var t = $0
            t.outlineLevel = 1
            return t
        }
        let uids = Set(project.tasks.map(\.uid))
        project.relations.removeAll { !uids.contains($0.predUID) || !uids.contains($0.succUID) }
        project.assignments.removeAll { !uids.contains($0.taskUID) }
        let saved = try save(project, over: template)
        let after = try vars(saved, "TBkndTask")
        for uid in uids {
            for field: UInt32 in [215, 112, 106, 417, 203] { XCTAssertNil(after[uid]?[field], "task \(uid) field \(field)") }
        }
    }
}
