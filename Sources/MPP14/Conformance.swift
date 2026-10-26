// MPPKit: Microsoft Project (.mpp) files in Swift
// Copyright (C) 2026 Henrik Petersen
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

/// Rules every file Microsoft Project saves follows, checked against MPXJ's
/// corpus of Project 2010 and 2013 files. A file the writer produces must
/// follow them too: a round trip through MPPKit cannot show a rule both the
/// reader and the writer get wrong, and MPXJ does not read the meta bitmaps.
extension MPP14File {

    /// What in this file breaks a rule Project's own files keep; empty when
    /// nothing does.
    public func conformanceIssues() -> [String] {
        var issues: [String] = []
        for (name, storage, metaSize, meta2Size, mapKey, uidField) in Self.classes {
            let k = EntityClass(root: root, storage: "\(MPP.projectStorage)/\(storage)", metaSize: metaSize,
                                meta2Size: meta2Size, propsKey: mapKey, props: props)
            issues += Self.presenceIssues(k, name: name, uidField: uidField)
        }
        return issues
    }

    /// The file with every var-data presence bit set from the record's own
    /// entries and nothing else changed: repairs a file written before the
    /// Fixed2Meta indexing was fixed without rewriting its content.
    public func repairingPresenceBits() throws -> [UInt8] {
        for (_, storage, metaSize, meta2Size, mapKey, uidField) in Self.classes {
            let path = "\(MPP.projectStorage)/\(storage)"
            let k = EntityClass(root: root, storage: path, metaSize: metaSize, meta2Size: meta2Size,
                                propsKey: mapKey, props: props)
            var metas = k.metas, metas2 = k.metas2
            let varFields = k.bitIndex.filter(\.value.varData)
            for i in k.records.indices where k.records[i].count > 30 && i < metas.count {
                guard let uid = k.u32(i, uidField), let entries = k.varTable[Int(uid)] else { continue }
                var meta2 = i < metas2.count ? metas2[i] : []
                for (id, bit) in varFields {
                    MPP.setMetaBit(meta: &metas[i], meta2: &meta2, bit, value: entries[id] != nil)
                }
                if i < metas2.count { metas2[i] = meta2 }
            }
            for (name, items) in [("FixedMeta", metas), ("Fixed2Meta", metas2)] where !items.isEmpty {
                var bytes = try root.stream(path: "\(path)/\(name)")
                let size = items[0].count
                for (i, item) in items.enumerated() where 16 + (i + 1) * size <= bytes.count {
                    bytes.replaceSubrange(16 + i * size..<16 + (i + 1) * size, with: item)
                }
                root.setStream(path: "\(path)/\(name)", bytes)
            }
        }
        return try CFBWriter.write(root: root, rootCLSID: rootCLSID)
    }

    private static let classes: [(String, String, Int, Int, UInt32, UInt32)] = [
        ("task", "TBkndTask", MPP.taskMetaSize, MPP.taskMeta2Size, MPP.PropsKey.taskFieldMap,
         MPP.TaskField.uniqueID),
        ("resource", "TBkndRsc", MPP.resourceMetaSize, 53, MPP.PropsKey.resourceFieldMap,
         MPP.ResourceField.uniqueID),
        ("assignment", "TBkndAssn", MPP.assignmentMetaSize, 53, MPP.PropsKey.assignmentFieldMap,
         MPP.AssignmentField.uniqueID),
    ]

    /// A var-data field's meta bit is set exactly when the record has an
    /// entry for it. Project shows a value whose bit is clear as empty.
    private static func presenceIssues(_ k: EntityClass, name: String, uidField: UInt32) -> [String] {
        var issues: [String] = []
        let varFields = k.bitIndex.filter(\.value.varData).sorted { $0.key < $1.key }
        for i in k.records.indices where k.records[i].count > 30 && i < k.metas.count {
            guard let uid = k.u32(i, uidField), let entries = k.varTable[Int(uid)] else { continue }
            let meta2 = i < k.metas2.count ? k.metas2[i] : []
            for (id, bit) in varFields {
                let has = entries[id] != nil
                guard let set = MPP.metaBit(meta: k.metas[i], meta2: meta2, bit), (set == 1) != has else { continue }
                issues.append("\(name) \(uid): field \(id) "
                              + (has ? "has a value but its meta bit is clear" : "has its meta bit set but no value"))
            }
        }
        return issues
    }
}
