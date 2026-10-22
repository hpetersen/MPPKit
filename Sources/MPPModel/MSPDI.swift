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
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Microsoft Project's XML format (MSPDI, the schema Project writes as
/// "XML Format"): the plan as text, for Project versions, tools and services
/// that do not read `.mpp`.
///
/// Written and read: project settings, base calendars (week, exceptions with
/// their working hours), tasks (outline, duration and its units, constraints,
/// deadline, manual scheduling, progress, notes, Text1–Text30, baseline 0–10),
/// links (type, lag and its units), resources, and assignments.
public enum MSPDI {
    // MARK: Writing

    public static func data(_ p: Project) -> Data {
        var x = XMLOut()
        x.raw("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n")
        x.open("Project", attrs: "xmlns=\"http://schemas.microsoft.com/project\"")
        x.leaf("SaveVersion", "14")
        x.leaf("Name", p.title)
        x.leaf("Title", p.title)
        if let v = p.author { x.leaf("Author", v) }
        if let v = p.company { x.leaf("Company", v) }
        if let v = p.manager { x.leaf("Manager", v) }
        x.leaf("ScheduleFromStart", "1")
        x.leaf("StartDate", date(p.start))
        if let f = p.finish ?? p.tasks.compactMap(\.finish).max() { x.leaf("FinishDate", date(f)) }
        x.leaf("CalendarUID", "1")
        x.leaf("DefaultStartTime", clock(p.defaultStartTime))
        x.leaf("DefaultFinishTime", clock(p.defaultFinishTime))
        x.leaf("MinutesPerDay", "\(p.minutesPerDay)")
        x.leaf("MinutesPerWeek", "\(p.minutesPerWeek)")
        x.leaf("DaysPerMonth", "\(p.daysPerMonth)")
        if let s = p.statusDate { x.leaf("StatusDate", date(s)) }
        if let c = p.currencySymbol { x.leaf("CurrencySymbol", c) }

        // Text field names.
        let aliases = p.fieldAliases.compactMap { key, name -> (Int, String)? in
            guard key.lowercased().hasPrefix("text"), let n = Int(key.dropFirst(4)), let id = textFieldID(n) else { return nil }
            return (id, name)
        }.sorted { $0.0 < $1.0 }
        if !aliases.isEmpty {
            x.open("ExtendedAttributes")
            for (id, name) in aliases {
                x.open("ExtendedAttribute")
                x.leaf("FieldID", "\(id)")
                x.leaf("FieldName", "Text\(textNumber(id) ?? 0)")
                x.leaf("Alias", name)
                x.close("ExtendedAttribute")
            }
            x.close("ExtendedAttributes")
        }

        // Calendars: the project's as uid 1, then the other base calendars.
        var calendarUIDs: [String: Int] = [:]
        x.open("Calendars")
        let base = [p.calendar ?? ProjectCalendar()] + p.calendars.filter { $0.name != (p.calendar?.name ?? "Standard") }
        for (i, cal) in base.enumerated() {
            calendarUIDs[cal.name] = i + 1
            writeCalendar(cal, uid: i + 1, to: &x)
        }
        x.close("Calendars")

        x.open("Tasks")
        let summaries = Set(p.tasks.map(\.parentUID))
        for t in p.tasks {
            x.open("Task")
            x.leaf("UID", "\(t.uid)")
            x.leaf("ID", "\(t.rowID)")
            x.leaf("Name", t.name)
            x.leaf("Manual", t.manual ? "1" : "0")
            x.leaf("OutlineLevel", "\(t.outlineLevel)")
            if let w = t.wbs { x.leaf("WBS", w) }
            x.leaf("Priority", "\(t.priority)")
            if let s = t.start { x.leaf("Start", date(s)) }
            if let f = t.finish { x.leaf("Finish", date(f)) }
            x.leaf("Duration", duration(minutes: Int((t.durationDays * Double(p.minutesPerDay)).rounded())))
            x.leaf("DurationFormat", "\(unitCode(t.durationUnits) + (t.estimated ? 32 : 0))")
            x.leaf("Estimated", t.estimated ? "1" : "0")
            x.leaf("Milestone", t.milestone || t.durationDays == 0 ? "1" : "0")
            x.leaf("Summary", summaries.contains(t.uid) ? "1" : "0")
            x.leaf("PercentComplete", "\(t.percentComplete)")
            if let a = t.actualStart { x.leaf("ActualStart", date(a)) }
            if let a = t.actualFinish { x.leaf("ActualFinish", date(a)) }
            x.leaf("ConstraintType", "\(constraintCode(t.constraint))")
            if let d = t.constraintDate { x.leaf("ConstraintDate", date(d)) }
            if let d = t.deadline { x.leaf("Deadline", date(d)) }
            if let c = t.calendar, let uid = calendarUIDs[c] { x.leaf("CalendarUID", "\(uid)") }
            x.leaf("Type", "\(["fixed_units": 0, "fixed_duration": 1, "fixed_work": 2][t.taskType] ?? 0)")
            x.leaf("EffortDriven", t.effortDriven ? "1" : "0")
            if !t.notes.isEmpty { x.leaf("Notes", t.notes) }
            for r in p.relations where r.succUID == t.uid {
                x.open("PredecessorLink")
                x.leaf("PredecessorUID", "\(r.predUID)")
                x.leaf("Type", "\(["FF": 0, "FS": 1, "SF": 2, "SS": 3][r.type] ?? 1)")
                let lag = r.lagIsPercent ? Int((r.lagDays * 10_000).rounded())
                                         : Int((r.lagDays * Double(p.minutesPerDay) * 10).rounded())
                x.leaf("LinkLag", "\(lag)")
                x.leaf("LagFormat", "\(unitCode(r.lagUnits))")
                x.close("PredecessorLink")
            }
            for (n, v) in t.text.sorted(by: { $0.key < $1.key }) {
                guard let id = textFieldID(n) else { continue }
                x.open("ExtendedAttribute")
                x.leaf("FieldID", "\(id)")
                x.leaf("Value", v)
                x.close("ExtendedAttribute")
            }
            for (n, b) in t.baselines.projectSlots.sorted(by: { $0.key < $1.key }) {
                x.open("Baseline")
                x.leaf("Number", "\(n)")
                if let s = b.start { x.leaf("Start", date(s)) }
                if let f = b.finish { x.leaf("Finish", date(f)) }
                x.leaf("Duration", duration(minutes: Int((b.durationDays * Double(p.minutesPerDay)).rounded())))
                x.leaf("Work", duration(minutes: Int((b.workHours * 60).rounded())))
                x.close("Baseline")
            }
            x.close("Task")
        }
        x.close("Tasks")

        x.open("Resources")
        for (i, r) in p.resources.enumerated() {
            x.open("Resource")
            x.leaf("UID", "\(r.uid)")
            x.leaf("ID", "\(r.rowID == 0 ? i + 1 : r.rowID)")
            x.leaf("Name", r.name)
            x.leaf("Type", r.type == "material" ? "0" : (r.type == "cost" ? "2" : "1"))
            if !r.initials.isEmpty { x.leaf("Initials", r.initials) }
            if !r.email.isEmpty { x.leaf("EmailAddress", r.email) }
            if !r.group.isEmpty { x.leaf("Group", r.group) }
            x.leaf("MaxUnits", String(format: "%.2f", r.maxUnits))
            x.close("Resource")
        }
        x.close("Resources")

        x.open("Assignments")
        for (i, a) in p.assignments.enumerated() {
            x.open("Assignment")
            x.leaf("UID", "\(a.uid == 0 ? i + 1 : a.uid)")
            x.leaf("TaskUID", "\(a.taskUID)")
            x.leaf("ResourceUID", "\(a.resourceUID)")
            x.leaf("Units", String(format: "%.2f", a.units))
            let hours = a.workHours > 0 ? a.workHours
                : (p.task(uid: a.taskUID).map { $0.durationDays * Double(p.minutesPerDay) / 60 * a.units } ?? 0)
            x.leaf("Work", duration(minutes: Int((hours * 60).rounded())))
            x.close("Assignment")
        }
        x.close("Assignments")
        x.close("Project")
        return Data(x.text.utf8)
    }

    private static func writeCalendar(_ cal: ProjectCalendar, uid: Int, to x: inout XMLOut) {
        x.open("Calendar")
        x.leaf("UID", "\(uid)")
        x.leaf("Name", cal.name)
        x.leaf("IsBaseCalendar", "1")
        x.leaf("BaseCalendarUID", "-1")
        x.open("WeekDays")
        for day in 1...7 {
            let ranges = cal.workingRanges(weekday: day)
            x.open("WeekDay")
            x.leaf("DayType", "\(day)")
            x.leaf("DayWorking", ranges.isEmpty ? "0" : "1")
            if !ranges.isEmpty { writeTimes(ranges, to: &x) }
            x.close("WeekDay")
        }
        x.close("WeekDays")
        if !cal.exceptions.isEmpty {
            x.open("Exceptions")
            for e in cal.exceptions {
                x.open("Exception")
                x.leaf("EnteredByOccurrences", "0")
                x.open("TimePeriod")
                x.leaf("FromDate", date(e.start))
                x.leaf("ToDate", date(e.lastDay.addingTimeInterval(86_340)))
                x.close("TimePeriod")
                x.leaf("Occurrences", "1")
                x.leaf("Name", e.name)
                x.leaf("Type", "1")
                x.leaf("DayWorking", e.isNonWorking ? "0" : "1")
                if !e.isNonWorking { writeTimes(e.working, to: &x) }
                x.close("Exception")
            }
            x.close("Exceptions")
        }
        x.close("Calendar")
    }

    private static func writeTimes(_ ranges: [ClosedRange<Int>], to x: inout XMLOut) {
        x.open("WorkingTimes")
        for r in ranges {
            x.open("WorkingTime")
            x.leaf("FromTime", clock(r.lowerBound) + ":00")
            x.leaf("ToTime", clock(r.upperBound % 1_440) + ":00")
            x.close("WorkingTime")
        }
        x.close("WorkingTimes")
    }

    // MARK: Reading

    public enum Failure: Error { case notMSPDI }

    public static func project(from data: Data) throws -> Project {
        let tree = try XMLTree.parse(data)
        guard tree.name == "Project" else { throw Failure.notMSPDI }
        func dateOf(_ s: String?) -> Date? { s.flatMap(parseDate) }
        let start = dateOf(tree["StartDate"]) ?? Date()
        var p = Project(title: tree["Name"] ?? tree["Title"] ?? "Project", start: start)
        p.author = tree["Author"]
        p.company = tree["Company"]
        p.manager = tree["Manager"]
        p.finish = dateOf(tree["FinishDate"])
        p.statusDate = dateOf(tree["StatusDate"])
        if let v = tree["MinutesPerDay"].flatMap(Int.init), v > 0 { p.minutesPerDay = v }
        if let v = tree["MinutesPerWeek"].flatMap(Int.init), v > 0 { p.minutesPerWeek = v }
        if let v = tree["DaysPerMonth"].flatMap(Int.init), v > 0 { p.daysPerMonth = v }
        if let v = tree["DefaultStartTime"].flatMap(parseClock) { p.defaultStartTime = v }
        if let v = tree["DefaultFinishTime"].flatMap(parseClock) { p.defaultFinishTime = v }
        p.currencySymbol = tree["CurrencySymbol"]
        for a in tree.child("ExtendedAttributes")?.children("ExtendedAttribute") ?? [] {
            if let id = a["FieldID"].flatMap(Int.init), let n = textNumber(id), let alias = a["Alias"], !alias.isEmpty {
                p.fieldAliases["text\(n)"] = alias
            }
        }

        // Calendars.
        var calendarNames: [Int: String] = [:]
        let projectCalendarUID = tree["CalendarUID"].flatMap(Int.init) ?? 1
        for c in tree.child("Calendars")?.children("Calendar") ?? [] {
            guard c["IsBaseCalendar"] == "1", let uid = c["UID"].flatMap(Int.init) else { continue }
            var cal = ProjectCalendar(name: c["Name"] ?? "Calendar \(uid)")
            for d in c.child("WeekDays")?.children("WeekDay") ?? [] {
                guard let type = d["DayType"].flatMap(Int.init) else { continue }
                if type == 0 {
                    // Type 0 is an exception in Project 2003's layout.
                    if let e = exception(from: d) { cal.exceptions.append(e) }
                    continue
                }
                let times = workingTimes(d)
                cal.week[type] = d["DayWorking"] == "1" && !times.isEmpty ? times : .some(nil)
            }
            for e in c.child("Exceptions")?.children("Exception") ?? [] {
                if let x = exception(from: e) { cal.exceptions.append(x) }
            }
            calendarNames[uid] = cal.name
            if uid == projectCalendarUID { p.calendar = cal } else { p.calendars.append(cal) }
        }
        if p.calendar == nil { p.calendar = ProjectCalendar(name: "Standard") }

        // Tasks; the project summary (UID 0) is the project itself.
        for t in tree.child("Tasks")?.children("Task") ?? [] {
            guard let uid = t["UID"].flatMap(Int.init), uid != 0, t["IsNull"] != "1" else { continue }
            var task = ProjectTask(uid: uid, name: t["Name"] ?? "", start: dateOf(t["Start"]), finish: dateOf(t["Finish"]))
            task.rowID = t["ID"].flatMap(Int.init) ?? 0
            task.outlineLevel = t["OutlineLevel"].flatMap(Int.init) ?? 1
            task.wbs = t["WBS"]
            task.priority = t["Priority"].flatMap(Int.init) ?? 500
            task.manual = t["Manual"] == "1"
            let format = t["DurationFormat"].flatMap(Int.init) ?? 7
            task.estimated = t["Estimated"] == "1" || format >= 32
            task.durationUnits = unitLabel(format % 32 == 0 ? 7 : format % 32) ?? "d"
            if let m = t["Duration"].flatMap(parseDuration) { task.durationDays = Double(m) / Double(p.minutesPerDay) }
            task.milestone = t["Milestone"] == "1"
            task.percentComplete = t["PercentComplete"].flatMap(Int.init) ?? 0
            task.actualStart = dateOf(t["ActualStart"])
            task.actualFinish = dateOf(t["ActualFinish"])
            let constraint = constraintLabel(t["ConstraintType"].flatMap(Int.init) ?? 0)
            task.constraint = constraint == "ASAP" ? nil : constraint
            task.constraintDate = dateOf(t["ConstraintDate"])
            task.deadline = dateOf(t["Deadline"])
            if let c = t["CalendarUID"].flatMap(Int.init), c >= 0 { task.calendar = calendarNames[c] }
            task.taskType = ["0": "fixed_units", "1": "fixed_duration", "2": "fixed_work"][t["Type"] ?? "0"] ?? "fixed_units"
            task.effortDriven = t["EffortDriven"] == "1"
            task.notes = t["Notes"] ?? ""
            for a in t.children("ExtendedAttribute") {
                if let id = a["FieldID"].flatMap(Int.init), let n = textNumber(id), let v = a["Value"] { task.text[n] = v }
            }
            for b in t.children("Baseline") {
                guard let n = b["Number"].flatMap(Int.init), (0...10).contains(n) else { continue }
                task.baselines[n] = Baseline(start: dateOf(b["Start"]), finish: dateOf(b["Finish"]),
                                             durationDays: Double(b["Duration"].flatMap(parseDuration) ?? 0) / Double(p.minutesPerDay),
                                             workHours: Double(b["Work"].flatMap(parseDuration) ?? 0) / 60)
            }
            for l in t.children("PredecessorLink") {
                guard let pred = l["PredecessorUID"].flatMap(Int.init) else { continue }
                let type = ["0": "FF", "1": "FS", "2": "SF", "3": "SS"][l["Type"] ?? "1"] ?? "FS"
                let units = unitLabel(l["LagFormat"].flatMap(Int.init) ?? 7) ?? "d"
                let raw = Double(l["LinkLag"].flatMap(Int.init) ?? 0)
                let lag = units.hasSuffix("%") ? raw / 10_000 : raw / 10 / Double(p.minutesPerDay)
                p.relations.append(Relation(predUID: pred, succUID: uid, type: type, lagDays: lag, lagUnits: units))
            }
            p.tasks.append(task)
        }
        p.normalizeOutline()

        for r in tree.child("Resources")?.children("Resource") ?? [] {
            guard let uid = r["UID"].flatMap(Int.init), uid != 0, let name = r["Name"], !name.isEmpty else { continue }
            var res = Resource(uid: uid, name: name)
            res.rowID = r["ID"].flatMap(Int.init) ?? 0
            res.initials = r["Initials"] ?? ""
            res.email = r["EmailAddress"] ?? ""
            res.group = r["Group"] ?? ""
            res.type = ["0": "material", "1": "work", "2": "cost"][r["Type"] ?? "1"] ?? "work"
            res.maxUnits = r["MaxUnits"].flatMap(Double.init) ?? 1
            p.resources.append(res)
        }
        let taskUIDs = Set(p.tasks.map(\.uid)), resourceUIDs = Set(p.resources.map(\.uid))
        for a in tree.child("Assignments")?.children("Assignment") ?? [] {
            guard let t = a["TaskUID"].flatMap(Int.init), let r = a["ResourceUID"].flatMap(Int.init),
                  taskUIDs.contains(t), resourceUIDs.contains(r) else { continue }
            var asg = Assignment(taskUID: t, resourceUID: r)
            asg.uid = a["UID"].flatMap(Int.init) ?? 0
            asg.units = a["Units"].flatMap(Double.init) ?? 1
            asg.workHours = Double(a["Work"].flatMap(parseDuration) ?? 0) / 60
            p.assignments.append(asg)
        }
        p.relations.removeAll { !taskUIDs.contains($0.predUID) || !taskUIDs.contains($0.succUID) }
        p.inferSplitGaps()
        return p
    }

    private static func workingTimes(_ node: XMLTree) -> [ClosedRange<Int>] {
        (node.child("WorkingTimes")?.children("WorkingTime") ?? []).compactMap { w in
            guard let a = w["FromTime"].flatMap(parseClock), var b = w["ToTime"].flatMap(parseClock) else { return nil }
            if b <= a { b += 1_440 }   // 00:00 as an end means midnight
            return a...b
        }
    }

    private static func exception(from node: XMLTree) -> CalendarException? {
        guard let period = node.child("TimePeriod"), let from = period["FromDate"].flatMap(parseDate),
              let to = period["ToDate"].flatMap(parseDate) else { return nil }
        let first = MPPTime.startOfDay(from), last = MPPTime.startOfDay(to)
        let hours = node["DayWorking"] == "1" ? workingTimes(node) : []
        return CalendarException(start: first, finish: last == first ? nil : last, name: node["Name"] ?? "", working: hours)
    }

    // MARK: Values

    private static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    static func date(_ d: Date) -> String { iso.string(from: d) }
    static func parseDate(_ s: String) -> Date? { iso.date(from: String(s.prefix(19))) }
    static func clock(_ minutes: Int) -> String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }
    static func parseClock(_ s: String) -> Int? {
        let parts = s.split(separator: ":").compactMap { Int($0) }
        return parts.count >= 2 ? parts[0] * 60 + parts[1] : nil
    }

    /// `PT8H0M0S`, working (or elapsed) time.
    static func duration(minutes: Int) -> String {
        let m = abs(minutes)
        return "\(minutes < 0 ? "-" : "")PT\(m / 60)H\(m % 60)M0S"
    }

    static func parseDuration(_ s: String) -> Int? {
        var rest = Substring(s), sign = 1
        if rest.hasPrefix("-") { sign = -1; rest = rest.dropFirst() }
        guard rest.hasPrefix("PT") else { return nil }
        rest = rest.dropFirst(2)
        var minutes = 0.0, number = ""
        for ch in rest {
            if ch.isNumber || ch == "." { number.append(ch); continue }
            let v = Double(number) ?? 0
            switch ch {
            case "H": minutes += v * 60
            case "M": minutes += v
            case "S": minutes += v / 60
            default: break
            }
            number = ""
        }
        return sign * Int(minutes.rounded())
    }

    static func unitCode(_ label: String) -> Int {
        ["m": 3, "em": 4, "h": 5, "eh": 6, "d": 7, "ed": 8, "w": 9, "ew": 10, "mo": 11, "emo": 12, "%": 19, "e%": 20][label] ?? 7
    }
    static func unitLabel(_ code: Int) -> String? {
        [3: "m", 4: "em", 5: "h", 6: "eh", 7: "d", 8: "ed", 9: "w", 10: "ew", 11: "mo", 12: "emo", 19: "%", 20: "e%",
         35: "m", 36: "em", 37: "h", 38: "eh", 39: "d", 40: "ed", 41: "w", 42: "ew", 43: "mo", 44: "emo"][code]
    }
    static func constraintCode(_ c: String?) -> Int {
        ["ASAP": 0, "ALAP": 1, "MSO": 2, "MFO": 3, "SNET": 4, "SNLT": 5, "FNET": 6, "FNLT": 7][c ?? "ASAP"] ?? 0
    }
    static func constraintLabel(_ code: Int) -> String {
        ["ASAP", "ALAP", "MSO", "MFO", "SNET", "SNLT", "FNET", "FNLT"][min(max(code, 0), 7)]
    }

    /// Project's field ids for Text1...Text30 (`pjTaskText1` …).
    static let textFieldIDs: [Int] = [188_743_731, 188_743_734, 188_743_737, 188_743_740, 188_743_743,
                                      188_743_746, 188_743_747, 188_743_748, 188_743_749, 188_743_750]
        + (0..<20).map { 188_743_997 + $0 }
    static func textFieldID(_ n: Int) -> Int? { (1...30).contains(n) ? textFieldIDs[n - 1] : nil }
    static func textNumber(_ id: Int) -> Int? { textFieldIDs.firstIndex(of: id).map { $0 + 1 } }
}

// MARK: - XML plumbing

private struct XMLOut {
    var text = ""
    private var depth = 0
    mutating func raw(_ s: String) { text += s }
    mutating func open(_ tag: String, attrs: String = "") {
        text += String(repeating: "  ", count: depth) + "<\(tag)\(attrs.isEmpty ? "" : " " + attrs)>\n"
        depth += 1
    }
    mutating func close(_ tag: String) {
        depth -= 1
        text += String(repeating: "  ", count: depth) + "</\(tag)>\n"
    }
    mutating func leaf(_ tag: String, _ value: String) {
        text += String(repeating: "  ", count: depth) + "<\(tag)>\(Self.escape(value))</\(tag)>\n"
    }
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// A small DOM over Foundation's streaming parser: enough for MSPDI.
final class XMLTree {
    let name: String
    var text = ""
    private(set) var kids: [XMLTree] = []
    init(name: String) { self.name = name }

    func child(_ name: String) -> XMLTree? { kids.first { $0.name == name } }
    func children(_ name: String) -> [XMLTree] { kids.filter { $0.name == name } }
    /// The text of a direct child element: a leaf's exactly (a task name may
    /// end in a space), an element with children's trimmed of the layout.
    subscript(_ name: String) -> String? {
        child(name).map { $0.kids.isEmpty ? $0.text : $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    static func parse(_ data: Data) throws -> XMLTree {
        let delegate = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else {
            throw parser.parserError ?? MSPDI.Failure.notMSPDI
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLTree?
        var stack: [XMLTree] = []
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let node = XMLTree(name: name)
            stack.last?.kids.append(node)
            if root == nil { root = node }
            stack.append(node)
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            stack.removeLast()
        }
    }
}
