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

public enum CFBError: Error, CustomStringConvertible {
    case notCompoundFile
    case unsupportedByteOrder(UInt16)
    case unsupportedSectorShift(UInt16)
    case truncated(String)
    case malformed(String)
    case missingEntry(String)
    case nameTooLong(String)

    public var description: String {
        switch self {
        case .notCompoundFile:
            return "not a compound file (bad signature)"
        case .unsupportedByteOrder(let v):
            let hex = String(v, radix: 16, uppercase: true)
            return "unsupported byte-order mark 0x" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
        case .unsupportedSectorShift(let v):
            return "unsupported sector shift \(v)"
        case .truncated(let what):
            return "truncated: \(what)"
        case .malformed(let what):
            return "malformed container: \(what)"
        case .missingEntry(let path):
            return "no such stream or storage: \(path)"
        case .nameTooLong(let name):
            return "directory entry name too long (max 31 UTF-16 units): \(name)"
        }
    }
}

/// Sentinel sector values from [MS-CFB] 2.2.
public enum CFBSentinel {
    public static let free: UInt32      = 0xFFFF_FFFF
    public static let endOfChain: UInt32 = 0xFFFF_FFFE
    public static let fat: UInt32       = 0xFFFF_FFFD
    public static let difat: UInt32     = 0xFFFF_FFFC
    public static let noStream: UInt32  = 0xFFFF_FFFF
}

/// Directory entry object types ([MS-CFB] 2.6.1).
public enum CFBObjectType: UInt8 {
    case unknown = 0
    case storage = 1
    case stream = 2
    case root = 5
}

/// One node in the mini-filesystem: either a stream or a nested storage.
public enum CFBNode {
    case storage(CFBStorage)
    case stream([UInt8])

    public var isStorage: Bool { if case .storage = self { return true }; return false }

    public var streamBytes: [UInt8]? {
        if case .stream(let b) = self { return b }
        return nil
    }

    public var childStorage: CFBStorage? {
        if case .storage(let s) = self { return s }
        return nil
    }

    /// Size reported to callers: stream length, or 0 for a storage.
    public var size: Int { streamBytes?.count ?? 0 }
}

/// A storage (directory) inside a compound file.
///
/// Children are held in a dictionary keyed by the exact name Project wrote.
/// Names are case-sensitive here even though the container's sibling ordering
/// is case-insensitive: MPP14 storages are named with leading spaces
/// (`"   114"`) and mixing the two would corrupt a round trip.
public final class CFBStorage {
    public let name: String
    public private(set) var children: [String: CFBNode] = [:]
    /// Insertion order, preserved so a rewritten file keeps Project's own
    /// stream ordering rather than a hash-ordered one.
    public private(set) var order: [String] = []

    public init(name: String = "Root Entry") {
        self.name = name
    }

    // MARK: - Construction

    @discardableResult
    public func addStream(_ name: String, _ data: [UInt8]) -> CFBStorage {
        if children[name] == nil { order.append(name) }
        children[name] = .stream(data)
        return self
    }

    @discardableResult
    public func addStorage(_ name: String) -> CFBStorage {
        if let existing = children[name]?.childStorage { return existing }
        let s = CFBStorage(name: name)
        if children[name] == nil { order.append(name) }
        children[name] = .storage(s)
        return s
    }

    public func removeChild(_ name: String) {
        guard children.removeValue(forKey: name) != nil else { return }
        order.removeAll { $0 == name }
    }

    /// Create every intermediate storage and set the trailing component as a stream.
    public func setStream(path: String, _ data: [UInt8]) {
        let parts = path.split(separator: "/").map(String.init)
        guard let last = parts.last else { return }
        var node = self
        for part in parts.dropLast() { node = node.addStorage(part) }
        node.addStream(last, data)
    }

    /// Navigate to (and create) a storage by slash-separated path.
    public func storage(path: String) -> CFBStorage {
        var node = self
        for part in path.split(separator: "/").map(String.init) { node = node.addStorage(part) }
        return node
    }

    /// Navigate to a storage that must already exist.
    public func existingStorage(path: String) throws -> CFBStorage {
        var node = self
        for part in path.split(separator: "/").map(String.init) {
            guard let next = node.children[part]?.childStorage else {
                throw CFBError.missingEntry(path)
            }
            node = next
        }
        return node
    }

    // MARK: - Lookup

    public func node(_ name: String) -> CFBNode? { children[name] }

    public func child(_ name: String) -> CFBStorage? { children[name]?.childStorage }

    public func stream(_ name: String) throws -> [UInt8] {
        guard let s = children[name]?.streamBytes else { throw CFBError.missingEntry(name) }
        return s
    }

    public func stream(path: String) throws -> [UInt8] {
        let parts = path.split(separator: "/").map(String.init)
        guard let last = parts.last else { throw CFBError.missingEntry(path) }
        var node = self
        for part in parts.dropLast() {
            guard let next = node.children[part]?.childStorage else {
                throw CFBError.missingEntry(path)
            }
            node = next
        }
        return try node.stream(last)
    }

    public func streamIfPresent(path: String) -> [UInt8]? { try? stream(path: path) }

    // MARK: - Traversal

    /// Depth-first walk in stored order, yielding (path, node) for every entry.
    public func walk(_ prefix: String = "") -> [(path: String, node: CFBNode)] {
        var out: [(String, CFBNode)] = []
        for name in order {
            guard let node = children[name] else { continue }
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            out.append((path, node))
            if let storage = node.childStorage {
                out.append(contentsOf: storage.walk(path))
            }
        }
        return out
    }
}
