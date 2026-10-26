// MPPKit: Microsoft Project (.mpp) files in Swift
// Copyright (C) 2026 Henrik Petersen
//
// Portions are ported from pymppwriter, Copyright (c) Kevin McAleer,
// under the MIT License; see THIRD_PARTY_NOTICES.md.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License version 3 as
// published by the Free Software Foundation. It is distributed WITHOUT ANY
// WARRANTY; see the LICENSE file for details. https://mppstudio.com
//
// SPDX-License-Identifier: AGPL-3.0-only

#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif
import MPPCFB
import MPPModel

/// Reads an `.mpp` file saved by Microsoft Project 2010 through Microsoft 365
/// (the MPP14 family).
///
/// The reader is field-map driven in exactly the same way the writer is: every
/// record offset comes from the file's own `Props` field maps and every flag
/// from its own meta bitmaps. There are therefore no hard-coded record layouts
/// to go stale between Project versions — which matters because Project
/// reorders the field map each time it saves, so offsets differ between files
/// written by the same version.
public final class MPP14File {
    public let root: CFBStorage
    public let props: MPP.PropsStream

    /// The container's root CLSID. For a genuine Project file this is
    /// `CFBFile.projectRootCLSID`.
    public let rootCLSID: [UInt8]

    /// Whether the root CLSID is the one Project stamps on its own files. A file
    /// that parses but fails this was probably produced by another tool.
    public var hasProjectRootCLSID: Bool {
        rootCLSID == CFBFile.projectRootCLSID
    }

    public convenience init(data: Data) throws { try self.init(bytes: [UInt8](data)) }

    public convenience init(contentsOf url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    public convenience init(path: String) throws {
        try self.init(contentsOf: URL(fileURLWithPath: path))
    }

    public init(bytes: [UInt8]) throws {
        let cfb = try CFBFile(bytes: bytes)
        self.root = cfb.root
        self.rootCLSID = cfb.rootCLSID
        let propsPath = "\(MPP.projectStorage)/Props"
        guard let raw = try? cfb.root.stream(path: propsPath) else {
            // Earlier Project versions keep the project in a storage named
            // for their format: say which, rather than "corrupt".
            let older = ["   112": "Microsoft Project 2007", "   19": "Microsoft Project 2000–2003",
                         "   18": "Microsoft Project 98"]
            if let version = older.first(where: { cfb.root.children[$0.key] != nil })?.value {
                throw MPPError.olderFormat(version)
            }
            throw MPPError.notAnMPPFile("no \(propsPath) stream")
        }
        self.props = MPP.parseProps(raw)
    }

    // MARK: - Entity classes

    /// One entity class (tasks, resources, assignments, relations) together with
    /// the field map and block streams that describe its records.
    final class EntityClass {
        let fieldMap: [UInt32: MPP.FieldItem]
        /// native field id -> its bit in the meta bitmaps.
        let bitIndex: [UInt32: MPP.MetaBit]
        var records: [[UInt8]] = []
        var metas: [[UInt8]] = []
        var records2: [[UInt8]] = []
        var metas2: [[UInt8]] = []
        var varTable: [Int: [UInt32: Int]] = [:]
        var varData: [UInt8] = []

        init(root: CFBStorage, storage: String, metaSize: Int, meta2Size: Int,
             propsKey: UInt32, props: MPP.PropsStream) {
            var fm: [UInt32: MPP.FieldItem] = [:]
            let items = props[propsKey].map(MPP.parseFieldMap) ?? []
            for item in items where item.inFixed && fm[item.nativeID] == nil { fm[item.nativeID] = item }
            self.fieldMap = fm
            self.bitIndex = MPP.metaBits(items)

            if let meta = try? root.stream(path: "\(storage)/FixedMeta"),
               let data = try? root.stream(path: "\(storage)/FixedData"),
               let parsed = try? MPP.parseFixedMetaAuto(meta, defaultItemSize: metaSize) {
                metas = MPP.declaredItems(parsed)
                records = MPP.splitFixedData(data, metaItems: metas)
            }
            if let meta2 = try? root.stream(path: "\(storage)/Fixed2Meta"),
               let data2 = try? root.stream(path: "\(storage)/Fixed2Data"),
               let parsed2 = try? MPP.parseFixedMetaAuto(meta2, defaultItemSize: meta2Size) {
                metas2 = MPP.declaredItems(parsed2)
                records2 = MPP.splitFixedData(data2, metaItems: metas2)
            }
            if let vm = try? root.stream(path: "\(storage)/VarMeta"),
               let vd = try? root.stream(path: "\(storage)/Var2Data") {
                varTable = MPP.parseVarMeta(vm).table
                varData = vd
            }
        }

        /// The fixed-block bytes backing record `i`, honouring which block the
        /// field map says the field lives in.
        private func source(_ i: Int, _ item: MPP.FieldItem) -> [UInt8] {
            if item.block == 0 { return i < records.count ? records[i] : [] }
            return i < records2.count ? records2[i] : []
        }

        func u32(_ i: Int, _ id: UInt32) -> UInt32? {
            guard let it = fieldMap[id] else { return nil }
            return BinaryReader(source(i, it)).u32(at: it.offset)
        }

        func i32(_ i: Int, _ id: UInt32) -> Int32? {
            guard let it = fieldMap[id] else { return nil }
            return BinaryReader(source(i, it)).i32(at: it.offset)
        }

        func u16(_ i: Int, _ id: UInt32) -> UInt16? {
            guard let it = fieldMap[id] else { return nil }
            return BinaryReader(source(i, it)).u16(at: it.offset)
        }

        func f64(_ i: Int, _ id: UInt32) -> Double? {
            guard let it = fieldMap[id] else { return nil }
            return BinaryReader(source(i, it)).f64(at: it.offset)
        }

        func timestamp(_ i: Int, _ id: UInt32) -> Date? {
            guard let it = fieldMap[id] else { return nil }
            return MPP.decodeTimestamp(source(i, it), offset: it.offset)
        }

        func bytes(_ i: Int, _ id: UInt32, count: Int) -> [UInt8]? {
            guard let it = fieldMap[id] else { return nil }
            let src = source(i, it)
            guard it.offset + count <= src.count else { return nil }
            return Array(src[it.offset..<it.offset + count])
        }

        /// Read a boolean whose value lives in its field map entry's meta bit.
        func flag(_ i: Int, _ id: UInt32) -> Bool {
            guard let idx = bitIndex[id], i < metas.count else { return false }
            let meta2 = i < metas2.count ? metas2[i] : []
            return (MPP.metaBit(meta: metas[i], meta2: meta2, idx) ?? 0) != 0
        }

        func varBytes(_ uid: Int, _ id: UInt32) -> [UInt8]? {
            guard let off = varTable[uid]?[id] else { return nil }
            return MPP.readVar(varData, offset: off)
        }

        func text(_ uid: Int, _ id: UInt32) -> String {
            guard let raw = varBytes(uid, id), !raw.isEmpty else { return "" }
            return MPP.decodeUnicode(raw)
        }
    }

    private func classMap(_ propsKey: UInt32) -> (fm: [UInt32: MPP.FieldItem], bits: [UInt32: MPP.MetaBit]) {
        var fm: [UInt32: MPP.FieldItem] = [:]
        let items = props[propsKey].map(MPP.parseFieldMap) ?? []
        for item in items where item.inFixed && fm[item.nativeID] == nil { fm[item.nativeID] = item }
        return (fm, MPP.metaBits(items))
    }

    // MARK: - Reading

    /// Minutes in one project day, from the file's own calendar options.
    ///
    /// Every duration, lag and baseline duration on disk is in tenths of a
    /// minute, and Project displays them in days of *this* length — a project
    /// on a 7.5- or 8.5-hour day would otherwise read 6% off everywhere.
    public var minutesPerDay: Int {
        guard let v = props.u32(MPP.PropsKey.minutesPerDay), v > 0, v <= 1_440 else { return 480 }
        return Int(v)
    }

    private var tenthsPerDay: Double { Double(minutesPerDay * 10) }

    /// Tenths of a minute to project days, rounded to four places.
    private func days(_ tenths: Int32) -> Double {
        (Double(tenths) / tenthsPerDay * 10_000).rounded() / 10_000
    }

    public func readProject() throws -> Project {
        let calendars = readCalendars()
        let tasks = try readTasks(calendarNames: calendars.names)
        let resources = readResources()
        let assignments = readAssignments()
        let relations = readRelations()

        let start = props[MPP.PropsKey.projectStartDate].flatMap {
            MPP.decodeTimestamp($0, offset: 0)
        } ?? tasks.compactMap { $0.start }.min() ?? Date()

        var project = Project(title: props.text(MPP.PropsKey.title) ?? "Project", start: start)
        project.finish = props[MPP.PropsKey.projectFinishDate].flatMap {
            MPP.decodeTimestamp($0, offset: 0)
        }
        project.tasks = tasks
        project.resources = resources
        project.assignments = assignments
        // A link to a task that is gone (deleted, its record left behind) is
        // not part of the plan; Project ignores it too.
        let uids = Set(tasks.map(\.uid))
        project.relations = relations.filter { uids.contains($0.predUID) && uids.contains($0.succUID) }
        project.fieldAliases = readTaskFieldAliases()
        project.calendar = calendars.standard
        project.calendars = calendars.base
        // A resource calendar is named after its resource.
        project.resourceCalendars = calendars.resource.map { cal in
            var cal = cal
            if cal.name.isEmpty, let r = resources.first(where: { $0.uid == cal.resourceUID }) { cal.name = r.name }
            return cal
        }
        project.defaultCalendar = props.text(MPP.PropsKey.defaultCalendarName)
        // The app's shifts and holiday sets, kept beside Project's calendars.
        if let bytes = try? root.stream(MPP.calendarSetupStream) {
            let setups = CalendarSetup.decode(bytes)
            if let name = project.calendar?.name, let setup = setups[name] {
                project.calendar?.shifts = setup.shifts
                project.calendar?.holidays = setup.holidays
            }
            for i in project.calendars.indices {
                if let setup = setups[project.calendars[i].name] {
                    project.calendars[i].shifts = setup.shifts
                    project.calendars[i].holidays = setup.holidays
                }
            }
        }
        project.currencySymbol = props.text(MPP.PropsKey.currencySymbol)
        project.currencyCode = props.text(MPP.PropsKey.currencyCode)

        project.minutesPerDay = minutesPerDay
        project.inferSplitGaps()
        if let v = props.u32(MPP.PropsKey.minutesPerWeek), v > 0 { project.minutesPerWeek = Int(v) }
        if let raw = props[MPP.PropsKey.daysPerMonth], let v = BinaryReader(raw).u16(at: 0), v > 0 {
            project.daysPerMonth = Int(v)
        }
        if let raw = props[MPP.PropsKey.defaultStartTime], let v = BinaryReader(raw).u16(at: 0) {
            project.defaultStartTime = Int(v) / 10
        }
        if let raw = props[MPP.PropsKey.defaultFinishTime], let v = BinaryReader(raw).u16(at: 0) {
            project.defaultFinishTime = Int(v) / 10
        }

        if let raw = props[MPP.PropsKey.statusDate],
           let u = BinaryReader(raw).u32(at: 0), u != 0xFFFF_FFFF {
            project.statusDate = MPP.decodeTimestamp(raw, offset: 0)
        }
        Self.applyDocumentProperties(to: &project, root: root)
        // Baselines past Project's eleven, kept by the app.
        if let bytes = try? root.stream(MPP.extraBaselinesStream) {
            ExtraBaselines.decode(bytes).apply(to: &project)
        }
        // The columns: Project's Entry table is the truth both ways. The
        // app's own list — which also keeps widths and columns Project's
        // table cannot hold — is used while it still agrees with that table,
        // i.e. unless the file was since changed in Project.
        let saved = (try? root.stream(MPP.viewColumnsStream)).map {
            String(decoding: $0, as: UTF8.self).split(separator: ",").map(String.init)
        }
        let entry = readEntryTableColumns()
        if let saved, let entry {
            let mappable = Set(MPP.EntryTable.fields.map(\.name))
            func names(_ list: [String]) -> [String] {
                list.map { String($0.split(separator: ":").first ?? "") }.filter(mappable.contains)
            }
            project.viewColumns = names(saved) == names(entry) ? saved : entry
        } else {
            project.viewColumns = saved ?? entry
        }
        return project
    }

    /// The app's names for the columns of Project's Entry table, in order and
    /// with their widths ("start:91", characters at 7 pt each); columns the
    /// app does not show (Indicators, Task Mode, …) are skipped.
    private func readEntryTableColumns() -> [String]? {
        typealias T = MPP.EntryTable
        guard let vm = try? root.stream(path: "\(T.storage)/VarMeta"),
              let vd = try? root.stream(path: "\(T.storage)/Var2Data") else { return nil }
        guard let entry = MPP.parseVarMeta(vm).entries.last(where: {
            $0.uid == T.tableID && $0.field & 0xFFFF == T.columnsField }) else { return nil }
        let blob = MPP.readVar(vd, offset: entry.offset)
        let r = BinaryReader(blob)
        guard let n = r.u16(at: 4).map({ Int($0) + 1 }),
              blob.count >= T.headerSize + n * T.recordSize else { return nil }
        let names = Dictionary(T.fields.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let out = (0..<n).compactMap { i -> String? in
            let at = T.headerSize + i * T.recordSize
            guard let name = r.u32(at: at).flatMap({ names[$0] }) else { return nil }
            // The name column is left to fit the window — Project's is often
            // a hundred characters wide; others are kept, within reason.
            let chars = Int(blob[at + 4])
            return chars > 0 && name != "name" ? "\(name):\(min(chars * 7, 200))" : name
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Document metadata

    /// Property ids in the `SummaryInformation` set ([MS-OLEPS] / [MS-PROPSTORE]).
    private enum SummaryPID {
        static let title: UInt32 = 2
        static let subject: UInt32 = 3
        static let author: UInt32 = 4
        static let keywords: UInt32 = 5
        static let comments: UInt32 = 6
        static let lastSavedBy: UInt32 = 8
        static let revision: UInt32 = 9
        static let creatingApplication: UInt32 = 18
    }

    /// Property ids in the first section of `DocumentSummaryInformation`.
    private enum DocSummaryPID {
        static let category: UInt32 = 2
        static let manager: UInt32 = 14
        static let company: UInt32 = 15
    }

    /// Fill in the document metadata from the OLE property sets.
    ///
    /// These live outside the MPP14 block structures entirely, in the standard
    /// compound-file summary streams, so they are read independently and their
    /// absence is not an error.
    private static func applyDocumentProperties(to project: inout Project, root: CFBStorage) {
        if let raw = try? root.stream("\u{5}SummaryInformation") {
            let doc = OLEPropertySet.parse(raw)
            if let s = doc[0] {
                project.author = s.string(SummaryPID.author)
                project.subject = s.string(SummaryPID.subject)
                project.keywords = s.string(SummaryPID.keywords)
                project.comments = s.string(SummaryPID.comments)
                // Project's own "Title" property and the Props-stream title can
                // disagree; the property set is the document-level one, so it
                // only overrides when the project data has nothing.
                if project.title.isEmpty || project.title == "Project" {
                    project.title = s.string(SummaryPID.title) ?? project.title
                }
            }
        }
        if let raw = try? root.stream("\u{5}DocumentSummaryInformation") {
            let doc = OLEPropertySet.parse(raw)
            if let s = doc[0] {
                project.category = s.string(DocSummaryPID.category)
                project.manager = s.string(DocSummaryPID.manager)
                project.company = s.string(DocSummaryPID.company)
            }
        }
    }

    // MARK: - Custom fields

    /// Values of custom-field lookup tables, by value id: var entry 22 of each
    /// `TBkndOutlCode` record (entry 23 is the value's description).
    private lazy var lookupValues: [Int: String] = {
        let base = "\(MPP.projectStorage)/TBkndOutlCode"
        guard let vm = try? root.stream(path: "\(base)/VarMeta"),
              let vd = try? root.stream(path: "\(base)/Var2Data") else { return [:] }
        var out: [Int: String] = [:]
        for e in MPP.parseVarMeta(vm).entries where e.field & 0xFFFF == 22 {
            out[e.uid] = MPP.decodeUnicode(MPP.readVar(vd, offset: e.offset))
        }
        return out
    }()

    /// A field with a value list stores a reference instead of its text:
    /// `01 07`, the `u32` value id, then the value's GUID.
    private func lookupText(_ raw: [UInt8]) -> String? {
        guard raw.count >= 6, raw[0] == 0x01, raw[1] == 0x07,
              let id = BinaryReader(raw).u32(at: 2) else { return nil }
        return lookupValues[Int(id)]
    }

    /// Read the Text/Number/Date/Flag custom fields for one entity.
    ///
    /// These are keyed by native field id in var data and numbered from 1 for
    /// the caller. Fields with no saved value are left out entirely rather than
    /// reported as empty, so `task.text[1] == nil` means "not set" and an
    /// explicitly blank string is preserved as `""`.
    private func readCustomFields(_ k: EntityClass, uid: Int,
                                  text: inout [Int: String],
                                  numbers: inout [Int: Double],
                                  dates: inout [Int: Date],
                                  flags: inout [Int: Bool]) {
        for (index, id) in MPP.CustomField.text.enumerated() {
            guard let raw = k.varBytes(uid, id), !raw.isEmpty else { continue }
            text[index + 1] = lookupText(raw) ?? MPP.decodeUnicode(raw)
        }
        for (index, id) in MPP.CustomField.number.enumerated() {
            guard let raw = k.varBytes(uid, id), raw.count >= 8,
                  let v = BinaryReader(raw).f64(at: 0) else { continue }
            numbers[index + 1] = v
        }
        for (index, id) in MPP.CustomField.date.enumerated() {
            guard let raw = k.varBytes(uid, id) else { continue }
            if let d = MPP.decodeTimestamp(raw, offset: 0) { dates[index + 1] = d }
        }
        for (index, id) in MPP.CustomField.flag.enumerated() {
            guard let raw = k.varBytes(uid, id) else { continue }
            // Flags are stored as an int32 holding 0 or 1.
            if let v = BinaryReader(raw).i32(at: 0) { flags[index + 1] = v != 0 }
        }
    }

    private func readTasks(calendarNames: [Int: String]) throws -> [ProjectTask] {
        let k = EntityClass(root: root, storage: "\(MPP.projectStorage)/TBkndTask",
                            metaSize: MPP.taskMetaSize, meta2Size: MPP.taskMeta2Size,
                            propsKey: MPP.PropsKey.taskFieldMap, props: props)
        var out: [ProjectTask] = []
        for i in 0..<k.records.count {
            // Deleted-task stubs and other placeholders carry no fields at all.
            if k.records[i].count <= 100 { continue }
            guard let uid = k.u32(i, MPP.TaskField.uniqueID), uid != 0 else { continue }
            // uid 0 is the project summary row.
            guard let start = k.timestamp(i, MPP.TaskField.start),
                  let finish = k.timestamp(i, MPP.TaskField.finish) else { continue }

            let tenths = k.i32(i, MPP.TaskField.duration) ?? 0
            let unitsWord = k.u16(i, MPP.TaskField.actualDurationUnits) ?? 0
            let unitCode = unitsWord & ~MPP.estimatedFlag
            let constraintName = k.u16(i, MPP.TaskField.constraintType)
                .flatMap { MPP.constraintTypes[$0] }

            var task = ProjectTask(uid: Int(uid), name: k.text(Int(uid), MPP.TaskField.name),
                            start: start, finish: finish)
            task.rowID = Int(k.u32(i, MPP.TaskField.id) ?? 0)
            task.durationDays = days(tenths)
            task.outlineLevel = Int(k.u16(i, MPP.TaskField.outlineLevel) ?? 1)
            task.parentUID = Int(k.u32(i, MPP.TaskField.parentUID) ?? 0)
            task.summary = k.flag(i, MPP.TaskField.summary)
            task.milestone = k.flag(i, MPP.TaskField.milestone)
            // Summary rows carry a units word of their own (0x15), not a unit.
            task.durationUnits = MPP.unitCodes[unitCode] ?? "d"
            task.estimated = (unitsWord & MPP.estimatedFlag) != 0
            if let raw = k.varBytes(Int(uid), MPP.TaskField.notes), !raw.isEmpty {
                task.notes = MPP14File.decodeRTFNotes(raw)
            }
            let wbs = k.text(Int(uid), MPP.TaskField.wbs)
            task.wbs = wbs.isEmpty ? nil : wbs
            task.constraint = (constraintName == "ASAP") ? nil : constraintName
            if task.constraint != nil {
                task.constraintDate = k.timestamp(i, MPP.TaskField.constraintDate)
            }
            task.deadline = k.timestamp(i, MPP.TaskField.deadline)
            task.percentComplete = Int(k.u16(i, MPP.TaskField.percentComplete) ?? 0)
            task.lateStart = k.timestamp(i, MPP.TaskField.lateStart)
            task.lateFinish = k.timestamp(i, MPP.TaskField.lateFinish)
            task.actualStart = k.timestamp(i, MPP.TaskField.actualStart)
            task.actualFinish = k.timestamp(i, MPP.TaskField.actualFinish)
            task.workHours = Self.hours(k.f64(i, MPP.TaskField.work))
            task.priority = Int(k.u16(i, MPP.TaskField.priority) ?? 500)
            task.taskType = k.u16(i, MPP.TaskField.taskType)
                .flatMap { MPP.taskTypes[$0] } ?? "fixed_units"
            task.effortDriven = k.flag(i, MPP.TaskField.effortDriven)
            task.manual = k.flag(i, MPP.TaskField.manuallyScheduled)
            // A manual task's Start/Finish fields hold what the scheduler would
            // have computed; the dates Project shows are the manual pair.
            if task.manual, !task.summary,
               let ms = k.timestamp(i, MPP.TaskField.manualStart),
               let mf = k.timestamp(i, MPP.TaskField.manualFinish) {
                task.start = ms
                task.finish = mf
            }
            task.created = k.timestamp(i, MPP.TaskField.created)
            task.guid = k.bytes(i, MPP.TaskField.guid, count: 16) ?? []
            if let cal = k.i32(i, MPP.TaskField.calendarUniqueID), cal > 0 {
                task.calendar = calendarNames[Int(cal)]
            }
            task.baselines = readTaskBaselines(k, uid: Int(uid))
            readCustomFields(k, uid: Int(uid),
                                  text: &task.text, numbers: &task.numbers,
                                  dates: &task.dateFields, flags: &task.flags)
            // Custom flags live in the meta bitmap, not in var data.
            for (index, id) in MPP.CustomField.flag.enumerated() where task.flags[index + 1] == nil {
                if k.flag(i, id) { task.flags[index + 1] = true }
            }
            out.append(task)
        }
        // Records are stored in creation order; Project displays them by ID,
        // which is the outline order an app needs.
        return out.sorted { ($0.rowID, $0.uid) < ($1.rowID, $1.uid) }
    }

    /// Work doubles are thousandths of a minute: 60 000 to the hour.
    static func hours(_ raw: Double?) -> Double {
        guard let raw, raw > 0 else { return 0 }
        return (raw / (MPP.workScale * 60) * 10_000).rounded() / 10_000
    }

    private func readResources() -> [Resource] {
        let k = EntityClass(root: root, storage: "\(MPP.projectStorage)/TBkndRsc",
                            metaSize: MPP.resourceMetaSize, meta2Size: 53,
                            propsKey: MPP.PropsKey.resourceFieldMap, props: props)
        var out: [Resource] = []
        for i in 0..<k.records.count {
            if k.records[i].count <= 100 { continue }
            guard let uid = k.u32(i, MPP.ResourceField.uniqueID) else { continue }
            let name = k.text(Int(uid), MPP.ResourceField.name)
            // uid 0 is Project's own unnamed placeholder resource.
            if uid == 0 || name.isEmpty { continue }

            var r = Resource(uid: Int(uid), name: name)
            r.rowID = Int(k.u32(i, MPP.ResourceField.id) ?? 0)
            r.initials = k.text(Int(uid), MPP.ResourceField.initials)
            r.email = k.text(Int(uid), MPP.ResourceField.emailAddress)
            let maxUnits = k.f64(i, MPP.ResourceField.maxUnits)
            let units = (maxUnits ?? MPP.percentScale) / MPP.percentScale
            r.maxUnits = (units * 10_000).rounded() / 10_000
            if let cal = k.i32(i, MPP.ResourceField.calendarUID), cal > 0 { r.calendarUID = Int(cal) }
            r.guid = k.bytes(i, MPP.ResourceField.guid, count: 16) ?? []
            r.baselines = Self.readResourceBaselines(k, uid: Int(uid))
            readCustomFields(k, uid: Int(uid),
                                  text: &r.text, numbers: &r.numbers,
                                  dates: &r.dateFields, flags: &r.flags)
            out.append(r)
        }
        return out.sorted { ($0.rowID, $0.uid) < ($1.rowID, $1.uid) }
    }

    private func readAssignments() -> [Assignment] {
        let k = EntityClass(root: root, storage: "\(MPP.projectStorage)/TBkndAssn",
                            metaSize: MPP.assignmentMetaSize, meta2Size: 53,
                            propsKey: MPP.PropsKey.assignmentFieldMap, props: props)
        var out: [Assignment] = []
        for i in 0..<k.records.count {
            guard let taskUID = k.u32(i, MPP.AssignmentField.taskUniqueID),
                  let resourceUID = k.i32(i, MPP.AssignmentField.resourceUniqueID) else { continue }
            // Negative resource uids are Project's "unassigned" placeholders.
            if taskUID == 0 || resourceUID <= 0 { continue }
            var a = Assignment(taskUID: Int(taskUID), resourceUID: Int(resourceUID))
            let units = k.f64(i, MPP.AssignmentField.units)
            a.units = ((units ?? MPP.percentScale) / MPP.percentScale * 10_000).rounded() / 10_000
            a.workHours = Self.hours(k.f64(i, MPP.AssignmentField.work))
            a.start = k.timestamp(i, MPP.AssignmentField.start)
            a.finish = k.timestamp(i, MPP.AssignmentField.finish)
            if let auid = k.u32(i, MPP.AssignmentField.uniqueID) {
                a.uid = Int(auid)
                a.baselines = Self.readAssignmentBaselines(k, uid: Int(auid))
            }
            out.append(a)
        }
        return out
    }

    /// Custom field names from `TBkndTask/Props`, key 0x04400001: a length,
    /// a count, then per alias a field id (0x0B40 prefix + native field index)
    /// and the offset of its UTF-16 name, measured from byte 4.
    private func readTaskFieldAliases() -> [String: String] {
        guard let raw = try? root.stream(path: "\(MPP.projectStorage)/TBkndTask/Props") else { return [:] }
        guard let d = MPP.parseProps(raw)[0x0440_0001], d.count >= 12 else { return [:] }
        let r = BinaryReader(d)
        guard let count = r.u32(at: 8) else { return [:] }
        var byNative: [UInt32: String] = [:]
        for (kind, ids) in [("text", MPP.CustomField.text), ("number", MPP.CustomField.number),
                            ("date", MPP.CustomField.date), ("flag", MPP.CustomField.flag)] {
            for (i, id) in ids.enumerated() { byNative[id] = "\(kind)\(i + 1)" }
        }
        var out: [String: String] = [:]
        var offset = 12
        for _ in 0..<min(Int(count), 512) {
            guard let fid = r.u32(at: offset), let at = r.u32(at: offset + 4) else { break }
            offset += 8
            var i = Int(at) + 4, units: [UInt16] = []
            while i + 1 < d.count, units.count < 256 {
                let c = UInt16(d[i]) | UInt16(d[i + 1]) << 8
                if c == 0 { break }
                units.append(c); i += 2
            }
            let name = String(decoding: units, as: UTF16.self).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, let key = byNative[fid & 0xFFFF] { out[key] = name }
        }
        return out
    }

    /// Dependencies from `TBkndCons`.
    ///
    /// Only the first three dwords (uid, predecessor, successor) and the type
    /// word are mapped there; the trailer holding lag moved between eras, so it
    /// is read the way the format presents it — 2010-era files put lag units
    /// first, M365 puts the lag.
    private func readRelations() -> [Relation] {
        guard let metaRaw = try? root.stream(path: "\(MPP.projectStorage)/TBkndCons/FixedMeta"),
              let dataRaw = try? root.stream(path: "\(MPP.projectStorage)/TBkndCons/FixedData"),
              let parsed = try? MPP.parseFixedMetaAuto(metaRaw,
                                                       defaultItemSize: MPP.relationMetaSize)
        else { return [] }

        let is2010 = relationLayoutIs2010
        let metas = MPP.declaredItems(parsed)
        var out: [Relation] = []
        var seen = Set<[UInt32]>()
        for (meta, rec) in zip(metas, MPP.splitFixedData(dataRaw, metaItems: metas)) {
            // A non-zero first word in the meta item marks a deleted dependency.
            // Project leaves the record in place, so reading it back resurrects a
            // link the user removed — and two such links can form a cycle that
            // makes the file impossible to reschedule.
            guard BinaryReader(meta).u16(at: 0) == 0 else { continue }
            guard rec.count >= 20 else { continue }
            let r = BinaryReader(rec)
            guard let pred = r.u32(at: 4), let succ = r.u32(at: 8), pred != 0, succ != 0, pred != succ,
                  seen.insert([pred, succ]).inserted else {
                continue
            }
            let kind = r.u16(at: 12).flatMap { MPP.relationTypes[$0] } ?? "FS"
            let lag = r.i32(at: is2010 ? 16 : 14) ?? 0
            let units = r.u16(at: is2010 ? 14 : 18).flatMap { MPP.unitCodes[$0] } ?? "d"
            // A percentage lag is stored as hundredths of a percent.
            let value = units.hasSuffix("%") ? Double(lag) / 10_000 : days(lag)
            out.append(Relation(predUID: Int(pred), succUID: Int(succ), type: kind, lagDays: value, lagUnits: units))
        }
        return out
    }

    /// 2010-era relation records put native field 9 at offset 0 and the lag
    /// after its units word; M365 records put the lag first.
    var relationLayoutIs2010: Bool {
        let (relFM, _) = classMap(MPP.PropsKey.relationFieldMap)
        return relFM[9] != nil && relFM[9]?.offset == 0
    }

    // MARK: - Baselines
    //
    // Baselines live in var data, not the fixed record — the fixed baseline
    // fields stay empty in files Project writes. A cleared slot keeps its entries
    // with the dates at NA and the numbers at zero, so those are skipped.

    static let taskBaselineUnits: [UInt32] =
        [179, 488, 499, 510, 521, 532, 550, 561, 572, 583, 594]
    static let taskBaselineStart: [UInt32] =
        [43, 482, 493, 504, 515, 526, 544, 555, 566, 577, 588]
    static let taskBaselineFinish: [UInt32] =
        [44, 483, 494, 505, 516, 527, 545, 556, 567, 578, 589]
    static let taskBaselineDuration: [UInt32] =
        [27, 487, 498, 509, 520, 531, 549, 560, 571, 582, 593]
    static let taskBaselineWork: [UInt32] =
        [1, 485, 496, 507, 518, 529, 547, 558, 569, 580, 591]
    static let taskBaselineCost: [UInt32] =
        [6, 484, 495, 506, 517, 528, 546, 557, 568, 579, 590]
    static let resourceBaselineWork: [UInt32] =
        [15] + (0..<10).map { UInt32(342 + 10 * $0) }
    static let resourceBaselineCost: [UInt32] =
        [17] + (0..<10).map { UInt32(343 + 10 * $0) }
    static let assignmentBaselineStart: [UInt32] =
        [146, 295, 304, 313, 322, 331, 340, 349, 358, 367, 376]
    static let assignmentBaselineFinish: [UInt32] =
        [147, 296, 305, 314, 323, 332, 341, 350, 359, 368, 377]
    static let assignmentBaselineWork: [UInt32] =
        [16, 289, 298, 307, 316, 325, 334, 343, 352, 361, 370]
    static let assignmentBaselineCost: [UInt32] =
        [32, 290, 299, 308, 317, 326, 335, 344, 353, 362, 371]

    /// Project's "no value" double.
    static let nullDouble: Double = -1e-06

    private static func double(_ raw: [UInt8]?) -> Double? {
        guard let raw, raw.count >= 8, let v = BinaryReader(raw).f64(at: 0) else { return nil }
        return v == nullDouble ? nil : v
    }

    private func readTaskBaselines(_ k: EntityClass, uid: Int) -> [Int: Baseline] {
        var out: [Int: Baseline] = [:]
        for slot in 0..<Self.taskBaselineStart.count {
            let startRaw = k.varBytes(uid, Self.taskBaselineStart[slot])
            let finishRaw = k.varBytes(uid, Self.taskBaselineFinish[slot])
            if startRaw == nil && finishRaw == nil { continue }

            var b = Baseline()
            if let startRaw { b.start = MPP.decodeTimestamp(startRaw, offset: 0) }
            if let finishRaw { b.finish = MPP.decodeTimestamp(finishRaw, offset: 0) }
            if let dur = k.varBytes(uid, Self.taskBaselineDuration[slot]), dur.count >= 4,
               let tenths = BinaryReader(dur).i32(at: 0) {
                b.durationDays = days(tenths)
            }
            if let work = k.varBytes(uid, Self.taskBaselineWork[slot]), work.count >= 8,
               let w = BinaryReader(work).f64(at: 0) {
                b.workHours = Self.hours(w)
            }
            if let cost = k.varBytes(uid, Self.taskBaselineCost[slot]), cost.count >= 8,
               let c = BinaryReader(cost).f64(at: 0) {
                b.cost = c
            }
            // A cleared slot rather than a saved one.
            if b.start == nil && b.finish == nil && b.durationDays == 0 && b.workHours == 0 {
                continue
            }
            out[slot] = b
        }
        return out
    }

    /// Project writes no baseline start or finish on a resource, and clearing a
    /// slot leaves the numbers at zero rather than removing them, so a resource
    /// with nothing assigned looks exactly like a cleared slot. That ambiguity is
    /// in the format; an all-zero entry is therefore not reported.
    private static func readResourceBaselines(_ k: EntityClass, uid: Int) -> [Int: Baseline] {
        var out: [Int: Baseline] = [:]
        for slot in 0..<resourceBaselineWork.count {
            let work = double(k.varBytes(uid, resourceBaselineWork[slot]))
            let cost = double(k.varBytes(uid, resourceBaselineCost[slot]))
            if (work ?? 0) == 0 && (cost ?? 0) == 0 { continue }
            out[slot] = Baseline(workHours: hours(work), cost: cost ?? 0)
        }
        return out
    }

    private static func readAssignmentBaselines(_ k: EntityClass, uid: Int) -> [Int: Baseline] {
        var out: [Int: Baseline] = [:]
        for slot in 0..<assignmentBaselineStart.count {
            let startRaw = k.varBytes(uid, assignmentBaselineStart[slot])
            let finishRaw = k.varBytes(uid, assignmentBaselineFinish[slot])
            if startRaw == nil && finishRaw == nil { continue }
            var b = Baseline()
            if let startRaw { b.start = MPP.decodeTimestamp(startRaw, offset: 0) }
            if let finishRaw { b.finish = MPP.decodeTimestamp(finishRaw, offset: 0) }
            b.workHours = hours(double(k.varBytes(uid, assignmentBaselineWork[slot])))
            b.cost = double(k.varBytes(uid, assignmentBaselineCost[slot])) ?? 0
            if b.start == nil && b.finish == nil && b.workHours == 0 { continue }
            out[slot] = b
        }
        return out
    }

    // MARK: - Notes

    /// Plain text out of the RTF Project stores notes in.
    ///
    /// A small RTF reader rather than a pattern match: Project's notes come
    /// from RichEdit, with font and colour tables, `{\*\generator …}`
    /// groups, CRLFs between control words, `\'hh` escapes in the document's
    /// code page and `\uN` escapes whose fallback characters must be skipped.
    public static func decodeRTFNotes(_ rtf: [UInt8]) -> String {
        guard rtf.starts(with: Array("{\\rtf".utf8)) else {
            // Not RTF: plain text, NUL-terminated.
            return String(decoding: rtf.prefix { $0 != 0 }, as: UTF8.self).trimmed
        }
        var units: [UInt16] = []           // collected as UTF-16 so \u surrogate pairs combine
        var pendingBytes: [UInt8] = []     // \'hh bytes awaiting code-page decoding
        var codePage: UInt32 = 1252
        func flushBytes() {
            guard !pendingBytes.isEmpty else { return }
            let encoding = OLEPropertySet.stringEncoding(codePage: codePage) ?? .windowsCP1252
            let text = String(bytes: pendingBytes, encoding: encoding)
                ?? String(pendingBytes.map { Character(Unicode.Scalar($0)) })
            units.append(contentsOf: text.utf16)
            pendingBytes.removeAll()
        }
        func emit(_ s: String) { flushBytes(); units.append(contentsOf: s.utf16) }

        // Per-group state: whether the group is a skipped destination, and the
        // \uc fallback length.
        var stack: [(skip: Bool, uc: Int)] = [(false, 1)]
        var fallbackToSkip = 0
        let skipped: Set<String> = ["fonttbl", "colortbl", "stylesheet", "info", "pict", "header",
                                     "footer", "listtable", "listoverridetable", "themedata",
                                     "datastore", "latentstyles", "generator", "object", "rsidtbl"]
        let bytes = rtf.prefix { $0 != 0 }
        var i = bytes.startIndex
        func peek(_ k: Int = 0) -> UInt8? { i + k < bytes.endIndex ? bytes[i + k] : nil }

        while let c = peek() {
            switch c {
            case UInt8(ascii: "{"):
                stack.append(stack.last!)
                i += 1
                // `{\\*\\…}` marks an optional destination: skip it whole.
                if peek() == UInt8(ascii: "\\"), peek(1) == UInt8(ascii: "*") { stack[stack.count - 1].skip = true }
            case UInt8(ascii: "}"):
                if stack.count > 1 { stack.removeLast() }
                i += 1
            case UInt8(ascii: "\\"):
                i += 1
                guard let n = peek() else { break }
                if (n >= 0x41 && n <= 0x5A) || (n >= 0x61 && n <= 0x7A) {
                    var word = ""
                    while let ch = peek(), (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A) {
                        word.append(Character(Unicode.Scalar(ch))); i += 1
                    }
                    var digits = ""
                    if peek() == UInt8(ascii: "-") { digits = "-"; i += 1 }
                    while let ch = peek(), ch >= 0x30 && ch <= 0x39 { digits.append(Character(Unicode.Scalar(ch))); i += 1 }
                    if peek() == UInt8(ascii: " ") { i += 1 }
                    let param = Int(digits)
                    let skip = stack.last!.skip
                    if skipped.contains(word) { stack[stack.count - 1].skip = true; continue }
                    if skip { continue }
                    switch word {
                    case "ansicpg": if let p = param, p > 0 { codePage = UInt32(p) }
                    case "uc": stack[stack.count - 1].uc = max(0, param ?? 1)
                    case "u":
                        flushBytes()
                        if let v = param { units.append(UInt16(truncatingIfNeeded: v < 0 ? v + 65_536 : v)) }
                        fallbackToSkip = stack.last!.uc
                    case "par", "line", "sect", "page": emit("\n")
                    case "tab": emit("\t")
                    case "emdash": emit("\u{2014}")
                    case "endash": emit("\u{2013}")
                    case "bullet": emit("\u{2022}")
                    case "lquote": emit("\u{2018}")
                    case "rquote": emit("\u{2019}")
                    case "ldblquote": emit("\u{201C}")
                    case "rdblquote": emit("\u{201D}")
                    default: break
                    }
                    continue
                }
                // Control symbols.
                i += 1
                if stack.last!.skip { if n == UInt8(ascii: "'") { i += 2 }; continue }
                switch n {
                case UInt8(ascii: "'"):
                    let hex = String(decoding: bytes[i..<min(i + 2, bytes.endIndex)], as: UTF8.self)
                    i = min(i + 2, bytes.endIndex)
                    if fallbackToSkip > 0 { fallbackToSkip -= 1; continue }
                    if let b = UInt8(hex, radix: 16) { pendingBytes.append(b) }
                case UInt8(ascii: "~"): emit("\u{00A0}")
                case UInt8(ascii: "_"): emit("\u{2011}")
                case UInt8(ascii: "-"): break
                case 0x0A, 0x0D: emit("\n")
                default: emit(String(Character(Unicode.Scalar(n))))
                }
            case 0x0D, 0x0A:
                i += 1                                   // raw line breaks are not text in RTF
            default:
                i += 1
                if stack.last!.skip { continue }
                if fallbackToSkip > 0 { fallbackToSkip -= 1; continue }
                if c < 0x80 { emit(String(Character(Unicode.Scalar(c)))) } else { pendingBytes.append(c) }
            }
        }
        flushBytes()
        return String(decoding: units, as: UTF16.self).trimmed
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
