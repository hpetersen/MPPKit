#!/bin/bash
# MPPKit: Microsoft Project (.mpp) files in Swift
# Copyright (C) 2026 Henrik Petersen
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License version 3 as published
# by the Free Software Foundation. It is distributed WITHOUT ANY WARRANTY;
# see the LICENSE file for details. https://mppstudio.com
#
# SPDX-License-Identifier: GPL-3.0-only
#
# Download the Project 2010/2013 files from MPXJ's test corpus into a folder
# (default Corpus/), for ConformanceTests and `mppdump check`. Each was saved
# by Microsoft Project itself, so they show what Project writes — the
# shipped samples were written by MPPKit and cannot. They are fetched at a
# pinned MPXJ commit rather than kept in this repository.
#
#   Tools/ci/fetch-corpus.sh [dir]
set -euo pipefail
commit=acc66da5f16be803d6a893faa8ab80e76f94e012
dir=${1:-Corpus}
files=(
    mpp14assignmentcustom.mpp
    mpp14assignmentfields.mpp
    mpp14autofilter.mpp
    mpp14availability.mpp
    mpp14barstyle.mpp
    mpp14baseline.mpp
    mpp14baselines.mpp
    mpp14calendar.mpp
    mpp14columns.mpp
    mpp14costratetable.mpp
    mpp14duration.mpp
    mpp14embedded.mpp
    mpp14enterprise.mpp
    mpp14exceptions.mpp
    mpp14filterlogic.mpp
    mpp14filter.mpp
    mpp14gantt.mpp
    mpp14graphind.mpp
    mpp14group.mpp
    mpp14header.mpp
    mpp14nulltasks.mpp
    mpp14recurring.mpp
    mpp14relations.mpp
    mpp14resource.mpp
    mpp14splittask.mpp
    mpp14subproject.mpp
    mpp14task-from2013.mpp
    mpp14task.mpp
    mpp14timephased2.mpp
    mpp14timephased.mpp
    mpp14timephasedsegmentsmanual.mpp
    mpp14timephasedsegmentsmanualoffsets.mpp
    mpp14timephasedsegments.mpp
    mpp14viewstate.mpp
    ResourceIdAndUniqueId-project2010-mpp14.mpp
    ResourceIdAndUniqueId-project2013-mpp14.mpp
)
mkdir -p "$dir"
for f in "${files[@]}"; do
    [[ -s "$dir/$f" ]] && continue
    curl -fsSL --retry 3 -o "$dir/$f" "https://raw.githubusercontent.com/joniles/mpxj/$commit/junit/data/$f"
done
echo "${#files[@]} Project-saved files in $dir"
