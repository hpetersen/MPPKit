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

/// Baselines past the eleven Project has fields for. Project stores each slot
/// in its own fixed field ids (`Baseline` and `Baseline1`...`Baseline10`) and
/// has none beyond, so slot 11 and up are kept by the app in a stream of its
/// own, keyed by task uid, resource uid and "task:resource" for assignments.
/// Project never sees them.
public struct ExtraBaselines: Codable, Equatable, Sendable {
    /// The slots Project itself stores.
    public static let projectSlots = 0...10

    public var tasks: [String: [String: Baseline]] = [:]
    public var resources: [String: [String: Baseline]] = [:]
    public var assignments: [String: [String: Baseline]] = [:]

    public init() {}

    public var isEmpty: Bool { tasks.isEmpty && resources.isEmpty && assignments.isEmpty }

    /// The slots of `project` past Project's eleven.
    public init(_ project: Project) {
        func extra(_ b: [Int: Baseline]) -> [String: Baseline]? {
            let out = Dictionary(uniqueKeysWithValues: b.filter { !Self.projectSlots.contains($0.key) }
                .map { (String($0.key), $0.value) })
            return out.isEmpty ? nil : out
        }
        for t in project.tasks { if let e = extra(t.baselines) { tasks[String(t.uid)] = e } }
        for r in project.resources { if let e = extra(r.baselines) { resources[String(r.uid)] = e } }
        for a in project.assignments {
            if let e = extra(a.baselines) { assignments["\(a.taskUID):\(a.resourceUID)"] = e }
        }
    }

    /// Put the extra slots back on the tasks, resources and assignments they
    /// were saved for; entries whose owner is gone are dropped.
    public func apply(to project: inout Project) {
        func merge(_ into: inout [Int: Baseline], _ from: [String: Baseline]?) {
            for (k, b) in from ?? [:] {
                if let slot = Int(k), !Self.projectSlots.contains(slot) { into[slot] = b }
            }
        }
        for i in project.tasks.indices { merge(&project.tasks[i].baselines, tasks[String(project.tasks[i].uid)]) }
        for i in project.resources.indices {
            merge(&project.resources[i].baselines, resources[String(project.resources[i].uid)])
        }
        for i in project.assignments.indices {
            let a = project.assignments[i]
            merge(&project.assignments[i].baselines, assignments["\(a.taskUID):\(a.resourceUID)"])
        }
    }

    public func encode() -> [UInt8]? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)).map(Array.init)
    }

    public static func decode(_ bytes: [UInt8]) -> ExtraBaselines {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(ExtraBaselines.self, from: Data(bytes))) ?? ExtraBaselines()
    }
}

extension [Int: Baseline] {
    /// Only the slots Project has fields for.
    public var projectSlots: [Int: Baseline] { filter { ExtraBaselines.projectSlots.contains($0.key) } }
}
