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
import MPPKit

/// The rules Project's own files keep (`MPP14File.conformanceIssues`), held
/// against files Project saved and against what the writer produces. A round
/// trip cannot catch a rule the reader and writer both get wrong; this can.
final class ConformanceTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func assertConforms(_ file: MPP14File, _ name: String,
                                file path: StaticString = #filePath, line: UInt = #line) {
        let issues = file.conformanceIssues()
        XCTAssert(issues.isEmpty, "\(name): \(issues.count) issues, first: \(issues.prefix(5))",
                  file: path, line: line)
    }

    /// MPXJ's Project 2010/2013 files, from `Tools/ci/fetch-corpus.sh`: the
    /// folder in `MPP_CORPUS`, else `Corpus/`. Skips when there is none.
    func testProjectSavedFilesConform() throws {
        let dir = ProcessInfo.processInfo.environment["MPP_CORPUS"].map { URL(fileURLWithPath: $0) }
            ?? Self.root.appendingPathComponent("Corpus")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "mpp" }.sorted { $0.path < $1.path }
        guard !files.isEmpty else { throw XCTSkip("no corpus in \(dir.path) — run Tools/ci/fetch-corpus.sh") }
        for url in files {
            let file = try MPP14File(path: url.path)
            XCTAssertNoThrow(try file.readProject(), url.lastPathComponent)
            assertConforms(file, url.lastPathComponent)
        }
    }

    /// The samples are what people open in Project to see what MPPKit does.
    func testSamplesConform() throws {
        for name in ["Blank-Template", "MPPKit-Diagnostic", "MPPKit-Feature-Sample"] {
            let url = Self.root.appendingPathComponent("Samples/\(name).mpp")
            assertConforms(try MPP14File(path: url.path), name)
        }
    }

    /// Every baseline slot, so every block-1 baseline field, on tasks,
    /// resources and assignments.
    func testWrittenFileConforms() throws {
        let template = [UInt8](try Data(contentsOf: Self.root.appendingPathComponent("Samples/Blank-Template.mpp")))
        var project = SampleProject.make()
        for slot in 0...10 { project.setBaseline(slot: slot) }
        let file = try MPP14File(bytes: try MPP14Writer(template: template).build(project))
        assertConforms(file, "written sample")
        let back = try file.readProject()
        for t in back.tasks { XCTAssertEqual(t.baselines.keys.sorted(), Array(0...10), "task \(t.uid)") }
    }

    /// A file written before the Fixed2Meta fix, repaired: its bits follow
    /// the rule again and what it holds is unchanged.
    func testRepairSetsBitsAndKeepsContent() throws {
        let url = Self.root.appendingPathComponent("Samples/MPPKit-Feature-Sample.mpp")
        let file = try MPP14File(path: url.path)
        let repaired = try MPP14File(bytes: try file.repairingPresenceBits())
        assertConforms(repaired, "repaired sample")
        XCTAssertEqual(try repaired.readProject(), try MPP14File(path: url.path).readProject())
    }
}
