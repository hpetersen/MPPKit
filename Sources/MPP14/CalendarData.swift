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

/// The calendar definition blob: var-data entry 8 on a `TBkndCal` record.
///
/// Layout, in the dialect Microsoft 365 writes (format notes from the
/// MIT-licensed pymppwriter, confirmed against the Project-written fixture):
///
/// - seven 60-byte day blocks, **Sunday first**. Each is `u16 type` (1 = keep
///   Project's default for the weekday, 0 = explicit), `u16 rangeCount` (0 on an
///   explicit day means non-working), `u32` total working tenths of a minute,
///   up to five range starts as `u16` tenths at +8, the matching durations as
///   `u32` tenths at +20, and running totals of those durations at +40;
/// - then, if there are exceptions, a `u32` count and one record per exception:
///   92 bytes (`u16` first day, `u16` last day, `u16` day count, a 60-byte day
///   block at +12 — range count 0 for a non-working exception, otherwise the
///   exception's working hours — recurrence dwords at +72...+87, `u32` name
///   byte length at +88) followed by the UTF-16 name, zero-padded to four
///   bytes. The blob ends with four zero bytes.
///
/// Day numbers count from the MPP epoch, 1983-12-31.
public enum CalendarData {
    static let dayBlockSize = 60
    static let exceptionHeaderSize = 92
    static let maxRanges = 5

    public struct Decoded: Equatable, Sendable {
        public var week: [Int: [ClosedRange<Int>]?]
        public var exceptions: [CalendarException]
    }

    public static func parse(_ blob: [UInt8]) -> Decoded {
        let r = BinaryReader(blob)
        var week: [Int: [ClosedRange<Int>]?] = [:]
        /// The working ranges of a day block; empty for a non-working day.
        func ranges(at base: Int) -> [ClosedRange<Int>] {
            let count = min(Int(r.u16(at: base + 2) ?? 0), maxRanges)
            var out: [ClosedRange<Int>] = []
            for i in 0..<count {
                guard let start = r.u16(at: base + 8 + 2 * i),
                      let length = r.u32(at: base + 20 + 4 * i) else { break }
                let lo = Int(start) / 10
                out.append(lo...(lo + Int(length) / 10))
            }
            return out
        }
        for block in 0..<7 where (block + 1) * dayBlockSize <= blob.count {
            let base = block * dayBlockSize
            let weekday = block + 1                       // Foundation: 1 = Sunday
            let type = r.u16(at: base) ?? 1
            if type == 1 { continue }                     // Project's default
            let day = ranges(at: base)
            week[weekday] = day.isEmpty ? .some(nil) : day
        }

        var exceptions: [CalendarException] = []
        var pos = 7 * dayBlockSize
        if let count = r.u32(at: pos), count < 10_000 {
            pos += 4
            for _ in 0..<count {
                guard pos + exceptionHeaderSize <= blob.count,
                      let from = r.u16(at: pos), let to = r.u16(at: pos + 2),
                      let nameLength = r.u32(at: pos + 88) else { break }
                let nameStart = pos + exceptionHeaderSize
                let nameEnd = min(nameStart + Int(nameLength), blob.count)
                let name = nameStart < nameEnd
                    ? MPP.decodeUnicode(Array(blob[nameStart..<nameEnd])) : ""
                let first = MPPTime.date(days: Int(from), tenths: 0)
                let last = MPPTime.date(days: Int(to), tenths: 0)
                exceptions.append(CalendarException(start: first,
                                                    finish: to == from ? nil : last,
                                                    name: name,
                                                    working: ranges(at: pos + 12)))
                pos = nameStart + Int(nameLength)
                pos += (4 - pos % 4) % 4
            }
        }
        return Decoded(week: week, exceptions: exceptions)
    }

    /// Encode a week and its exceptions, holidays and changed working hours.
    public static func build(week: [Int: [ClosedRange<Int>]?],
                             exceptions: [CalendarException]) -> [UInt8] {
        var out = BinaryWriter()
        for weekday in 1...7 {
            var block = BinaryWriter()
            block.append([UInt8](repeating: 0, count: dayBlockSize))
            if let entry = week[weekday] {
                let ranges = Array((entry ?? []).prefix(maxRanges))
                block.patchU16(at: 0, 0)
                block.patchU16(at: 2, UInt16(ranges.count))
                let total = ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) * 10 }
                block.patchU32(at: 4, UInt32(total))
                var cumulative = 0
                for (i, range) in ranges.enumerated() {
                    let length = (range.upperBound - range.lowerBound) * 10
                    cumulative += length
                    block.patchU16(at: 8 + 2 * i, UInt16(range.lowerBound * 10))
                    block.patchU32(at: 20 + 4 * i, UInt32(length))
                    block.patchU32(at: 40 + 4 * i, UInt32(cumulative))
                }
            } else {
                block.patchU16(at: 0, 1)
            }
            out.append(block.bytes)
        }

        let sorted = exceptions.sorted { $0.start < $1.start }
        guard !sorted.isEmpty else { return out.bytes }
        out.u32(UInt32(sorted.count))
        for exception in sorted {
            let first = MPPTime.dayNumber(exception.start)
            let last = MPPTime.dayNumber(exception.lastDay)
            var record = BinaryWriter()
            record.append([UInt8](repeating: 0, count: exceptionHeaderSize))
            record.patchU16(at: 0, UInt16(first))
            record.patchU16(at: 2, UInt16(last))
            record.patchU16(at: 4, UInt16(last - first + 1))
            let hours = Array(exception.working.prefix(maxRanges))
            if !hours.isEmpty {
                record.patchU16(at: 14, UInt16(hours.count))
                record.patchU32(at: 16, UInt32(hours.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) * 10 }))
                var cumulative = 0
                for (i, range) in hours.enumerated() {
                    let length = (range.upperBound - range.lowerBound) * 10
                    cumulative += length
                    record.patchU16(at: 12 + 8 + 2 * i, UInt16(range.lowerBound * 10))
                    record.patchU32(at: 12 + 20 + 4 * i, UInt32(length))
                    record.patchU32(at: 12 + 40 + 4 * i, UInt32(cumulative))
                }
            }
            record.patchU32(at: 72, 1)
            record.patchU32(at: 80, 1)
            record.patchU32(at: 84, 0x4000)
            let name = MPP.encodeUnicode(exception.name)
            record.patchU32(at: 88, UInt32(name.count))
            record.append(name)
            record.pad(toMultipleOf: 4)
            out.append(record.bytes)
        }
        out.append([0, 0, 0, 0])
        return out.bytes
    }
}
