// MPPKit: Microsoft Project (.mpp) files in Swift
// Copyright (C) 2026 Henrik Petersen
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Affero General Public License version 3 as
// published by the Free Software Foundation. It is distributed WITHOUT ANY
// WARRANTY; see the LICENSE file for details. https://mppstudio.com
//
// SPDX-License-Identifier: AGPL-3.0-only

// Labels need localized date formatting (full Foundation): not in the
// WebAssembly build, which labels its timescale in the browser.
#if !os(WASI)
#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif
import MPPModel

/// The two-tier timescale above a Gantt chart, adapted to the zoom.
public struct Timescale: Sendable {
    public enum Unit: Sendable { case day, week, month, quarter, year }

    public struct Tick: Sendable, Equatable {
        /// World x (minutes since the layout epoch) where the unit starts.
        public let x: Double
        public let label: String
    }

    public let major: Unit
    public let minor: Unit
    public let top: [Tick]
    public let bottom: [Tick]

    /// - Parameters:
    ///   - visible: the world x range on screen.
    ///   - pointsPerMinute: the zoom.
    public init(epoch: Date, visible: Range<Double>, pointsPerMinute: Double, locale: Locale = .current) {
        let perDay = pointsPerMinute * 1_440
        switch perDay {
        case 60...: (major, minor) = (.week, .day)
        case 14..<60: (major, minor) = (.month, .week)
        case 2.5..<14: (major, minor) = (.year, .month)
        default: (major, minor) = (.year, .quarter)
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        cal.firstWeekday = 2                  // ISO weeks: Monday
        cal.minimumDaysInFirstWeek = 4
        cal.locale = locale

        func ticks(_ unit: Unit, _ label: (Date) -> String) -> [Tick] {
            let from = epoch.addingTimeInterval(visible.lowerBound * 60)
            let to = epoch.addingTimeInterval(visible.upperBound * 60)
            var d = Self.floor(from, unit, cal)
            var out: [Tick] = []
            while d < to, out.count < 2_000 {
                out.append(Tick(x: d.timeIntervalSince(epoch) / 60, label: label(d)))
                d = Self.next(d, unit, cal)
            }
            return out
        }

        let utc = TimeZone(secondsFromGMT: 0)!
        func format(_ style: Date.FormatStyle) -> (Date) -> String {
            var s = style
            s.timeZone = utc
            s = s.locale(locale)
            return { $0.formatted(s) }
        }
        let wide = perDay >= 28
        let topLabel: (Date) -> String
        switch major {
        case .week:
            let f = format(.dateTime.day().month(.abbreviated).year())
            topLabel = { "\(String(localized: "Week")) \(cal.component(.weekOfYear, from: $0)) · \(f($0))" }
        case .month: topLabel = format(.dateTime.month(.wide).year())
        default: topLabel = format(.dateTime.year())
        }
        let bottomLabel: (Date) -> String
        switch minor {
        case .day:
            let wd = format(.dateTime.weekday(.narrow)), dd = format(.dateTime.day())
            bottomLabel = wide ? { "\(wd($0)) \(dd($0))" } : { dd($0) }
        case .week: bottomLabel = format(.dateTime.day())
        case .month: bottomLabel = format(.dateTime.month(.abbreviated))   // ≥ 75 pt per month at this tier
        default: bottomLabel = { "Q\(cal.component(.month, from: $0) / 3 + 1)" }
        }
        top = ticks(major, topLabel)
        bottom = ticks(minor, bottomLabel)
    }

    static func floor(_ d: Date, _ unit: Unit, _ cal: Calendar) -> Date {
        switch unit {
        case .day: return cal.startOfDay(for: d)
        case .week: return cal.dateInterval(of: .weekOfYear, for: d)!.start
        case .month: return cal.dateInterval(of: .month, for: d)!.start
        case .quarter:
            let c = cal.dateComponents([.year, .month], from: d)
            return cal.date(from: DateComponents(year: c.year, month: ((c.month! - 1) / 3) * 3 + 1))!
        case .year: return cal.dateInterval(of: .year, for: d)!.start
        }
    }

    static func next(_ d: Date, _ unit: Unit, _ cal: Calendar) -> Date {
        switch unit {
        case .day: return cal.date(byAdding: .day, value: 1, to: d)!
        case .week: return cal.date(byAdding: .day, value: 7, to: d)!
        case .month: return cal.date(byAdding: .month, value: 1, to: d)!
        case .quarter: return cal.date(byAdding: .month, value: 3, to: d)!
        case .year: return cal.date(byAdding: .year, value: 1, to: d)!
        }
    }
}

#endif
