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

/// Reader for OLE property sets ([MS-OLEPS]), the format behind a compound
/// file's `\x05SummaryInformation` and `\x05DocumentSummaryInformation` streams.
///
/// These carry the document metadata Project writes alongside the project data
/// — title, author, manager, company and so on. They are entirely independent of
/// the MPP14 block structures, which is why they are parsed separately.
///
/// Layout:
///   header       28 bytes: byte order, version, system id, CLSID, section count
///   section list 20 bytes each: FMTID (16) + offset to the section
///   section      8 bytes: size + property count, then count x (id, offset)
///   property     type (4 bytes) + value
///
/// Property offsets are relative to the start of their section.
public enum OLEPropertySet {

    public enum Value: Equatable, Sendable {
        case string(String)
        case int(Int32)
        case uint(UInt32)
        case double(Double)
        case boolean(Bool)
        case null
        case unsupported(UInt32)

        public var stringValue: String? {
            if case .string(let s) = self { return s }
            return nil
        }

        public var intValue: Int? {
            switch self {
            case .int(let v): return Int(v)
            case .uint(let v): return Int(v)
            default: return nil
            }
        }
    }

    /// One section: property id -> value, plus the section's FMTID.
    public struct Section: Sendable {
        public var formatID: [UInt8]
        public var properties: [UInt32: Value]

        public subscript(id: UInt32) -> Value? { properties[id] }
        public func string(_ id: UInt32) -> String? {
            guard let s = properties[id]?.stringValue, !s.isEmpty else { return nil }
            return s
        }
    }

    public struct Document: Sendable {
        public var sections: [Section]
        public subscript(index: Int) -> Section? {
            index < sections.count ? sections[index] : nil
        }
    }

    // MARK: - Variant type tags ([MS-OLEPS] 2.15)

    private enum VT {
        static let i2: UInt32 = 2
        static let i4: UInt32 = 3
        static let r4: UInt32 = 4
        static let r8: UInt32 = 5
        static let bool: UInt32 = 11
        static let i1: UInt32 = 16
        static let ui1: UInt32 = 17
        static let ui2: UInt32 = 18
        static let ui4: UInt32 = 19
        static let i8: UInt32 = 20
        static let ui8: UInt32 = 21
        static let lpstr: UInt32 = 30
        static let lpwstr: UInt32 = 31
        static let filetime: UInt32 = 64
        static let blob: UInt32 = 65
        static let cf: UInt32 = 71
        static let clsid: UInt32 = 72
        static let vector: UInt32 = 0x1000
        static let variant: UInt32 = 12
    }

    public static func parse(_ bytes: [UInt8]) -> Document {
        let r = BinaryReader(bytes)
        guard bytes.count >= 28 else { return Document(sections: []) }
        let sectionCount = Int(r.u32(at: 24) ?? 0)
        guard sectionCount > 0, sectionCount < 64 else { return Document(sections: []) }

        var sections: [Section] = []
        for s in 0..<sectionCount {
            let entry = 28 + s * 20
            guard entry + 20 <= bytes.count else { break }
            let fmtid = Array(bytes[entry..<entry + 16])
            guard let sectionOffset = r.u32(at: entry + 16) else { break }

            guard let size = r.u32(at: Int(sectionOffset)),
                  let count = r.u32(at: Int(sectionOffset) + 4) else { break }
            let sectionEnd = min(Int(sectionOffset) + Int(size), bytes.count)
            guard count < 4096 else { break }

            // Property 1 is the code page that LPSTR values are encoded in.
            var codePage: UInt32 = 1252
            for i in 0..<Int(count) {
                let e = Int(sectionOffset) + 8 + i * 8
                guard e + 8 <= bytes.count else { break }
                if r.u32(at: e) == 1, let off = r.u32(at: e + 4),
                   let v = r.u32(at: Int(sectionOffset) + Int(off)), v < 65536 {
                    codePage = v
                }
            }

            var props: [UInt32: Value] = [:]
            for i in 0..<Int(count) {
                let e = Int(sectionOffset) + 8 + i * 8
                guard e + 8 <= bytes.count else { break }
                guard let id = r.u32(at: e), let off = r.u32(at: e + 4) else { break }
                let pos = Int(sectionOffset) + Int(off)
                guard pos >= 0, pos + 4 <= sectionEnd, pos + 4 <= bytes.count else { continue }
                props[id] = decode(bytes, at: pos, codePage: codePage)
            }
            sections.append(Section(formatID: fmtid, properties: props))
        }
        return Document(sections: sections)
    }

    private static func decode(_ bytes: [UInt8], at pos: Int, codePage: UInt32) -> Value {
        let r = BinaryReader(bytes)
        guard let vtype = r.u32(at: pos) else { return .null }
        // Vector types and VT_VARIANT are not used by the properties Project
        // writes; report rather than guess.
        if vtype & VT.vector != 0 || vtype == VT.variant { return .unsupported(vtype) }

        switch vtype {
        case VT.lpstr:
            guard let len = r.u32(at: pos + 4) else { return .null }
            let start = pos + 8
            let end = min(start + Int(len), bytes.count)
            guard start <= end else { return .null }
            var raw = Array(bytes[start..<end])
            while raw.last == 0 { raw.removeLast() }
            return .string(decodeString(raw, codePage: codePage))
        case VT.lpwstr:
            guard let len = r.u32(at: pos + 4) else { return .null }
            let start = pos + 8
            let end = min(start + Int(len) * 2, bytes.count)
            guard start <= end else { return .null }
            var raw = Array(bytes[start..<end])
            while raw.count >= 2, raw.suffix(2) == [0, 0] { raw.removeLast(2) }
            return .string(decodeUTF16LE(raw))
        case VT.i1:
            guard let v = r.u8(at: pos + 4) else { return .null }
            return .int(Int32(Int8(bitPattern: v)))
        case VT.ui1:
            guard let v = r.u8(at: pos + 4) else { return .null }
            return .uint(UInt32(v))
        case VT.i2:
            guard let v = r.u16(at: pos + 4) else { return .null }
            return .int(Int32(Int16(bitPattern: v)))
        case VT.ui2:
            guard let v = r.u16(at: pos + 4) else { return .null }
            return .uint(UInt32(v))
        case VT.i4:
            return r.i32(at: pos + 4).map { .int($0) } ?? .null
        case VT.ui4:
            return r.u32(at: pos + 4).map { .uint($0) } ?? .null
        case VT.i8:
            guard let v = r.u64(at: pos + 4) else { return .null }
            // Value.int is 32-bit; Project's own properties never exceed that,
            // and truncating keeps the low-order value rather than throwing.
            return .int(Int32(truncatingIfNeeded: v))
        case VT.ui8:
            return r.u64(at: pos + 4).map { .uint(UInt32(truncatingIfNeeded: $0)) } ?? .null
        case VT.r4:
            guard let v = r.u32(at: pos + 4) else { return .null }
            return .double(Double(Float(bitPattern: v)))
        case VT.r8:
            return r.f64(at: pos + 4).map { .double($0) } ?? .null
        case VT.bool:
            guard let v = r.u16(at: pos + 4) else { return .null }
            return .boolean(v != 0)
        case VT.filetime:
            guard let v = r.u64(at: pos + 4) else { return .null }
            return .double(filetimeToInterval(v))
        default:
            return .unsupported(vtype)
        }
    }

    // MARK: - Writing

    /// Replace or add string properties in one section of a property set,
    /// keeping every other property byte-for-byte.
    ///
    /// Values are written as `VT_LPSTR` in the section's own code page
    /// (property 1), which is how Project writes them. Ported from
    /// pymppwriter's `update_property_set_strings` (MIT).
    public static func updatingStrings(_ bytes: [UInt8], _ updates: [UInt32: String],
                                       section target: Int = 0) -> [UInt8] {
        let r = BinaryReader(bytes)
        guard bytes.count >= 28, let sectionCount = r.u32(at: 24), sectionCount > 0,
              sectionCount < 64, target < Int(sectionCount) else { return bytes }

        struct RawSection {
            var formatID: [UInt8]
            var order: [UInt32]
            var raw: [UInt32: [UInt8]]
        }
        var sections: [RawSection] = []
        for s in 0..<Int(sectionCount) {
            let entry = 28 + s * 20
            guard entry + 20 <= bytes.count, let offset = r.u32(at: entry + 16).map(Int.init),
                  let size = r.u32(at: offset).map(Int.init),
                  let count = r.u32(at: offset + 4).map(Int.init), count < 4096 else { return bytes }
            var entries: [(UInt32, Int)] = []
            for i in 0..<count {
                guard let pid = r.u32(at: offset + 8 + i * 8),
                      let poff = r.u32(at: offset + 12 + i * 8) else { return bytes }
                entries.append((pid, Int(poff)))
            }
            let bounds = entries.map(\.1).sorted() + [size]
            var raw: [UInt32: [UInt8]] = [:]
            for (pid, poff) in entries {
                let next = bounds.first { $0 > poff } ?? size
                let lo = offset + poff, hi = min(offset + next, bytes.count)
                guard lo <= hi else { return bytes }
                raw[pid] = Array(bytes[lo..<hi])
            }
            sections.append(RawSection(formatID: Array(bytes[entry..<entry + 16]),
                                       order: entries.map(\.0), raw: raw))
        }

        // The code page LPSTR values are encoded in.
        var codePage: UInt32 = 1252
        if let cp = sections[target].raw[1], cp.count >= 8, let v = BinaryReader(cp).u16(at: 4) {
            codePage = UInt32(v)
        }
        for (pid, value) in updates {
            var encoded = encodeString(value, codePage: codePage)
            encoded.append(0)
            var w = BinaryWriter()
            w.u32(VT.lpstr)
            w.u32(UInt32(encoded.count))
            w.append(encoded)
            w.pad(toMultipleOf: 4)
            sections[target].raw[pid] = w.bytes
            if !sections[target].order.contains(pid) { sections[target].order.append(pid) }
        }

        var built: [(formatID: [UInt8], body: [UInt8])] = []
        for section in sections {
            let base = 8 + section.order.count * 8
            var body = BinaryWriter()
            var table = BinaryWriter()
            for pid in section.order {
                table.u32(pid)
                table.u32(UInt32(base + body.count))
                body.append(section.raw[pid] ?? [])
                body.pad(toMultipleOf: 4)
            }
            var out = BinaryWriter()
            out.u32(UInt32(base + body.count))
            out.u32(UInt32(section.order.count))
            out.append(table.bytes)
            out.append(body.bytes)
            built.append((section.formatID, out.bytes))
        }
        var out = BinaryWriter()
        out.append(Array(bytes.prefix(28)))
        var position = 28 + built.count * 20
        for section in built {
            out.append(section.formatID)
            out.u32(UInt32(position))
            position += section.body.count
        }
        for section in built { out.append(section.body) }
        return out.bytes
    }

    private static func encodeString(_ s: String, codePage: UInt32) -> [UInt8] {
        switch codePage {
        case 65001: return Array(s.utf8)
        default:
            let encoding = stringEncoding(codePage: codePage) ?? .windowsCP1252
            return s.data(using: encoding, allowLossyConversion: true).map { [UInt8]($0) }
                ?? Array(s.utf8)
        }
    }

    /// The Foundation encoding for a Windows code page number, as property 1
    /// of a section declares it (1252, 1250, 932, ...).
    public static func stringEncoding(codePage: UInt32) -> String.Encoding? {
        #if canImport(Darwin)
        let cf = CFStringConvertWindowsCodepageToEncoding(codePage)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        #else
        // swift-corelibs-foundation has no CFString code-page table.
        switch codePage {
        case 1250: return .windowsCP1250
        case 1251: return .windowsCP1251
        case 1252: return .windowsCP1252
        case 1253: return .windowsCP1253
        case 1254: return .windowsCP1254
        case 932: return .shiftJIS
        case 65001: return .utf8
        default: return nil
        }
        #endif
    }

    /// FILETIME is 100-nanosecond ticks since 1601-01-01; `Date` counts seconds
    /// from 1970-01-01.
    private static func filetimeToInterval(_ ticks: UInt64) -> Double {
        let secondsBetweenEpochs: Double = 11_644_473_600
        return Double(ticks) / 10_000_000 - secondsBetweenEpochs
    }

    /// Decode a single-byte-coded string using the section's declared code page,
    /// falling back to Latin-1 so no byte is ever lost.
    private static func decodeString(_ raw: [UInt8], codePage: UInt32) -> String {
        switch codePage {
        case 1200: return decodeUTF16LE(raw)
        case 65001: return String(decoding: raw, as: UTF8.self)
        default:
            if let encoding = stringEncoding(codePage: codePage),
               let s = String(bytes: raw, encoding: encoding) { return s }
            // Latin-1 cannot fail, and preserves every byte value.
            return String(raw.map { Character(Unicode.Scalar($0)) })
        }
    }
}
