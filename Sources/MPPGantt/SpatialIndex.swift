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

/// An axis-aligned rectangle in world coordinates.
public struct Rect: Sendable, Equatable {
    public var minX: Double, minY: Double, maxX: Double, maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
    }

    @inline(__always)
    public func intersects(_ o: Rect) -> Bool {
        minX <= o.maxX && o.minX <= maxX && minY <= o.maxY && o.minY <= maxY
    }

    @inline(__always)
    func union(_ o: Rect) -> Rect {
        Rect(minX: Swift.min(minX, o.minX), minY: Swift.min(minY, o.minY),
             maxX: Swift.max(maxX, o.maxX), maxY: Swift.max(maxY, o.maxY))
    }

    static let empty = Rect(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity)
}

/// A static, packed R-tree (sort-tile-recursive bulk load).
///
/// Built once per layout and queried every frame for what is on screen, and
/// on every tap for what was hit. Nodes are stored level by level in flat
/// arrays — no per-node allocations — so a query over a 100 000-task
/// project touches a few hundred bytes of bounds.
public struct SpatialIndex<Payload: Sendable>: Sendable {
    /// Children per node.
    public static var fanout: Int { 16 }

    /// Leaf entries, in packed order.
    private let leafBounds: [Rect]
    private let payloads: [Payload]
    /// Internal levels, bottom (just above the leaves) first. Node `i` of a
    /// level covers children `i*fanout ..< (i+1)*fanout` of the level below.
    private let levels: [[Rect]]

    public var count: Int { payloads.count }

    public init(_ entries: [(Rect, Payload)]) {
        let f = Self.fanout
        // Sort-tile-recursive: slice by x, sort each slice by y.
        var items = entries
        let n = items.count
        if n > f {
            let leafCount = (n + f - 1) / f
            let slices = Int(Double(leafCount).squareRoot().rounded(.up))
            let perSlice = slices * f
            items.sort { ($0.0.minX + $0.0.maxX) < ($1.0.minX + $1.0.maxX) }
            var packed: [(Rect, Payload)] = []
            packed.reserveCapacity(n)
            var i = 0
            while i < n {
                let slice = items[i..<min(i + perSlice, n)].sorted { ($0.0.minY + $0.0.maxY) < ($1.0.minY + $1.0.maxY) }
                packed.append(contentsOf: slice)
                i += perSlice
            }
            items = packed
        }
        leafBounds = items.map(\.0)
        payloads = items.map(\.1)

        var levels: [[Rect]] = []
        var below = leafBounds
        while below.count > 1 {
            var level: [Rect] = []
            level.reserveCapacity((below.count + f - 1) / f)
            var i = 0
            while i < below.count {
                var r = Rect.empty
                for j in i..<min(i + f, below.count) { r = r.union(below[j]) }
                level.append(r)
                i += f
            }
            levels.append(level)
            below = level
        }
        self.levels = levels
    }

    /// Every payload whose bounds intersect `area`, in no particular order.
    public func query(_ area: Rect, into out: inout [Payload]) {
        let f = Self.fanout
        guard !leafBounds.isEmpty else { return }
        if levels.isEmpty {
            for (i, r) in leafBounds.enumerated() where r.intersects(area) { out.append(payloads[i]) }
            return
        }
        // Depth-first over (level, node); the top level has a single node.
        var stack: [(level: Int, node: Int)] = [(levels.count - 1, 0)]
        while let (level, node) = stack.popLast() {
            guard levels[level][node].intersects(area) else { continue }
            let lo = node * f
            if level == 0 {
                for i in lo..<min(lo + f, leafBounds.count) where leafBounds[i].intersects(area) {
                    out.append(payloads[i])
                }
            } else {
                for c in lo..<min(lo + f, levels[level - 1].count) { stack.append((level - 1, c)) }
            }
        }
    }

    public func query(_ area: Rect) -> [Payload] {
        var out: [Payload] = []
        query(area, into: &out)
        return out
    }
}
