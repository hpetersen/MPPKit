# Third-party notices

MPPKit is Copyright © 2026 Henrik Petersen and is released under
the GNU General Public License version 3 (see `LICENSE`). It includes code
ported from the project below, which remains under its own MIT licence; the
notice that licence requires is reproduced at the end of its section.

## pymppwriter / mppwriter — MIT

The MPP14 format knowledge in this package is a Swift port of the reverse
engineering published in **pymppwriter** and its TypeScript sibling
**mppwriter**, by Kevin McAleer:

- https://github.com/kevinmcaleer/pymppwriter
- https://www.npmjs.com/package/mppwriter

MIT licensed, so the port is permitted with attribution. What was ported:

| This package | Upstream |
|---|---|
| `Sources/MPPCFB/CFBWriter.swift` | `pymppwriter/cfb.py` (`write_cfb`, `_dir_entry`, `_name_key`, `_build_tree`) |
| `Sources/MPP14/Blocks.swift` | `pymppwriter/blocks.py` |
| `Sources/MPP14/MPP14Reader.swift` | `pymppwriter/reader.py` |
| `Sources/MPP14/MPP14Writer.swift` | `pymppwriter/writer.py` (`MppWriter`, progress contours, view-cache refresh) |
| `Sources/MPP14/CalendarData.swift` | `pymppwriter/blocks.py` (`build_calendar_data`; the parser is the inverse) |
| `Sources/MPPCFB/OLEPropertySet.swift` (`updatingStrings`) | `pymppwriter/blocks.py` (`update_property_set_strings`) |
| `Sources/MPPModel/WorkingTime.swift`, `Scheduler.swift` | scheduling helpers in `pymppwriter/writer.py` |

`Sources/MPPCFB/CFBFile.swift` is **not** a port: upstream delegates container
reading to the third-party `olefile` module, so the reader here was written
against the published Microsoft specification **[MS-CFB]** instead.

### Provenance of the upstream format knowledge

From the upstream project's own notes, its `docs/FORMAT_NOTES.md` was produced
dirty-room from three sources:

1. the public **[MS-CFB]** specification,
2. the *observable behaviour* of the LGPL MPXJ reader (used as an oracle — its
   source was not consulted),
3. byte-diffing files saved by Microsoft Project.

`MPP14Writer.encodeRTFNotes` reimplements `encode_rtf_notes` from the same
upstream project. `MPP14File.decodeRTFNotes` is now an independent RTF reader.

Where this package departs from upstream, the reason is evidence from a
Project-written Microsoft 365 file, cross-checked against MPXJ's output:
Props key `0x1000003` is the calendar record count; records past a table's
declared count are slack; blank sheet rows are not deleted-record stubs;
custom-field lookup references resolve through `TBkndOutlCode`; and the root
CLSID belongs on the root directory entry, not in the header.

### Upstream licence text

```
MIT License

Copyright (c) Kevin McAleer

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Deliberately not used

**[MPXJ](https://github.com/joniles/mpxj)** — the de facto reference for reading
`.mpp` — is **LGPL-2.1**. It was used only as a behavioural oracle (via the
upstream project's `mpxj_oracle.py`, and here via `Tools/mpxj-oracle`, which runs
it as a separate process on files and compares the results), never as a source
of code. Its licence is
awkward for static linking on Apple platforms, which is part of why this package
is a port of the MIT implementation instead.

**alterion-mpp-parser** (Rust) declares no licence, so it is all rights reserved
and was not consulted.
