# MPPKit: Microsoft Project (.mpp) files in Swift
# Copyright (C) 2026 Henrik Petersen
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License version 3 as published
# by the Free Software Foundation. It is distributed WITHOUT ANY WARRANTY;
# see the LICENSE file for details. https://mppstudio.com
#
# SPDX-License-Identifier: GPL-3.0-only

"""Diff MPXJ's reading of a file (arg 1) against MPPKit's (arg 2)."""
import json, sys
x = json.load(open(sys.argv[1])); m = json.load(open(sys.argv[2]))
mpd = m["minutesPerDay"]; mpw = m["minutesPerWeek"]; dpm = m["daysPerMonth"]
issues = []
def bad(what, a, b): issues.append(f"{what}: MPXJ={a!r} MPPKit={b!r}")
def days(d):
    if d is None: return None
    v, u = d["value"], d["units"]
    f = {"m": 1/mpd, "em": 1/mpd, "h": 60/mpd, "eh": 60/mpd, "d": 1, "ed": 1, "w": mpw/mpd, "ew": mpw/mpd,
         "mo": dpm, "emo": dpm, "%": None}.get(u)
    return None if f is None else v * f
def hours(d):
    if d is None: return 0.0
    v, u = d["value"], d["units"]
    return v * {"m": 1/60, "h": 1, "d": mpd/60, "w": mpw/60}.get(u, 1)
CON = {"AS_SOON_AS_POSSIBLE": None, "AS_LATE_AS_POSSIBLE": "ALAP", "MUST_START_ON": "MSO", "MUST_FINISH_ON": "MFO",
       "START_NO_EARLIER_THAN": "SNET", "START_NO_LATER_THAN": "SNLT", "FINISH_NO_EARLIER_THAN": "FNET",
       "FINISH_NO_LATER_THAN": "FNLT"}
REL = {"FINISH_START": "FS", "START_START": "SS", "FINISH_FINISH": "FF", "START_FINISH": "SF", "FS": "FS", "SS": "SS", "FF": "FF", "SF": "SF"}
for k in ["title", "author", "company", "manager", "subject", "keywords", "comments", "category",
          "currencySymbol", "currencyCode", "statusDate", "start", "defaultCalendar"]:
    a, b = x.get(k), m.get(k)
    if (a or None) != (b or None): bad(k, a, b)
for k in ["minutesPerDay", "minutesPerWeek", "daysPerMonth"]:
    if x[k] != m[k]: bad(k, x[k], m[k])

mt = {t["uid"]: t for t in m["tasks"]}
xt = {t["uid"]: t for t in x["tasks"] if not (t["name"] is None and t["start"] is None)}  # blank sheet rows
if set(mt) != set(xt): bad("task uid set", sorted(set(xt) - set(mt)), sorted(set(mt) - set(xt)))
checked = 0
for uid, a in xt.items():
    b = mt.get(uid)
    if b is None: continue
    checked += 1
    L = f"task {uid} {a['name'][:30]!r}"
    for k in ["name", "outlineLevel", "parentUID", "start", "finish", "estimated", "summary", "manual", "calendar",
              "deadline", "priority", "effortDriven", "id"]:
        if a[k] != b[k] and not (a[k] in (None, "") and b[k] in (None, "")): bad(f"{L} {k}", a[k], b[k])
    if not b["summary"] and a["milestone"] != b["milestone"]: bad(f"{L} milestone", a["milestone"], b["milestone"])
    dd = days(a["duration"])
    if dd is not None and abs(dd - b["durationDays"]) > 1e-3: bad(f"{L} duration days", round(dd, 4), b["durationDays"])
    if CON.get(a["constraint"], a["constraint"]) != b["constraint"]: bad(f"{L} constraint", a["constraint"], b["constraint"])
    if b["constraint"] and a["constraintDate"] != b["constraintDate"]: bad(f"{L} constraint date", a["constraintDate"], b["constraintDate"])
    if a["type"] and a["type"].lower() != b["taskType"]: bad(f"{L} type", a["type"], b["taskType"])
    if round(a["percentComplete"] or 0) != b["percentComplete"]: bad(f"{L} % complete", a["percentComplete"], b["percentComplete"])
    for k in ["actualStart", "actualFinish"]:
        if a[k] != b[k]: bad(f"{L} {k}", a[k], b[k])
    if (a["notes"] or "").strip() != (b["notes"] or "").strip(): bad(f"{L} notes", a["notes"], b["notes"])
    if b["wbs"] is not None and a["wbs"] != b["wbs"]: bad(f"{L} wbs", a["wbs"], b["wbs"])
    if abs(hours(a["work"]) - b["workHours"]) > 1e-2: bad(f"{L} work hours", hours(a["work"]), b["workHours"])
    if {str(k): v for k, v in a["text"].items()} != b["text"]: bad(f"{L} text", a["text"], b["text"])
    if {str(k): v for k, v in a["numbers"].items()} != {k: v for k, v in b["numbers"].items() if v != 0}: bad(f"{L} numbers", a["numbers"], b["numbers"])
    if {str(k): v for k, v in a["dates"].items()} != b["dates"]: bad(f"{L} dates", a["dates"], b["dates"])
    if {str(k): v for k, v in a["flags"].items()} != {k: v for k, v in b["flags"].items() if v}: bad(f"{L} flags", a["flags"], b["flags"])
    xb = {str(k): v for k, v in a["baselines"].items()}
    if set(xb) != set(b["baselines"]): bad(f"{L} baseline slots", sorted(xb), sorted(b["baselines"]))
    for slot, v in xb.items():
        w = b["baselines"].get(slot)
        if not w: continue
        if v["start"] != w["start"] or v["finish"] != w["finish"]: bad(f"{L} baseline {slot} dates", (v["start"], v["finish"]), (w["start"], w["finish"]))
        bd = days(v["duration"])
        if bd is not None and abs(bd - w["durationDays"]) > 1e-3: bad(f"{L} baseline {slot} duration", bd, w["durationDays"])
        if abs(hours(v["work"]) - w["workHours"]) > 1e-2: bad(f"{L} baseline {slot} work", hours(v["work"]), w["workHours"])

xr = sorted((r["pred"], r["succ"], REL[r["type"]], round(days(r["lag"]) or 0, 4)) for r in x["relations"])
mr = sorted((r["predUID"], r["succUID"], r["type"], round(r["lagDays"], 4)) for r in m["relations"])
if xr != mr: bad("relations", [r for r in xr if r not in mr][:8], [r for r in mr if r not in xr][:8])

mres = {r["uid"]: r for r in m["resources"]}
for r in x["resources"]:
    b = mres.get(r["uid"])
    if b is None: bad("resource missing", r["uid"], None); continue
    for k in ["name", "initials", "email"]:
        if (r[k] or "") != (b[k] or ""): bad(f"resource {r['uid']} {k}", r[k], b[k])
    if abs((r["maxUnits"] or 0) / 100 - b["maxUnits"]) > 1e-6: bad(f"resource {r['uid']} max units", r["maxUnits"], b["maxUnits"])
if len(x["resources"]) != len(m["resources"]): bad("resource count", len(x["resources"]), len(m["resources"]))

xa = sorted((a["task"], a["resource"], round(a["units"] / 100, 4), round(hours(a["work"]), 3), a["start"], a["finish"])
            for a in x["assignments"] if a["resource"] is not None and a["resource"] > 0)
ma = sorted((a["taskUID"], a["resourceUID"], round(a["units"], 4), round(a["workHours"], 3), a["start"], a["finish"])
            for a in m["assignments"])
if xa != ma: bad("assignments", [a for a in xa if a not in ma][:5], [a for a in ma if a not in xa][:5])

DAYS = ["SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY"]
mc = {c["name"]: c for c in m["calendars"]}
for c in x["calendars"]:
    if c["derived"]: continue
    b = mc.get(c["name"])
    if b is None: bad("calendar missing in MPPKit", c["name"], None); continue
    for i, d in enumerate(DAYS, start=1):
        day = c["days"][d]
        entry = b["week"].get(str(i), "default")
        if entry == "default":
            # Project's defaults: Monday–Friday working, the weekend not.
            default = "NON_WORKING" if d in ("SATURDAY", "SUNDAY") else "WORKING"
            if day["type"] not in ("DEFAULT", None, default): bad(f"calendar {c['name']} {d} type", day["type"], "default")
            continue
        ranges = [[f"{r[0]//60:02d}:{r[0]%60:02d}", f"{(r[1]//60)%24:02d}:{r[1]%60:02d}"] for r in (entry or [])]
        if day["type"] == "NON_WORKING" and entry is not None: bad(f"calendar {c['name']} {d}", day, entry)
        if day["type"] == "WORKING" and day["ranges"] != ranges: bad(f"calendar {c['name']} {d} ranges", day["ranges"], ranges)
    xe = sorted((e["from"], e["to"], e["name"]) for e in c["exceptions"])
    me = sorted((e["start"][:10], e["finish"][:10], e["name"]) for e in b["exceptions"])
    if xe != me: bad(f"calendar {c['name']} exceptions", xe[:4], me[:4])
print(f"compared {checked} tasks, {len(xr)} relations, {len(x['resources'])} resources, "
      f"{len(xa)} assignments, {len(x['calendars'])} calendars (MPXJ)")
print(f"{len(issues)} differences")
for i in issues[:int(sys.argv[3]) if len(sys.argv) > 3 else 80]: print(" -", i)
