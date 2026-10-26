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

/// Writer for the Microsoft Compound File Binary format ([MS-CFB]).
///
/// Ported from the MIT-licensed `pymppwriter` container writer (see
/// THIRD_PARTY_NOTICES.md), which is the implementation verified to produce
/// files Microsoft Project opens. It emits version 3 (512-byte sectors,
/// 64-byte mini sectors, 4096-byte mini-stream cutoff) with a balanced
/// directory tree — [MS-CFB] requires the sibling tree be balanced, not that it
/// be specifically red-black, and a black-coloured balanced tree is accepted by
/// Project and by Apache POI.
public enum CFBWriter {
    private static let sectorSize = 512
    private static let miniSectorSize = 64
    private static let miniCutoff = 4096
    private static let fatPerSector = sectorSize / 4
    private static let difatPerSector = fatPerSector - 1

    private final class Entry {
        let name: String
        let type: CFBObjectType
        let data: [UInt8]?
        var child: UInt32 = CFBSentinel.noStream
        var left: UInt32 = CFBSentinel.noStream
        var right: UInt32 = CFBSentinel.noStream
        var start: UInt32 = CFBSentinel.endOfChain
        var size: UInt64 = 0
        var clsid = [UInt8](repeating: 0, count: 16)

        init(name: String, type: CFBObjectType, data: [UInt8]? = nil) {
            self.name = name
            self.type = type
            self.data = data
        }
    }

    /// [MS-CFB] 2.6.4 ordering: compare by UTF-16 length first, then by the
    /// upper-cased code units.
    private static func nameKey(_ name: String) -> (Int, [UInt8]) {
        let lower = utf16LEBytes(name)
        let upper = utf16LEBytes(name.uppercased())
        return (lower.count, upper)
    }

    private static func utf16LEBytes(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(s.utf16.count * 2)
        for unit in s.utf16 {
            out.append(UInt8(unit & 0xFF))
            out.append(UInt8((unit >> 8) & 0xFF))
        }
        return out
    }

    /// Balanced binary tree over sorted entries; returns the root's index.
    private static func buildTree(_ entries: [Entry], indexOf: (Entry) -> UInt32) -> UInt32 {
        if entries.isEmpty { return CFBSentinel.noStream }
        let mid = entries.count / 2
        let node = entries[mid]
        node.left = buildTree(Array(entries[0..<mid]), indexOf: indexOf)
        node.right = buildTree(Array(entries[(mid + 1)...]), indexOf: indexOf)
        return indexOf(node)
    }

    public static func write(root: CFBStorage, rootCLSID: [UInt8]? = nil) throws -> [UInt8] {
        var entries: [Entry] = []
        let rootEntry = Entry(name: "Root Entry", type: .root)
        entries.append(rootEntry)
        // Project recognises its files by the *root directory entry's* CLSID
        // ([MS-CFB] 2.6.1); the header's own CLSID field must stay zero.
        if let clsid = rootCLSID, clsid.count == 16 { rootEntry.clsid = clsid }

        func indexOf(_ e: Entry) -> UInt32 {
            UInt32(entries.firstIndex { $0 === e } ?? 0)
        }

        func flatten(_ storage: CFBStorage, parent: Entry) throws {
            var kids: [Entry] = []
            for name in storage.order {
                guard let node = storage.children[name] else { continue }
                switch node {
                case .storage:
                    let e = Entry(name: name, type: .storage)
                    entries.append(e)
                    kids.append(e)
                case .stream(let data):
                    let e = Entry(name: name, type: .stream, data: data)
                    entries.append(e)
                    kids.append(e)
                }
            }
            // [MS-CFB] 2.6.4: order by UTF-16 length first, then by the
            // upper-cased code units. Swift tuples are not Comparable, so the
            // two-way comparison is written out.
            kids.sort { a, b in
                let ka = nameKey(a.name), kb = nameKey(b.name)
                return ka.0 != kb.0 ? ka.0 < kb.0 : ka.1.lexicographicallyPrecedes(kb.1)
            }
            parent.child = buildTree(kids, indexOf: indexOf)
            for e in kids where e.type == .storage {
                guard let sub = storage.children[e.name]?.childStorage else { continue }
                try flatten(sub, parent: e)
            }
        }

        // [MS-CFB] caps a directory entry name at 31 UTF-16 units plus the
        // terminator. Silently blanking an over-long entry would produce a file
        // whose streams Project cannot find by name, so fail up front instead.
        for (path, _) in root.walk() {
            let leaf = path.split(separator: "/").last.map(String.init) ?? path
            if utf16LEBytes(leaf).count + 2 > 64 { throw CFBError.nameTooLong(leaf) }
        }

        try flatten(root, parent: rootEntry)

        // ---- mini stream ---------------------------------------------------
        var miniStream: [UInt8] = []
        var miniFAT: [UInt32] = []
        for e in entries where e.type == .stream {
            guard let data = e.data, data.count > 0, data.count < miniCutoff else { continue }
            e.size = UInt64(data.count)
            e.start = UInt32(miniFAT.count)
            let padded = paddedToMultiple(data, of: miniSectorSize)
            let n = padded.count / miniSectorSize
            miniStream.append(contentsOf: padded)
            if n > 1 {
                for next in (miniFAT.count + 1)..<(miniFAT.count + n) {
                    miniFAT.append(UInt32(next))
                }
            }
            miniFAT.append(CFBSentinel.endOfChain)
        }
        rootEntry.size = UInt64(miniStream.count)

        // ---- regular sectors -----------------------------------------------
        var sectors: [[UInt8]] = []
        var fat: [UInt32] = []

        func addChain(_ data: [UInt8]) -> UInt32 {
            let padded = paddedToMultiple(data, of: sectorSize)
            let n = padded.count / sectorSize
            if n == 0 { return CFBSentinel.endOfChain }
            let first = UInt32(sectors.count)
            for i in 0..<n {
                let start = i * sectorSize
                sectors.append(Array(padded[start..<start + sectorSize]))
                fat.append(i < n - 1 ? first + UInt32(i) + 1 : CFBSentinel.endOfChain)
            }
            return first
        }

        for e in entries where e.type == .stream {
            guard let data = e.data, data.count >= miniCutoff else { continue }
            e.size = UInt64(data.count)
            e.start = addChain(data)
        }

        rootEntry.start = miniStream.isEmpty
            ? CFBSentinel.endOfChain
            : addChain(miniStream)

        // ---- mini FAT ------------------------------------------------------
        var miniFATStart = CFBSentinel.endOfChain
        var miniFATCount: UInt32 = 0
        if !miniFAT.isEmpty {
            var raw = BinaryWriter()
            for v in miniFAT { raw.u32(v) }
            var bytes = raw.bytes
            bytes = paddedToMultiple(bytes, of: sectorSize)
            // Unused mini FAT slots are FREESECT, not zero.
            if bytes.count > miniFAT.count * 4 {
                for i in (miniFAT.count * 4)..<bytes.count { bytes[i] = 0xFF }
            }
            miniFATStart = addChain(bytes)
            miniFATCount = UInt32(bytes.count / sectorSize)
        }

        // ---- directory -----------------------------------------------------
        var dirRaw = BinaryWriter()
        for e in entries { dirRaw.append(directoryEntryBytes(e)) }
        var dirBytes = dirRaw.bytes
        dirBytes = paddedToMultiple(dirBytes, of: sectorSize)
        let slots = dirBytes.count / 128
        if slots > entries.count {
            for i in entries.count..<slots {
                let empty = directoryEntryBytes(nil)
                for j in 0..<128 { dirBytes[i * 128 + j] = empty[j] }
            }
        }
        let dirStart = addChain(dirBytes)

        // ---- FAT and DIFAT sectors -----------------------------------------
        let nData = sectors.count
        var nFAT = 0
        var nDIFAT = 0
        while true {
            let neededFAT = (nData + nFAT + nDIFAT + fatPerSector - 1) / fatPerSector
            let neededDIFAT = (max(0, neededFAT - 109) + difatPerSector - 1) / difatPerSector
            if neededFAT == nFAT && neededDIFAT == nDIFAT { break }
            nFAT = neededFAT
            nDIFAT = neededDIFAT
        }

        var fatFull = fat
        fatFull.append(contentsOf: [UInt32](repeating: CFBSentinel.fat, count: nFAT))
        fatFull.append(contentsOf: [UInt32](repeating: CFBSentinel.difat, count: nDIFAT))
        if nFAT * fatPerSector > fatFull.count {
            fatFull.append(contentsOf: [UInt32](repeating: CFBSentinel.free,
                                                count: nFAT * fatPerSector - fatFull.count))
        }
        var fatRaw = BinaryWriter()
        for v in fatFull { fatRaw.u32(v) }
        let fatBytes = fatRaw.bytes

        let fatSectorIDs = (nData..<(nData + nFAT)).map(UInt32.init)
        let difatSectorIDs = ((nData + nFAT)..<(nData + nFAT + nDIFAT)).map(UInt32.init)

        for i in 0..<nFAT {
            let start = i * sectorSize
            sectors.append(Array(fatBytes[start..<start + sectorSize]))
        }
        for i in 0..<nDIFAT {
            var w = BinaryWriter()
            let lo = 109 + i * difatPerSector
            let hi = min(lo + difatPerSector, fatSectorIDs.count)
            var chunk: [UInt32] = lo < hi ? Array(fatSectorIDs[lo..<hi]) : []
            chunk.append(contentsOf: [UInt32](repeating: CFBSentinel.free,
                                              count: max(0, difatPerSector - chunk.count)))
            for v in chunk { w.u32(v) }
            w.u32(i + 1 < nDIFAT ? difatSectorIDs[i + 1] : CFBSentinel.endOfChain)
            sectors.append(w.bytes)
        }

        // ---- header ---------------------------------------------------------
        var h = BinaryWriter()
        h.append([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])   // signature
        h.append([UInt8](repeating: 0, count: 16))                   // header CLSID: must be zero
        h.u16(0x003E)                                                // minor version
        h.u16(0x0003)                                                // major version: v3
        h.u16(0xFFFE)                                                // byte order
        h.u16(9)                                                     // sector shift
        h.u16(6)                                                     // mini sector shift
        h.append([UInt8](repeating: 0, count: 6))                    // reserved
        h.u32(0)                                                     // num directory sectors (v3)
        h.u32(UInt32(nFAT))
        h.u32(dirStart)
        h.u32(0)                                                     // transaction signature
        h.u32(UInt32(miniCutoff))
        h.u32(miniFATStart)
        h.u32(miniFATCount)
        h.u32(nDIFAT > 0 ? difatSectorIDs[0] : CFBSentinel.endOfChain)
        h.u32(UInt32(nDIFAT))
        for i in 0..<109 {
            h.u32(i < fatSectorIDs.count ? fatSectorIDs[i] : CFBSentinel.free)
        }

        var out = h.bytes
        for sector in sectors { out.append(contentsOf: sector) }
        return out
    }

    public static func writeData(root: CFBStorage, rootCLSID: [UInt8]? = nil) throws -> Data {
        Data(try write(root: root, rootCLSID: rootCLSID as [UInt8]?))
    }

    private static func directoryEntryBytes(_ e: Entry?) -> [UInt8] {
        var w = BinaryWriter()
        guard let e else {
            // A blank entry: 64 zero name bytes, type 0, all sentinels.
            w.append([UInt8](repeating: 0, count: 64))
            w.u16(0); w.u8(0); w.u8(0)
            w.u32(CFBSentinel.noStream); w.u32(CFBSentinel.noStream); w.u32(CFBSentinel.noStream)
            w.append([UInt8](repeating: 0, count: 16))
            w.u32(0); w.u64(0); w.u64(0)
            w.u32(0); w.u64(0)
            return w.bytes
        }

        // `nameLength` counts the UTF-16 code units *including* the terminating
        // NUL. `write()` has already rejected names that cannot fit, so the
        // pad-to-64 below cannot silently swallow a name.
        let rawName = utf16LEBytes(e.name)
        var nameBytes = rawName
        nameBytes.append(contentsOf: [0, 0])          // terminating NUL
        nameBytes.append(contentsOf: [UInt8](repeating: 0, count: max(0, 64 - nameBytes.count)))

        w.append(nameBytes)
        w.u16(UInt16(rawName.count + 2))
        w.u8(e.type.rawValue)
        w.u8(1)                                        // colour: black
        w.u32(e.left); w.u32(e.right); w.u32(e.child)
        w.append(e.clsid)                              // CLSID (the root's identifies the file type)
        w.u32(0)                                       // state bits
        w.u64(0); w.u64(0)                             // creation / modified time
        if e.start != CFBSentinel.endOfChain {
            w.u32(e.start)
        } else if e.type == .stream {
            w.u32(CFBSentinel.endOfChain)
        } else {
            w.u32(0)
        }
        w.u64(e.size)
        return w.bytes
    }
}
