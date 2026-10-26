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

/// Block structures inside an MPP14 file.
///
/// Layouts derive from the MIT-licensed `pymppwriter` reverse-engineering notes
/// (see THIRD_PARTY_NOTICES.md), which were themselves derived from the public
/// [MS-CFB] specification and from diffing files saved by Microsoft Project.
///
/// The governing principle throughout is that **nothing is hard-coded to a
/// Project version**: record offsets come from the file's own field map, item
/// sizes from the file's own header counts, and flag positions from its own meta
/// bitmaps. Project reorders its field map on save, so any hard-coded offset
/// would be wrong in most real files.
public enum MPP {
    public static let fixedMetaMagic: UInt32 = 0xFADFADBA

    // MARK: Props keys

    public enum PropsKey {
        public static let taskFieldMap: UInt32 = 131_092
        public static let resourceFieldMap: UInt32 = 131_093
        public static let relationFieldMap: UInt32 = 131_094
        public static let assignmentFieldMap: UInt32 = 131_095
        public static let projectStartDate: UInt32 = 37_748_738
        public static let projectFinishDate: UInt32 = 37_748_739
        public static let title: UInt32 = 37_748_744
        /// UTF-16 name plus four NUL bytes.
        public static let defaultCalendarName: UInt32 = 37_748_750
        public static let currencySymbol: UInt32 = 37_748_752
        /// `0xFFFFFFFF` means "no status date".
        public static let statusDate: UInt32 = 37_748_805
        public static let currencyCode: UInt32 = 37_753_787
        /// `u16` tenths of a minute after midnight.
        public static let defaultStartTime: UInt32 = 37_748_764
        public static let minutesPerDay: UInt32 = 37_748_765
        public static let minutesPerWeek: UInt32 = 37_748_766
        /// `u16` tenths of a minute after midnight.
        public static let defaultFinishTime: UInt32 = 37_748_769
        /// `u16`.
        public static let daysPerMonth: UInt32 = 37_753_743
        /// When the baseline was last saved; NA once it is cleared. The next ten
        /// keys are Baseline1...Baseline10's.
        public static let baselineSaved: UInt32 = 37_753_749
        /// 2010-era only; stale values make Project renumber task uids.
        public static let legacyNextUIDs: UInt32 = 37_748_910
        /// Count of base calendars carrying custom working time.
        public static let editedBaseCalendars: UInt32 = 8_388_609

        /// Var2Data byte length per storage. Project truncates its var-data read
        /// at the declared length, so a stale value hides var entries.
        public static func var2DataSize(for storage: String) -> UInt32? {
            switch storage {
            case "TBkndTask": return 65_537
            case "TBkndRsc": return 65_538
            case "TBkndCal": return 65_539
            case "TBkndAssn": return 65_540
            default: return nil
            }
        }

        /// Record counts, including deleted stubs and the uid-0 summary row.
        /// Project sizes its tables from these on load and silently drops
        /// records beyond the count.
        public static let taskRecordCount: UInt32 = 16_777_217
        public static let resourceRecordCount: UInt32 = 16_777_218
        /// Calendar rows, stubs included. (Upstream writes resources + 2, which
        /// only coincides with this in a template that has no resources.)
        public static let calendarRecordCount: UInt32 = 16_777_219
        public static let assignmentRecordCount: UInt32 = 16_777_220
        public static let relationRecordCount: UInt32 = 16_777_221
    }

    /// Native field-class prefixes carried in the high word of a VarMeta entry.
    public enum FieldClass {
        public static let task: UInt16 = 0x0B40
        public static let resource: UInt16 = 0x0C40
        public static let assignment: UInt16 = 0x0F40
    }

    /// Field categories from the field map's own category word.
    public enum Category {
        public static let uint16: UInt16 = 0x02
        public static let int32: UInt16 = 0x03
        public static let double: UInt16 = 0x05
        public static let timestamp: UInt16 = 0x13
        public static let guid: UInt16 = 0x48
        public static let workOrCost: UInt16 = 0x65
        public static let string: UInt16 = 0x08
        /// Booleans live as a single bit in FixedMeta/Fixed2Meta.
        public static let boolean: UInt16 = 0x0B
        public static let booleanAlt: UInt16 = 0x64

        public static func isBoolean(_ c: UInt16) -> Bool { c == boolean || c == booleanAlt }
    }

    // MARK: - Primitives

    /// Duration is tenths of a minute; one day is 4800.
    public static let tenthsPerDay: Int32 = 4_800
    /// Work is thousandths of a minute: one hour is 60 000.0, one 8-hour day 480 000.0.
    public static let workScale: Double = 1_000
    /// Percent-style doubles (max units, assignment units) where 10000.0 = 100%.
    public static let percentScale: Double = 10_000
    /// The bit in the units word meaning "estimated" (Project's trailing `?`).
    public static let estimatedFlag: UInt16 = 0x0020

    /// Duration unit codes to (label, tenths-of-a-minute divisor).
    public static let durationUnits: [UInt16: (label: String, tenthsPerUnit: Int)] = [
        3: ("m", 10),
        5: ("h", 600),
        7: ("d", 4_800),
        9: ("w", 24_000),
        11: ("mo", 96_000),
    ]

    // MARK: - Native field ids
    //
    // A field map entry's type value is `0xNN40_00xx`, where the high word names
    // the entity class (0x0B40 task, 0x0C40 resource, 0x0F40 assignment) and the
    // **low 16 bits** index Project's own TaskField / ResourceField enumeration.
    // Lookups must mask with 0xFFFF, so these are the bare low-word values.

    /// Task fields (`0x0B40` class).
    public enum TaskField {
        public static let uniqueID: UInt32 = 86
        public static let id: UInt32 = 23
        public static let name: UInt32 = 14
        public static let wbs: UInt32 = 16
        public static let outlineLevel: UInt32 = 249
        public static let parentUID: UInt32 = 160
        public static let duration: UInt32 = 29
        public static let remainingDuration: UInt32 = 31
        public static let actualDurationUnits: UInt32 = 181
        public static let actualDuration: UInt32 = 28
        public static let start: UInt32 = 35
        public static let finish: UInt32 = 36
        public static let earlyStart: UInt32 = 37
        public static let earlyFinish: UInt32 = 38
        public static let lateStart: UInt32 = 39
        public static let lateFinish: UInt32 = 40
        public static let created: UInt32 = 93
        public static let guid: UInt32 = 1143
        public static let milestone: UInt32 = 24
        public static let summary: UInt32 = 92
        public static let estimated: UInt32 = 396
        public static let work: UInt32 = 0
        public static let remainingWork: UInt32 = 4
        public static let calendarUniqueID: UInt32 = 401
        public static let manualStart: UInt32 = 1283
        public static let manualFinish: UInt32 = 1284
        public static let manualDuration: UInt32 = 1288
        public static let manualDurationUnits: UInt32 = 1289
        /// The flag M365 actually reads; `TASK_MODE` (1280) stays set either way.
        public static let manuallyScheduled: UInt32 = 1408
        public static let notes: UInt32 = 15
        public static let constraintType: UInt32 = 17
        public static let constraintDate: UInt32 = 18
        public static let deadline: UInt32 = 437
        public static let percentComplete: UInt32 = 32
        public static let percentWorkComplete: UInt32 = 33
        public static let actualStart: UInt32 = 41
        public static let actualFinish: UInt32 = 42
        public static let actualWork: UInt32 = 2
        public static let stop: UInt32 = 100
        public static let resume: UInt32 = 99
        public static let priority: UInt32 = 25
        public static let taskType: UInt32 = 128
        public static let effortDriven: UInt32 = 132
        /// Project keeps the task's start here (M365); 2010-era files keep the
        /// working moment before it.
        public static let summaryProgress: UInt32 = 387
        /// M365 only: paired with 387, see `ScheduleDriver`.
        public static let summaryProgressPrior: UInt32 = 1_255
        /// What determines the task's start; see `ScheduleDriver`.
        public static let scheduleDriver: UInt32 = 1_250
        /// A flag word: 0x80 always, 0x2000 on non-summary rows, 0x300 when
        /// constrained, 0x9000 once progress is recorded, 0x20000 on milestones
        /// (as observed in Project-written files).
        public static let taskFlags: UInt32 = 201
        /// Boolean on summary rows: set while nothing under them has started
        /// (2/2 unstarted, 0/5 progressed summaries in a Project-written file).
        public static let summaryUnstarted: UInt32 = 381
    }

    /// Resource fields (`0x0C40` class).
    public enum ResourceField {
        public static let uniqueID: UInt32 = 27
        public static let id: UInt32 = 0
        public static let name: UInt32 = 1
        public static let initials: UInt32 = 2
        public static let emailAddress: UInt32 = 35
        public static let maxUnits: UInt32 = 4
        public static let calendarUID: UInt32 = 56
        public static let guid: UInt32 = 728
        public static let calendarGUID: UInt32 = 729
        public static let position: UInt32 = 730
    }

    /// Assignment fields (`0x0F40` class).
    public enum AssignmentField {
        public static let uniqueID: UInt32 = 0
        public static let taskUniqueID: UInt32 = 1
        public static let resourceUniqueID: UInt32 = 2
        public static let start: UInt32 = 20
        public static let finish: UInt32 = 21
        public static let resume: UInt32 = 24
        public static let stop: UInt32 = 264
        public static let units: UInt32 = 7
        public static let work: UInt32 = 8
        public static let actualWork: UInt32 = 10
        public static let regularWork: UInt32 = 11
        public static let remainingWork: UInt32 = 12
        public static let guid: UInt32 = 636
        public static let taskGUID: UInt32 = 637
        public static let resourceGUID: UInt32 = 638
        public static let created: UInt32 = 634
        public static let actualStart: UInt32 = 22
        public static let actualFinish: UInt32 = 23
        public static let percentWorkComplete: UInt32 = 43
        /// Booleans: the assignment has started / has finished. Microsoft 365
        /// files have no fixed slot for the actual start, finish or % work
        /// complete above; these two bits are what records progress (0/0
        /// unstarted, 1/0 in progress, 1/1 finished, across a Project-written
        /// file). Project recalculates milestones, manual and fixed-duration
        /// tasks from them, so a stray "finished" opens such a task as 100%.
        public static let started: UInt32 = 41
        public static let finished: UInt32 = 42
    }

    /// Field 1250: what drives a task's start, as Project records it. Fields
    /// 387 and 1255 hold the date that driver imposes. Observed in a
    /// Microsoft 365 file across 200 tasks:
    ///
    /// | driver | 387 | 1255 |
    /// |---|---|---|
    /// | `actuals` started | start | start |
    /// | `actuals` complete | start (none on a milestone) | none |
    /// | `constraint` (and milestones) | none | start |
    /// | `projectStart` | start | start |
    /// | `predecessor` | predecessor's finish | predecessor's finish |
    /// | `summary` | none | none |
    ///
    /// The writer reproduces these combinations exactly. (Unstarted tasks
    /// opening as 100% complete turned out to be caused by cleared presence
    /// bits, not by these fields; see `Editor.bit`.)
    public enum ScheduleDriver: Int32 {
        case actuals = 1
        case constraint = 4
        case projectStart = 8
        case predecessor = 40
        case summary = 64
    }

    /// Calendar var-data entries.
    public enum CalendarVar {
        public static let name: UInt32 = 1
        public static let data: UInt32 = 8
    }

    /// Predecessor/successor link types as stored in the relation record.
    public static let relationTypes: [UInt16: String] = [0: "FF", 1: "FS", 2: "SF", 3: "SS"]

    /// Custom field native ids, in field-number order — index 0 is Text1, Flag1,
    /// Number1 and Date1 respectively.
    ///
    /// The numbering is not arithmetic: the ids jump from 70 to 317, and the
    /// stride is irregular, so these are the real ids rather than a formula.
    /// Custom fields are stored in var data, not the fixed record, which is why
    /// the field map lists them with offset 65535.
    public enum CustomField {
        public static let text: [UInt32] = [
            51, 54, 57, 60, 63, 66, 67, 68, 69, 70,
            317, 318, 319, 320, 321, 322, 323, 324, 325, 326,
            327, 328, 329, 330, 331, 332, 333, 334, 335, 336,
        ]
        public static let number: [UInt32] = [
            87, 88, 89, 90, 91,
            302, 303, 304, 305, 306, 307, 308, 309, 310, 311,
            312, 313, 314, 315, 316,
        ]
        public static let date: [UInt32] = [
            265, 266, 267, 268, 269, 270, 271, 272, 273, 274,
        ]
        public static let flag: [UInt32] = [
            72, 73, 74, 75, 76, 77, 78, 79, 80, 81,
            292, 293, 294, 295, 296, 297, 298, 299, 300, 301,
        ]
    }

    /// Task constraint types, by the code in the constraint-type field.
    public static let constraintTypes: [UInt16: String] = [
        0: "ASAP", 1: "ALAP", 2: "MSO", 3: "MFO",
        4: "SNET", 5: "SNLT", 6: "FNET", 7: "FNLT",
    ]

    /// Duration unit code to label.
    /// Elapsed units (`em`...`emo`) count wall-clock time, round the clock;
    /// `%` and `e%` only occur on lags.
    public static let unitCodes: [UInt16: String] = [3: "m", 4: "em", 5: "h", 6: "eh", 7: "d", 8: "ed",
                                                     9: "w", 10: "ew", 11: "mo", 12: "emo", 19: "%", 20: "e%"]
    /// Label to duration unit code.
    public static let unitLabels: [String: UInt16] = Dictionary(uniqueKeysWithValues: unitCodes.map { ($1, $0) })
    /// What Project writes in the units word of summary rows.
    public static let summaryUnits: UInt16 = 0x15

    /// Task type codes.
    public static let taskTypes: [UInt16: String] = [0: "fixed_units", 1: "fixed_duration", 2: "fixed_work"]

    /// The "project" storage: three spaces followed by 114.
    public static let projectStorage = "   114"

    /// A root stream of our own: the outline columns, comma-separated.
    public static let viewColumnsStream = "ProjectsColumns"

    /// A root stream of our own: each calendar's shifts and holiday sets, as
    /// JSON keyed by calendar name (`CalendarSetup`).
    public static let calendarSetupStream = "ProjectsCalendars"

    /// A root stream of our own: baseline slots 11 and up, which Project has
    /// no fields for, as JSON (`ExtraBaselines`).
    public static let extraBaselinesStream = "ProjectsBaselines"

    /// The Entry table (table 1, the Gantt Chart's) as Project stores it:
    /// `   214/CTable`, Var2Data field 6 per table — a 12-byte header (table
    /// id, `u16` column count − 1, …) then one 115-byte record per column:
    /// field id, width in characters, alignment and wrap bytes, and from byte
    /// 13 an optional UTF-16 title.
    public enum EntryTable {
        public static let storage = "   214/CTable"
        public static let tableID = 1
        public static let columnsField: UInt32 = 6
        public static let headerSize = 12
        public static let recordSize = 115
        /// `   214/Props` key holding the CTable Var2Data length.
        public static let var2DataSizeKey: UInt32 = 0x10003

        /// The app's column names and the task fields Project shows for them.
        public static let fields: [(name: String, id: UInt32)] = {
            var out: [(String, UInt32)] = [
                ("id", 0x0B40_0017), ("name", 0x0B40_000E), ("duration", 0x0B40_0507),
                ("start", 0x0B40_0505), ("finish", 0x0B40_0506), ("predecessors", 0x0B40_002F),
                ("successors", 0x0B40_0030), ("percent", 0x0B40_0020), ("resources", 0x0B40_0031),
            ]
            for (kind, natives) in [("text", CustomField.text), ("number", CustomField.number),
                                    ("date", CustomField.date), ("flag", CustomField.flag)] {
                for (i, native) in natives.enumerated() {
                    out.append(("\(kind)\(i + 1)", UInt32(FieldClass.task) << 16 | native))
                }
            }
            return out
        }()
    }

    // FixedMeta item sizes for a 2010-era file. Anything newer is derived from
    // the stream's own header count, so these are fallbacks only.
    public static let taskMetaSize = 47
    public static let taskMeta2Size = 92
    public static let relationMetaSize = 10
    public static let resourceMetaSize = 37
    public static let assignmentMetaSize = 34

    // MARK: - Props stream

    /// A parsed `Props` stream.
    ///
    /// The 16-byte header carries the stream length in its first two dwords and
    /// the entry count at offset 12; **both size dwords must be updated whenever
    /// any entry changes length**, or Project rejects the file.
    public struct PropsStream {
        public var header: [UInt8]
        public var values: [UInt32: [UInt8]]
        public var order: [UInt32]
        /// The third dword of each entry. Project rejects the file if it is
        /// zeroed, so it is preserved rather than synthesised.
        public var typeCodes: [UInt32: UInt32]

        public init(header: [UInt8] = [UInt8](repeating: 0, count: 16),
                    values: [UInt32: [UInt8]] = [:],
                    order: [UInt32] = [],
                    typeCodes: [UInt32: UInt32] = [:]) {
            self.header = header
            self.values = values
            self.order = order
            self.typeCodes = typeCodes
        }

        public subscript(key: UInt32) -> [UInt8]? { values[key] }

        public func u32(_ key: UInt32) -> UInt32? {
            guard let v = values[key], v.count >= 4 else { return nil }
            return BinaryReader(v).u32(at: 0)
        }

        /// Decode an entry holding a UTF-16 string.
        public func text(_ key: UInt32) -> String? {
            guard let v = values[key], !v.isEmpty else { return nil }
            let s = MPP.decodeUnicode(v)
            return s.isEmpty ? nil : s
        }
    }

    public static func parseProps(_ data: [UInt8]) -> PropsStream {
        let header = Array(data.prefix(16))
        let count = BinaryReader(data).u16(at: 12) ?? 0
        var values: [UInt32: [UInt8]] = [:]
        var order: [UInt32] = []
        var typeCodes: [UInt32: UInt32] = [:]
        var pos = 16
        for _ in 0..<count {
            guard data.count - pos >= 12 else { break }
            let r = BinaryReader(data)
            guard let size = r.u32(at: pos), let key = r.u32(at: pos + 4),
                  let ptype = r.u32(at: pos + 8) else { break }
            pos += 12
            let end = min(pos + Int(size), data.count)
            let value = pos <= end ? Array(data[pos..<end]) : []
            pos += Int(size) + (Int(size) & 1)          // 2-byte alignment
            values[key] = value
            typeCodes[key] = ptype
            order.append(key)
        }
        return PropsStream(header: header, values: values, order: order, typeCodes: typeCodes)
    }

    public static func buildProps(_ props: PropsStream) -> [UInt8] {
        var w = BinaryWriter()
        var header = props.header
        while header.count < 16 { header.append(0) }
        w.append(header)
        for key in props.order {
            guard let value = props.values[key] else { continue }
            w.u32(UInt32(value.count))
            w.u32(key)
            w.u32(props.typeCodes[key] ?? 0)
            w.append(value)
            if value.count & 1 == 1 { w.u8(0) }
        }
        // Header dwords 0 and 1 hold (stream length - 4) and dword 12 holds the
        // entry count. Project rejects the file if the length dwords are stale.
        w.patchU32(at: 0, UInt32(w.count) &- 4)
        w.patchU32(at: 4, UInt32(w.count) &- 4)
        w.patchU16(at: 12, UInt16(props.order.count))
        return w.bytes
    }

    // MARK: - Field map

    /// One 28-byte field map entry: `+0 mask | +4 fixedOffset | +6 varKey |
    /// +12 nativeFieldId | +20 category`.
    public struct FieldItem {
        public var typeValue: UInt32
        public var block: Int
        /// `65535` means the field is not stored in a fixed block.
        public var offset: Int
        public var varKey: UInt8
        public var category: UInt16
        public var mask: UInt32
        public var raw: [UInt8]

        /// The low 16 bits index Project's native field enumeration.
        public var nativeID: UInt32 { typeValue & 0xFFFF }

        public var inFixed: Bool {
            !Category.isBoolean(category) && offset != 65_535
        }

        public var inMeta: Bool { Category.isBoolean(category) }
    }

    /// Parse a field map. The block index (0 = FixedData, 1 = Fixed2Data) is
    /// inferred from a drop in the offset column, which is what marks the switch
    /// between the two fixed blocks.
    public static func parseFieldMap(_ data: [UInt8]) -> [FieldItem] {
        var items: [FieldItem] = []
        var last = 0
        var block = 0
        var i = 0
        while i + 28 <= data.count {
            let r = BinaryReader(data)
            let mask = r.u32(at: i) ?? 0
            let offset = Int(r.u16(at: i + 4) ?? 0)
            let varKey = r.u8(at: i + 6) ?? 0
            let typeValue = r.u32(at: i + 12) ?? 0
            let category = r.u16(at: i + 20) ?? 0
            if !Category.isBoolean(category) && offset != 65_535 {
                if offset < last { block += 1 }
                last = offset
            }
            items.append(FieldItem(typeValue: typeValue, block: block, offset: offset,
                                   varKey: varKey, category: category, mask: mask,
                                   raw: Array(data[i..<i + 28])))
            i += 28
        }
        return items
    }

    // MARK: - Fixed blocks

    public struct FixedMeta {
        public var header: [UInt8]
        public var declaredCount: UInt32
        public var items: [[UInt8]]
    }

    public static func parseFixedMeta(_ data: [UInt8], itemSize: Int) throws -> FixedMeta {
        guard let magic = BinaryReader(data).u32(at: 0) else {
            throw MPPError.malformed("FixedMeta shorter than its header")
        }
        guard magic == fixedMetaMagic else {
            throw MPPError.malformed(String(format: "FixedMeta magic 0x%08X", magic))
        }
        guard itemSize > 0 else { throw MPPError.malformed("FixedMeta item size 0") }
        let declaredCount = BinaryReader(data).u32(at: 8) ?? 0
        let n = (data.count - 16) / itemSize
        var items: [[UInt8]] = []
        items.reserveCapacity(max(0, n))
        for i in 0..<max(0, n) {
            let start = 16 + i * itemSize
            items.append(Array(data[start..<start + itemSize]))
        }
        return FixedMeta(header: Array(data.prefix(16)), declaredCount: declaredCount, items: items)
    }

    /// Parse a FixedMeta, deriving the item size from the stream itself so files
    /// of any Project vintage parse (M365 uses 96/51-byte Fixed2Meta items where
    /// 2010-era files use 92/50).
    ///
    /// **Divisibility alone is not enough.** The header's declared count is often
    /// one short of the number of items actually present, so `(len-16) % count`
    /// fails on real files and a fallback constant gets used instead — which
    /// silently mis-slices the stream and corrupts every flag read from it. The
    /// size is therefore chosen by *evidence*: each meta item stores its record's
    /// byte offset in FixedData at +4, so under the correct item size those
    /// offsets must increase monotonically from 0. Candidates are ranked by how
    /// close their implied item count is to the declared one.
    public static func parseFixedMetaAuto(_ data: [UInt8],
                                          defaultItemSize: Int) throws -> FixedMeta {
        let declaredCount = Int(BinaryReader(data).u32(at: 8) ?? 0)
        let body = data.count - 16
        guard body > 0 else {
            return try parseFixedMeta(data, itemSize: max(1, defaultItemSize))
        }

        for candidate in candidateItemSizes(body: body, declaredCount: declaredCount,
                                            preferred: defaultItemSize) {
            if let parsed = try? parseFixedMeta(data, itemSize: candidate),
               offsetsAreMonotonic(parsed.items) {
                return parsed
            }
        }
        return try parseFixedMeta(data, itemSize: max(1, defaultItemSize))
    }

    /// Item sizes worth testing, best first: ones that divide the body evenly and
    /// imply an item count near the declared one, ranked by that distance and
    /// then by closeness to the preferred size.
    private static func candidateItemSizes(body: Int, declaredCount: Int,
                                           preferred: Int) -> [Int] {
        // Slack of a few items is normal: Project leaves room for rows it has not
        // written yet, and the declared count can lag the stream. On the sample
        // file the task meta declares 205 items where 206 are physically present.
        let slack = 5
        var candidates: [Int] = []
        let lower = max(1, declaredCount - slack)
        let upper = declaredCount + slack
        for size in 8...max(8, body) where body % size == 0 {
            let n = body / size
            if n >= lower, n <= upper { candidates.append(size) }
        }
        if candidates.isEmpty {
            candidates = [preferred, preferred + 1, preferred - 1].filter { $0 > 0 }
        }
        return candidates.sorted {
            let da = abs(body / $0 - declaredCount), db = abs(body / $1 - declaredCount)
            if da != db { return da < db }
            return abs($0 - preferred) < abs($1 - preferred)
        }
    }

    /// Under the correct item size every item's FixedData offset at +4 is a
    /// non-decreasing byte offset, and the first record starts at zero.
    private static func offsetsAreMonotonic(_ items: [[UInt8]]) -> Bool {
        guard items.count > 1 else { return true }
        var previous = 0
        for (i, item) in items.enumerated() {
            guard let offset = BinaryReader(item).u32(at: 4) else { return false }
            if i == 0 { guard offset == 0 else { return false } }
            guard Int(offset) >= previous else { return false }
            previous = Int(offset)
        }
        return true
    }

    /// The items a table actually holds: the header's declared count, when it
    /// is smaller than what the stream physically contains. Project leaves
    /// slack and stale records past the count (on the sample, four old links
    /// past 213) and ignores them on load.
    public static func declaredItems(_ meta: FixedMeta) -> [[UInt8]] {
        let n = Int(meta.declaredCount)
        return n > 0 && n < meta.items.count ? Array(meta.items.prefix(n)) : meta.items
    }

    public static func buildFixedMeta(header: [UInt8], items: [[UInt8]],
                                      dataLength: Int? = nil) -> [UInt8] {
        var w = BinaryWriter()
        var h = header
        while h.count < 16 { h.append(0) }
        w.append(h)
        w.patchU32(at: 8, UInt32(items.count))
        if let dataLength { w.patchU32(at: 12, UInt32(dataLength)) }
        for item in items { w.append(item) }
        return w.bytes
    }

    /// Split FixedData into per-record slices using the offsets each FixedMeta
    /// item carries at `+4`.
    public static func splitFixedData(_ data: [UInt8], metaItems: [[UInt8]]) -> [[UInt8]] {
        // A record runs to the next record *in the data*, which is not always
        // the next item in the meta: Project rewrites an edited record at the
        // end of FixedData and leaves the meta in row order. Taking the next
        // meta item's offset gave such rows a negative length and dropped
        // them — a whole task (and every link to it) missing from the plan.
        let offsets = metaItems.map { Int(BinaryReader($0).u32(at: 4) ?? 0) }
        let sorted = Array(Set(offsets)).sorted()
        var out: [[UInt8]] = []
        out.reserveCapacity(metaItems.count)
        for off in offsets {
            guard off <= data.count else { out.append([]); continue }
            // The smallest offset after this one, else the end of the data.
            var lo = 0, hi = sorted.count
            while lo < hi { let mid = (lo + hi) / 2; if sorted[mid] <= off { lo = mid + 1 } else { hi = mid } }
            let next = lo < sorted.count ? min(sorted[lo], data.count) : data.count
            out.append(Array(data[off..<next]))
        }
        return out
    }

    // MARK: - Meta bitmaps
    //
    // A FixedMeta / Fixed2Meta item is: uint32 flags, uint32 offset-in-FixedData,
    // then a bitmap with a bit per field map entry in little-endian bit order.
    // Boolean fields store their value in their entry's bit; for value fields
    // the bit marks the field as populated, and Project shows a var-data field
    // whose bit is clear as empty.
    //
    // Two indexings meet in Fixed2Meta, established from files Project saved
    // rather than understood:
    // - booleans and fixed-data fields: the entry's place in the whole map,
    //   FixedMeta holding the first (itemSize-8)*8 and Fixed2Meta the rest.
    //   Checked against MPXJ, whose boolean positions are hard-coded, on the
    //   M365 files' block-1 Manually Scheduled flag; the var-data indexing
    //   reads it as set on every task.
    // - var-data fields: the entry's place within its block, so Fixed2Meta
    //   counts from the first block-1 entry. FixedMeta's bitmap is padded past
    //   the block-0 entries (312 bits for 305 or 307), so the first indexing
    //   lands these 5 to 7 places off. Checked on every var field of the 36
    //   Project 2010/2013 files in MPXJ's corpus (Tools/ci/fetch-corpus.sh);
    //   Baseline1...Baseline10 only show in Project with these bits.
    // In block 0 the two agree.
    //
    // Because Project reorders the field map per file, these positions must be
    // derived from the file's own field map and never hard-coded.

    /// A field map entry's meta bit.
    public struct MetaBit: Equatable, Sendable {
        /// The entry's place in the whole field map.
        public var entry: Int
        /// Its block, and its place among that block's entries.
        public var block: Int
        public var index: Int
        /// The field's value is in var data, so the bit only says whether the
        /// record has an entry for it, and is found by `block` and `index`.
        public var varData: Bool
    }

    /// Each native field's meta bit, from the field map's own order. The
    /// first entry of a field wins.
    public static func metaBits(_ items: [FieldItem]) -> [UInt32: MetaBit] {
        var out: [UInt32: MetaBit] = [:]
        var count = [0, 0]
        for (entry, item) in items.enumerated() {
            let block = min(item.block, 1)
            if out[item.nativeID] == nil {
                out[item.nativeID] = MetaBit(entry: entry, block: block, index: count[block],
                                             varData: item.offset == 65_535 && !Category.isBoolean(item.category))
            }
            count[block] += 1
        }
        return out
    }

    /// Which meta item holds a bit, and where in its bitmap.
    private static func locate(_ bit: MetaBit, metaCount: Int) -> (second: Bool, index: Int) {
        if bit.varData { return (bit.block != 0, bit.index) }
        let bits0 = max(0, (metaCount - 8) * 8)
        return bit.entry < bits0 ? (false, bit.entry) : (true, bit.entry - bits0)
    }

    public static func metaBit(meta: [UInt8], meta2: [UInt8], _ bit: MetaBit) -> Int? {
        let (second, i) = locate(bit, metaCount: meta.count)
        let buffer = second ? meta2 : meta
        let byte = 8 + i / 8
        guard byte < buffer.count else { return nil }
        return (Int(buffer[byte]) >> (i % 8)) & 1
    }

    public static func setMetaBit(meta: inout [UInt8], meta2: inout [UInt8], _ bit: MetaBit, value: Bool) {
        let (second, i) = locate(bit, metaCount: meta.count)
        let byte = 8 + i / 8
        let mask = UInt8(1 << (i % 8))
        if !second {
            guard byte < meta.count else { return }
            if value { meta[byte] |= mask } else { meta[byte] &= ~mask }
        } else {
            guard byte < meta2.count else { return }
            if value { meta2[byte] |= mask } else { meta2[byte] &= ~mask }
        }
    }

    // MARK: - Var blocks

    /// VarMeta: a 24-byte header then 12-byte entries
    /// `uint32 uid, uint32 offset, uint16 fieldLo, uint16 fieldHi`.
    ///
    /// `fieldHi` is the field-class prefix (0x0B40 tasks, 0x0C40 resources,
    /// 0x0F40 assignments). Project ignores the entry — the value disappears —
    /// if that word is zero.
    public struct VarMeta {
        public var header: [UInt8]
        /// uid -> (field id -> offset in Var2Data)
        public var table: [Int: [UInt32: Int]]
        public var entries: [(uid: Int, offset: Int, field: UInt32, fieldClass: UInt16)]
    }

    public static func parseVarMeta(_ data: [UInt8]) -> VarMeta {
        let r = BinaryReader(data)
        let count = r.u32(at: 8) ?? 0
        var table: [Int: [UInt32: Int]] = [:]
        var entries: [(Int, Int, UInt32, UInt16)] = []
        var pos = 24
        for _ in 0..<count {
            guard data.count - pos >= 12 else { break }
            guard let uid = r.u32(at: pos), let off = r.u32(at: pos + 4),
                  let lo = r.u16(at: pos + 8), let hi = r.u16(at: pos + 10) else { break }
            pos += 12
            // The table is keyed by the **low** word alone — the native field id
            // that the field map also publishes and that all lookups use. The
            // high word is the entity-class prefix (0x0B40 task, 0x0C40 resource,
            // 0x0F40 assignment), which is carried alongside rather than mixed
            // into the key; folding it in makes every lookup miss.
            let field = (UInt32(hi) << 16) | UInt32(lo)
            table[Int(uid), default: [:]][UInt32(lo)] = Int(off)
            entries.append((Int(uid), Int(off), field, hi))
        }
        return VarMeta(header: Array(data.prefix(24)), table: table, entries: entries)
    }

    public static func readVar(_ data: [UInt8], offset: Int) -> [UInt8] {
        guard let size = BinaryReader(data).u32(at: offset) else { return [] }
        let start = offset + 4
        let end = min(start + Int(size), data.count)
        guard start <= end else { return [] }
        return Array(data[start..<end])
    }

    public static func buildVarBlocks(header: [UInt8],
                                      values: [(uid: Int, field: UInt32, payload: [UInt8])],
                                      fieldClass: UInt16) -> (meta: [UInt8], data: [UInt8]) {
        var meta = BinaryWriter()
        var h = header
        while h.count < 24 { h.append(0) }
        meta.append(h)

        var varData = BinaryWriter()
        var entries = BinaryWriter()
        for v in values.sorted(by: { ($0.uid, $0.field) < ($1.uid, $1.field) }) {
            entries.u32(UInt32(v.uid))
            entries.u32(UInt32(varData.count))
            entries.u16(UInt16(v.field & 0xFFFF))
            entries.u16(fieldClass)
            varData.u32(UInt32(v.payload.count))
            varData.append(v.payload)
        }
        var m = meta.bytes
        m.append(contentsOf: entries.bytes)
        var w = BinaryWriter()
        w.append(m)
        w.patchU32(at: 8, UInt32(values.count))
        w.patchU32(at: 20, UInt32(varData.count))
        return (w.bytes, varData.bytes)
    }

    // MARK: - Timestamps

    /// A timestamp is `uint16 tenthsOfMinute, uint16 daysSince1983-12-31`;
    /// `FFFFFFFF` means "no value". Day counts of 0, 1 and 65535 are also treated
    /// as unset, matching what Project writes for an empty slot.
    public static func decodeTimestamp(_ b: [UInt8], offset: Int) -> Date? {
        let r = BinaryReader(b)
        guard let time = r.u16(at: offset), let days = r.u16(at: offset + 2) else { return nil }
        if days <= 1 || days == 65_535 { return nil }
        let tenths = time == 65_535 ? 0 : Int(time)
        return MPPTime.date(days: Int(days), tenths: tenths)
    }

    public static func encodeTimestamp(_ date: Date?) -> [UInt8] {
        guard let date else { return [0xFF, 0xFF, 0xFF, 0xFF] }
        let (days, tenths) = MPPTime.wire(from: date)
        var w = BinaryWriter()
        w.u16(UInt16(clamping: tenths))
        w.u16(UInt16(clamping: days))
        return w.bytes
    }

    // MARK: - Strings

    /// UTF-16LE, terminated by a single NUL code unit.
    public static func encodeUnicode(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(s.utf16.count * 2 + 2)
        for unit in s.utf16 {
            out.append(UInt8(unit & 0xFF))
            out.append(UInt8((unit >> 8) & 0xFF))
        }
        out.append(contentsOf: [0, 0])
        return out
    }

    public static func decodeUnicode(_ b: [UInt8]) -> String {
        var bytes = b
        if bytes.count % 2 == 1 { bytes.removeLast() }
        let s = decodeUTF16LE(bytes)
        if let idx = s.firstIndex(of: "\0") { return String(s[s.startIndex..<idx]) }
        return s
    }
}

public enum MPPError: Error, CustomStringConvertible {
    case notAnMPPFile(String)
    case malformed(String)
    case unsupported(String)
    /// A Project file from before Project 2010, in a format not read here:
    /// `MPP12` (Project 2007), `MPP9` (Project 2000–2003) or `MPP8` (Project 98).
    case olderFormat(String)
    /// The project cannot be written as given.
    case invalidProject(String)
    /// The template lacks a record the writer clones.
    case template(String)

    public var description: String {
        switch self {
        case .invalidProject(let detail): return "invalid project: \(detail)"
        case .template(let detail): return "unusable template: \(detail)"
        case .notAnMPPFile(let detail): return "not an MPP14 project file: \(detail)"
        case .malformed(let detail): return "malformed MPP data: \(detail)"
        case .unsupported(let detail): return "unsupported: \(detail)"
        case .olderFormat(let version): return "saved by \(version), an older format than Project 2010"
        }
    }
}
