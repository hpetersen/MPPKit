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
import MPPCFB
import MPPModel
import MPP14
import MPPKit

// mppdump — reverse-engineering and inspection tool for MPP14 files.
//
// The container tree, Props dump and field-map dump are what make a new Project
// vintage tractable: they show the field map, record counts and item sizes the
// file itself publishes, which is exactly what the parser keys off. Nothing in
// the parser is hard-coded per version, so when a new Project release appears,
// these three commands are how you find out whether anything moved.

func usage() {
    print("""
    mppdump — inspect Microsoft Project (.mpp) files

    USAGE
      mppdump <command> <file.mpp>
      mppdump sample <template.mpp> <out.mpp>
      mppdump template <project.mpp> <out.mpp>
      mppdump check <file.mpp>...
      mppdump fixbits <in.mpp> <out.mpp>
      mppdump baselines <template.mpp> <out.mpp> [count]

    COMMANDS
      tree        container tree: every storage and stream with its size
      props       the project storage's Props stream: keys, sizes, type codes
      fieldmap    the field maps: per-entry block, offset, category
      meta        FixedMeta item sizes and record counts per entity class
      tasks       task rows
      resources   resource rows
      relations   dependency rows
      calendars   base and resource calendars: working weeks and exceptions
      strings     readable text in every stream (for checking what a file carries)
      sample      write the all-features sample project, using any Project-saved
                  file as the template (its user data is neutralised first)
      template    turn any Project-saved file into a clean writer template: no
                  user data, a summary task over two linked tasks
      baselines   the sample with [count] baselines (default 50), slot n moved n
                  weeks earlier; slots past 10 go to the app's own stream
      json        the whole parsed project as JSON
      check       the rules every Project-saved file keeps (meta bits); lists
                  what breaks them, exits 1 if anything does
      fixbits     set every var-field meta bit from the record's own values and
                  change nothing else (repairs files written before that fix)
      xml         export as Microsoft Project XML (MSPDI): mppdump xml <file.mpp> <out.xml>
      schedcheck  reschedule with MPPKit and compare with the dates, late dates
                  and critical path Project saved in the file
                  (set SCHEDCHECK_LIST=n to list n differing tasks)
    """)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("mppdump: \(message)\n".utf8))
    exit(1)
}

/// Space-pad to a fixed column width.
///
/// `String(format:)` is avoided for the column headers because `%s` does not
/// accept a Swift `String`, and `%d` with a Swift `Int` reads only 32 bits.
func pad(_ s: String, _ width: Int, right: Bool = false) -> String {
    guard s.count < width else { return s }
    let fill = String(repeating: " ", count: width - s.count)
    return right ? fill + s : s + fill
}

/// Format a double: integral values without a decimal point, everything else at
/// full round-trip precision.
///
/// `%g` is deliberately avoided — it defaults to six significant digits, which
/// silently turns a valid duration such as 164.6875 days into 164.688.
func num(_ v: Double) -> String {
    if v == v.rounded(), abs(v) < 1e15 { return String(Int(v)) }
    return String(v)
}

/// Indented container tree, in stored order.
func printTree(_ node: CFBStorage, depth: Int = 0) {
    for name in node.order {
        guard let child = node.children[name] else { continue }
        let indent = String(repeating: "  ", count: depth)
        switch child {
        case .storage(let sub):
            print("\(indent)[storage] \(name.debugDescription)")
            printTree(sub, depth: depth + 1)
        case .stream(let bytes):
            print("\(indent)\(pad(String(bytes.count), 9, right: true)) B  \(name.debugDescription)")
        }
    }
}

func hexPreview(_ value: [UInt8], limit: Int = 20) -> String {
    value.prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ")
}

// MARK: - Entry point

let args = CommandLine.arguments
guard args.count >= 3 else { usage(); exit(2) }
let command = args[1]
let path = args[2]

/// A synthetic plan: phases of 50 tasks chained FS, each phase linked to the
/// next, a summary over all — for timing the scheduler at sizes no file has.
func synthetic(_ n: Int) -> Project {
    var p = Project(title: "Synthetic", start: MPPTime.date(2026, 1, 5, 8))
    p.calendar = ProjectCalendar(name: "Standard")
    var uid = 1
    var phases: [Int] = []
    while p.tasks.count < n {
        let phase = uid; uid += 1
        var s = ProjectTask(uid: phase, name: "Phase \(phases.count + 1)"); s.outlineLevel = 1
        p.tasks.append(s); phases.append(phase)
        var prev: Int?
        for i in 0..<49 {
            var t = ProjectTask(uid: uid, name: "Task \(uid)"); t.outlineLevel = 2; t.parentUID = phase
            t.durationDays = Double(1 + (i * 7) % 5)
            p.tasks.append(t)
            if let prev { p.relations.append(Relation(predUID: prev, succUID: uid, type: i % 9 == 0 ? "SS" : "FS", lagDays: i % 7 == 0 ? 1 : 0)) }
            prev = uid; uid += 1
        }
    }
    for (a, b) in zip(phases, phases.dropFirst()) { p.relations.append(Relation(predUID: a, succUID: b)) }
    for (i, _) in p.tasks.enumerated() { p.tasks[i].rowID = i + 1 }
    return p
}

if command == "synthfile" {
    // mppdump synthfile <template.mpp> <out.mpp> <tasks>
    guard args.count >= 5, let n = Int(args[4]) else { usage(); exit(2) }
    do {
        let source = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        var p = synthetic(n)
        try Scheduler.schedule(&p)
        var options = MPP14Writer.Options()
        options.scrubTemplateIdentity = true
        try MPP14Writer(template: try MPP14Template.neutralized(source), options: options).write(p, to: URL(fileURLWithPath: args[3]))
        print("wrote \(args[3]): \(p.tasks.count) tasks")
        exit(0)
    } catch { fail("\(error)") }
}

if command == "check" {
    var failed = false
    for file in args.dropFirst(2) {
        guard let f = try? MPP14File(path: file) else {
            print("\(file): cannot read")
            failed = true
            continue
        }
        let issues = f.conformanceIssues()
        print("\(file): \(issues.isEmpty ? "conforms" : "\(issues.count) issues")")
        for issue in issues.prefix(20) { print("  \(issue)") }
        if issues.count > 20 { print("  … \(issues.count - 20) more") }
        failed = failed || !issues.isEmpty
    }
    exit(failed ? 1 : 0)
}

if command == "fixbits" {
    guard args.count >= 4 else { usage(); exit(2) }
    do {
        let bytes = try MPP14File(path: path).repairingPresenceBits()
        try Data(bytes).write(to: URL(fileURLWithPath: args[3]))
        print("wrote \(args[3])")
        exit(0)
    } catch {
        fail("\(error)")
    }
}

if command == "sample" || command == "template" {
    guard args.count >= 4 else { usage(); exit(2) }
    do {
        let source = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        if command == "template" {
            try Data(try MPP14Template.makeBlank(from: source)).write(to: URL(fileURLWithPath: args[3]))
            print("wrote \(args[3])")
            exit(0)
        }
        let writer = try MPP14Writer(template: try MPP14Template.neutralized(source))
        let project = SampleProject.make()
        try writer.write(project, to: URL(fileURLWithPath: args[3]))
        print("wrote \(args[3]): \(project.tasks.count) tasks, \(project.relations.count) links, "
              + "\(project.resources.count) resources, \(project.assignments.count) assignments, "
              + "\(project.calendars.count + 1) base calendars")
        exit(0)
    } catch {
        fail("\(error)")
    }
}

// Experimental: the sample with `count` baselines (default 50), slot n moved
// n weeks earlier so each is told apart. Slots 0...10 go to Project's fields,
// the rest to the app's own stream.
if command == "baselines" {
    guard args.count >= 4 else { usage(); exit(2) }
    do {
        let source = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        let count = args.count >= 5 ? Int(args[4]) ?? 50 : 50
        var project = SampleProject.make()
        project.title = "MPPKit \(count) baselines"
        for i in project.tasks.indices { project.tasks[i].baselines = [:] }
        for i in project.assignments.indices { project.assignments[i].baselines = [:] }
        for slot in 0..<count {
            project.setBaseline(slot: slot)
            let shift = TimeInterval(-7 * 86_400 * slot)
            func moved(_ b: Baseline) -> Baseline {
                var b = b
                b.start = b.start?.addingTimeInterval(shift)
                b.finish = b.finish?.addingTimeInterval(shift)
                return b
            }
            for i in project.tasks.indices { project.tasks[i].baselines[slot] = project.tasks[i].baselines[slot].map(moved) }
            for i in project.assignments.indices {
                project.assignments[i].baselines[slot] = project.assignments[i].baselines[slot].map(moved)
            }
        }
        let writer = try MPP14Writer(template: try MPP14Template.neutralized(source))
        try writer.write(project, to: URL(fileURLWithPath: args[3]))
        let back = try MPP14File(path: args[3]).readProject()
        print("wrote \(args[3]): \(project.tasks.count) tasks with \(count) baselines; "
              + "read back \(back.tasks.map(\.baselines.count).max() ?? 0)")
        exit(0)
    } catch {
        fail("\(error)")
    }
}

if command == "schedbench" {
    let p = path.hasPrefix("synth") ? synthetic(Int(path.dropFirst(5)) ?? 2000)
        : ((try? MPP14File(path: path).readProject()) ?? { fail("cannot read \(path)") }())
    var times: [Double] = []
    for _ in 0..<5 {
        var q = p
        let t0 = Date()
        do { try Scheduler.schedule(&q) } catch { fail("\(error)") }
        times.append(Date().timeIntervalSince(t0) * 1000)
    }
    print(String(format: "%d tasks, %d links: schedule %.1f ms (best of 5)", p.tasks.count, p.relations.count, times.min()!))
    exit(0)
}

guard FileManager.default.fileExists(atPath: path) else { fail("no such file: \(path)") }

let bytes: [UInt8]
do {
    bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
} catch {
    fail("cannot read \(path): \(error)")
}

// `tree` and `meta` work off the raw container, so read it first.
let cfb: CFBFile
do {
    cfb = try CFBFile(bytes: bytes)
} catch {
    fail("\(error)")
}

/// Open as an MPP14 project, or exit with the reason.
func openProject() -> MPP14File {
    do { return try MPP14File(bytes: bytes) }
    catch { fail("\(error)") }
}

/// Parse the whole project, or exit with the reason.
func loadProject() -> Project {
    do { return try openProject().readProject() }
    catch { fail("\(error)") }
}

if command == "xml" {
    guard args.count >= 4 else { usage(); exit(2) }
    try! MSPDI.data(loadProject()).write(to: URL(fileURLWithPath: args[3]))
    let back = try! MSPDI.project(from: Data(contentsOf: URL(fileURLWithPath: args[3])))
    print("wrote \(args[3]); reads back \(back.tasks.count) tasks, \(back.relations.count) links, \(back.resources.count) resources")
    exit(0)
}

if command == "schedcheck" {
    let stored = loadProject()
    var mine = stored
    do { try Scheduler.schedule(&mine) } catch { fail("schedule: \(error)") }
    let index = Dictionary(uniqueKeysWithValues: mine.tasks.map { ($0.uid, $0) })
    let time = stored.workingTimes()
    func off(_ a: Date?, _ b: Date?, _ t: ProjectTask) -> Int? {
        guard let a, let b else { return nil }
        let m = time(t).signedMinutes(from: a, to: b)
        return m == 0 ? nil : m
    }
    var counts = ["start": 0, "finish": 0, "lateStart": 0, "lateFinish": 0]
    var listed: [(ProjectTask, String)] = []
    for t in stored.tasks where !t.summary {
        guard let m = index[t.uid] else { continue }
        var notes: [String] = []
        for (k, a, b) in [("start", t.start, m.start), ("finish", t.finish, m.finish),
                          ("lateStart", t.lateStart, m.lateStart), ("lateFinish", t.lateFinish, m.lateFinish)] {
            if let d = off(a, b, t) { counts[k]! += 1; notes.append("\(k) \(d > 0 ? "+" : "")\(Double(d) / Double(stored.minutesPerDay))d") }
        }
        if !notes.isEmpty { listed.append((t, notes.joined(separator: ", "))) }
    }
    // Tasks whose saved span is longer than their duration: split in Project.
    let stretched = stored.tasks.filter { t in
        guard !t.summary, !t.manual, let s = t.start, let f = t.finish else { return false }
        return time(t).minutes(from: s, to: f) > Int((t.durationDays * Double(stored.minutesPerDay)).rounded()) + 1
    }
    let a = stored.criticalUIDs(), b = mine.criticalUIDs()
    let leaves = stored.tasks.filter { !$0.summary }.count
    print("\(URL(fileURLWithPath: path).lastPathComponent)")
    print("  tasks \(stored.tasks.count) (\(leaves) leaves), links \(stored.relations.count)")
    print("  critical  Project \(a.count)  MPPKit \(b.count)  only-Project \(a.subtracting(b).count)  only-MPPKit \(b.subtracting(a).count)")
    print("  stretched (split?) \(stretched.count): \(stretched.prefix(6).map { "\($0.rowID)" }.joined(separator: ","))")
    print("  leaves differing  start \(counts["start"]!)  finish \(counts["finish"]!)  lateStart \(counts["lateStart"]!)  lateFinish \(counts["lateFinish"]!)")
    if let row = Int(ProcessInfo.processInfo.environment["SCHEDCHECK_ROW"] ?? "") {
        func d(_ x: Date?) -> String { x.map { MPPTime.isoMinute($0) } ?? "—" }
        func show(_ uid: Int, _ prefix: String) {
            guard let t = stored.tasks.first(where: { $0.uid == uid }), let m = index[uid] else { return }
            print("\(prefix)\(t.rowID) \(t.name.prefix(30)) dur \(t.durationDays) \(t.constraint ?? "") \(d(t.constraintDate)) \(t.percentComplete)% cal \(t.calendar ?? "-") manual \(t.manual)")
            print("\(prefix)   Project  S \(d(t.start))  F \(d(t.finish))  LS \(d(t.lateStart))  LF \(d(t.lateFinish))")
            print("\(prefix)   MPPKit   S \(d(m.start))  F \(d(m.finish))  LS \(d(m.lateStart))  LF \(d(m.lateFinish))")
        }
        if let t = stored.tasks.first(where: { $0.rowID == row }) {
            show(t.uid, "")
            var anc = t.parentUID
            while anc != 0 { show(anc, "  parent "); anc = stored.tasks.first { $0.uid == anc }?.parentUID ?? 0 }
            for r in stored.relations where r.predUID == t.uid || stored.tasks.contains(where: { $0.uid == r.predUID && $0.uid == t.parentUID }) {
                print("  -> \(r.type) lag \(r.lagDays)d"); show(r.succUID, "     ")
            }
        }
    }
    if ProcessInfo.processInfo.environment["SCHEDCHECK_CRIT"] != nil {
        let rows = Dictionary(uniqueKeysWithValues: stored.tasks.map { ($0.uid, $0) })
        for u in a.symmetricDifference(b).sorted() {
            guard let t = rows[u], let m = index[u] else { continue }
            func d(_ x: Date?) -> String { x.map { MPPTime.isoMinute($0) } ?? "—" }
            print("    crit \(a.contains(u) ? "Project-only" : "MPPKit-only") \(t.rowID) \(t.name.prefix(28)) summary \(t.summary) \(t.percentComplete)% P[\(d(t.start)) \(d(t.finish)) \(d(t.lateStart)) \(d(t.lateFinish))] M[\(d(m.start)) \(d(m.finish)) \(d(m.lateStart)) \(d(m.lateFinish))]")
        }
    }
    let n = Int(ProcessInfo.processInfo.environment["SCHEDCHECK_LIST"] ?? "0") ?? 0
    for (t, note) in listed.prefix(n) {
        print("    \(t.rowID) \(t.name.prefix(36)) [\(t.constraint ?? "ASAP")\(t.deadline == nil ? "" : ", deadline")\(t.manual ? ", manual" : "")]: \(note)")
    }
    exit(0)
}

switch command {

case "tree":
    printTree(cfb.root)

case "props":
    let props = openProject().props
    print("Props entries: \(props.order.count)")
    print(pad("key", 12) + pad("size", 9, right: true) + "  "
          + pad("type", 6, right: true) + "  preview")
    for key in props.order {
        let value = props.values[key] ?? []
        let type = props.typeCodes[key] ?? 0
        var preview = hexPreview(value)
        let text = MPP.decodeUnicode(value)
        let printable = !text.isEmpty && text.allSatisfy {
            $0.isLetter || $0.isNumber || $0.isWhitespace || "_-./&()".contains($0)
        }
        if printable { preview = "\"\(text.prefix(44))\"" }
        print(pad(String(key), 12) + pad(String(value.count), 9, right: true) + "  "
              + pad(String(type), 6, right: true) + "  " + preview)
    }

case "fieldmap":
    let props = openProject().props
    let maps: [(String, UInt32)] = [
        ("TASK", MPP.PropsKey.taskFieldMap),
        ("RESOURCE", MPP.PropsKey.resourceFieldMap),
        ("RELATION", MPP.PropsKey.relationFieldMap),
        ("ASSIGNMENT", MPP.PropsKey.assignmentFieldMap),
    ]
    for (label, key) in maps {
        guard let raw = props[key] else {
            print("== \(label): absent")
            continue
        }
        let items = MPP.parseFieldMap(raw)
        print("== \(label) field map: \(items.count) entries (\(raw.count) bytes)")
        print("   " + pad("idx", 5) + pad("native", 8, right: true) + pad("block", 7, right: true)
              + pad("offset", 9, right: true) + "  " + pad("cat", 7) + "raw")
        for (i, item) in items.enumerated().prefix(200) {
            print("   " + pad(String(i), 5) + pad(String(item.nativeID), 8, right: true)
                  + pad(String(item.block), 7, right: true) + pad(String(item.offset), 9, right: true)
                  + "  0x" + pad(String(format: "%02X", item.category), 5) + hexPreview(item.raw, limit: 12))
        }
        if items.count > 200 { print("   … \(items.count - 200) more") }
    }

case "meta":
    let classes: [(String, Int)] = [
        ("TBkndTask", MPP.taskMetaSize),
        ("TBkndRsc", MPP.resourceMetaSize),
        ("TBkndAssn", MPP.assignmentMetaSize),
        ("TBkndCons", MPP.relationMetaSize),
        ("TBkndCal", 10),
    ]
    let props = openProject().props
    for (storage, fallback) in classes {
        let base = "\(MPP.projectStorage)/\(storage)"
        print("== \(storage)")
        for file in ["FixedMeta", "Fixed2Meta"] {
            guard let raw = try? cfb.root.stream(path: "\(base)/\(file)"), raw.count >= 16 else {
                print("   \(file): absent")
                continue
            }
            let count = BinaryReader(raw).u32(at: 8) ?? 0
            let declared = BinaryReader(raw).u32(at: 12) ?? 0
            var sizeText = "\(fallback) (fallback)"
            if count > 0, (raw.count - 16) % Int(count) == 0 {
                sizeText = "\((raw.count - 16) / Int(count)) (derived)"
            }
            print("   \(file): \(raw.count) B, count=\(count), dataLen=\(declared), itemSize=\(sizeText)")
        }
        for file in ["FixedData", "Fixed2Data", "VarMeta", "Var2Data"] {
            if let raw = try? cfb.root.stream(path: "\(base)/\(file)") {
                print("   \(file): \(raw.count) B")
            }
        }
        // Keys 0x10001..: the Var2Data length Project truncates its read at.
        if let key = MPP.PropsKey.var2DataSize(for: storage), let declared = props[key] {
            print("   Props[\(key)] declared Var2Data bytes: \(declared.count)")
        }
    }

case "tasks":
    let project = loadProject()
    print("title: \(project.title)")
    print("start: \(MPPTime.isoMinute(project.start))")
    print("tasks: \(project.tasks.count)")
    print()
    print(pad("uid", 7) + pad("lvl", 5) + pad("name", 54) + pad("duration", 11, right: true) + "  "
          + pad("start", 12) + pad("finish", 12) + "units")
    for t in project.tasks {
        let name = t.name.count > 52 ? String(t.name.prefix(51)) + "…" : t.name
        let duration = num(t.durationDays) + (t.estimated ? "?" : "")
        print(pad(String(t.uid), 7) + pad(String(t.outlineLevel), 5) + pad(name, 54)
              + pad(duration, 11, right: true) + "  "
              + pad(t.start.map(MPPTime.iso) ?? "-", 12)
              + pad(t.finish.map(MPPTime.iso) ?? "-", 12)
              + t.durationUnits)
    }

case "resources":
    let project = loadProject()
    print("resources: \(project.resources.count)")
    print(pad("uid", 7) + pad("name", 44) + pad("maxUnits", 10, right: true) + "  initials")
    for r in project.resources {
        print(pad(String(r.uid), 7) + pad(r.name, 44) + pad(num(r.maxUnits), 10, right: true)
              + "  " + r.initials)
    }

case "relations":
    let project = loadProject()
    print("relations: \(project.relations.count)")
    print(pad("pred", 9) + pad("succ", 9) + pad("type", 6) + "lag_days")
    for r in project.relations {
        print(pad(String(r.predUID), 9) + pad(String(r.succUID), 9) + pad(r.type, 6) + num(r.lagDays))
    }

case "calendars":
    let project = loadProject()
    let weekdays = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    func clock(_ m: Int) -> String { String(format: "%02d:%02d", m / 60, m % 60) }
    func describe(_ cal: ProjectCalendar, kind: String) {
        var title = "\(kind) uid \(cal.uid) \(cal.name.debugDescription)"
        if let r = cal.resourceUID { title += " resource \(r)" }
        if let b = cal.baseCalendarUID { title += " base \(b)" }
        print(title)
        for day in 1...7 {
            guard let entry = cal.week[day] else { continue }
            let text = (entry ?? []).map { "\(clock($0.lowerBound))-\(clock($0.upperBound))" }
            print("   \(weekdays[day])  \(text.isEmpty ? "non-working" : text.joined(separator: ", "))")
        }
        for x in cal.exceptions {
            let span = x.finish.map { "\(MPPTime.iso(x.start)) .. \(MPPTime.iso($0))" } ?? MPPTime.iso(x.start)
            let hours = x.working.map { "\(clock($0.lowerBound))-\(clock($0.upperBound))" }.joined(separator: " ")
            print("   exception \(span)  \(x.name)  \(x.isNonWorking ? "non-working" : "working " + hours)")
        }
    }
    print("minutes/day \(project.minutesPerDay), minutes/week \(project.minutesPerWeek), "
          + "days/month \(project.daysPerMonth), day \(clock(project.defaultStartTime))-\(clock(project.defaultFinishTime))")
    print("default calendar: \(project.defaultCalendar ?? "-")")
    if let std = project.calendar { describe(std, kind: "standard") }
    for c in project.calendars { describe(c, kind: "base") }
    for c in project.resourceCalendars { describe(c, kind: "resource") }

case "strings":
    // UTF-16 and ASCII runs of four or more characters containing letters.
    for (streamPath, data) in cfb.allStreams() {
        var found: [String] = []
        var seen = Set<String>()
        func keep(_ s: String) {
            guard s.count >= 4, s.contains(where: { $0.isLetter }), seen.insert(s).inserted else { return }
            found.append(s)
        }
        for phase in 0..<2 {
            var run = ""
            var i = phase
            while i + 1 < data.count {
                let unit = UInt16(data[i]) | UInt16(data[i + 1]) << 8
                if unit >= 0x20, unit < 0x2000, !(0x7F..<0xA0).contains(unit),
                   let scalar = Unicode.Scalar(unit) {
                    run.unicodeScalars.append(scalar)
                } else { keep(run); run = "" }
                i += 2
            }
            keep(run)
        }
        var ascii = ""
        for byte in data {
            if byte >= 0x20, byte < 0x7F { ascii.append(Character(Unicode.Scalar(byte))) }
            else { if ascii.count >= 6 { keep(ascii) }; ascii = "" }
        }
        guard !found.isEmpty else { continue }
        print("== \(streamPath.debugDescription)")
        for s in found { print("   \(s)") }
    }

case "json":
    let project = loadProject()
    func iso(_ d: Date?) -> Any { d.map { MPPTime.isoMinute($0).replacingOccurrences(of: " ", with: "T") } ?? NSNull() }
    func keyed<V>(_ d: [Int: V], _ f: (V) -> Any) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: d.map { (String($0.key), f($0.value)) })
    }
    func baselines(_ b: [Int: Baseline]) -> [String: Any] {
        keyed(b) { ["start": iso($0.start), "finish": iso($0.finish), "durationDays": $0.durationDays,
                    "workHours": $0.workHours, "cost": $0.cost] }
    }
    func calendar(_ c: ProjectCalendar) -> [String: Any] {
        var week: [String: Any] = [:]
        for (day, entry) in c.week {
            week[String(day)] = entry.map { $0.map { [$0.lowerBound, $0.upperBound] } } ?? NSNull()
        }
        return ["uid": c.uid, "name": c.name, "resourceUID": c.resourceUID ?? NSNull(), "week": week,
                "exceptions": c.exceptions.map { ["start": iso($0.start), "finish": iso($0.lastDay), "name": $0.name] }]
    }
    let tasks: [[String: Any]] = project.tasks.map { t in
        ["uid": t.uid, "id": t.rowID, "name": t.name, "outlineLevel": t.outlineLevel, "parentUID": t.parentUID,
         "start": iso(t.start), "finish": iso(t.finish), "durationDays": t.durationDays,
         "durationUnits": t.durationUnits, "estimated": t.estimated, "summary": t.summary,
         "milestone": t.milestone, "manual": t.manual, "calendar": t.calendar ?? NSNull(),
         "notes": t.notes, "wbs": t.wbs ?? NSNull(), "constraint": t.constraint ?? NSNull(),
         "constraintDate": iso(t.constraintDate), "deadline": iso(t.deadline),
         "percentComplete": t.percentComplete, "actualStart": iso(t.actualStart),
         "actualFinish": iso(t.actualFinish), "workHours": t.workHours, "priority": t.priority,
         "taskType": t.taskType, "effortDriven": t.effortDriven, "created": iso(t.created),
         "text": keyed(t.text) { $0 }, "numbers": keyed(t.numbers) { $0 },
         "dates": keyed(t.dateFields) { iso($0) }, "flags": keyed(t.flags) { $0 },
         "baselines": baselines(t.baselines)]
    }
    let resources: [[String: Any]] = project.resources.map { r in
        ["uid": r.uid, "id": r.rowID, "name": r.name, "initials": r.initials, "email": r.email,
         "maxUnits": r.maxUnits, "calendarUID": r.calendarUID ?? NSNull(), "baselines": baselines(r.baselines)]
    }
    let assignments: [[String: Any]] = project.assignments.map { a in
        ["uid": a.uid, "taskUID": a.taskUID, "resourceUID": a.resourceUID, "units": a.units,
         "workHours": a.workHours, "start": iso(a.start), "finish": iso(a.finish),
         "baselines": baselines(a.baselines)]
    }
    let root: [String: Any] = [
        "title": project.title, "start": iso(project.start), "finish": iso(project.finish),
        "statusDate": iso(project.statusDate), "author": project.author ?? NSNull(),
        "subject": project.subject ?? NSNull(), "keywords": project.keywords ?? NSNull(),
        "comments": project.comments ?? NSNull(), "manager": project.manager ?? NSNull(),
        "company": project.company ?? NSNull(), "category": project.category ?? NSNull(),
        "currencySymbol": project.currencySymbol ?? NSNull(), "currencyCode": project.currencyCode ?? NSNull(),
        "defaultCalendar": project.defaultCalendar ?? NSNull(),
        "minutesPerDay": project.minutesPerDay, "minutesPerWeek": project.minutesPerWeek,
        "daysPerMonth": project.daysPerMonth, "defaultStartTime": project.defaultStartTime,
        "defaultFinishTime": project.defaultFinishTime,
        "tasks": tasks,
        "relations": project.relations.map { ["predUID": $0.predUID, "succUID": $0.succUID,
                                              "type": $0.type, "lagDays": $0.lagDays] },
        "resources": resources, "assignments": assignments,
        "calendars": ([project.calendar].compactMap { $0 } + project.calendars).map(calendar),
        "resourceCalendars": project.resourceCalendars.map(calendar),
    ]
    do {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    } catch {
        fail("\(error)")
    }

default:
    fail("unknown command: \(command)")
}
