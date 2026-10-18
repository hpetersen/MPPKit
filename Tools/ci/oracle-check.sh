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
# Run the MPXJ oracle on each file and fail unless MPPKit and MPXJ agree on
# every field.
#
#   Tools/ci/oracle-check.sh <file.mpp>...
set -euo pipefail
root=${0:A:h:h:h}
failed=0
for file in "$@"; do
    echo "::group::MPXJ oracle: $file"
    out=$("$root/Tools/mpxj-oracle/oracle.sh" "$file")
    print -r -- "$out"
    echo "::endgroup::"
    if ! print -r -- "$out" | grep -qx '0 differences'; then
        echo "::error file=$file::MPPKit and MPXJ disagree on $file"
        failed=1
    fi
done
exit $failed
