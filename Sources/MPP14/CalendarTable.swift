// MPPKit: Microsoft Project (.mpp) files in Swift
// Copyright (C) 2026 Henrik Petersen
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 3 as published
// by the Free Software Foundation. It is distributed WITHOUT ANY WARRANTY;
// see the LICENSE file for details. https://mppstudio.com
//
// SPDX-License-Identifier: GPL-3.0-only

#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif
import MPPCFB
import MPPModel

/// The `TBkndCal` block: one row per calendar, base and resource alike.
///
/// A calendar's fixed record is three `int32`s — its own uid, its base
/// calendar's uid and its resource's uid, `-1` where not applicable — in a
/// column order that varies between Project versions. The order is therefore
/// detected from the records themselves: a base calendar has `-1` in two
/// columns, which pins the uid column, and of the remaining two, the base
/// column is the one whose values are base-calendar uids.
///
/// Names (var entry 1) are only stored for base calendars; a resource calendar
/// takes its resource's name. Working weeks and exceptions are the var entry 8
/// blob decoded by `CalendarData`.
struct CalendarTable {
    struct Row {
        var rec: [UInt8]
        var rec2: [UInt8]
        var meta: [UInt8]
        var meta2: [UInt8]
    }

    struct Columns: Equatable {
        var uid: Int
        var base: Int
        var resource: Int
    }

    var rows: [Row] = []
    var metaHeader: [UInt8] = []
    var meta2Header: [UInt8] = []
    var varHeader: [UInt8] = []
    /// The class word Project writes in this block's VarMeta entries.
    var varClass: UInt16 = 0
    var varEntries: [(uid: Int, field: UInt32, payload: [UInt8])] = []
    var columns: Columns?

    static let path = "\(MPP.projectStorage)/TBkndCal"

    init(root: CFBStorage) {
        let base = Self.path
        if let metaRaw = try? root.stream(path: "\(base)/FixedMeta"),
           let data = try? root.stream(path: "\(base)/FixedData"),
           let meta = try? MPP.parseFixedMetaAuto(metaRaw, defaultItemSize: 10) {
            metaHeader = Array(metaRaw.prefix(16))
            let items = MPP.declaredItems(meta)
            let recs = MPP.splitFixedData(data, metaItems: items)
            var recs2: [[UInt8]] = []
            var metas2: [[UInt8]] = []
            if let meta2Raw = try? root.stream(path: "\(base)/Fixed2Meta"),
               let data2 = try? root.stream(path: "\(base)/Fixed2Data"),
               let meta2 = try? MPP.parseFixedMetaAuto(meta2Raw, defaultItemSize: 9) {
                meta2Header = Array(meta2Raw.prefix(16))
                metas2 = MPP.declaredItems(meta2)
                recs2 = MPP.splitFixedData(data2, metaItems: metas2)
            }
            for i in 0..<recs.count {
                rows.append(Row(rec: recs[i],
                                rec2: i < recs2.count ? recs2[i] : [],
                                meta: items[i],
                                meta2: i < metas2.count ? metas2[i] : []))
            }
        }
        if let vm = try? root.stream(path: "\(base)/VarMeta"),
           let vd = try? root.stream(path: "\(base)/Var2Data") {
            let parsed = MPP.parseVarMeta(vm)
            varHeader = parsed.header
            varClass = parsed.entries.first?.fieldClass ?? 0
            for e in parsed.entries {
                varEntries.append((e.uid, e.field & 0xFFFF, MPP.readVar(vd, offset: e.offset)))
            }
        }
        columns = Self.detectColumns(rows)
    }

    /// The three dwords of a calendar record, or `nil` for a stub.
    static func values(_ row: Row) -> [Int32]? {
        guard row.rec.count == 12 else { return nil }
        let r = BinaryReader(row.rec)
        guard let a = r.i32(at: 0), let b = r.i32(at: 4), let c = r.i32(at: 8) else { return nil }
        return [a, b, c]
    }

    /// "No calendar" / "no resource": Project writes -1, and some versions 0
    /// in the base column.
    static func isNone(_ v: Int32) -> Bool { v <= 0 }

    static func detectColumns(_ rows: [Row]) -> Columns? {
        let all = rows.compactMap(values)
        // A base calendar has nothing in both its base and resource columns.
        let isBaseRow: ([Int32]) -> Bool = { $0.filter(isNone).count == 2 }
        guard let baseRow = all.first(where: isBaseRow),
              let uidColumn = baseRow.firstIndex(where: { !isNone($0) }) else { return nil }
        let baseUIDs = Set(all.filter(isBaseRow).map { $0[uidColumn] })
        let others = [0, 1, 2].filter { $0 != uidColumn }
        // The base column is the one that names base calendars on rows that
        // are not themselves base calendars.
        let derived = all.filter { !isBaseRow($0) }
        let score: (Int) -> Int = { col in derived.filter { baseUIDs.contains($0[col]) }.count }
        let baseColumn = score(others[0]) >= score(others[1]) ? others[0] : others[1]
        let resourceColumn = others.first { $0 != baseColumn }!
        return Columns(uid: uidColumn, base: baseColumn, resource: resourceColumn)
    }

    func uid(of row: Row) -> Int? {
        guard let c = columns, let v = Self.values(row) else { return nil }
        return Int(v[c.uid])
    }

    func isBase(_ row: Row) -> Bool {
        guard let c = columns, let v = Self.values(row) else { return false }
        return Self.isNone(v[c.base]) && Self.isNone(v[c.resource])
    }

    func resourceUID(of row: Row) -> Int? {
        guard let c = columns, let v = Self.values(row), !Self.isNone(v[c.resource]) else { return nil }
        return Int(v[c.resource])
    }

    func baseUID(of row: Row) -> Int? {
        guard let c = columns, let v = Self.values(row), !Self.isNone(v[c.base]) else { return nil }
        return Int(v[c.base])
    }

    func payload(uid: Int, field: UInt32) -> [UInt8]? {
        varEntries.last { $0.uid == uid && $0.field == field }?.payload
    }
}

extension MPP14File {
    struct ReadCalendars {
        var standard: ProjectCalendar?
        var base: [ProjectCalendar] = []
        var resource: [ProjectCalendar] = []
        /// Every calendar uid to its display name.
        var names: [Int: String] = [:]
    }

    func readCalendars() -> ReadCalendars {
        let table = CalendarTable(root: root)
        var out = ReadCalendars()
        let defaultName = props.text(MPP.PropsKey.defaultCalendarName) ?? "Standard"
        for row in table.rows {
            guard let uid = table.uid(of: row) else { continue }
            var cal = ProjectCalendar()
            cal.uid = uid
            cal.name = table.payload(uid: uid, field: MPP.CalendarVar.name)
                .map(MPP.decodeUnicode) ?? ""
            if let blob = table.payload(uid: uid, field: MPP.CalendarVar.data) {
                let decoded = CalendarData.parse(blob)
                cal.week = decoded.week
                cal.exceptions = decoded.exceptions
            }
            cal.guid = Array(row.rec2.prefix(16))
            if table.isBase(row) {
                out.names[uid] = cal.name
                if out.standard == nil && cal.name == defaultName {
                    out.standard = cal
                } else {
                    out.base.append(cal)
                }
            } else {
                cal.resourceUID = table.resourceUID(of: row)
                cal.baseCalendarUID = table.baseUID(of: row)
                out.resource.append(cal)
            }
        }
        return out
    }
}
