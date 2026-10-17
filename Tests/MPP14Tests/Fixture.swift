// MPPKit: Microsoft Project (.mpp) files in Swift
// Copyright (C) 2026 Henrik Petersen
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License version 3 as published
// by the Free Software Foundation. It is distributed WITHOUT ANY WARRANTY;
// see the LICENSE file for details. https://mppstudio.com
//
// SPDX-License-Identifier: GPL-3.0-only

import XCTest
import Foundation

/// The first `.mpp` in `Fixtures/`, or a skip when there is none.
///
/// Fixtures are git-ignored because a real Project file embeds the author's
/// display name and the machine path it was saved from.
enum Fixture {
    static func url() throws -> URL {
        // .../Tests/MPP14Tests/<this file> -> package root
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dir = root.appendingPathComponent("Fixtures")
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        let files = entries
            .filter { $0.pathExtension.lowercased() == "mpp" }
            .sorted { $0.path < $1.path }
        guard let first = files.first else {
            throw XCTSkip("no .mpp fixture in \(dir.path) — drop one in to enable these tests")
        }
        return first
    }

    static func bytes() throws -> [UInt8] { [UInt8](try Data(contentsOf: try url())) }
}
