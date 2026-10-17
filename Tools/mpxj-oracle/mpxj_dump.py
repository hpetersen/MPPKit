# MPPKit: Microsoft Project (.mpp) files in Swift
# Copyright (C) 2026 Henrik Petersen
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License version 3 as published
# by the Free Software Foundation. It is distributed WITHOUT ANY WARRANTY;
# see the LICENSE file for details. https://mppstudio.com
#
# SPDX-License-Identifier: GPL-3.0-only

"""Dump a project as MPXJ (the independent LGPL reader) sees it, as JSON: mpxj_dump.py <in.mpp> <out.json>."""
import json, sys, os
import jpype
jpype.startJVM(classpath=[os.path.join(os.path.dirname(__import__("mpxj").__file__), "lib", "*")])
from org.mpxj.reader import UniversalProjectReader
from org.mpxj import TimeUnit, TaskMode
from java.time import DayOfWeek

def s(v): return None if v is None else str(v)
def iso(d): return None if d is None else str(d)[:16]
def num(v):
    try: return None if v is None else float(v.doubleValue() if hasattr(v, "doubleValue") else v)
    except Exception: return None
def dur(d):
    if d is None: return None
    return {"value": float(d.getDuration()), "units": str(d.getUnits())}

p = UniversalProjectReader().read(sys.argv[1])
props = p.getProjectProperties()
out = {
  "title": s(props.getProjectTitle()), "author": s(props.getAuthor()), "company": s(props.getCompany()),
  "manager": s(props.getManager()), "subject": s(props.getSubject()), "keywords": s(props.getKeywords()),
  "comments": s(props.getComments()), "category": s(props.getCategory()),
  "minutesPerDay": num(props.getMinutesPerDay()), "minutesPerWeek": num(props.getMinutesPerWeek()),
  "daysPerMonth": num(props.getDaysPerMonth()), "currencySymbol": s(props.getCurrencySymbol()),
  "currencyCode": s(props.getCurrencyCode()), "statusDate": iso(props.getStatusDate()),
  "start": iso(props.getStartDate()), "finish": iso(props.getFinishDate()),
  "defaultCalendar": s(props.getDefaultCalendar().getName()) if props.getDefaultCalendar() else None,
  "tasks": [], "relations": [], "resources": [], "assignments": [], "calendars": [],
}
for t in p.getTasks():
    if t.getUniqueID() is None or int(t.getUniqueID()) == 0: continue
    cal = t.getCalendar()
    row = {
      "uid": int(t.getUniqueID()), "id": int(t.getID()) if t.getID() is not None else None,
      "name": s(t.getName()), "outlineLevel": int(t.getOutlineLevel() or 0),
      "parentUID": int(t.getParentTask().getUniqueID()) if t.getParentTask() is not None else 0,
      "start": iso(t.getStart()), "finish": iso(t.getFinish()), "duration": dur(t.getDuration()),
      "estimated": bool(t.getEstimated()), "summary": bool(t.getSummary()), "milestone": bool(t.getMilestone()),
      "manual": t.getTaskMode() == TaskMode.MANUALLY_SCHEDULED, "calendar": s(cal.getName()) if cal else None,
      "notes": s(t.getNotes()), "wbs": s(t.getWBS()), "constraint": s(t.getConstraintType()),
      "constraintDate": iso(t.getConstraintDate()), "deadline": iso(t.getDeadline()),
      "percentComplete": num(t.getPercentageComplete()), "actualStart": iso(t.getActualStart()),
      "actualFinish": iso(t.getActualFinish()), "work": dur(t.getWork()),
      "priority": int(t.getPriority().getValue()) if t.getPriority() else None, "type": s(t.getType()),
      "effortDriven": bool(t.getEffortDriven()),
      "text": {i: s(t.getText(i)) for i in range(1, 31) if t.getText(i)},
      "numbers": {i: num(t.getNumber(i)) for i in range(1, 21) if t.getNumber(i) is not None and num(t.getNumber(i)) != 0},
      "dates": {i: iso(t.getDate(i)) for i in range(1, 11) if t.getDate(i) is not None},
      "flags": {i: True for i in range(1, 21) if t.getFlag(i)},
      "baselines": {},
    }
    for slot in range(0, 11):
        bs = t.getBaselineStart() if slot == 0 else t.getBaselineStart(slot)
        bf = t.getBaselineFinish() if slot == 0 else t.getBaselineFinish(slot)
        bd = t.getBaselineDuration() if slot == 0 else t.getBaselineDuration(slot)
        bw = t.getBaselineWork() if slot == 0 else t.getBaselineWork(slot)
        if bs is not None or bf is not None:
            row["baselines"][slot] = {"start": iso(bs), "finish": iso(bf), "duration": dur(bd), "work": dur(bw)}
    out["tasks"].append(row)
    for r in t.getPredecessors():
        out["relations"].append({"pred": int(r.getPredecessorTask().getUniqueID()),
                                 "succ": int(r.getSuccessorTask().getUniqueID()),
                                 "type": s(r.getType()), "lag": dur(r.getLag())})
for r in p.getResources():
    if r.getUniqueID() is None or int(r.getUniqueID()) == 0 or r.getName() is None: continue
    out["resources"].append({"uid": int(r.getUniqueID()), "name": s(r.getName()), "initials": s(r.getInitials()),
                             "email": s(r.getEmailAddress()), "maxUnits": num(r.getMaxUnits()),
                             "calendar": s(r.getCalendar().getName()) if r.getCalendar() else None})
for a in p.getResourceAssignments():
    res = a.getResource()
    out["assignments"].append({"task": int(a.getTask().getUniqueID()) if a.getTask() else None,
                               "resource": int(res.getUniqueID()) if res is not None else None,
                               "units": num(a.getUnits()), "work": dur(a.getWork()),
                               "start": iso(a.getStart()), "finish": iso(a.getFinish())})
for c in p.getCalendars():
    days = {}
    for d in DayOfWeek.values():
        hours = c.getCalendarHours(d)
        days[str(d)] = {"type": s(c.getCalendarDayType(d)),
                        "ranges": [[str(h.getStart())[:5], str(h.getEnd())[:5]] for h in hours] if hours else []}
    out["calendars"].append({"name": s(c.getName()), "uid": int(c.getUniqueID()) if c.getUniqueID() else None,
                             "derived": c.isDerived(), "parent": s(c.getParent().getName()) if c.getParent() else None,
                             "days": days,
                             "exceptions": [{"from": str(x.getFromDate()), "to": str(x.getToDate()),
                                             "name": s(x.getName()), "working": bool(x.getWorking())}
                                            for x in c.getCalendarExceptions()]})
open(sys.argv[2], "w").write(json.dumps(out, indent=1, ensure_ascii=False, default=str))
