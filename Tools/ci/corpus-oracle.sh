#!/bin/zsh
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
# Run the MPXJ oracle on the Project-saved corpus (Tools/ci/fetch-corpus.sh)
# and compare its differences with the known ones in
# Tools/ci/corpus-known-differences.txt. Fails on a difference not listed
# there; a listed one that no longer shows is reported, so it can be removed.
#
#   Tools/ci/corpus-oracle.sh <file.mpp>...
set -euo pipefail
root=${0:A:h:h:h}
known=$root/Tools/ci/corpus-known-differences.txt
actual=$(mktemp)
trap 'rm -f $actual' EXIT
for file in "$@"; do
    "$root/Tools/mpxj-oracle/oracle.sh" "$file" | grep '^ - ' | sed "s|^ - |${file:t}: |" >> $actual || true
done
sort -o $actual $actual
new=$(grep -v '^#' $known | sort | comm -13 - $actual)
gone=$(grep -v '^#' $known | sort | comm -23 - $actual)
echo "$(wc -l < $actual | tr -d ' ') differences on $# Project-saved files"
if [[ -n $gone ]]; then
    echo "::notice::known differences that no longer show; remove them from ${known:t}:"
    print -r -- "$gone"
fi
if [[ -n $new ]]; then
    echo "::error::new differences between MPPKit and MPXJ on Project-saved files:"
    print -r -- "$new"
    exit 1
fi
