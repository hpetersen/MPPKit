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

/// A little-endian cursor over a byte buffer.
///
/// Every integer in the compound-file container and in the MPP14 block
/// structures is little-endian, and both formats routinely describe fields that
/// a given file's Project version did not write. Reads therefore return `nil`
/// rather than trapping when they run off the end of the buffer, which is what
/// lets one parser handle every Project vintage.
public struct BinaryReader {
    public let bytes: [UInt8]
    public private(set) var offset: Int

    public init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    public init(_ data: Data, offset: Int = 0) {
        self.init([UInt8](data), offset: offset)
    }

    public var count: Int { bytes.count }
    public var remaining: Int { bytes.count - offset }
    public func has(_ n: Int) -> Bool { offset + n <= bytes.count }

    public mutating func seek(to newOffset: Int) { offset = newOffset }
    public mutating func skip(_ n: Int) { offset += n }

    /// Unsigned 8-bit value at the cursor, advancing past it.
    public mutating func u8() -> UInt8? {
        guard has(1) else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    /// Unsigned 16-bit little-endian value, advancing past it.
    public mutating func u16() -> UInt16? {
        guard has(2) else { return nil }
        defer { offset += 2 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    /// Unsigned 32-bit little-endian value, advancing past it.
    public mutating func u32() -> UInt32? {
        guard let v = u32(at: offset) else { return nil }
        offset += 4
        return v
    }

    /// Unsigned 64-bit little-endian value, advancing past it.
    public mutating func u64() -> UInt64? {
        guard let v = u64(at: offset) else { return nil }
        offset += 8
        return v
    }

    /// Signed 32-bit little-endian value, advancing past it.
    public mutating func i32() -> Int32? {
        guard let raw = u32() else { return nil }
        return Int32(bitPattern: raw)
    }

    /// Fixed-width slice, advancing past it.
    public mutating func bytes(_ n: Int) -> [UInt8]? {
        guard n >= 0, has(n) else { return nil }
        defer { offset += n }
        return Array(bytes[offset..<offset + n])
    }

    // MARK: - Random access
    //
    // The block structures address fields by byte offset published in the
    // file's own field map, so positional reads are the common case.

    public func u8(at index: Int) -> UInt8? {
        guard index >= 0, index < bytes.count else { return nil }
        return bytes[index]
    }

    public func u16(at index: Int) -> UInt16? {
        guard index >= 0, index + 2 <= bytes.count else { return nil }
        return UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
    }

    public func u32(at index: Int) -> UInt32? {
        guard index >= 0, index + 4 <= bytes.count else { return nil }
        var v: UInt32 = 0
        for i in (0..<4).reversed() { v = (v << 8) | UInt32(bytes[index + i]) }
        return v
    }

    public func i32(at index: Int) -> Int32? {
        guard let raw = u32(at: index) else { return nil }
        return Int32(bitPattern: raw)
    }

    public func u64(at index: Int) -> UInt64? {
        guard index >= 0, index + 8 <= bytes.count else { return nil }
        var v: UInt64 = 0
        for i in (0..<8).reversed() { v = (v << 8) | UInt64(bytes[index + i]) }
        return v
    }

    public func f64(at index: Int) -> Double? {
        guard let raw = u64(at: index) else { return nil }
        return Double(bitPattern: raw)
    }
}

/// Little-endian append helpers used by the container writer.
public struct BinaryWriter {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public var count: Int { bytes.count }

    public mutating func u8(_ v: UInt8) { bytes.append(v) }

    public mutating func u16(_ v: UInt16) {
        bytes.append(UInt8(v & 0xFF))
        bytes.append(UInt8((v >> 8) & 0xFF))
    }

    public mutating func u32(_ v: UInt32) {
        for i in 0..<4 { bytes.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) }
    }

    public mutating func u64(_ v: UInt64) {
        for i in 0..<8 { bytes.append(UInt8((v >> (8 * UInt64(i))) & 0xFF)) }
    }

    public mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }

    public mutating func f64(_ v: Double) { u64(v.bitPattern) }

    public mutating func append(_ raw: [UInt8]) { bytes.append(contentsOf: raw) }

    public mutating func append(_ raw: ArraySlice<UInt8>) { bytes.append(contentsOf: raw) }

    /// Overwrite four bytes at an absolute position (used to patch length
    /// fields once the body length is known).
    public mutating func patchU32(at index: Int, _ v: UInt32) {
        guard index >= 0, index + 4 <= bytes.count else { return }
        for i in 0..<4 { bytes[index + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF) }
    }

    public mutating func patchU16(at index: Int, _ v: UInt16) {
        guard index >= 0, index + 2 <= bytes.count else { return }
        bytes[index] = UInt8(v & 0xFF)
        bytes[index + 1] = UInt8((v >> 8) & 0xFF)
    }

    public mutating func set(_ index: Int, _ v: UInt8) {
        guard index >= 0, index < bytes.count else { return }
        bytes[index] = v
    }

    /// Zero-pad the buffer up to a multiple of `unit`.
    public mutating func pad(toMultipleOf unit: Int) {
        let rem = bytes.count % unit
        if rem != 0 { bytes.append(contentsOf: [UInt8](repeating: 0, count: unit - rem)) }
    }
}

/// Decode little-endian UTF-16 bytes into a `String`.
///
/// `String(decoding:as:)` requires the collection's element type to match the
/// encoding's code unit, so UTF-16 needs `[UInt16]` rather than raw bytes — this
/// does that regrouping, and tolerates a trailing odd byte rather than trapping.
public func decodeUTF16LE(_ bytes: [UInt8]) -> String {
    var units: [UInt16] = []
    units.reserveCapacity(bytes.count / 2)
    var i = 0
    while i + 1 < bytes.count {
        units.append(UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8))
        i += 2
    }
    return String(decoding: units, as: UTF16.self)
}

@inline(__always)
func paddedToMultiple(_ raw: [UInt8], of unit: Int) -> [UInt8] {
    let rem = raw.count % unit
    guard rem != 0 else { return raw }
    return raw + [UInt8](repeating: 0, count: unit - rem)
}
