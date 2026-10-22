// MPPKit: Microsoft Project (.mpp) files in Swift
// Copyright (C) 2026 Henrik Petersen
//
// Portions are ported from pymppwriter, Copyright (c) Kevin McAleer,
// under the MIT License; see THIRD_PARTY_NOTICES.md.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 3 as published
// by the Free Software Foundation. It is distributed WITHOUT ANY WARRANTY;
// see the LICENSE file for details. https://mppstudio.com
//
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import MPPCFB
import MPPModel

/// Writes MPP14 (Project 2010 through Microsoft 365) files.
///
/// **Template-and-patch.** A Project file carries ~170 KB of view, table,
/// filter and Gantt-bar definitions that Project insists on and nobody has
/// specified. The writer therefore starts from a file Project itself saved,
/// keeps every stream it does not own byte-for-byte, and rebuilds the task,
/// dependency, resource, assignment and calendar tables by cloning the
/// template's own records as prototypes and patching the fields it controls.
/// Field offsets come from the template's field maps, so the output speaks the
/// dialect of whichever Project version saved the template.
///
/// Ported from the MIT-licensed pymppwriter (see THIRD_PARTY_NOTICES.md), with
/// one deliberate difference: upstream assumes a near-empty template, while
/// this writer accepts any Project-saved file. It never carries the template's
/// tasks, resources, assignments, links or resource calendars over, and it
/// strips per-record data (notes, custom fields, baselines) from the records
/// it clones, so a real schedule can serve as the template.
public final class MPP14Writer {
    public struct Options {
        /// Replace the template's saved path, user name and document metadata
        /// with the project's own (empty where the project has none), so the
        /// output does not carry the template author's identity.
        public var scrubTemplateIdentity = true
        /// Clock used for creation stamps; fix it for reproducible output.
        public var now: () -> Date = {
            let d = Date()
            return d.addingTimeInterval(-d.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
                                        + Double(TimeZone.current.secondsFromGMT(for: d)))
        }
        /// GUID source, 16 bytes in on-disk order; fix it for reproducible output.
        public var newGUID: () -> [UInt8] = {
            withUnsafeBytes(of: UUID().uuid) { Array($0) }
        }

        public init() {}
    }

    private let templateBytes: [UInt8]
    public var options: Options

    public init(template bytes: [UInt8], options: Options = Options()) throws {
        // Fail early on something that is not a project file at all.
        _ = try MPP14File(bytes: bytes)
        self.templateBytes = bytes
        self.options = options
    }

    public convenience init(templateURL: URL, options: Options = Options()) throws {
        try self.init(template: [UInt8](try Data(contentsOf: templateURL)), options: options)
    }

    public func write(_ project: Project, to url: URL) throws {
        try Data(try build(project)).write(to: url, options: .atomic)
    }

    /// The complete `.mpp` file for `project`.
    public func build(_ project: Project) throws -> [UInt8] {
        let session = try Session(templateBytes: templateBytes, options: options)
        return try session.build(project)
    }
}

// MARK: - Constants

private enum W {
    static let prj = MPP.projectStorage
    static let workScale = 100.0          // work doubles: duration tenths × 100
    static let pctScale = MPP.percentScale
    static let nullResourceUID: Int32 = -65_535
    static let nullResourceGUID: [UInt8] = [0x78, 0x8B, 0xCB, 0xA0, 0x8C, 0x2A, 0x6D, 0x43,
                                            0, 0, 0, 0, 0, 0, 0, 0xFF]
    static let unsetDouble: [UInt8] = [0x8D, 0xED, 0xB5, 0xA0, 0xF7, 0xC6, 0xB0, 0xBE] // -1e-06
    static let relationTypes: [String: UInt16] = ["FF": 0, "FS": 1, "SF": 2, "SS": 3]
    static let constraintCodes: [String: UInt16] = [
        "ASAP": 0, "ALAP": 1, "MSO": 2, "MFO": 3, "SNET": 4, "SNLT": 5, "FNET": 6, "FNLT": 7,
    ]
    static let taskTypeCodes: [String: UInt16] = ["fixed_units": 0, "fixed_duration": 1, "fixed_work": 2]

    enum Assn {
        static let plannedWorkData: UInt32 = 49   // timephased remaining regular work
        static let actualWorkData: UInt32 = 50    // timephased actual regular work
        static let actualIrregularData: UInt32 = 87
        static let emptyVars: [UInt32] = [665, 667]   // 16 zero bytes; 667 only on placeholders
        static let baselineBudget: [(work: UInt32, cost: UInt32)] = [(673, 674), (677, 678)]
        static let baselineTimephased: [UInt32] = [52, 53]
    }
    enum TaskIDs {
        static let baselineExtras: [(ds: UInt32, df: UInt32, bw: UInt32, bc: UInt32)] =
            [(1174, 1175, 1176, 1177), (1180, 1181, 1182, 1183)]
        static let baselineTimephased: [UInt32] = [173, 174]
    }
    enum Rsc {
        static let baselineBudget: [(work: UInt32, cost: UInt32)] = [(756, 757), (760, 761)]
        static let baselineTimephased: [UInt32] = [68, 69]
    }
    enum View {
        static let storage = "   214"
        static let edlRows: UInt32 = 0x2640_0035
        static let edlLayout: UInt32 = 0x2640_003D
        static let edlPainted: UInt32 = 0x2640_0024
        static let edlVar2DataSize: UInt32 = 0x10007
        /// Gantt timescale: range start, range end and scroll position, as
        /// `u32` tenths of a minute since the MPP epoch.
        static let edlRangeStart: UInt32 = 0x2640_002A
        static let edlRangeEnd: UInt32 = 0x2640_002B
        static let edlScroll: UInt32 = 0x2640_002D
    }
    enum Summary {
        static let title: UInt32 = 2, subject: UInt32 = 3, author: UInt32 = 4
        static let keywords: UInt32 = 5, comments: UInt32 = 6, template: UInt32 = 7, lastSavedBy: UInt32 = 8
        static let category: UInt32 = 2, manager: UInt32 = 14, company: UInt32 = 15
    }
}

// MARK: - Records

/// One row of an entity table: its fixed records and meta items in both blocks.
private struct Row {
    var rec: [UInt8]
    var rec2: [UInt8]
    var meta: [UInt8]
    var meta2: [UInt8]
}

/// A row being patched through its class's field map.
private struct Editor {
    var row: Row
    let fm: [UInt32: MPP.FieldItem]
    let bits: [UInt32: Int]

    mutating func put(_ id: UInt32, _ value: [UInt8]) {
        guard let it = fm[id] else { return }
        if it.block == 0 {
            guard it.offset + value.count <= row.rec.count else { return }
            row.rec.replaceSubrange(it.offset..<it.offset + value.count, with: value)
        } else {
            guard it.offset + value.count <= row.rec2.count else { return }
            row.rec2.replaceSubrange(it.offset..<it.offset + value.count, with: value)
        }
    }
    mutating func u16(_ id: UInt32, _ v: UInt16) { var w = BinaryWriter(); w.u16(v); put(id, w.bytes) }
    mutating func u32(_ id: UInt32, _ v: UInt32) { var w = BinaryWriter(); w.u32(v); put(id, w.bytes) }
    mutating func i32(_ id: UInt32, _ v: Int32) { var w = BinaryWriter(); w.i32(v); put(id, w.bytes) }
    mutating func f64(_ id: UInt32, _ v: Double) { var w = BinaryWriter(); w.f64(v); put(id, w.bytes) }
    mutating func ts(_ id: UInt32, _ d: Date?) { put(id, MPP.encodeTimestamp(d)) }
    /// Set a field's meta bit.
    ///
    /// For a boolean field the bit *is* the value. For a fixed value field it
    /// only says the field is present, and Project keeps it set whatever the
    /// value — clearing it on an empty % complete, actual start or deadline
    /// makes Project derive the value itself, which it does as 100% complete
    /// on milestones and some constrained tasks. Such bits are therefore only
    /// ever set, never cleared, so they stay as the Project-written prototype
    /// has them.
    mutating func bit(_ id: UInt32, _ v: Bool) {
        guard let i = bits[id] else { return }
        if fm[id] != nil && !v { return }
        MPP.setMetaBit(meta: &row.meta, meta2: &row.meta2, entryIndex: i, value: v)
    }
    func has(_ id: UInt32) -> Bool { fm[id] != nil }
}

private func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] {
    withUnsafeBytes(of: v.littleEndian) { Array($0) }
}
private func le(_ v: Double) -> [UInt8] { le(v.bitPattern) }

/// A deleted-record placeholder: 16 bytes, `u16` slot index, `FF FF`, zeros.
/// Project keeps these at the head of a table and they are carried verbatim.
/// A blank task-sheet row is also 16 bytes but holds a real uid, row number
/// and position, and the zero-length item past a table's declared count is
/// slack — neither may be carried into another project.
private func isDeletedStub(_ rec: [UInt8]) -> Bool {
    rec.count == 16 && rec[2] == 0xFF && rec[3] == 0xFF && rec[4...].allSatisfy { $0 == 0 }
}

private func assemble(_ rows: [Row], second: Bool) -> (data: [UInt8], metas: [[UInt8]]) {
    var data: [UInt8] = []
    var metas: [[UInt8]] = []
    for row in rows {
        var m = second ? row.meta2 : row.meta
        let r = second ? row.rec2 : row.rec
        if m.count >= 8 { m.replaceSubrange(4..<8, with: le(UInt32(data.count))) }
        data.append(contentsOf: r)
        metas.append(m)
    }
    return (data, metas)
}

// MARK: - One build

private final class Session {
    let root: CFBStorage
    var props: MPP.PropsStream
    let options: MPP14Writer.Options
    let taskMap: (fm: [UInt32: MPP.FieldItem], bits: [UInt32: Int])
    let rscMap: (fm: [UInt32: MPP.FieldItem], bits: [UInt32: Int])
    let assnMap: (fm: [UInt32: MPP.FieldItem], bits: [UInt32: Int])
    let relation2010: Bool
    let templateStart: [UInt8]?
    let templateStandard: ProjectCalendar?

    init(templateBytes: [UInt8], options: MPP14Writer.Options) throws {
        let file = try MPP14File(bytes: templateBytes)
        root = file.root
        props = file.props
        self.options = options
        func map(_ key: UInt32) -> ([UInt32: MPP.FieldItem], [UInt32: Int]) {
            var fm: [UInt32: MPP.FieldItem] = [:], bits: [UInt32: Int] = [:]
            for (i, item) in MPP.parseFieldMap(file.props[key] ?? []).enumerated() {
                if item.inFixed, fm[item.nativeID] == nil { fm[item.nativeID] = item }
                if bits[item.nativeID] == nil { bits[item.nativeID] = i }
            }
            return (fm, bits)
        }
        taskMap = map(MPP.PropsKey.taskFieldMap)
        rscMap = map(MPP.PropsKey.resourceFieldMap)
        assnMap = map(MPP.PropsKey.assignmentFieldMap)
        relation2010 = file.relationLayoutIs2010
        templateStart = file.props[MPP.PropsKey.projectStartDate]
        templateStandard = file.readCalendars().standard
    }

    // MARK: Stream access

    func stream(_ path: String) throws -> [UInt8] {
        do { return try root.stream(path: "\(W.prj)/\(path)") }
        catch { throw MPPError.template("missing stream \(path)") }
    }
    func set(_ path: String, _ data: [UInt8]) { root.setStream(path: "\(W.prj)/\(path)", data) }

    struct Table {
        var rows: [Row]
        var metaHeader: [UInt8]
        var meta2Header: [UInt8]
        var varHeader: [UInt8]
        var varTable: [Int: [UInt32: Int]]
        var varData: [UInt8]
        func vars(of uid: Int) -> [(field: UInt32, payload: [UInt8])] {
            (varTable[uid] ?? [:]).sorted { $0.key < $1.key }
                .map { ($0.key, MPP.readVar(varData, offset: $0.value)) }
        }
    }

    func table(_ storage: String, metaSize: Int, meta2Size: Int) throws -> Table {
        let metaRaw = try stream("\(storage)/FixedMeta")
        let meta = try MPP.parseFixedMetaAuto(metaRaw, defaultItemSize: metaSize)
        let items = MPP.declaredItems(meta)
        let recs = MPP.splitFixedData(try stream("\(storage)/FixedData"), metaItems: items)
        var meta2Items: [[UInt8]] = [], recs2: [[UInt8]] = [], meta2Header: [UInt8] = []
        if let m2 = try? stream("\(storage)/Fixed2Meta"), let d2 = try? stream("\(storage)/Fixed2Data") {
            let parsed = try MPP.parseFixedMetaAuto(m2, defaultItemSize: meta2Size)
            meta2Items = MPP.declaredItems(parsed)
            meta2Header = Array(m2.prefix(16))
            recs2 = MPP.splitFixedData(d2, metaItems: parsed.items)
        }
        var rows: [Row] = []
        for i in 0..<recs.count {
            rows.append(Row(rec: recs[i], rec2: i < recs2.count ? recs2[i] : [],
                            meta: items[i], meta2: i < meta2Items.count ? meta2Items[i] : []))
        }
        var varHeader: [UInt8] = [], varTable: [Int: [UInt32: Int]] = [:], varData: [UInt8] = []
        if let vm = try? stream("\(storage)/VarMeta") {
            let parsed = MPP.parseVarMeta(vm)
            varHeader = parsed.header
            varTable = parsed.table
            varData = (try? stream("\(storage)/Var2Data")) ?? []
        }
        return Table(rows: rows, metaHeader: Array(metaRaw.prefix(16)), meta2Header: meta2Header,
                     varHeader: varHeader, varTable: varTable, varData: varData)
    }

    func writeTable(_ storage: String, _ t: Table, rows: [Row],
                    vars: [(uid: Int, field: UInt32, payload: [UInt8])]?, fieldClass: UInt16) {
        let (d1, m1) = assemble(rows, second: false)
        set("\(storage)/FixedData", d1)
        set("\(storage)/FixedMeta", MPP.buildFixedMeta(header: t.metaHeader, items: m1, dataLength: d1.count))
        if !t.meta2Header.isEmpty {
            let (d2, m2) = assemble(rows, second: true)
            set("\(storage)/Fixed2Data", d2)
            set("\(storage)/Fixed2Meta", MPP.buildFixedMeta(header: t.meta2Header, items: m2, dataLength: d2.count))
        }
        if let vars {
            let (vm, vd) = MPP.buildVarBlocks(header: t.varHeader, values: vars, fieldClass: fieldClass)
            set("\(storage)/VarMeta", vm)
            set("\(storage)/Var2Data", vd)
        }
    }

    /// Whether a payload is a "no value" — all zero or all `0xFF` — and so
    /// cannot carry the template's data or point at its records.
    static func isNeutral(_ payload: [UInt8]) -> Bool {
        payload.allSatisfy { $0 == 0 } || payload.allSatisfy { $0 == 0xFF }
    }

    // MARK: Build

    func build(_ input: Project) throws -> [UInt8] {
        var project = input
        try validate(project)

        let tenthsPerDay = Double(project.tenthsPerDay)
        let time = WorkingTime(calendar: project.calendar ?? templateStandard)
        let now = options.now()

        // GUIDs the file links records by.
        for i in project.tasks.indices where project.tasks[i].guid.count != 16 {
            project.tasks[i].guid = options.newGUID()
        }
        for i in project.resources.indices where project.resources[i].guid.count != 16 {
            project.resources[i].guid = options.newGUID()
        }
        let byUID = Dictionary(uniqueKeysWithValues: project.tasks.map { ($0.uid, $0) })
        var children: [Int: [Int]] = [:]
        for t in project.tasks { children[t.parentUID, default: []].append(t.uid) }
        func depth(_ t: MPPModel.ProjectTask) -> Int {
            var d = 0, p = t.parentUID
            while p != 0, let parent = byUID[p], d <= project.tasks.count { d += 1; p = parent.parentUID }
            return d
        }
        let deepestFirst = project.tasks.sorted { depth($0) > depth($1) }

        // Effective (start, finish, duration tenths), summaries rolled up.
        var eff: [Int: (start: Date, finish: Date, tenths: Int)] = [:]
        for t in deepestFirst {
            if let kids = children[t.uid], !kids.isEmpty {
                let s = kids.map { eff[$0]!.start }.min()!, f = kids.map { eff[$0]!.finish }.max()!
                eff[t.uid] = (s, f, time.minutes(from: s, to: f) * 10)
            } else {
                guard let s = t.start, let f = t.finish else {
                    throw MPPError.invalidProject("task \(t.uid) has no start or finish; run Scheduler.schedule first")
                }
                eff[t.uid] = (s, f, Int((t.durationDays * tenthsPerDay).rounded()))
            }
        }

        // Starts the links already produce: those tasks stay ASAP. Every other
        // auto-scheduled start after the project start is pinned with SNET,
        // as Project pins a typed-in date, so it survives recalculation.
        var taskTime: [String: WorkingTime] = [:]
        for cal in project.calendars { taskTime[cal.name] = WorkingTime(calendar: cal) }
        var linkStart: [Int: Date] = [:]
        // The date the driving link imposes before rounding onto working time —
        // what Project records in 387/1255 for a predecessor-driven task.
        var linkDriver: [Int: Date] = [:]
        for rel in project.relations {
            guard let p = eff[rel.predUID], let s = eff[rel.succUID] else { continue }
            let time = byUID[rel.succUID]?.calendar.flatMap { taskTime[$0] } ?? time
            let lag = rel.lagIsPercent
                ? Int((rel.lagDays * (byUID[rel.predUID].map { $0.durationDays } ?? 0) * tenthsPerDay).rounded()) / 10
                : Int((rel.lagDays * tenthsPerDay).rounded()) / 10
            var candidate: Date?, base: Date?
            switch rel.type {
            case "FS":
                base = lag == 0 ? p.finish
                    : (lag > 0 ? time.advance(p.finish, minutes: lag) : time.retreat(p.finish, minutes: -lag))
                candidate = (lag == 0 && s.tenths == 0) ? p.finish : time.nextWorkingMoment(base!)
            case "SS":
                base = lag == 0 ? p.start
                    : (lag > 0 ? time.advance(p.start, minutes: lag) : time.retreat(p.start, minutes: -lag))
                candidate = s.tenths == 0 ? base : time.nextWorkingMoment(base!)
            default:
                candidate = nil
            }
            if let c = candidate, c > (linkStart[rel.succUID] ?? .distantPast) {
                linkStart[rel.succUID] = c
                linkDriver[rel.succUID] = base
            }
        }

        // Work in milli-minutes per task, rolled up into summaries.
        var directWork: [Int: Double] = [:]
        for a in project.assignments {
            directWork[a.taskUID, default: 0] += Double(eff[a.taskUID]!.tenths) * W.workScale * a.units
        }
        var workSum: [Int: Double] = [:]
        for t in deepestFirst {
            var sum = directWork[t.uid] ?? 0
            for kid in children[t.uid] ?? [] { sum += workSum[kid] ?? 0 }
            workSum[t.uid] = sum
        }

        // Percent complete, summaries weighted by duration.
        var pct: [Int: Int] = [:]
        func weighted(_ uids: [Int]) -> Int {
            var total = 0, done = 0
            for uid in uids {
                let tenths = eff[uid]?.tenths ?? 0
                total += tenths
                done += tenths * (pct[uid] ?? 0)
            }
            return total == 0 ? 0 : Int((Double(done) / Double(total)).rounded())
        }
        for t in deepestFirst {
            if let kids = children[t.uid], !kids.isEmpty {
                pct[t.uid] = weighted(kids)
            } else {
                pct[t.uid] = t.percentComplete
            }
        }
        let top = project.tasks.filter { $0.parentUID == 0 }
        let pct0 = weighted(top.map(\.uid))

        let pStart = project.tasks.map { eff[$0.uid]!.start }.min() ?? project.start
        let pFinish = project.tasks.map { eff[$0.uid]!.finish }.max() ?? project.start

        // ---- calendars (before resources, which add resource calendars) ----
        var calendars = try CalendarBuild(session: self, project: project)

        // ---- tasks ----------------------------------------------------------
        let tasks = try table("TBkndTask", metaSize: MPP.taskMetaSize, meta2Size: MPP.taskMeta2Size)
        let protos = try taskPrototypes(tasks)
        var taskRows = tasks.rows.filter { isDeletedStub($0.rec) }
        var taskVars: [(uid: Int, field: UInt32, payload: [UInt8])] = []
        let summaryGUID = options.newGUID()

        func emit(_ proto: Prototype, uid: Int, rowID: Int, name: String,
                  start: Date, finish: Date, tenths: Int, level: Int, parentUID: Int,
                  guid: [UInt8], parentGUID: [UInt8], isSummary: Bool, position: Int,
                  task: MPPModel.ProjectTask?, percent: Int, work: Double,
                  baselines: [Int: Baseline], calendarUID: Int?) {
            var e = Editor(row: proto.row, fm: taskMap.fm, bits: taskMap.bits)
            let F = MPP.TaskField.self
            e.u32(F.uniqueID, UInt32(uid))
            e.u32(F.id, UInt32(rowID))
            e.u16(F.outlineLevel, UInt16(level))
            e.u32(F.parentUID, UInt32(parentUID))
            e.i32(F.duration, Int32(tenths))
            e.i32(F.remainingDuration, Int32(tenths))
            e.f64(F.work, work)
            e.f64(F.remainingWork, work)
            let units = task?.durationUnits ?? "d"
            let estimated = task?.estimated ?? false
            let unitsWord = (isSummary ? MPP.summaryUnits : (MPP.unitLabels[units] ?? 7))
                | (estimated ? MPP.estimatedFlag : 0)
            e.u16(F.actualDurationUnits, unitsWord)
            for f in [F.start, F.earlyStart] { e.ts(f, start) }
            for f in [F.finish, F.earlyFinish] { e.ts(f, finish) }
            e.ts(F.lateStart, task?.lateStart ?? start)
            e.ts(F.lateFinish, task?.lateFinish ?? finish)
            e.ts(F.created, now)
            // Fixed2: GUID, display position, parent GUID.
            if e.row.rec2.count >= 40 {
                e.row.rec2.replaceSubrange(0..<16, with: guid)
                e.row.rec2.replaceSubrange(16..<24, with: le(Double(position)))
                e.row.rec2.replaceSubrange(24..<40, with: parentGUID)
            }
            e.bit(F.summary, isSummary)
            e.bit(F.milestone, !isSummary && (tenths == 0 || task?.milestone == true))
            e.bit(F.estimated, estimated)
            let manual = task?.manual ?? false
            e.bit(F.manuallyScheduled, manual)
            if manual {
                e.ts(F.manualStart, start)
                e.ts(F.manualFinish, finish)
                e.i32(F.manualDuration, Int32(tenths))
                e.u16(F.manualDurationUnits, MPP.unitLabels[units] ?? 7)
            } else {
                e.ts(F.manualStart, nil)
                e.ts(F.manualFinish, nil)
                e.i32(F.manualDuration, 0)          // what Project writes on auto-scheduled tasks
            }
            e.i32(F.calendarUniqueID, Int32(calendarUID ?? -1))
            e.bit(F.calendarUniqueID, calendarUID != nil)

            // Scheduling fields, reset first: the prototype is a real record.
            var constraint = task?.constraint
            var constraintDate = task?.constraintDate
            if task != nil, constraint == nil, !manual, !isSummary,
               start > project.start, linkStart[uid] != start {
                constraint = "SNET"
                constraintDate = start
            }
            e.u16(F.constraintType, W.constraintCodes[constraint ?? "ASAP"] ?? 0)
            e.ts(F.constraintDate, constraint == nil ? nil : constraintDate)
            e.bit(F.constraintType, constraint != nil)
            e.ts(F.deadline, task?.deadline)
            e.bit(F.deadline, task?.deadline != nil)
            e.u16(F.priority, UInt16(clamping: task?.priority ?? 500))
            e.u16(F.taskType, W.taskTypeCodes[task?.taskType ?? "fixed_units"] ?? 0)
            e.bit(F.effortDriven, task?.effortDriven ?? false)

            let actualTenths = Int((Double(tenths) * Double(percent) / 100).rounded())
            e.u16(F.percentComplete, UInt16(percent))
            e.u16(F.percentWorkComplete, UInt16(percent))
            e.i32(F.actualDuration, Int32(actualTenths))
            e.i32(F.remainingDuration, Int32(tenths - actualTenths))
            e.f64(F.actualWork, work * Double(percent) / 100)
            e.f64(F.remainingWork, work * Double(100 - percent) / 100)
            if percent > 0 {
                e.ts(F.actualStart, start)
                let point = percent == 100 ? finish : time.advance(start, minutes: actualTenths / 10)
                e.ts(F.actualFinish, percent == 100 ? finish : nil)
                e.ts(F.stop, point)
                e.ts(F.resume, point)
            } else {
                // Started on a given day with nothing done yet: Project keeps
                // the actual start alone.
                e.ts(F.actualStart, task?.actualStart)
                for f in [F.actualFinish, F.stop, F.resume] { e.ts(f, nil) }
            }
            for f in [F.percentComplete, F.actualDuration] { e.bit(f, percent > 0) }
            e.bit(F.actualStart, percent > 0 || task?.actualStart != nil)
            if isSummary { e.bit(F.summaryUnstarted, percent == 0) }

            // What drives the start, encoded exactly as Project writes it
            // (see `MPP.ScheduleDriver`).
            let isMilestone = !isSummary && tenths == 0
            let D = MPP.ScheduleDriver.self
            let driver: MPP.ScheduleDriver
            var mark387: Date?, mark1255: Date?
            if isSummary {
                driver = D.summary
            } else if percent == 100 {
                driver = D.actuals
                mark387 = isMilestone ? nil : start
            } else if percent > 0 {
                driver = D.actuals
                (mark387, mark1255) = (start, start)
            } else if constraint != nil || isMilestone || manual {
                driver = D.constraint
                mark1255 = start
            } else if let linked = linkStart[uid], linked == start {
                driver = D.predecessor
                let moment = linkDriver[uid] ?? start
                (mark387, mark1255) = (moment, moment)
            } else {
                driver = D.projectStart
                (mark387, mark1255) = (start, start)
            }
            if e.has(F.summaryProgressPrior) {
                e.ts(F.summaryProgress, mark387)
                e.ts(F.summaryProgressPrior, mark1255)
                e.i32(F.scheduleDriver, driver.rawValue)
            } else {
                // 2010-era files have 387 alone, holding the earlier moment.
                e.ts(F.summaryProgress, isSummary ? nil
                     : max(time.previousWorkingMoment(start) ?? project.start, project.start))
            }
            if let it = taskMap.fm[F.taskFlags] {
                let src = it.block == 0 ? e.row.rec : e.row.rec2
                if var flags = BinaryReader(src).u32(at: it.offset) {
                    flags &= ~UInt32(0x0002_B300)
                    flags |= 0x80
                    if !isSummary { flags |= 0x2000 }
                    if constraint != nil || isMilestone { flags |= 0x300 }
                    if percent > 0 && !isSummary { flags |= 0x9000 }
                    if isMilestone { flags |= 0x2_0000 }
                    if isSummary { flags &= ~UInt32(0x2000) }
                    e.u32(F.taskFlags, flags)
                }
            }

            // Var data.
            var extra: [(UInt32, [UInt8])] = []
            if let task {
                if !task.notes.isEmpty { extra.append((F.notes, MPP14Writer.encodeRTFNotes(task.notes))) }
                if let wbs = task.wbs { extra.append((F.wbs, MPP.encodeUnicode(wbs))) }
                for (n, v) in task.text.sorted(by: { $0.key < $1.key }) {
                    extra.append((MPP.CustomField.text[n - 1], MPP.encodeUnicode(v)))
                }
                for (n, v) in task.numbers.sorted(by: { $0.key < $1.key }) {
                    extra.append((MPP.CustomField.number[n - 1], le(v)))
                }
                for (n, v) in task.dateFields.sorted(by: { $0.key < $1.key }) {
                    extra.append((MPP.CustomField.date[n - 1], MPP.encodeTimestamp(v)))
                }
            }
            for (n, id) in MPP.CustomField.flag.enumerated() {
                e.bit(id, task?.flags[n + 1] ?? false)
            }
            for (slot, b) in baselines.sorted(by: { $0.key < $1.key }) {
                extra.append((MPP14File.taskBaselineStart[slot], MPP.encodeTimestamp(b.start)))
                extra.append((MPP14File.taskBaselineFinish[slot], MPP.encodeTimestamp(b.finish)))
                extra.append((MPP14File.taskBaselineDuration[slot],
                              le(Int32((b.durationDays * tenthsPerDay).rounded()))))
                extra.append((MPP14File.taskBaselineUnits[slot],
                              le(isSummary ? MPP.summaryUnits : (MPP.unitLabels[units] ?? 7))))
                extra.append((MPP14File.taskBaselineWork[slot], le(b.workHours * 600 * W.workScale)))
                extra.append((MPP14File.taskBaselineCost[slot], le(b.cost)))
                if slot < W.TaskIDs.baselineExtras.count {
                    let x = W.TaskIDs.baselineExtras[slot]
                    extra.append((x.ds, MPP.encodeTimestamp(nil)))
                    extra.append((x.df, MPP.encodeTimestamp(nil)))
                    extra.append((x.bw, W.unsetDouble))
                    extra.append((x.bc, W.unsetDouble))
                }
            }
            for (field, _) in extra { e.bit(field, true) }
            var vars = proto.vars.map { ($0.field, $0.field == F.name ? MPP.encodeUnicode(name) : $0.payload) }
            vars.append(contentsOf: extra)
            if e.row.meta.count > 2 { e.row.meta[2] = UInt8(clamping: vars.count) }
            taskRows.append(e.row)
            for (field, payload) in vars { taskVars.append((uid, field, payload)) }
        }

        // Summary baselines span the tasks' own.
        var summaryBaselines: [Int: Baseline] = [:]
        for slot in Set(project.tasks.flatMap { $0.baselines.keys }).sorted() {
            let rows = project.tasks.compactMap { $0.baselines[slot] }
            guard let s0 = rows.compactMap(\.start).min(), let f0 = rows.compactMap(\.finish).max() else { continue }
            summaryBaselines[slot] = Baseline(
                start: s0, finish: f0,
                durationDays: Double(time.minutes(from: s0, to: f0) * 10) / tenthsPerDay,
                workHours: project.tasks.filter { $0.parentUID == 0 }
                    .reduce(0) { $0 + ($1.baselines[slot]?.workHours ?? 0) })
        }
        emit(protos.summary, uid: 0, rowID: 0, name: project.title, start: pStart, finish: pFinish,
             tenths: time.minutes(from: pStart, to: pFinish) * 10, level: 0, parentUID: 0,
             guid: summaryGUID, parentGUID: [UInt8](repeating: 0, count: 16), isSummary: true,
             position: 1, task: nil, percent: pct0,
             work: top.reduce(0) { $0 + workSum[$1.uid]! }, baselines: summaryBaselines, calendarUID: nil)
        for (n, t) in project.tasks.enumerated() {
            let e = eff[t.uid]!
            let parentGUID = t.parentUID == 0 ? summaryGUID : byUID[t.parentUID]!.guid
            var calUID: Int?
            if let name = t.calendar {
                guard let uid = calendars.uidByName[name] else {
                    throw MPPError.invalidProject("task \(t.uid) references unknown calendar \"\(name)\"")
                }
                calUID = uid
            }
            let isSummaryTask = !(children[t.uid] ?? []).isEmpty
            emit(isSummaryTask ? protos.summaryTask : protos.leaf, uid: t.uid, rowID: n + 1, name: t.name, start: e.start, finish: e.finish,
                 tenths: e.tenths, level: t.outlineLevel, parentUID: t.parentUID, guid: t.guid,
                 parentGUID: parentGUID, isSummary: !(children[t.uid] ?? []).isEmpty, position: n + 2,
                 task: t, percent: pct[t.uid]!, work: workSum[t.uid]!, baselines: t.baselines,
                 calendarUID: calUID)
        }
        writeTable("TBkndTask", tasks, rows: taskRows, vars: taskVars, fieldClass: MPP.FieldClass.task)

        // ---- relations --------------------------------------------------------
        let cons = try table("TBkndCons", metaSize: MPP.relationMetaSize, meta2Size: 9)
        let relationProto = cons.rows.first { $0.rec.count >= 20 }
        if !project.relations.isEmpty && relationProto == nil {
            throw MPPError.template("no dependency record to clone; save the template with one linked pair of tasks")
        }
        var relRows: [Row] = []
        for (i, r) in project.relations.enumerated() {
            guard var row = relationProto else { break }
            row.rec.replaceSubrange(0..<12, with: le(UInt32(i + 1)) + le(UInt32(r.predUID)) + le(UInt32(r.succUID)))
            row.rec.replaceSubrange(12..<14, with: le(W.relationTypes[r.type]!))
            let lag = Int32((r.lagIsPercent ? r.lagDays * 10_000 : r.lagDays * tenthsPerDay).rounded())
            let units = MPP.unitLabels[r.lagUnits] ?? 7
            if relation2010 {
                row.rec.replaceSubrange(14..<20, with: le(units) + le(lag))   // lag units, lag
            } else {
                row.rec.replaceSubrange(14..<20, with: le(lag) + le(units))   // lag, lag units
            }
            if row.rec2.count >= 48 {
                row.rec2.replaceSubrange(0..<16, with: options.newGUID())
                row.rec2.replaceSubrange(16..<32, with: byUID[r.predUID]!.guid)
                row.rec2.replaceSubrange(32..<48, with: byUID[r.succUID]!.guid)
            }
            relRows.append(row)
        }
        writeTable("TBkndCons", cons, rows: relRows, vars: nil, fieldClass: 0)

        // ---- resources (always rebuilt: the template's never carry over) -------
        let rsc = try table("TBkndRsc", metaSize: MPP.resourceMetaSize, meta2Size: 50)
        let RF = MPP.ResourceField.self
        func rscUID(_ row: Row) -> Int? {
            guard row.rec.count > 100 else { return nil }
            return Editor(row: row, fm: rscMap.fm, bits: rscMap.bits).fm[RF.uniqueID]
                .flatMap { BinaryReader(row.rec).u32(at: $0.offset) }.map(Int.init)
        }
        var rscRows = rsc.rows.filter { isDeletedStub($0.rec) }
        var rscVars: [(uid: Int, field: UInt32, payload: [UInt8])] = []
        let rscProtoRow = rsc.rows.first { rscUID($0) == 0 }
        if let p = rscProtoRow {
            rscRows.append(p)
            for v in rsc.vars(of: 0) { rscVars.append((0, v.field, v.payload)) }
        }
        // Built step by step: as one `+` chain it exceeds Swift 6.1's type-checker budget.
        var rscDataFields = Set<UInt32>(MPP14File.resourceBaselineWork)
        rscDataFields.formUnion(MPP14File.resourceBaselineCost)
        rscDataFields.formUnion(W.Rsc.baselineBudget.flatMap { [$0.work, $0.cost] })
        rscDataFields.formUnion(W.Rsc.baselineTimephased)
        rscDataFields.formUnion(MPP.CustomField.text)
        rscDataFields.formUnion(MPP.CustomField.number)
        rscDataFields.formUnion(MPP.CustomField.date)
        rscDataFields.formUnion([RF.name, RF.initials, RF.emailAddress])
        let rscProtoVars = rsc.vars(of: 0).filter { !rscDataFields.contains($0.field) }
        if !project.resources.isEmpty && rscProtoRow == nil {
            throw MPPError.template("no uid-0 resource record to clone")
        }
        for (n, res) in project.resources.enumerated() {
            guard let proto = rscProtoRow else { break }
            var e = Editor(row: proto, fm: rscMap.fm, bits: rscMap.bits)
            for (field, _) in rsc.vars(of: 0) where rscDataFields.contains(field) { e.bit(field, false) }
            var extra: [(UInt32, [UInt8])] = [(RF.name, MPP.encodeUnicode(res.name))]
            if !res.initials.isEmpty { extra.append((RF.initials, MPP.encodeUnicode(res.initials))) }
            if !res.email.isEmpty { extra.append((RF.emailAddress, MPP.encodeUnicode(res.email))) }
            for (slot, b) in res.baselines.sorted(by: { $0.key < $1.key }) {
                extra.append((MPP14File.resourceBaselineWork[slot], le(b.workHours * 600 * W.workScale)))
                extra.append((MPP14File.resourceBaselineCost[slot], le(b.cost)))
                if slot < W.Rsc.baselineBudget.count {
                    extra.append((W.Rsc.baselineBudget[slot].work, W.unsetDouble))
                    extra.append((W.Rsc.baselineBudget[slot].cost, W.unsetDouble))
                }
            }
            let calUID = calendars.addResourceCalendar(resourceUID: res.uid, guid: res.guid)
            e.u32(RF.uniqueID, UInt32(res.uid))
            e.u32(RF.id, UInt32(n + 1))
            e.f64(RF.maxUnits, res.maxUnits * W.pctScale)
            if let calUID { e.i32(RF.calendarUID, Int32(calUID)) }
            e.f64(RF.position, Double(n + 2))
            e.put(RF.guid, res.guid)
            e.put(RF.calendarGUID, res.guid)
            for f in [RF.uniqueID, RF.id, RF.name, RF.maxUnits] { e.bit(f, true) }
            for (field, _) in extra { e.bit(field, true) }
            if e.row.meta.count > 2 { e.row.meta[2] = UInt8(clamping: rscProtoVars.count + extra.count) }
            rscRows.append(e.row)
            for v in rscProtoVars { rscVars.append((res.uid, v.field, v.payload)) }
            for (field, payload) in extra { rscVars.append((res.uid, field, payload)) }
        }
        writeTable("TBkndRsc", rsc, rows: rscRows, vars: rscVars, fieldClass: MPP.FieldClass.resource)

        // ---- calendars ----------------------------------------------------------
        calendars.write()

        // ---- assignments ----------------------------------------------------------
        try writeAssignments(project, eff: eff, pct: pct, children: children, byUID: byUID,
                             time: time, now: now)

        writeFieldAliases(project)
        writeEntryTable(project)

        // ---- Props ------------------------------------------------------------------
        let assnCount = (try? MPP.parseFixedMeta(try stream("TBkndAssn/FixedMeta"), itemSize: 1).declaredCount) ?? 0
        let counters: [(UInt32, Int)] = [
            (MPP.PropsKey.taskRecordCount, taskRows.count),
            (MPP.PropsKey.relationRecordCount, relRows.count),
            (MPP.PropsKey.resourceRecordCount, rscRows.count),
            (MPP.PropsKey.calendarRecordCount, calendars.rowCount),
            (MPP.PropsKey.assignmentRecordCount, Int(assnCount)),
        ]
        for (key, n) in counters where props.values[key] != nil { props.values[key] = le(UInt32(n)) }
        for storage in ["TBkndTask", "TBkndRsc", "TBkndCal", "TBkndAssn"] {
            if let key = MPP.PropsKey.var2DataSize(for: storage), props.values[key] != nil,
               let vd = try? stream("\(storage)/Var2Data") {
                props.values[key] = le(UInt32(vd.count))
            }
        }
        if props.values[MPP.PropsKey.editedBaseCalendars] != nil {
            props.values[MPP.PropsKey.editedBaseCalendars] = le(UInt32(calendars.editedBaseCount))
        }
        if let name = project.defaultCalendar, props.values[MPP.PropsKey.defaultCalendarName] != nil {
            props.values[MPP.PropsKey.defaultCalendarName] = Array(MPP.encodeUnicode(name).dropLast(2)) + [0, 0, 0, 0]
        }
        props.values[MPP.PropsKey.projectStartDate] = MPP.encodeTimestamp(project.start)
        if props.values[MPP.PropsKey.projectFinishDate] != nil {
            props.values[MPP.PropsKey.projectFinishDate] = MPP.encodeTimestamp(pFinish)
        }
        if props.values[MPP.PropsKey.statusDate] != nil {
            props.values[MPP.PropsKey.statusDate] = MPP.encodeTimestamp(project.statusDate)
        }
        if let s = project.currencySymbol, props.values[MPP.PropsKey.currencySymbol] != nil {
            props.values[MPP.PropsKey.currencySymbol] = MPP.encodeUnicode(s)
        }
        if let s = project.currencyCode, props.values[MPP.PropsKey.currencyCode] != nil {
            props.values[MPP.PropsKey.currencyCode] = MPP.encodeUnicode(s)
        }
        // When each of Baseline...Baseline10 was saved, as Set Baseline
        // records it. Project shows a slot without one too (baselines typed in
        // by hand have none); this is the date its dialogs report.
        for slot in 0...10 {
            let key = MPP.PropsKey.baselineSaved + UInt32(slot)
            guard props.values[key] != nil else { continue }
            let has = project.tasks.contains { $0.baselines[slot] != nil }
            props.values[key] = MPP.encodeTimestamp(has ? now : nil)
        }
        if props.values[MPP.PropsKey.minutesPerDay] != nil {
            props.values[MPP.PropsKey.minutesPerDay] = le(UInt32(project.minutesPerDay))
        }
        if props.values[MPP.PropsKey.minutesPerWeek] != nil {
            props.values[MPP.PropsKey.minutesPerWeek] = le(UInt32(project.minutesPerWeek))
        }
        if props.values[MPP.PropsKey.daysPerMonth] != nil {
            props.values[MPP.PropsKey.daysPerMonth] = le(UInt16(project.daysPerMonth))
        }
        if props.values[MPP.PropsKey.defaultStartTime] != nil {
            props.values[MPP.PropsKey.defaultStartTime] = le(UInt16(project.defaultStartTime * 10))
        }
        if props.values[MPP.PropsKey.defaultFinishTime] != nil {
            props.values[MPP.PropsKey.defaultFinishTime] = le(UInt16(project.defaultFinishTime * 10))
        }
        // Stale 2010-era next-uid counters make Project renumber task uids;
        // M365 itself deletes the key on save.
        props.values[MPP.PropsKey.legacyNextUIDs] = nil
        props.order.removeAll { $0 == MPP.PropsKey.legacyNextUIDs }
        if props.values[MPP.PropsKey.title] != nil {
            props.values[MPP.PropsKey.title] = Array(MPP.encodeUnicode(project.title).dropLast(2)) + [0, 0, 0, 0]
        }
        set("Props", MPP.buildProps(props))

        // ---- view state ----------------------------------------------------------
        retargetGanttScroll(to: project.start)
        refreshGanttRows(project.tasks.map(\.uid), start: pStart, finish: pFinish)

        // ---- document metadata -------------------------------------------------
        writeDocumentProperties(project)

        // ---- app view state ------------------------------------------------------
        // Project ignores streams it does not know; a file without one keeps
        // whatever it had.
        if let columns = project.viewColumns {
            root.addStream(MPP.viewColumnsStream, Array(columns.joined(separator: ",").utf8))
        }
        // Shifts and holiday sets, by calendar name. Always written, so a
        // set removed in the app does not come back from an older stream.
        var setups: [String: CalendarSetup] = [:]
        for cal in [project.calendar].compactMap({ $0 }) + project.calendars {
            let setup = CalendarSetup(shifts: cal.shifts, holidays: cal.holidays)
            if !setup.isEmpty { setups[cal.name] = setup }
        }
        if let bytes = CalendarSetup.encode(setups) {
            root.addStream(MPP.calendarSetupStream, bytes)
        }

        return try CFBWriter.write(root: root, rootCLSID: CFBFile.projectRootCLSID)
    }

    // MARK: Validation

    func validate(_ project: Project) throws {
        func fail(_ s: String) -> MPPError { .invalidProject(s) }
        guard project.minutesPerDay > 0, project.minutesPerDay <= 1_440 else {
            throw fail("minutesPerDay must be 1...1440")
        }
        var seen = Set<Int>()
        for t in project.tasks {
            guard t.uid > 0 else { throw fail("task uid must be > 0 (got \(t.uid))") }
            guard seen.insert(t.uid).inserted else { throw fail("duplicate task uid \(t.uid)") }
            if let s = t.start, let f = t.finish, f < s { throw fail("task \(t.uid): finish before start") }
            if let c = t.constraint, W.constraintCodes[c] == nil { throw fail("task \(t.uid): unknown constraint \(c)") }
            guard W.taskTypeCodes[t.taskType] != nil else { throw fail("task \(t.uid): unknown task type \(t.taskType)") }
            guard MPP.unitLabels[t.durationUnits] != nil else { throw fail("task \(t.uid): unknown duration units \(t.durationUnits)") }
            guard (0...100).contains(t.percentComplete) else { throw fail("task \(t.uid): percent complete out of range") }
            guard (0...1000).contains(t.priority) else { throw fail("task \(t.uid): priority out of range") }
            for (label, keys, limit) in [("Text", Array(t.text.keys), 30), ("Number", Array(t.numbers.keys), 20),
                                         ("Date", Array(t.dateFields.keys), 10), ("Flag", Array(t.flags.keys), 20)] {
                if let bad = keys.first(where: { !(1...limit).contains($0) }) {
                    throw fail("task \(t.uid): \(label)\(bad) out of range 1...\(limit)")
                }
            }
            if t.baselines.keys.contains(where: { !(0...10).contains($0) }) { throw fail("task \(t.uid): baseline slot out of range") }
        }
        // Row-order outline: a level may rise by one at most, and the parent
        // must be the nearest preceding task one level up.
        var stack: [MPPModel.ProjectTask] = []
        for t in project.tasks {
            guard t.outlineLevel >= 1 else { throw fail("task \(t.uid): outline level must be >= 1") }
            while let last = stack.last, last.outlineLevel >= t.outlineLevel { stack.removeLast() }
            if t.outlineLevel > 1, stack.last?.outlineLevel != t.outlineLevel - 1 {
                throw fail("task \(t.uid): outline level \(t.outlineLevel) does not follow a level \(t.outlineLevel - 1) task")
            }
            let expected = t.outlineLevel > 1 ? stack.last!.uid : 0
            guard t.parentUID == expected else {
                throw fail("task \(t.uid): parentUID \(t.parentUID) does not match the outline (expected \(expected))")
            }
            stack.append(t)
        }
        for r in project.relations {
            guard seen.contains(r.predUID), seen.contains(r.succUID) else {
                throw fail("relation \(r.predUID) -> \(r.succUID) references an unknown task")
            }
            guard r.predUID != r.succUID else { throw fail("task \(r.predUID) cannot depend on itself") }
            guard W.relationTypes[r.type] != nil else { throw fail("unknown relation type \(r.type)") }
        }
        // No dependency cycles: iterative depth-first search, since a plan may
        // chain more tasks than the stack allows.
        var successors: [Int: [Int]] = [:]
        for r in project.relations { successors[r.predUID, default: []].append(r.succUID) }
        var state: [Int: Int] = [:]          // 1 = on the current path, 2 = done
        for root in successors.keys.sorted() where state[root] == nil {
            var stack: [(uid: Int, next: Int)] = [(root, 0)]
            state[root] = 1
            while let top = stack.last {
                let succs = successors[top.uid] ?? []
                if top.next == succs.count {
                    state[top.uid] = 2
                    stack.removeLast()
                    continue
                }
                stack[stack.count - 1].next += 1
                let n = succs[top.next]
                if state[n] == 1 {
                    let path = stack.map(\.uid).drop { $0 != n } + [n]
                    throw fail("dependency cycle: " + path.map(String.init).joined(separator: " -> "))
                }
                if state[n] == nil { state[n] = 1; stack.append((n, 0)) }
            }
        }
        var rscSeen = Set<Int>()
        for r in project.resources {
            guard r.uid > 0, rscSeen.insert(r.uid).inserted else { throw fail("resource uids must be unique and > 0") }
            guard !r.name.isEmpty else { throw fail("resource \(r.uid) has no name") }
        }
        for a in project.assignments {
            guard seen.contains(a.taskUID) else { throw fail("assignment references unknown task \(a.taskUID)") }
            guard rscSeen.contains(a.resourceUID) else { throw fail("assignment references unknown resource \(a.resourceUID)") }
        }
    }

    // MARK: Task prototypes

    struct Prototype {
        var row: Row
        var vars: [(field: UInt32, payload: [UInt8])]
    }

    /// The project summary (uid 0), a summary task, and the cleanest leaf
    /// task, each with every per-record value stripped. Summary rows carry
    /// booleans of their own that a leaf record lacks, so they get their own
    /// prototype when the template has one.
    func taskPrototypes(_ t: Table) throws -> (summary: Prototype, summaryTask: Prototype, leaf: Prototype) {
        let F = MPP.TaskField.self
        struct Candidate { var index: Int; var uid: Int; var row: Row }
        var full: [Candidate] = []
        for (i, row) in t.rows.enumerated() where row.rec.count > 100 {
            guard let it = taskMap.fm[F.uniqueID], let uid = BinaryReader(row.rec).u32(at: it.offset) else { continue }
            full.append(Candidate(index: i, uid: Int(uid), row: row))
        }
        guard !full.isEmpty else { throw MPPError.template("no task records to clone") }

        func flag(_ row: Row, _ id: UInt32) -> Bool {
            guard let bit = taskMap.bits[id] else { return false }
            return (MPP.metaBit(meta: row.meta, meta2: row.meta2, entryIndex: bit) ?? 0) != 0
        }
        func value(_ row: Row, _ id: UInt32) -> UInt32 {
            guard let it = taskMap.fm[id] else { return 0 }
            let src = it.block == 0 ? row.rec : row.rec2
            return UInt32(BinaryReader(src).u16(at: it.offset) ?? 0)
        }

        // Var fields every template task carries are structural; anything
        // else is that task's own data.
        var structural: Set<UInt32>?
        for c in full {
            let fields = Set((t.varTable[c.uid] ?? [:]).keys)
            structural = structural.map { $0.intersection(fields) } ?? fields
        }
        var data = Set<UInt32>([F.notes, F.wbs])
        data.formUnion(MPP.CustomField.text + MPP.CustomField.number + MPP.CustomField.date + MPP.CustomField.flag)
        data.formUnion(MPP14File.taskBaselineStart + MPP14File.taskBaselineFinish + MPP14File.taskBaselineDuration
                       + MPP14File.taskBaselineUnits + MPP14File.taskBaselineWork + MPP14File.taskBaselineCost)
        data.formUnion(W.TaskIDs.baselineTimephased)
        data.formUnion(W.TaskIDs.baselineExtras.flatMap { [$0.ds, $0.df, $0.bw, $0.bc] })

        func prototype(_ c: Candidate) -> Prototype {
            var e = Editor(row: c.row, fm: taskMap.fm, bits: taskMap.bits)
            var kept: [(field: UInt32, payload: [UInt8])] = []
            for v in t.vars(of: c.uid) {
                let keep = v.field == F.name
                    || (!data.contains(v.field) && (structural?.contains(v.field) == true || Self.isNeutral(v.payload)))
                if keep { kept.append(v) } else { e.bit(v.field, false) }
            }
            return Prototype(row: e.row, vars: kept)
        }

        let summary = full.first { $0.uid == 0 } ?? full[0]
        let leaves = full.filter { $0.uid != 0 && !flag($0.row, F.summary) }
        let clean = leaves.filter {
            value($0.row, F.percentComplete) == 0 && value($0.row, F.constraintType) == 0
                && !flag($0.row, F.manuallyScheduled) && !flag($0.row, F.milestone)
        }
        let leaf = (clean.isEmpty ? leaves : clean)
            .min { (t.varTable[$0.uid]?.count ?? 0) < (t.varTable[$1.uid]?.count ?? 0) } ?? summary
        let summaries = full.filter { $0.uid != 0 && flag($0.row, F.summary) }
        let summaryTask = summaries.first { value($0.row, F.percentComplete) == 0 } ?? summaries.first
        return (prototype(summary), summaryTask.map(prototype) ?? prototype(leaf), prototype(leaf))
    }

    // MARK: Assignments

    func writeAssignments(_ project: Project, eff: [Int: (start: Date, finish: Date, tenths: Int)],
                          pct: [Int: Int], children: [Int: [Int]], byUID: [Int: MPPModel.ProjectTask],
                          time: WorkingTime, now: Date) throws {
        let t = try table("TBkndAssn", metaSize: MPP.assignmentMetaSize, meta2Size: 53)
        let A = MPP.AssignmentField.self
        func taskUID(_ row: Row) -> UInt32? {
            guard let it = assnMap.fm[A.taskUniqueID] else { return nil }
            return BinaryReader(it.block == 0 ? row.rec : row.rec2).u32(at: it.offset)
        }
        func ownUID(_ row: Row) -> Int {
            Int(assnMap.fm[A.uniqueID].flatMap { BinaryReader(row.rec).u32(at: $0.offset) } ?? 0)
        }
        // Prototype: a real per-task row (the uid-0 row carries no work contour).
        let real = t.rows.filter { $0.rec.count > 50 && (taskUID($0) ?? 0) != 0 }
        // Prefer an unstarted row: a progressed one carries the started and
        // finished flags, which would be cloned onto every assignment.
        func unstarted(_ row: Row) -> Bool {
            for id in [A.started, A.finished] {
                if let i = assnMap.bits[id], MPP.metaBit(meta: row.meta, meta2: row.meta2, entryIndex: i) == 1 { return false }
            }
            let work = assnMap.fm[A.actualWork].flatMap { w in
                BinaryReader(w.block == 0 ? row.rec : row.rec2).f64(at: w.offset) } ?? 0
            return work == 0
        }
        guard let protoRow = real.first(where: unstarted) ?? real.first else {
            if project.tasks.isEmpty { return }
            throw MPPError.template("no assignment record to clone")
        }
        var structural: Set<UInt32>?
        for row in real {
            let fields = Set((t.varTable[ownUID(row)] ?? [:]).keys)
            structural = structural.map { $0.intersection(fields) } ?? fields
        }
        var data = Set(MPP14File.assignmentBaselineStart + MPP14File.assignmentBaselineFinish
                       + MPP14File.assignmentBaselineWork + MPP14File.assignmentBaselineCost)
        data.formUnion(W.Assn.baselineBudget.flatMap { [$0.work, $0.cost] } + W.Assn.baselineTimephased)
        data.formUnion([W.Assn.actualWorkData, W.Assn.actualIrregularData] + W.Assn.emptyVars)
        var protoEditor = Editor(row: protoRow, fm: assnMap.fm, bits: assnMap.bits)
        var protoVars: [(field: UInt32, payload: [UInt8])] = []
        for v in t.vars(of: ownUID(protoRow)) {
            if !data.contains(v.field), structural?.contains(v.field) == true || Self.isNeutral(v.payload) {
                protoVars.append(v)
            } else {
                protoEditor.bit(v.field, false)
            }
        }
        for f in [A.actualStart, A.actualFinish] { protoEditor.bit(f, false) }

        let rscByUID = Dictionary(uniqueKeysWithValues: project.resources.map { ($0.uid, $0) })
        let assigned = Set(project.assignments.map(\.taskUID))
        // Project keeps an assignment row for every leaf task, with a
        // placeholder resource where nobody is assigned.
        var specs: [(task: Int, resource: Int32, units: Double, baselines: [Int: Baseline]?)] =
            project.assignments.map { ($0.taskUID, Int32($0.resourceUID), $0.units, $0.baselines) }
        specs += project.tasks.filter { !assigned.contains($0.uid) && (children[$0.uid] ?? []).isEmpty }
            .map { ($0.uid, W.nullResourceUID, 1.0, nil) }

        var rows: [Row] = []
        var vars: [(uid: Int, field: UInt32, payload: [UInt8])] = []
        for (n, spec) in specs.enumerated() {
            let uid = n + 1
            let empty = spec.resource == W.nullResourceUID
            let task = byUID[spec.task]!
            let (start, finish, tenths) = eff[spec.task]!
            var e = protoEditor
            e.u32(A.uniqueID, UInt32(uid))
            e.u32(A.taskUniqueID, UInt32(spec.task))
            e.i32(A.resourceUniqueID, spec.resource)
            e.f64(A.units, spec.units * W.pctScale)
            let work = Double(tenths) * W.workScale * spec.units
            for f in [A.work, A.regularWork, A.remainingWork] { e.f64(f, work) }
            e.f64(A.actualWork, 0)
            e.u16(A.percentWorkComplete, 0)
            e.ts(A.actualStart, nil)
            e.ts(A.actualFinish, nil)

            let p = pct[spec.task] ?? 0
            var reached = start, remainingWork = work, remainingTenths = tenths
            if p > 0 {
                e.f64(A.actualWork, work * Double(p) / 100)
                remainingWork = work * Double(100 - p) / 100
                e.f64(A.remainingWork, remainingWork)
                let elapsed = Int((Double(tenths) * Double(p) / 100).rounded())
                remainingTenths = tenths - elapsed
                reached = p == 100 ? finish : time.advance(start, minutes: elapsed / 10)
                e.u16(A.percentWorkComplete, UInt16(p))
                e.ts(A.actualStart, start)
                e.bit(A.actualStart, true)
                if p == 100 {
                    e.ts(A.actualFinish, finish)
                    e.bit(A.actualFinish, true)
                }
            }
            e.bit(A.started, p > 0)
            e.bit(A.finished, p == 100)
            e.ts(A.start, start)
            e.ts(A.resume, reached)
            e.ts(A.stop, reached)
            e.ts(A.finish, finish)
            e.put(A.guid, options.newGUID())
            e.put(A.taskGUID, task.guid)
            e.put(A.resourceGUID, empty ? W.nullResourceGUID : rscByUID[Int(spec.resource)]!.guid)
            for f in [A.uniqueID, A.taskUniqueID, A.resourceUniqueID, A.units, A.work] { e.bit(f, true) }

            var out: [(UInt32, [UInt8])] = []
            for v in protoVars {
                var payload = v.payload
                if v.field == A.created {
                    payload = MPP.encodeTimestamp(now)
                } else if v.field == W.Assn.plannedWorkData, payload.count >= 36 {
                    // The planned-work contour Project schedules the assignment
                    // from: units × 16 at +8, remaining work at +16, remaining
                    // duration × 8 at +24.
                    if p == 100 {
                        payload = Self.remainingAt100(units: spec.units, work: work, tenths: tenths)
                    } else {
                        // A zero-work row (a milestone) carries no units, as Project writes it.
                        payload.replaceSubrange(8..<16, with: le(tenths == 0 ? 0 : spec.units * W.pctScale * 16))
                        payload.replaceSubrange(16..<24, with: le(remainingWork))
                        payload.replaceSubrange(24..<28, with: le(UInt32(remainingTenths * 8)))
                    }
                }
                out.append((v.field, payload))
            }
            if p > 0 {
                out.append((W.Assn.actualWorkData,
                            Self.actualWorkContour(units: spec.units, work: work * Double(p) / 100,
                                                   tenths: tenths - remainingTenths)))
                e.bit(W.Assn.actualWorkData, true)
                out.append((W.Assn.actualIrregularData, Self.firstDayWindows(time, start: start, finish: reached)))
                e.bit(W.Assn.actualIrregularData, true)
            }
            out.append((665, [UInt8](repeating: 0, count: 16)))
            if empty { out.append((667, [UInt8](repeating: 0, count: 16))) }
            let baselines = spec.baselines ?? task.baselines
            for (slot, b) in baselines.sorted(by: { $0.key < $1.key }) {
                var entries: [(UInt32, [UInt8])] = [
                    (MPP14File.assignmentBaselineStart[slot], MPP.encodeTimestamp(b.start)),
                    (MPP14File.assignmentBaselineFinish[slot], MPP.encodeTimestamp(b.finish)),
                    (MPP14File.assignmentBaselineWork[slot], le(b.workHours * 600 * W.workScale)),
                    (MPP14File.assignmentBaselineCost[slot], le(b.cost)),
                ]
                if slot < W.Assn.baselineBudget.count {
                    entries.append((W.Assn.baselineBudget[slot].work, W.unsetDouble))
                    entries.append((W.Assn.baselineBudget[slot].cost, W.unsetDouble))
                }
                for (field, _) in entries { e.bit(field, true) }
                out.append(contentsOf: entries)
            }
            if e.row.meta.count > 2 { e.row.meta[2] = UInt8(clamping: out.count) }
            rows.append(e.row)
            for (field, payload) in out { vars.append((uid, field, payload)) }
        }
        writeTable("TBkndAssn", t, rows: rows, vars: vars, fieldClass: MPP.FieldClass.assignment)
    }

    /// Var 50: the work done so far, in the single-segment shape Project writes.
    static func actualWorkContour(units: Double, work: Double, tenths: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 56)
        b.replaceSubrange(0..<8, with: le(UInt16(1)) + le(UInt16(24)) + le(UInt32(36)))
        for off in [8, 44] { b.replaceSubrange(off..<off + 8, with: le(units * W.pctScale)) }
        for off in [16, 36] { b.replaceSubrange(off..<off + 8, with: le(work)) }
        for off in [24, 52] { b.replaceSubrange(off..<off + 4, with: le(UInt32(tenths * 8))) }
        return b
    }

    /// Var 49 as Project leaves it once an assignment is complete.
    static func remainingAt100(units: Double, work: Double, tenths: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 72)
        b.replaceSubrange(0..<8, with: le(UInt16(0)) + le(UInt16(32)) + le(UInt32(44)))
        b.replaceSubrange(44..<52, with: le(work))
        b.replaceSubrange(52..<60, with: le(units * W.pctScale * 16))
        b.replaceSubrange(68..<72, with: le(UInt32(tenths * 8)))
        return b
    }

    /// Var 87: the working windows of the first day worked.
    static func firstDayWindows(_ time: WorkingTime, start: Date, finish: Date) -> [UInt8] {
        var windows: [(Date, Date)] = []
        var day = MPPTime.startOfDay(start)
        while day <= finish, windows.isEmpty {
            for r in time.ranges(on: day) {
                let ws = day.addingTimeInterval(Double(r.lowerBound) * 60)
                let we = day.addingTimeInterval(Double(r.upperBound) * 60)
                if we <= start || ws >= finish { continue }
                windows.append((max(ws, start), min(we, finish)))
            }
            day = MPPTime.adding(days: 1, to: day)
        }
        var b = le(UInt16(windows.count)) + le(UInt16(2 * windows.count)) + le(UInt32(16))
        b += [UInt8](repeating: 0, count: 8)
        for (a, z) in windows { b += MPP.encodeTimestamp(a) + MPP.encodeTimestamp(z) }
        return b
    }

    // MARK: View state

    /// The Gantt view stores its scroll position as a timestamp equal to the
    /// template's project start; retarget it so the chart opens on this
    /// schedule.
    func retargetGanttScroll(to start: Date) {
        let path = "\(W.View.storage)/CV_iew/Var2Data"
        guard let old = templateStart, old.count == 4, let data = root.streamIfPresent(path: path) else { return }
        let new = MPP.encodeTimestamp(start)
        guard old != new else { return }
        var out = data
        var i = 0
        while i + 4 <= out.count {
            if Array(out[i..<i + 4]) == old { out.replaceSubrange(i..<i + 4, with: new); i += 4 } else { i += 1 }
        }
        root.setStream(path: path, out)
    }

    /// The Gantt row cache: the view remembers the rows it last painted (task
    /// uids and a pixel offset per row) and paints exactly those on open.
    func refreshGanttRows(_ uids: [Int], start: Date, finish: Date) {
        // The timescale window: Project opens the chart where the template was
        // last scrolled unless these move with the schedule.
        func tenths(_ d: Date) -> [UInt8] {
            let (days, t) = MPPTime.wire(from: d)
            return le(UInt32(clamping: days * 14_400 + t))
        }
        func monday(_ d: Date) -> Date {
            MPPTime.adding(days: -((MPPTime.weekday(d) + 5) % 7), to: MPPTime.startOfDay(d))
        }
        let window: [UInt32: [UInt8]] = [
            W.View.edlRangeStart: tenths(monday(MPPTime.adding(days: -35, to: start))),
            W.View.edlRangeEnd: tenths(MPPTime.adding(days: 35, to: MPPTime.startOfDay(finish))),
            W.View.edlScroll: tenths(monday(MPPTime.adding(days: -7, to: start))),
        ]
        let base = "\(W.View.storage)/CEdl"
        guard let vm = root.streamIfPresent(path: "\(base)/VarMeta"),
              let vd = root.streamIfPresent(path: "\(base)/Var2Data") else { return }
        let parsed = MPP.parseVarMeta(vm)
        guard !parsed.entries.isEmpty else { return }
        let rows = uids.flatMap { le(UInt32($0)) }
        var meta = BinaryWriter()
        meta.append(Array(vm.prefix(24)))
        var data = BinaryWriter()
        var changed = false
        for entry in parsed.entries {
            var blob = MPP.readVar(vd, offset: entry.offset)
            if entry.field & 0xFFFF == 6, blob.count >= 16 {
                var p = MPP.parseProps(blob)
                for (key, value) in window where p.values[key]?.count == 4 {
                    p.values[key] = value
                    blob = MPP.buildProps(p)
                    changed = true
                }
                if let oldRows = p.values[W.View.edlRows], let layout = p.values[W.View.edlLayout],
                   let oldN = BinaryReader(layout).u32(at: 0).map(Int.init) {
                    let rowHeight = BinaryReader(layout).u16(at: 4 + (oldN + 1) * 4).map(Int.init).flatMap { $0 == 0 ? nil : $0 } ?? 42
                    p.values[W.View.edlRows] = rows + Array(oldRows.dropFirst(min(oldN * 4, oldRows.count)))
                    var newLayout = le(UInt32(uids.count))
                    for i in 0...uids.count { newLayout += le(UInt32(i * rowHeight)) }
                    newLayout += Array(layout.dropFirst(min(4 + (oldN + 1) * 4, layout.count)))
                    p.values[W.View.edlLayout] = newLayout
                    if let painted = p.values[W.View.edlPainted] {
                        let slots = max(painted.count / 4, uids.count)
                        p.values[W.View.edlPainted] = rows + [UInt8](repeating: 0xFF, count: 4 * (slots - uids.count))
                    }
                    blob = MPP.buildProps(p)
                    changed = true
                }
            }
            meta.u32(UInt32(entry.uid))
            meta.u32(UInt32(data.count))
            meta.u16(UInt16(entry.field & 0xFFFF))
            meta.u16(entry.fieldClass)
            data.u32(UInt32(blob.count))
            data.append(blob)
        }
        guard changed else { return }
        meta.patchU32(at: 8, UInt32(parsed.entries.count))
        meta.patchU32(at: 20, UInt32(data.count))
        root.setStream(path: "\(base)/VarMeta", meta.bytes)
        root.setStream(path: "\(base)/Var2Data", data.bytes)
        // The view storage's Props gates the Var2Data read at its declared length.
        if let vp = root.streamIfPresent(path: "\(W.View.storage)/Props") {
            var p = MPP.parseProps(vp)
            if p.values[W.View.edlVar2DataSize] != nil {
                p.values[W.View.edlVar2DataSize] = le(UInt32(data.count))
                root.setStream(path: "\(W.View.storage)/Props", MPP.buildProps(p))
            }
        }
    }

    // MARK: The Entry table's columns

    /// The app's columns into Project's Entry table, so the file opens in
    /// Project with the same columns in the same order. Columns the app does
    /// not model (Indicators, Task Mode, …) stay where they were; columns kept
    /// keep their width and title; new ones get a plain record.
    func writeEntryTable(_ project: Project) {
        typealias T = MPP.EntryTable
        guard let columns = project.viewColumns else { return }
        let base = T.storage
        guard let vm = root.streamIfPresent(path: "\(base)/VarMeta"),
              let vd = root.streamIfPresent(path: "\(base)/Var2Data") else { return }
        let parsed = MPP.parseVarMeta(vm)
        guard !parsed.entries.isEmpty else { return }

        let idByName = Dictionary(T.fields.map { ($0.name, $0.id) }, uniquingKeysWith: { a, _ in a })
        let known = Set(T.fields.map(\.id))
        // The app's columns, in order, with widths in points where dragged.
        let wanted: [(id: UInt32, points: Double?)] = columns.compactMap { entry in
            let parts = entry.split(separator: ":", maxSplits: 1)
            guard let id = parts.first.flatMap({ idByName[String($0)] }) else { return nil }
            return (id, parts.count == 2 ? Double(parts[1]) : nil)
        }

        func rebuild(_ blob: [UInt8]) -> [UInt8]? {
            let r = BinaryReader(blob)
            guard blob.count >= T.headerSize, let n = r.u16(at: 4).map({ Int($0) + 1 }),
                  blob.count >= T.headerSize + n * T.recordSize else { return nil }
            var records = (0..<n).map { i -> [UInt8] in
                let at = T.headerSize + i * T.recordSize
                return Array(blob[at..<at + T.recordSize])
            }
            func id(_ rec: [UInt8]) -> UInt32 { BinaryReader(rec).u32(at: 0) ?? 0 }
            let existing = Dictionary(records.map { (id($0), $0) }, uniquingKeysWith: { a, _ in a })
            // A plain record to copy for new columns: no title of its own.
            let plain = records.first { $0[9] == 0x01 }
                ?? ([0, 0, 0, 0, 12, 0x10, 0x08, 0x00, 0x08, 0x01] + [UInt8](repeating: 0, count: T.recordSize - 10))
            let ordered = wanted.map { w -> [UInt8] in
                var rec = existing[w.id] ?? {
                    var rec = plain
                    rec.replaceSubrange(13..<T.recordSize, with: [UInt8](repeating: 0, count: T.recordSize - 13))
                    rec[9] = 0x01
                    rec.replaceSubrange(0..<4, with: le(w.id))
                    rec[4] = 14
                    return rec
                }()
                if let pts = w.points { rec[4] = UInt8(clamping: max(4, Int((pts / 7).rounded()))) }
                return rec
            }
            // Slots the app's columns occupy, in the file's order; the rest stay put.
            var out: [[UInt8]] = []
            var next = ordered.makeIterator()
            for rec in records {
                if known.contains(id(rec)) {
                    if wanted.contains(where: { $0.id == id(rec) }), let r = next.next() { out.append(r) }
                } else {
                    out.append(rec)
                }
            }
            while let r = next.next() { out.append(r) }
            records = out
            guard !records.isEmpty else { return nil }
            var header = Array(blob.prefix(T.headerSize))
            header.replaceSubrange(4..<6, with: [UInt8(truncatingIfNeeded: records.count - 1),
                                                 UInt8(truncatingIfNeeded: (records.count - 1) >> 8)])
            return header + records.flatMap { $0 }
        }

        var meta = BinaryWriter()
        meta.append(Array(vm.prefix(24)))
        var data = BinaryWriter()
        var changed = false
        for entry in parsed.entries {
            var blob = MPP.readVar(vd, offset: entry.offset)
            if entry.uid == T.tableID, entry.field & 0xFFFF == T.columnsField, let new = rebuild(blob) {
                if new != blob { changed = true }
                blob = new
            }
            meta.u32(UInt32(entry.uid))
            meta.u32(UInt32(data.count))
            meta.u16(UInt16(entry.field & 0xFFFF))
            meta.u16(entry.fieldClass)
            data.u32(UInt32(blob.count))
            data.append(blob)
        }
        guard changed else { return }
        meta.patchU32(at: 8, UInt32(parsed.entries.count))
        meta.patchU32(at: 20, UInt32(data.count))
        root.setStream(path: "\(base)/VarMeta", meta.bytes)
        root.setStream(path: "\(base)/Var2Data", data.bytes)
        if let vp = root.streamIfPresent(path: "\(W.View.storage)/Props") {
            var p = MPP.parseProps(vp)
            if p.values[T.var2DataSizeKey] != nil {
                p.values[T.var2DataSizeKey] = le(UInt32(data.count))
                root.setStream(path: "\(W.View.storage)/Props", MPP.buildProps(p))
            }
        }
    }

    // MARK: Custom field names

    /// The names given to task custom fields ("Timeframe" for Text1), into
    /// `TBkndTask/Props` key 0x04400001 as Project writes it:
    ///
    /// - task names: `u32` length (of what follows it), the same again, `u32`
    ///   count, then per name the field id (0x0B40 class + native index) and the
    ///   offset of its NUL-terminated UTF-16 text, counted from byte 4;
    /// - resource and assignment names in the same form (kept as found);
    /// - definitions: `u32` count, `u32` byte size, then one record per named
    ///   field: field id, 8, a definition id, 7, a has-value-list flag, the
    ///   field's GUID (000039B7-8BBE-4CEB-82C4-FA8C + the id, big-endian) and
    ///   its value list's GUID. Records already in the file are kept as they
    ///   are; a newly named field gets one without a value list.
    func writeFieldAliases(_ project: Project) {
        let path = "\(W.prj)/TBkndTask/Props"
        let key: UInt32 = 0x0440_0001
        guard let raw = root.streamIfPresent(path: path) else { return }
        var props = MPP.parseProps(raw)
        // Every Project-saved file has the entry; its type code cannot be made up.
        guard let old = props.values[key] else { return }

        var named: [(id: UInt32, name: String)] = []
        for (kind, natives) in [("text", MPP.CustomField.text), ("number", MPP.CustomField.number),
                                ("date", MPP.CustomField.date), ("flag", MPP.CustomField.flag)] {
            for (i, native) in natives.enumerated() {
                guard let name = project.fieldAliases["\(kind)\(i + 1)"]?
                    .trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
                named.append((UInt32(MPP.FieldClass.task) << 16 | native, name))
            }
        }
        guard !named.isEmpty || !old.isEmpty else { return }

        // What the file has: the three name sections and the definitions.
        let r = BinaryReader(old)
        var sections: [[UInt8]] = []
        var records: [[UInt8]] = []
        var recordSize = 88
        var pos = 0
        parse: do {
            for _ in 0..<3 {
                guard let len = r.u32(at: pos).map(Int.init), pos + 4 + len <= old.count else { break parse }
                sections.append(Array(old[pos..<pos + 4 + len]))
                pos += 4 + len
            }
            guard let count = r.u32(at: pos).map(Int.init), let size = r.u32(at: pos + 4).map(Int.init),
                  count > 0, size % count == 0, pos + 8 + size <= old.count else { break parse }
            recordSize = size / count
            for i in 0..<count {
                let at = pos + 8 + i * recordSize
                records.append(Array(old[at..<at + recordSize]))
            }
        }
        let empty: [UInt8] = le(UInt32(8)) + le(UInt32(8)) + le(UInt32(0))
        while sections.count < 3 { sections.append(empty) }

        // Task names.
        var table: [UInt8] = [], text: [UInt8] = []
        let namesStart = 12 + named.count * 8
        for (id, name) in named {
            table += le(id) + le(UInt32(namesStart + text.count - 4))
            text += MPP.encodeUnicode(name)
        }
        let length = UInt32(8 + table.count + text.count)
        sections[0] = le(length) + le(length) + le(UInt32(named.count)) + table + text

        // Definitions: the file's, less task fields no longer named, plus new.
        func u32(_ b: [UInt8], _ at: Int) -> UInt32 { BinaryReader(b).u32(at: at) ?? 0 }
        let taskIDs = Set(named.map(\.id))
        records.removeAll { u32($0, 0) >> 16 == UInt32(MPP.FieldClass.task) && !taskIDs.contains(u32($0, 0)) }
        var nextDefinition = records.map { u32($0, 8) & 0xFFFF }.max().map { $0 + 1 } ?? 0x4064
        for (id, _) in named where !records.contains(where: { u32($0, 0) == id }) {
            var rec = [UInt8](repeating: 0, count: max(recordSize, 52))
            rec.replaceSubrange(0..<4, with: le(id))
            rec.replaceSubrange(4..<8, with: le(UInt32(8)))
            rec.replaceSubrange(8..<12, with: le(UInt32(MPP.FieldClass.assignment) << 16 | nextDefinition))
            rec.replaceSubrange(12..<16, with: le(UInt32(7)))
            let guid: [UInt8] = [0xB7, 0x39, 0x00, 0x00, 0xBE, 0x8B, 0xEB, 0x4C, 0x82, 0xC4, 0xFA, 0x8C,
                                 UInt8(id >> 24), UInt8(id >> 16 & 0xFF), UInt8(id >> 8 & 0xFF), UInt8(id & 0xFF)]
            rec.replaceSubrange(20..<36, with: guid)
            records.append(rec)
            nextDefinition += 1
        }
        let defs = le(UInt32(records.count)) + le(UInt32(records.reduce(0) { $0 + $1.count })) + records.flatMap { $0 }

        let value = sections.flatMap { $0 } + defs
        guard value != old else { return }
        props.values[key] = value
        root.setStream(path: path, MPP.buildProps(props))
    }

    // MARK: Document metadata

    func writeDocumentProperties(_ project: Project) {
        let scrub = options.scrubTemplateIdentity
        let S = W.Summary.self
        // Who saved the template, captured before the property sets change.
        let templateSummary = OLEPropertySet.parse((try? root.stream("\u{5}SummaryInformation")) ?? [])[0]
        let templateIdentity = Set([templateSummary?.string(S.author), templateSummary?.string(S.lastSavedBy)]
            .compactMap { $0 }.filter { !$0.isEmpty })

        func pick(_ v: String?) -> String? { v ?? (scrub ? "" : nil) }
        var summary: [UInt32: String] = [S.title: project.title]
        for (pid, v) in [(S.subject, project.subject), (S.author, project.author), (S.keywords, project.keywords),
                         (S.comments, project.comments), (S.lastSavedBy, scrub ? project.author : nil),
                         (S.template, nil)] {
            if let v = pick(v) { summary[pid] = v }
        }
        if let si = try? root.stream("\u{5}SummaryInformation") {
            root.addStream("\u{5}SummaryInformation", OLEPropertySet.updatingStrings(si, summary))
        }
        var doc: [UInt32: String] = [:]
        for (pid, v) in [(S.manager, project.manager), (S.company, project.company), (S.category, project.category)] {
            if let v = pick(v) { doc[pid] = v }
        }
        if !doc.isEmpty, let dsi = try? root.stream("\u{5}DocumentSummaryInformation") {
            root.addStream("\u{5}DocumentSummaryInformation", OLEPropertySet.updatingStrings(dsi, doc))
        }

        // Props14 records where the template was saved and by whom. Only
        // values that are a saved path or exactly the template's author are
        // touched: short numeric values also decode as "text".
        guard scrub, let raw = try? root.stream("Props14") else { return }
        var p = MPP.parseProps(raw)
        var changed = false
        for key in p.order {
            guard let value = p.values[key], value.count >= 6, value.count % 2 == 0 else { continue }
            let text = MPP.decodeUnicode(value)
            let terminated = value.suffix(2) == [0, 0]
            var replacement: String?
            if text.contains(":\\") || text.hasPrefix("\\\\") || text.lowercased().hasSuffix(".mpp") {
                replacement = "\(project.title).mpp"
            } else if templateIdentity.contains(text) {
                replacement = project.author ?? ""
            }
            if let r = replacement {
                let encoded = MPP.encodeUnicode(r)
                p.values[key] = terminated ? encoded : Array(encoded.dropLast(2))
                changed = true
            }
        }
        if changed { root.addStream("Props14", MPP.buildProps(p)) }
    }
}

// MARK: - Calendars

/// The calendar table being rebuilt: the template's base calendars kept, its
/// resource calendars dropped (their resources are not carried over), the
/// Standard calendar's definition replaced when the project gives one, and
/// one new row per added base or resource calendar.
private struct CalendarBuild {
    let session: Session
    var table: CalendarTable
    var rows: [CalendarTable.Row]
    var vars: [(uid: Int, field: UInt32, payload: [UInt8])]
    var uidByName: [String: Int] = [:]
    var nextUID: Int
    let standardUID: Int
    let standardGUID: [UInt8]
    let resourceProto: CalendarTable.Row?
    let baseProto: CalendarTable.Row?

    init(session: Session, project: Project) throws {
        self.session = session
        let table = CalendarTable(root: session.root)
        self.table = table
        guard let cols = table.columns else { throw MPPError.template("calendar table has no base calendar") }

        // The Standard calendar: the template's project calendar if it is
        // called that, else the first base calendar named Standard.
        let defaultName = session.props.text(MPP.PropsKey.defaultCalendarName) ?? "Standard"
        var baseNames: [Int: String] = [:]
        for row in table.rows where table.isBase(row) {
            if let uid = table.uid(of: row) {
                baseNames[uid] = table.payload(uid: uid, field: MPP.CalendarVar.name).map(MPP.decodeUnicode) ?? ""
            }
        }
        guard let stdUID = baseNames.first(where: { $0.value == "Standard" })?.key
                ?? baseNames.first(where: { $0.value == defaultName })?.key
                ?? baseNames.keys.min() else {
            throw MPPError.template("no Standard calendar")
        }

        // Rows to keep: stubs, base calendars, and the uid-0 resource's
        // calendar. The template's other resource calendars belong to
        // resources that are not carried over. Its extra base calendars stay:
        // the project properties can name them, so dropping one could leave a
        // dangling reference (`MPP14Template.neutralized` renames them instead).
        var kept: [CalendarTable.Row] = []
        var resourceProto: CalendarTable.Row?
        for row in table.rows {
            guard let v = CalendarTable.values(row) else {
                if isDeletedStub(row.rec) { kept.append(CalendarTable.Row(rec: row.rec, rec2: row.rec2,
                                                                           meta: row.meta, meta2: row.meta2)) }
                continue
            }
            if table.isBase(row) {
                // A base calendar deleted in the app goes; Standard never does.
                if let uid = table.uid(of: row), uid != stdUID, project.removedCalendarUIDs.contains(uid) { continue }
                kept.append(row)
            }
            else if v[cols.resource] == 0 { kept.append(row); resourceProto = row }
        }
        rows = kept
        let keptUIDs = Set(kept.compactMap { table.uid(of: $0) })
        vars = table.varEntries.filter { keptUIDs.contains($0.uid) }
        self.resourceProto = resourceProto
        standardUID = stdUID
        for (uid, name) in baseNames where !name.isEmpty && keptUIDs.contains(uid) { uidByName[name] = uid }
        uidByName["Standard"] = stdUID
        let stdRow = kept.first { table.uid(of: $0) == stdUID }
        standardGUID = Array((stdRow?.rec2 ?? []).prefix(16))
        baseProto = stdRow
        nextUID = (table.rows.compactMap { table.uid(of: $0) }.max() ?? 0) + 1

        // The project calendar's name, when it was renamed in the app.
        if let name = project.calendar?.name, !name.isEmpty, name != baseNames[stdUID] {
            setName(uid: stdUID, name)
            uidByName[name] = stdUID
        }
        // The Standard calendar's own definition.
        if let std = project.calendar,
           !(std.week.isEmpty && std.exceptions.isEmpty && table.payload(uid: stdUID, field: MPP.CalendarVar.data) == nil) {
            setData(uid: stdUID, CalendarData.build(week: std.week, exceptions: std.exceptions))
        }
        // Additional base calendars. A file saved over itself already has them:
        // one the template has by name is updated in place, keeping its uid,
        // which is what tasks and resources refer to it by.
        var seen = Set<String>()
        for cal in project.calendars {
            guard seen.insert(cal.name).inserted else {
                throw MPPError.invalidProject("duplicate calendar name \"\(cal.name)\"")
            }
            // The same calendar as read from the file — by uid, so a rename
            // keeps the row tasks and resources point at.
            if cal.uid != 0, cal.uid != stdUID, keptUIDs.contains(cal.uid), baseNames[cal.uid] != nil {
                if baseNames[cal.uid] != cal.name {
                    setName(uid: cal.uid, cal.name)
                    if uidByName[baseNames[cal.uid] ?? ""] == cal.uid { uidByName[baseNames[cal.uid] ?? ""] = nil }
                }
                uidByName[cal.name] = cal.uid
                if !(cal.week.isEmpty && cal.exceptions.isEmpty
                     && table.payload(uid: cal.uid, field: MPP.CalendarVar.data) == nil) {
                    setData(uid: cal.uid, CalendarData.build(week: cal.week, exceptions: cal.exceptions))
                }
                continue
            }
            if let uid = uidByName[cal.name] {
                // Standard's definition is the project calendar's, set above.
                if uid != stdUID, !(cal.week.isEmpty && cal.exceptions.isEmpty
                                    && table.payload(uid: uid, field: MPP.CalendarVar.data) == nil) {
                    setData(uid: uid, CalendarData.build(week: cal.week, exceptions: cal.exceptions))
                }
                continue
            }
            guard var row = baseProto else { throw MPPError.template("no base calendar to clone") }
            let uid = nextUID
            nextUID += 1
            uidByName[cal.name] = uid
            var rec = [UInt8](repeating: 0, count: 12)
            for c in 0..<3 { rec.replaceSubrange(c * 4..<c * 4 + 4, with: le(Int32(c == cols.uid ? uid : -1))) }
            row.rec = rec
            var rec2 = [UInt8](repeating: 0, count: max(48, row.rec2.count))
            rec2.replaceSubrange(0..<16, with: cal.guid.count == 16 ? cal.guid : session.options.newGUID())
            row.rec2 = rec2
            rows.append(row)
            vars.append((uid, MPP.CalendarVar.name, MPP.encodeUnicode(cal.name)))
            if !cal.week.isEmpty || !cal.exceptions.isEmpty {
                vars.append((uid, MPP.CalendarVar.data, CalendarData.build(week: cal.week, exceptions: cal.exceptions)))
            }
            patchMeta(uid: uid)
        }
        if let name = project.defaultCalendar, uidByName[name] == nil {
            throw MPPError.invalidProject("unknown default calendar \"\(name)\"")
        }
    }

    mutating func setName(uid: Int, _ name: String) {
        vars.removeAll { $0.uid == uid && $0.field == MPP.CalendarVar.name }
        vars.append((uid, MPP.CalendarVar.name, MPP.encodeUnicode(name)))
        patchMeta(uid: uid)
    }

    mutating func setData(uid: Int, _ blob: [UInt8]) {
        vars.removeAll { $0.uid == uid && $0.field == MPP.CalendarVar.data }
        vars.append((uid, MPP.CalendarVar.data, blob))
        patchMeta(uid: uid)
    }

    /// Meta byte 2 counts the row's var entries; byte 8 flags a name (0x01)
    /// and a definition blob (0xC0 — 0x80 in 2010-era metas, 0x40 in M365).
    /// Without the flags Project never reads the blob.
    mutating func patchMeta(uid: Int) {
        guard let i = rows.firstIndex(where: { table.uid(of: $0) == uid }), rows[i].meta.count > 8 else { return }
        let own = vars.filter { $0.uid == uid }
        rows[i].meta[2] = UInt8(own.count)
        let hasData = own.contains { $0.field == MPP.CalendarVar.data }
        rows[i].meta[8] = (rows[i].meta[8] & ~0xC0) | (hasData ? 0xC0 : 0)
    }

    /// A resource's own calendar row: (calendar uid, base = Standard, resource
    /// uid), GUIDs = the resource's twice, then Standard's.
    mutating func addResourceCalendar(resourceUID: Int, guid: [UInt8]) -> Int? {
        guard var row = resourceProto, let cols = table.columns else { return nil }
        let uid = nextUID
        nextUID += 1
        var rec = row.rec
        rec.replaceSubrange(cols.uid * 4..<cols.uid * 4 + 4, with: le(Int32(uid)))
        rec.replaceSubrange(cols.base * 4..<cols.base * 4 + 4, with: le(Int32(standardUID)))
        rec.replaceSubrange(cols.resource * 4..<cols.resource * 4 + 4, with: le(Int32(resourceUID)))
        row.rec = rec
        if row.rec2.count >= 48 {
            row.rec2.replaceSubrange(0..<16, with: guid)
            row.rec2.replaceSubrange(16..<32, with: guid)
            row.rec2.replaceSubrange(32..<48, with: standardGUID)
        }
        rows.append(row)
        return uid
    }

    var rowCount: Int { rows.count }

    /// Base calendars carrying a definition blob — Project reads base-calendar
    /// blobs only when this Props count says there are some.
    var editedBaseCount: Int {
        rows.filter(table.isBase)
            .compactMap { table.uid(of: $0) }
            .filter { uid in vars.contains { $0.uid == uid && $0.field == MPP.CalendarVar.data } }
            .count
    }

    func write() {
        let base = "TBkndCal"
        var header1 = table.metaHeader, header2 = table.meta2Header
        if header1.isEmpty { header1 = [UInt8](repeating: 0, count: 16) }
        if header2.isEmpty { header2 = [UInt8](repeating: 0, count: 16) }
        let asRows = rows.map { Row(rec: $0.rec, rec2: $0.rec2, meta: $0.meta, meta2: $0.meta2) }
        let (d1, m1) = assemble(asRows, second: false)
        session.set("\(base)/FixedData", d1)
        session.set("\(base)/FixedMeta", MPP.buildFixedMeta(header: header1, items: m1, dataLength: d1.count))
        let (d2, m2) = assemble(asRows, second: true)
        session.set("\(base)/Fixed2Data", d2)
        session.set("\(base)/Fixed2Meta", MPP.buildFixedMeta(header: header2, items: m2, dataLength: d2.count))
        let (vm, vd) = MPP.buildVarBlocks(header: table.varHeader, values: vars, fieldClass: table.varClass)
        session.set("\(base)/VarMeta", vm)
        session.set("\(base)/Var2Data", vd)
    }
}

// MARK: - Notes and identity

extension MPP14Writer {
    /// Plain text in the minimal RTF envelope Project writes for notes.
    public static func encodeRTFNotes(_ text: String) -> [UInt8] {
        var body = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\", "{", "}": body += "\\" + String(scalar)
            case "\n": body += "\\par "
            case _ where scalar.value > 127:
                // RTF \u takes a signed 16-bit value; astral scalars go as a
                // surrogate pair.
                for unit in String(scalar).utf16 { body += "\\u\(Int16(bitPattern: unit))?" }
            default: body.unicodeScalars.append(scalar)
            }
        }
        let rtf = "{\\rtf1\\ansi\\ansicpg1252\\deff0\\nouicompat\\deflang1033"
            + "{\\fonttbl{\\f0\\fnil\\fcharset0 Segoe UI;}}\\viewkind4\\uc1 "
            + "\\pard\\f0\\fs20 " + body + "}"
        return Array(rtf.utf8)
    }
}
