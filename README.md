# MPPKit

[![CI](https://github.com/hpetersen/MPPKit/actions/workflows/ci.yml/badge.svg)](https://github.com/hpetersen/MPPKit/actions/workflows/ci.yml)
[![CodeQL](https://github.com/hpetersen/MPPKit/actions/workflows/codeql.yml/badge.svg)](https://github.com/hpetersen/MPPKit/actions/workflows/codeql.yml)
[![License: GPL v3](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

Native Swift reading **and writing** of Microsoft Project `.mpp` files, for
macOS and iPadOS. No JVM, no .NET, no Microsoft Project on the
machine.

MPPKit is the file-format layer of [MPP Studio](https://mppstudio.com), a
Microsoft Project companion for Mac and iPad, and is published under the
[GNU GPL v3](LICENSE).

## Status

| | |
|---|---|
| Reader | Working. Field-for-field identical to MPXJ on a real Microsoft 365 file (200 tasks, 213 links, 11 calendars) and on every file the writer produces. |
| Writer | Working, template-based. Output reads back field-for-field identical in MPPKit **and** in MPXJ, an independent reader. |
| Opened in Microsoft Project | **Verified** in Project Professional (Microsoft 365): the sample opens with outline, dates, durations, units, links, calendars, progress and Gantt as written, and Project's own recalculation matches `Scheduler`'s dates. |

## Why this exists

`.mpp` is the only major legacy Office format with **no published Microsoft
specification**. There is no Swift or Objective-C library for it anywhere — the
Apple-platform apps that read `.mpp` all ship closed-source parsers.

`.mpp` is also not one format but four: MPP8 (Project 98), MPP9 (2000/2002),
MPP12 (2003/2007) and MPP14 (2010 through Microsoft 365). **This package targets
MPP14**, which covers essentially every file in circulation.

## Design

Nothing is hard-coded per Project version. Microsoft Project **reorders the field
map every time it saves**, so two files from the same Project build lay their
records out differently. Accordingly:

- record offsets come from the file's own `Props` field maps;
- fixed-record item sizes are derived from the stream's own header counts;
- flags are read from the file's own meta bitmaps, indexed by the field map;
- durations are read against the file's own *minutes per day*.

### Writing is template-and-patch

A Project file carries ~170 KB of view, table, filter and Gantt-bar definitions
that Project insists on and nobody has specified. `MPP14Writer` therefore starts
from a file Project itself saved, keeps every stream it does not own
byte-for-byte, and rebuilds the task, link, resource, assignment and calendar
tables by cloning the template's own records and patching the fields it
controls.

Any Project-saved file can be the template. The writer never carries the
template's tasks, resources, assignments, links or resource calendars over, and
strips per-record data (notes, custom fields, baselines) from the records it
clones. `MPP14Template.neutralized` additionally replaces what a real schedule
keeps elsewhere — custom-field aliases and lookup values, extra calendars and
their holidays, saved paths, document properties — and
`MPP14Template.makeBlank` turns any file into a clean, reusable template.

## Modules

| Target | Purpose |
|---|---|
| `MPPCFB` | MS-CFB/OLE2 container: reader and writer, OLE property sets |
| `MPPModel` | Format-independent model, working-time arithmetic, scheduler |
| `MPP14` | MPP14 reader, writer, calendar codec, template tools |
| `MPPGantt` | Gantt geometry, spatial index and timescale, with no UI framework |
| `MPPKit` | Umbrella module re-exporting the four above, plus `SampleProject` |
| `mppdump` | Inspection CLI; writes the sample and blank templates |

## Installation

Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/hpetersen/MPPKit.git", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: ["MPPKit"]),
]
```

## Usage

```swift
import MPPKit

// Read
let project = try MPP14File(path: "plan.mpp").readProject()
for task in project.tasks {          // outline (ID) order
    print(task.rowID, task.name, task.durationDays, task.start.map(MPPTime.iso) ?? "-")
}

// Edit and write
var p = project
p.tasks[1].name = "Renamed"
try Scheduler.schedule(&p)           // recompute dates after edits
let writer = try MPP14Writer(templateURL: URL(fileURLWithPath: "Samples/Blank-Template.mpp"))
try writer.write(p, to: URL(fileURLWithPath: "plan-edited.mpp"))
```

The model's task type is `ProjectTask`, not `Task`, so it never collides with
Swift Concurrency's `Task` in app code.

### Dates are wall-clock

`.mpp` stores dates as a day count plus tenths of a minute with **no timezone** —
a 07:00 start means 07:00 wherever the file is opened. `MPPTime` converts through
a UTC calendar so wall-clock values round-trip exactly; build dates with
`MPPTime.date(2026, 3, 2, 8)`.

### Durations are project days

`durationDays` and `lagDays` are in days of `Project.minutesPerDay` — the
file's own setting, as Project displays them. On disk everything is tenths of a
minute.

## What is supported

Read and written:

- tasks: outline to any depth, summaries, milestones (including flagged ones
  with a duration), durations in m/h/d/w/mo and elapsed em/eh/ed/ew/emo,
  estimated durations, manual
  scheduling, all eight constraints, deadlines, priority, task type, effort
  driven, percent complete with actuals, task calendars, notes (RTF), custom WBS,
  Text1–30, Number1–20, Date1–10, Flag1–20, baselines 0–10;
- links: FS, SS, FF, SF with lags and leads in any unit — working, elapsed or a
  percentage of the predecessor — and links on summary tasks;
- work resources with max units, initials, e-mail and their own calendars;
  assignments with units, work and progress;
- calendars: Standard edits, holidays and exceptions with their own working
  hours, any number of base calendars;
- project: title, start/finish, status date, currency, minutes per day/week,
  days per month, default start/finish times, document properties.

Read only: custom-field lookup values (resolved to their text).

Also: Microsoft Project XML (MSPDI) export and import (`MSPDI`), with the same
fields, for tools and Project versions that do not read `.mpp`. Files from
Project 2007 and earlier are recognised and refused with a clear message
(`MPPError.olderFormat`).

Not yet supported: cost and rates, material and cost resources, outline codes,
hyperlinks, recurring tasks, blank task-sheet rows, inserted subprojects, and
timephased assignment contours beyond flat. Split tasks are read as their idle
time (`splitMinutes`, kept by the scheduler) rather than as individual splits.

Two things Project enforces that the writer does not check:

- A custom field with a value list (common on Text1–3 in real templates) only
  shows entries from that list; plain text written to it appears blank.
- A task whose own calendar shares no working time with its resources'
  calendars during the task collapses to zero duration when Project
  recalculates.

`Scheduler` is a critical-path scheduler: a forward pass for early dates, a
backward pass for late dates, and as-late-as-possible tasks placed at their
late dates. Float and the critical path follow Project (`Float.swift`): total
float is the smaller of start and finish float **in working time** on the
task's calendar, and a task is critical at float ≤ 0 — negative float from a
missed deadline included. Progress follows Project too: finished work has no
float and holds nothing back; work under way has its late start at its actual
start, float only at its finish, and holds its predecessors only to where its
own work has reached. It leaves `SNLT`/`FNLT` conflicts to Project and does no
resource levelling or effort-driven scheduling.

### Against Project's own results

`mppdump schedcheck <file.mpp>` reschedules a Project-saved file and compares
every task's dates, late dates and the critical path with what Project stored
(`SCHEDCHECK_LIST=n` lists differences, `SCHEDCHECK_ROW=<id>` traces one task
and its successors). `SchedulingTests.testScheduleMatchesProjectOnSavedFiles`
asserts the same over `Fixtures/` and any files listed in
`MPPKIT_REFERENCE_LIST`. On 24 real plans saved by Project, dates match on 20
and the critical path on most; the remaining differences are plans rescheduled
against a status date, a file with tasks past the project finish, and the late
dates of some summary rows. Only use files Project saved last: a file saved by
MPP Studio carries MPPKit's own late dates.

`mppdump schedbench <file.mpp | synthN>` times the scheduler: about 9 ms for
2 000 tasks and 46 ms for 10 000 (release build).

## The sample project

`Samples/MPPKit-Feature-Sample.mpp` exercises every feature above (see
`SampleProject.swift` for the map of feature → task). It contains no real
project data and is safe to share. `Samples/Blank-Template.mpp` is a clean
writer template. Regenerate both from any Project-saved file:

```
swift run mppdump sample   <any.mpp> Samples/MPPKit-Feature-Sample.mpp
swift run mppdump template <any.mpp> Samples/Blank-Template.mpp
```

## The `mppdump` CLI

```
swift run mppdump tree      <file.mpp>   # container tree with stream sizes
swift run mppdump props     <file.mpp>   # Props keys, sizes, type codes
swift run mppdump fieldmap  <file.mpp>   # per-entry block / offset / category
swift run mppdump meta      <file.mpp>   # item sizes and record counts
swift run mppdump tasks     <file.mpp>
swift run mppdump resources <file.mpp>
swift run mppdump relations <file.mpp>
swift run mppdump calendars <file.mpp>
swift run mppdump strings   <file.mpp>   # readable text per stream: what a file carries
swift run mppdump json      <file.mpp>   # the whole parsed project
swift run mppdump xml       <file.mpp> <out.xml>   # Microsoft Project XML
swift run mppdump schedcheck <file.mpp>  # MPPKit's schedule vs Project's saved one
swift run mppdump schedbench <file.mpp|synth5000>  # scheduler timing
swift run mppdump synthfile <template.mpp> <out.mpp> 5000   # a large test plan
```

`tree`, `props` and `fieldmap` are how a **new** Project release gets diagnosed:
they show the structures the file publishes about itself, which is exactly what
the parser keys off.

## Building and testing

```sh
swift build            # add --disable-sandbox if SwiftPM cannot nest a sandbox
swift test
```

Model, scheduler, calendar-codec, notes and container tests need nothing. The
reader and writer tests run against any `.mpp` dropped into `Fixtures/`
(git-ignored, since real files embed the author's name and machine path) and
skip cleanly when none is present. With a fixture they check, among other
things, that the sample round-trips every field, that nothing from the template
leaks into written files, and that the neutraliser only ever rewrites text in
structures it does not rebuild.

### Independent check against MPXJ

`Tools/mpxj-oracle/oracle.sh <file.mpp>` diffs MPPKit's reading of a file
against MPXJ's, field by field. It needs a JRE and a venv with
`pip install mpxj jpype1`; see the script header. MPXJ is LGPL and runs only as
an external tool here — it is never linked.

### Continuous integration

Every pull request and every push to `main` runs, on GitHub's macOS runners:

- `swift build` (warnings are errors) and `swift test` on the current and the
  previous macOS image, once per file in `Samples/`, so the fixture-based reader
  and writer tests run instead of skipping;
- a build of `MPPKit` for iPadOS;
- the MPXJ oracle on every sample and on files the writer produces in the same
  run (the feature sample, a blank template and a 500-task synthetic plan),
  failing on any difference;
- a licence-header check and CodeQL.

`main` only accepts pull requests whose checks all pass. Pushing a version tag
such as `0.2.0` on `main` reruns CI and publishes a GitHub release.

## Used in MPP Studio

[MPP Studio](https://mppstudio.com) is built on MPPKit: it opens, edits and
saves `.mpp` files on Mac and iPad, with a Gantt chart, a locked plan and daily
progress against it. If you need `.mpp` files on a Mac or an iPad rather than a
library, that is the place to start.

## Licence

MPPKit is free software, released under the
[GNU General Public License version 3](LICENSE) (`GPL-3.0-only`).
Copyright © 2026 Henrik Petersen.

You may use, change and share it under the terms of the GPL. In short, if you
distribute software that includes MPPKit, that software must also be released
under the GPL with its source code.

## Contributing

Bug reports are very welcome, above all `.mpp` files that MPPKit reads or
writes wrongly. See [CONTRIBUTING.md](CONTRIBUTING.md), including how to share
a file without sharing its contents.

## Attribution

The MPP14 format knowledge here is a Swift port of the MIT-licensed
[pymppwriter](https://github.com/kevinmcaleer/pymppwriter) reverse engineering.
See `THIRD_PARTY_NOTICES.md` for the full breakdown of what came from where,
including why LGPL MPXJ was used only as a behavioural oracle.
