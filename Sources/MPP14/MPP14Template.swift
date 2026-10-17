// MPPKit: Microsoft Project (.mpp) files in Swift
// Copyright (C) 2026 Henrik Petersen
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

/// Turning a real Project file into a neutral writer template.
///
/// The writer never carries a template's tasks, resources, assignments or
/// links over, but a real schedule holds user data in places the writer keeps
/// byte-for-byte: custom-field aliases and lookup tables, extra base calendars
/// and their holidays, the save path the Gantt view cache remembers, and the
/// document properties. `neutralized` replaces all of it.
///
/// Wherever a structure is not fully understood the replacement keeps the
/// exact UTF-16 length, so no offset, size or count in the file moves. Only
/// the calendar table, whose layout is known, is rebuilt.
public enum MPP14Template {

    /// The template with user data replaced. Its own tasks are left for the
    /// writer to drop; see `makeBlank` for a file that has none.
    public static func neutralized(_ bytes: [UInt8]) throws -> [UInt8] {
        let file = try MPP14File(bytes: bytes)
        let root = file.root
        var props = file.props
        let prj = MPP.projectStorage

        // 1. Base calendars: rename every one but Standard, drop holidays.
        var table = CalendarTable(root: root)
        var renamed: [String: String] = [:]
        var n = 0
        for row in table.rows where table.isBase(row) {
            guard let uid = table.uid(of: row) else { continue }
            let old = table.payload(uid: uid, field: MPP.CalendarVar.name).map(MPP.decodeUnicode) ?? ""
            if old != "Standard" {
                n += 1
                let new = "Base Calendar \(n)"
                renamed[old] = new
                replaceVar(&table, uid: uid, field: MPP.CalendarVar.name, MPP.encodeUnicode(new))
            }
            if let blob = table.payload(uid: uid, field: MPP.CalendarVar.data) {
                let decoded = CalendarData.parse(blob)
                replaceVar(&table, uid: uid, field: MPP.CalendarVar.data,
                           CalendarData.build(week: decoded.week, exceptions: []))
            }
        }
        let (vm, vd) = MPP.buildVarBlocks(header: table.varHeader, values: table.varEntries,
                                          fieldClass: table.varClass)
        root.setStream(path: "\(CalendarTable.path)/VarMeta", vm)
        root.setStream(path: "\(CalendarTable.path)/Var2Data", vd)
        if let key = MPP.PropsKey.var2DataSize(for: "TBkndCal"), props.values[key] != nil {
            props.values[key] = littleEndian(UInt32(vd.count))
        }
        // The project properties name calendars too.
        for key in props.order {
            guard let v = props.values[key], v.count >= 4, v.count % 2 == 0 else { continue }
            let text = MPP.decodeUnicode(v)
            if let new = renamed[text] {
                let tail = v.count - text.utf16.count * 2      // keep the original terminator
                props.values[key] = Array(MPP.encodeUnicode(new).dropLast(2))
                    + [UInt8](repeating: 0, count: max(2, tail))
            }
        }
        // Standard's own holidays are dropped above; neutral defaults stay.
        root.setStream(path: "\(prj)/Props", MPP.buildProps(props))

        // 2. Custom-field lookup tables: every text value, same length.
        let outline = "\(prj)/TBkndOutlCode"
        if let vmRaw = root.streamIfPresent(path: "\(outline)/VarMeta"),
           var data = root.streamIfPresent(path: "\(outline)/Var2Data") {
            var counter = 0
            for entry in MPP.parseVarMeta(vmRaw).entries {
                let start = entry.offset + 4
                guard let size = BinaryReader(data).u32(at: entry.offset).map(Int.init),
                      start + size <= data.count else { continue }
                let payload = Array(data[start..<start + size])
                guard isText(payload) else { continue }
                counter += 1
                let units = payload.count / 2 - 1
                data.replaceSubrange(start..<start + units * 2, with: utf16(filler("Value", counter, length: units)))
            }
            root.setStream(path: "\(outline)/Var2Data", data)
        }

        // 3. Custom-field aliases in each entity's Props, same length.
        var aliasCounter = 0
        for entity in ["TBkndTask", "TBkndRsc", "TBkndAssn"] {
            let path = "\(prj)/\(entity)/Props"
            guard let raw = root.streamIfPresent(path: path) else { continue }
            var p = MPP.parseProps(raw)
            var changed = false
            for key in p.order {
                guard var value = p.values[key] else { continue }
                if renameAliases(&value, counter: &aliasCounter) {
                    p.values[key] = value
                    changed = true
                }
            }
            if changed { root.setStream(path: path, MPP.buildProps(p)) }
        }

        // 4. Saved paths anywhere (view cache, Props14), same length.
        for (path, data) in root.walk().compactMap({ e in e.node.streamBytes.map { (e.path, $0) } }) {
            let patched = replacingPaths(data)
            if patched != data { root.setStream(path: path, patched) }
        }

        // 5. Document properties.
        let blank: [UInt32: String] = [2: "Template", 3: "", 4: "", 5: "", 6: "", 7: "", 8: ""]
        if let si = root.streamIfPresent(path: "\u{5}SummaryInformation") {
            root.addStream("\u{5}SummaryInformation", OLEPropertySet.updatingStrings(si, blank))
        }
        if let dsi = root.streamIfPresent(path: "\u{5}DocumentSummaryInformation") {
            root.addStream("\u{5}DocumentSummaryInformation",
                           OLEPropertySet.updatingStrings(dsi, [2: "", 14: "", 15: ""]))
        }
        return try CFBWriter.write(root: root, rootCLSID: file.rootCLSID)
    }

    /// A clean writer template: `neutralized`, then rewritten as the minimal
    /// project the writer needs prototypes from — a summary task over two
    /// linked tasks, as pymppwriter's own template recipe prescribes.
    public static func makeBlank(from bytes: [UInt8]) throws -> [UInt8] {
        let neutral = try neutralized(bytes)
        var p = Project(title: "Template", start: MPPTime.date(2026, 1, 5, 8))
        var t1 = ProjectTask(uid: 1, name: "Task 1")
        var t2 = ProjectTask(uid: 2, name: "Task 2")
        var t3 = ProjectTask(uid: 3, name: "Task 3")
        t2.outlineLevel = 2; t2.parentUID = 1
        t3.outlineLevel = 2; t3.parentUID = 1
        t1.durationDays = 2
        p.tasks = [t1, t2, t3]
        p.relations = [Relation(predUID: 2, succUID: 3)]
        try Scheduler.schedule(&p)
        var options = MPP14Writer.Options()
        options.scrubTemplateIdentity = true
        return try MPP14Writer(template: neutral, options: options).build(p)
    }

    // MARK: - Helpers

    private static func replaceVar(_ t: inout CalendarTable, uid: Int, field: UInt32, _ payload: [UInt8]) {
        if let i = t.varEntries.firstIndex(where: { $0.uid == uid && $0.field == field }) {
            t.varEntries[i].payload = payload
        }
    }

    /// A NUL-terminated UTF-16 string of printable characters with a letter.
    static func isText(_ payload: [UInt8]) -> Bool {
        guard payload.count >= 4, payload.count % 2 == 0, payload.suffix(2) == [0, 0] else { return false }
        let units = stride(from: 0, to: payload.count - 2, by: 2).map {
            UInt16(payload[$0]) | UInt16(payload[$0 + 1]) << 8
        }
        guard units.allSatisfy({ $0 >= 0x20 }) else { return false }
        return String(decoding: units, as: UTF16.self).contains { $0.isLetter }
    }

    /// `prefix n` at exactly `length` characters: zero-padded when short,
    /// base-36 when the room is too small for the prefix.
    static func filler(_ prefix: String, _ n: Int, length: Int) -> String {
        guard length > 0 else { return "" }
        let number = String(n)
        if prefix.count + 1 + number.count <= length {
            let zeros = length - prefix.count - 1 - number.count
            return prefix + " " + String(repeating: "0", count: zeros) + number
        }
        let code = String(n, radix: 36).uppercased()
        let body = String(code.suffix(length - 1))
        return "V" + String(repeating: "0", count: max(0, length - 1 - body.count)) + body
    }

    private static func utf16(_ s: String) -> [UInt8] { s.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } }

    private static func littleEndian(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }

    /// Rename the strings of an alias block in place.
    ///
    /// Layout: `u32` length, `u32`, `u32 count`, then `count` × (`u32` field id
    /// in an entity class, `u32` offset), each offset counted from byte 4 of
    /// the value and pointing at a NUL-terminated UTF-16 name. Every entry is
    /// validated before anything is changed; a value that does not fit the
    /// layout exactly is left alone.
    static func renameAliases(_ value: inout [UInt8], counter: inout Int) -> Bool {
        let base = 4
        let r = BinaryReader(value)
        guard let count = r.u32(at: 8), count > 0, count < 512,
              12 + Int(count) * 8 <= value.count else { return false }
        let classes: Set<UInt16> = [MPP.FieldClass.task, MPP.FieldClass.resource, MPP.FieldClass.assignment]
        var spans: [Range<Int>] = []
        for i in 0..<Int(count) {
            guard let field = r.u32(at: 12 + i * 8), let offset = r.u32(at: 16 + i * 8).map(Int.init),
                  classes.contains(UInt16(field >> 16)) else { return false }
            let start = base + offset
            // Names sit after the entry table.
            guard start >= 12 + Int(count) * 8, start < value.count else { return false }
            var end = start
            while end + 1 < value.count, value[end] != 0 || value[end + 1] != 0 { end += 2 }
            guard end + 2 <= value.count, end > start,
                  isText(Array(value[start..<end + 2])) else { return false }
            spans.append(start..<end)
        }
        for span in spans {
            counter += 1
            value.replaceSubrange(span, with: utf16(filler("Field", counter, length: span.count / 2)))
        }
        return true
    }

    /// Replace Windows paths (`C:\…`, `\\server\…`) held as UTF-16 text,
    /// keeping their length and any `.mpp` suffix.
    static func replacingPaths(_ data: [UInt8]) -> [UInt8] {
        var out = data
        var i = 0
        while i + 6 <= out.count {
            let isDrive = (out[i] | 0x20) >= 0x61 && (out[i] | 0x20) <= 0x7A && out[i + 1] == 0
                && out[i + 2] == 0x3A && out[i + 3] == 0 && out[i + 4] == 0x5C && out[i + 5] == 0
            let isUNC = out[i] == 0x5C && out[i + 1] == 0 && out[i + 2] == 0x5C && out[i + 3] == 0
            guard isDrive || isUNC else { i += 1; continue }
            // Extend over printable UTF-16 units.
            var end = i
            while end + 1 < out.count {
                let unit = UInt16(out[end]) | UInt16(out[end + 1]) << 8
                if unit < 0x20 || unit == 0x21 /* "!" separates a view name */ { break }
                end += 2
            }
            let units = (end - i) / 2
            guard units >= 6 else { i += 2; continue }
            let original = String(decoding: stride(from: i, to: end, by: 2).map {
                UInt16(out[$0]) | UInt16(out[$0 + 1]) << 8 }, as: UTF16.self)
            let suffix = original.lowercased().hasSuffix(".mpp") ? ".mpp" : ""
            var replacement = "C:\\Projects\\Sample"
            let room = units - suffix.count
            if replacement.count > room { replacement = String(replacement.prefix(room)) }
            replacement += String(repeating: "_", count: room - replacement.count) + suffix
            out.replaceSubrange(i..<end, with: utf16(replacement))
            i = end
        }
        return out
    }
}
