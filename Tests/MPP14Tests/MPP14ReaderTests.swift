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
import MPPCFB
import MPPModel
import MPP14

/// Tests run against any `.mpp` dropped into `Fixtures/`.
///
/// Fixtures are git-ignored because a real Project file embeds the author's
/// display name and the machine path it was saved from. When no fixture is
/// present the tests skip rather than fail, so a fresh clone still builds and
/// tests green.
final class MPP14ReaderTests: XCTestCase {

    private static func fixtureURL() throws -> URL { try Fixture.url() }

    // MARK: - Container

    /// The container must survive a read/write cycle with every stream intact.
    ///
    /// The bytes on disk will differ — the writer lays out sectors its own way,
    /// exactly as the format permits — but every stream's *contents* must come
    /// back identical, or the writer is silently corrupting a file.
    func testContainerRoundTripIsLossless() throws {
        let url = try Self.fixtureURL()
        let original = try CFBFile(contentsOf: url)

        let before = Dictionary(uniqueKeysWithValues: original.allStreams().map { ($0.path, $0.bytes) })
        XCTAssertFalse(before.isEmpty, "fixture has no streams")

        let rewritten = try CFBWriter.write(root: original.root)
        let reloaded = try CFBFile(bytes: rewritten)
        let after = Dictionary(uniqueKeysWithValues: reloaded.allStreams().map { ($0.path, $0.bytes) })

        XCTAssertEqual(Set(before.keys), Set(after.keys),
                       "round trip changed which streams exist")
        for (path, expected) in before {
            guard let actual = after[path] else {
                XCTFail("stream \(path) vanished")
                continue
            }
            XCTAssertEqual(actual, expected,
                           "stream \(path) changed across the round trip "
                           + "(\(expected.count) B in, \(actual.count) B out)")
        }
    }

    /// Payloads of 4096 bytes or more go in the regular FAT; smaller ones go in
    /// the mini stream. Both paths must be exercised by a real project file, or
    /// one of them is untested.
    func testFixtureExercisesBothMiniAndRegularSectors() throws {
        let url = try Self.fixtureURL()
        let file = try CFBFile(contentsOf: url)
        let sizes = file.allStreams().map(\.bytes.count)
        XCTAssertTrue(sizes.contains { $0 < 4096 }, "no mini-stream payload present")
        XCTAssertTrue(sizes.contains { $0 >= 4096 }, "no regular-sector payload present")
    }

    // MARK: - Project

    func testReadsProject() throws {
        let url = try Self.fixtureURL()
        let project = try MPP14File(contentsOf: url).readProject()

        XCTAssertFalse(project.title.isEmpty, "project has no title")
        XCTAssertGreaterThan(project.tasks.count, 0, "project has no tasks")
        // MPP14 files are Project 2010 or later; a date before the epoch or
        // obviously out of range means the timestamp decode is wrong.
        XCTAssertGreaterThan(MPPTime.wire(from: project.start).days, 0,
                             "project start decoded before the 1983-12-31 epoch")
    }

    /// Re-reading must be stable — a formatter or dictionary-ordering
    /// dependency would show up here as a diff.
    func testReadIsDeterministic() throws {
        let url = try Self.fixtureURL()
        let a = try MPP14File(contentsOf: url).readProject()
        let b = try MPP14File(contentsOf: url).readProject()

        XCTAssertEqual(a.tasks.count, b.tasks.count)
        for (x, y) in zip(a.tasks, b.tasks) {
            XCTAssertEqual(x.uid, y.uid)
            XCTAssertEqual(x.name, y.name)
            XCTAssertEqual(x.durationDays, y.durationDays)
            XCTAssertEqual(x.start, y.start)
        }
        XCTAssertEqual(a.relations, b.relations)
        XCTAssertEqual(a.resources, b.resources)
    }

    /// Invariants that must hold for any well-formed project. These are the
    /// assertions that catch an offset or bitmap read landing on the wrong byte.
    func testProjectIsInternallyConsistent() throws {
        let url = try Self.fixtureURL()
        let project = try MPP14File(contentsOf: url).readProject()

        let uids = Set(project.tasks.map(\.uid))
        XCTAssertEqual(uids.count, project.tasks.count, "duplicate task uids")

        for task in project.tasks {
            XCTAssertFalse(task.name.trimmingCharacters(in: .whitespaces).isEmpty,
                           "task uid \(task.uid) has no name — var-data lookup likely missed")
            XCTAssertGreaterThanOrEqual(task.durationDays, 0,
                                        "task uid \(task.uid) has a negative duration")
            XCTAssertGreaterThanOrEqual(task.outlineLevel, 1,
                                        "task uid \(task.uid) has outline level < 1")
            XCTAssertLessThanOrEqual(task.percentComplete, 100,
                                     "task uid \(task.uid) is more than 100% complete")
            XCTAssertLessThanOrEqual(task.priority, 1000,
                                     "task uid \(task.uid) has priority outside 0...1000")
            if let start = task.start, let finish = task.finish {
                XCTAssertLessThanOrEqual(start, finish,
                                         "task uid \(task.uid) finishes before it starts")
            }
            if task.parentUID != 0 {
                XCTAssertTrue(uids.contains(task.parentUID),
                              "task uid \(task.uid) names a parent (\(task.parentUID)) that is not a task")
            }
        }

        for relation in project.relations {
            XCTAssertTrue(uids.contains(relation.predUID),
                          "relation predecessor \(relation.predUID) is not a task")
            XCTAssertTrue(uids.contains(relation.succUID),
                          "relation successor \(relation.succUID) is not a task")
            XCTAssertTrue(["FF", "FS", "SF", "SS"].contains(relation.type),
                          "relation has an unknown type \(relation.type)")
        }

        for resource in project.resources {
            XCTAssertFalse(resource.name.isEmpty, "resource uid \(resource.uid) has no name")
        }
    }

    /// A custom field with a value list stores a reference (`U+0701`, value
    /// id) in place of its text; every one must resolve to the value's text.
    func testLookupReferencesResolve() throws {
        let project = try MPP14File(contentsOf: try Self.fixtureURL()).readProject()
        for t in project.tasks {
            for (n, v) in t.text {
                XCTAssertFalse(v.hasPrefix("\u{0701}"), "task \(t.uid) Text\(n) is an unresolved lookup reference")
            }
            XCTAssertFalse(t.notes.contains("\\par") || t.notes.contains("\u{0}") || t.notes.hasSuffix("}"),
                           "task \(t.uid) notes still carry RTF")
        }
    }

    /// Records past a table's declared count are slack or stale; Project
    /// ignores them, and so must the reader.
    func testReaderStopsAtDeclaredCounts() throws {
        let file = try MPP14File(contentsOf: try Self.fixtureURL())
        let project = try file.readProject()
        let meta = try MPP.parseFixedMetaAuto(
            try file.root.stream(path: "\(MPP.projectStorage)/TBkndCons/FixedMeta"), defaultItemSize: 10)
        XCTAssertLessThanOrEqual(project.relations.count, Int(meta.declaredCount))
    }

    // MARK: - Primitives

    /// A timestamp is tenths-of-a-minute plus a day count, so a round trip must
    /// be exact to the minute.
    func testTimestampRoundTripIsExactToTheMinute() {
        let samples = ["2025-04-14 07:00", "1983-12-31 00:00", "2026-10-06 23:59"]
        for text in samples {
            var components = text.split(separator: " ")
            let date = components.removeFirst()
            let time = components.first ?? "00:00"
            let parts = date.split(separator: "-").compactMap { Int($0) }
            let clock = time.split(separator: ":").compactMap { Int($0) }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(secondsFromGMT: 0)!
            guard let original = cal.date(from: DateComponents(year: parts[0], month: parts[1],
                                                              day: parts[2], hour: clock[0],
                                                              minute: clock[1])) else {
                XCTFail("could not build \(text)")
                continue
            }
            let decoded = MPP.decodeTimestamp(MPP.encodeTimestamp(original), offset: 0)
            // Day 0 is 1983-12-31 itself, which the decoder treats as unset.
            if text == "1983-12-31 00:00" {
                XCTAssertNil(decoded, "day zero is Project's 'no value' encoding")
                continue
            }
            XCTAssertEqual(decoded, original, "round trip drifted for \(text)")
        }
    }

    /// The two size dwords in a Props header must always describe the payload,
    /// or Project refuses the file.
    func testPropsHeaderLengthsAreConsistentAfterRebuild() {
        var props = MPP.PropsStream(header: [UInt8](repeating: 0, count: 16),
                                    values: [:], order: [], typeCodes: [:])
        props.values[131_092] = [UInt8](repeating: 0xAB, count: 28)
        props.order = [131_092]
        props.typeCodes[131_092] = 4

        let built = MPP.buildProps(props)
        let reader = BinaryReader(built)
        XCTAssertEqual(reader.u32(at: 0), UInt32(built.count - 4))
        XCTAssertEqual(reader.u32(at: 4), UInt32(built.count - 4))
        XCTAssertEqual(reader.u16(at: 12), 1)
        XCTAssertEqual(MPP.parseProps(built).values[131_092]?.count, 28)
    }
}
