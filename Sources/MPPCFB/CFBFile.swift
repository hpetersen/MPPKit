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

/// Reader for the Microsoft Compound File Binary format ([MS-CFB]).
///
/// Written from the published specification rather than ported, because the
/// upstream implementation this package's format layer derives from delegates
/// container reading to a third-party Python module.
///
/// Only the versions the `.mpp` format actually uses are accepted: 512-byte
/// sectors (v3) and 4096-byte sectors (v4), 64-byte mini sectors, and the
/// standard 4096-byte mini-stream cutoff.
public final class CFBFile {
    public let root: CFBStorage

    /// The root directory entry's CLSID.
    ///
    /// This matters for `.mpp`: Project does **not** identify its files by
    /// extension or by the `Props14` stream alone — it requires the root CLSID
    /// `74B78F3A-C8C8-11D1-BE11-00C04FB6FAF1`. A container rewritten with a
    /// zeroed CLSID will not be recognised, so it must be carried through.
    public let rootCLSID: [UInt8]

    public let majorVersion: UInt16
    public let sectorSize: Int
    public let miniSectorSize: Int
    public let miniStreamCutoff: Int

    /// The CLSID Project stamps on the root entry of an `.mpp` file.
    public static let projectRootCLSID: [UInt8] = [
        0x74, 0xB7, 0x8F, 0x3A, 0xC8, 0xC8, 0x11, 0xD1,
        0xBE, 0x11, 0x00, 0xC0, 0x4F, 0xB6, 0xFA, 0xF1,
    ]

    /// Sector allocation table, indexed by sector id.
    private let fat: [UInt32]
    private let miniFAT: [UInt32]
    private let fileBytes: [UInt8]
    private let miniStream: [UInt8]

    // MARK: - Loading

    public convenience init(contentsOf url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    public convenience init(path: String) throws {
        try self.init(contentsOf: URL(fileURLWithPath: path))
    }

    public convenience init(data: Data) throws {
        try self.init(bytes: [UInt8](data))
    }

    public init(bytes: [UInt8]) throws {
        let r = BinaryReader(bytes)

        // ---- file header ([MS-CFB] 2.2) ----------------------------------
        guard bytes.count >= 512 else { throw CFBError.truncated("file header") }
        let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]
        guard Array(bytes[0..<8]) == signature else { throw CFBError.notCompoundFile }

        guard let byteOrder = r.u16(at: 28) else { throw CFBError.truncated("header") }
        guard byteOrder == 0xFFFE else { throw CFBError.unsupportedByteOrder(byteOrder) }

        guard let sectorShift = r.u16(at: 30) else { throw CFBError.truncated("header") }
        guard sectorShift == 9 || sectorShift == 12 else {
            throw CFBError.unsupportedSectorShift(sectorShift)
        }
        let sectorSize = 1 << Int(sectorShift)

        guard let miniShift = r.u16(at: 32) else { throw CFBError.truncated("header") }
        let miniSectorSize = 1 << Int(miniShift)

        let majorVersion = r.u16(at: 26) ?? 3

        guard let numFATSectors = r.u32(at: 44),
              let firstDirSector = r.u32(at: 48),
              let cutoff = r.u32(at: 56),
              let firstMiniFATSector = r.u32(at: 60),
              let numMiniFATSectors = r.u32(at: 64),
              let firstDIFATSector = r.u32(at: 68),
              let numDIFATSectors = r.u32(at: 72)
        else { throw CFBError.truncated("file header") }

        self.fileBytes = bytes
        self.majorVersion = majorVersion
        self.sectorSize = sectorSize
        self.miniSectorSize = miniSectorSize
        self.miniStreamCutoff = Int(cutoff)

        let sectorCount = max(0, (bytes.count - sectorSize) / sectorSize)
        func sectorSlice(_ id: UInt32) -> ArraySlice<UInt8>? {
            let sid = Int(id)
            guard sid >= 0, sid < sectorCount else { return nil }
            let start = (sid + 1) * sectorSize
            guard start + sectorSize <= bytes.count else { return nil }
            return bytes[start..<start + sectorSize]
        }

        // ---- DIFAT: header's 109 entries, then the DIFAT sector chain -----
        var fatSectorIDs: [UInt32] = []
        for i in 0..<109 {
            guard let v = r.u32(at: 76 + i * 4) else { break }
            if v == CFBSentinel.free { break }
            fatSectorIDs.append(v)
        }
        // Follow the DIFAT chain only if the header's inline list is full;
        // otherwise there are no DIFAT sectors to read.
        if fatSectorIDs.count == 109, numDIFATSectors > 0, firstDIFATSector != CFBSentinel.endOfChain {
            let difatEntriesPerSector = sectorSize / 4 - 1
            var current = firstDIFATSector
            var guardCount = 0
            while current != CFBSentinel.endOfChain, guardCount <= Int(numDIFATSectors) + 1 {
                guard let slice = sectorSlice(current) else { break }
                let s = BinaryReader(Array(slice))
                for i in 0..<difatEntriesPerSector {
                    guard let v = s.u32(at: i * 4) else { break }
                    if v == CFBSentinel.free { continue }
                    fatSectorIDs.append(v)
                }
                current = s.u32(at: difatEntriesPerSector * 4) ?? CFBSentinel.endOfChain
                guardCount += 1
            }
        }

        // ---- FAT ---------------------------------------------------------
        var fat: [UInt32] = []
        fat.reserveCapacity(fatSectorIDs.count * (sectorSize / 4))
        for sectorID in fatSectorIDs {
            guard let slice = sectorSlice(sectorID) else { continue }
            let s = BinaryReader(Array(slice))
            for i in 0..<(sectorSize / 4) {
                guard let v = s.u32(at: i * 4) else { break }
                fat.append(v)
            }
        }
        // A file that declares FAT sectors we could not read has to fail loudly:
        // silently short FATs turn into wrong stream contents.
        if fat.count < Int(numFATSectors) * (sectorSize / 4) && !fatSectorIDs.isEmpty {
            throw CFBError.truncated("FAT sectors")
        }
        self.fat = fat

        func readChain(start: UInt32, table: [UInt32], unit: Int,
                       sectorAt: (UInt32) -> ArraySlice<UInt8>?) throws -> [UInt8] {
            guard start != CFBSentinel.endOfChain, start != CFBSentinel.free else { return [] }
            var out: [UInt8] = []
            var seen = Set<UInt32>()
            var current = start
            while current != CFBSentinel.endOfChain {
                guard current != CFBSentinel.free,
                      current != CFBSentinel.fat,
                      current != CFBSentinel.difat else {
                    throw CFBError.malformed("chain hit a reserved sector id")
                }
                guard Int(current) < table.count else {
                    throw CFBError.malformed("chain sector \(current) beyond the allocation table")
                }
                guard seen.insert(current).inserted else {
                    throw CFBError.malformed("cycle in sector chain at \(current)")
                }
                guard let slice = sectorAt(current) else {
                    throw CFBError.truncated("sector \(current)")
                }
                out.append(contentsOf: slice)
                _ = unit
                current = table[Int(current)]
            }
            return out
        }

        // ---- mini FAT ----------------------------------------------------
        var miniFAT: [UInt32] = []
        if numMiniFATSectors > 0, firstMiniFATSector != CFBSentinel.endOfChain {
            let raw = try readChain(start: firstMiniFATSector, table: fat,
                                    unit: sectorSize, sectorAt: sectorSlice)
            let s = BinaryReader(raw)
            for i in 0..<(raw.count / 4) {
                guard let v = s.u32(at: i * 4) else { break }
                miniFAT.append(v)
            }
        }
        self.miniFAT = miniFAT

        // ---- directory ---------------------------------------------------
        guard let dirRaw = try? readChain(start: firstDirSector, table: fat,
                                          unit: sectorSize, sectorAt: sectorSlice)
        else {
            throw CFBError.truncated("directory sectors")
        }

        var entries: [DirectoryEntry] = []
        var pos = 0
        while pos + 128 <= dirRaw.count {
            entries.append(DirectoryEntry(bytes: Array(dirRaw[pos..<pos + 128])))
            pos += 128
        }
        guard !entries.isEmpty else { throw CFBError.malformed("empty directory") }
        guard entries[0].objectType == .root else {
            throw CFBError.malformed("first directory entry is not the root")
        }

        // ---- mini stream -------------------------------------------------
        let rootEntry = entries[0]
        let miniStream: [UInt8]
        if rootEntry.startSector != CFBSentinel.endOfChain, rootEntry.streamSize > 0 {
            let raw = (try? readChain(start: rootEntry.startSector, table: fat,
                                      unit: sectorSize, sectorAt: sectorSlice)) ?? []
            miniStream = Array(raw.prefix(Int(rootEntry.streamSize)))
        } else {
            miniStream = []
        }
        self.miniStream = miniStream

        func miniSectorSlice(_ id: UInt32) -> ArraySlice<UInt8>? {
            let sid = Int(id)
            let start = sid * miniSectorSize
            guard sid >= 0, start + miniSectorSize <= miniStream.count else { return nil }
            return miniStream[start..<start + miniSectorSize]
        }

        // ---- build the storage tree --------------------------------------
        let rootStorage = CFBStorage(name: "Root Entry")

        // The directory is a per-storage ordered tree linked by left/right
        // siblings with `child` pointing at each storage's subtree root.
        var visited = Set<UInt32>()
        func collectSiblings(_ index: UInt32, into out: inout [UInt32], depth: Int) {
            guard index != CFBSentinel.noStream,
                  Int(index) < entries.count,
                  depth < 512,
                  visited.insert(index).inserted else { return }
            let e = entries[Int(index)]
            collectSiblings(e.leftSibling, into: &out, depth: depth + 1)
            out.append(index)
            collectSiblings(e.rightSibling, into: &out, depth: depth + 1)
        }

        func populate(_ storage: CFBStorage, childIndex: UInt32) {
            var indices: [UInt32] = []
            collectSiblings(childIndex, into: &indices, depth: 0)
            for index in indices {
                let e = entries[Int(index)]
                switch e.objectType {
                case .storage:
                    let sub = storage.addStorage(e.name)
                    populate(sub, childIndex: e.child)
                case .stream:
                    // Called as a static helper with explicit locals so this
                    // nested walk does not capture `self` before `root` — the
                    // last stored property — has been initialised.
                    let data = (try? CFBFile.readStreamData(e, fileBytes: bytes,
                                                            sectorSize: sectorSize,
                                                            fat: fat, miniFAT: miniFAT,
                                                            miniStream: miniStream,
                                                            miniStreamCutoff: Int(cutoff))) ?? []
                    storage.addStream(e.name, data)
                default:
                    continue
                }
            }
        }

        populate(rootStorage, childIndex: rootEntry.child)
        self.root = rootStorage
        self.rootCLSID = rootEntry.clsid
    }

    /// Read one stream's bytes: mini-FAT chain for small streams, FAT chain
    /// otherwise, exactly as [MS-CFB] 2.4 prescribes.
    ///
    /// Static with explicit parameters rather than an instance method, so the
    /// tree walk in `init` can call it before `root` is assigned.
    private static func readStreamData(_ e: DirectoryEntry,
                                       fileBytes: [UInt8],
                                       sectorSize: Int,
                                       fat: [UInt32],
                                       miniFAT: [UInt32],
                                       miniStream: [UInt8],
                                       miniStreamCutoff: Int) throws -> [UInt8] {
        let size = Int(e.streamSize)
        if size == 0 { return [] }

        let miniSectorSize = 64

        func sectorSlice(_ id: UInt32) -> ArraySlice<UInt8>? {
            let sid = Int(id)
            let start = (sid + 1) * sectorSize
            guard sid >= 0, start + sectorSize <= fileBytes.count else { return nil }
            return fileBytes[start..<start + sectorSize]
        }

        if size < miniStreamCutoff {
            guard e.startSector != CFBSentinel.endOfChain else { return [] }
            var out: [UInt8] = []
            var seen = Set<UInt32>()
            var current = e.startSector
            while current != CFBSentinel.endOfChain {
                guard Int(current) < miniFAT.count else {
                    throw CFBError.malformed("mini chain beyond the mini FAT")
                }
                guard seen.insert(current).inserted else {
                    throw CFBError.malformed("cycle in mini sector chain")
                }
                let start = Int(current) * miniSectorSize
                guard start + miniSectorSize <= miniStream.count else {
                    throw CFBError.truncated("mini sector \(current)")
                }
                out.append(contentsOf: miniStream[start..<start + miniSectorSize])
                current = miniFAT[Int(current)]
            }
            return Array(out.prefix(size))
        }

        guard e.startSector != CFBSentinel.endOfChain else { return [] }
        var out: [UInt8] = []
        var seen = Set<UInt32>()
        var current = e.startSector
        while current != CFBSentinel.endOfChain {
            guard Int(current) < fat.count else {
                throw CFBError.malformed("chain sector beyond the FAT")
            }
            guard seen.insert(current).inserted else {
                throw CFBError.malformed("cycle in sector chain")
            }
            guard let slice = sectorSlice(current) else {
                throw CFBError.truncated("sector \(current)")
            }
            out.append(contentsOf: slice)
            current = fat[Int(current)]
        }
        return Array(out.prefix(size))
    }

    // MARK: - Convenience

    /// Every stream in the file as `path -> bytes`, in stored order.
    public func allStreams() -> [(path: String, bytes: [UInt8])] {
        root.walk().compactMap { entry in
            guard let b = entry.node.streamBytes else { return nil }
            return (entry.path, b)
        }
    }
}

/// One 128-byte directory entry ([MS-CFB] 2.6.1).
struct DirectoryEntry {
    let name: String
    let nameLength: UInt16
    let objectType: CFBObjectType
    let color: UInt8
    let leftSibling: UInt32
    let rightSibling: UInt32
    let child: UInt32
    let clsid: [UInt8]
    let stateBits: UInt32
    let creationTime: UInt64
    let modifiedTime: UInt64
    let startSector: UInt32
    let streamSize: UInt64
    let raw: [UInt8]

    init(bytes: [UInt8]) {
        let r = BinaryReader(bytes)
        self.raw = bytes
        self.nameLength = r.u16(at: 64) ?? 0
        self.objectType = CFBObjectType(rawValue: r.u8(at: 66) ?? 0) ?? .unknown
        self.color = r.u8(at: 67) ?? 0
        self.leftSibling = r.u32(at: 68) ?? CFBSentinel.noStream
        self.rightSibling = r.u32(at: 72) ?? CFBSentinel.noStream
        self.child = r.u32(at: 76) ?? CFBSentinel.noStream
        self.clsid = Array(bytes[80..<96])
        self.stateBits = r.u32(at: 96) ?? 0
        self.creationTime = r.u64(at: 100) ?? 0
        self.modifiedTime = r.u64(at: 108) ?? 0
        self.startSector = r.u32(at: 116) ?? CFBSentinel.endOfChain
        self.streamSize = r.u64(at: 120) ?? 0

        // The name is UTF-16LE including a terminating NUL; nameLength counts
        // bytes and is authoritative when present.
        var nameBytes = Array(bytes[0..<64])
        if self.nameLength >= 2, Int(self.nameLength) <= 64 {
            nameBytes = Array(nameBytes[0..<Int(self.nameLength) - 2])
        } else {
            // No usable length: cut at the first NUL unit.
            var end = 0
            while end + 1 < 64 {
                if nameBytes[end] == 0 && nameBytes[end + 1] == 0 { break }
                end += 2
            }
            nameBytes = Array(nameBytes[0..<end])
        }
        self.name = decodeUTF16LE(nameBytes)
    }
}
