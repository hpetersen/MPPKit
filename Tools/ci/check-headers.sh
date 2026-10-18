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
# Fail when a tracked source file lacks the GPL licence header.
set -euo pipefail
missing=0
while IFS= read -r f; do
    if ! head -n 15 "$f" | grep -q 'SPDX-License-Identifier: GPL-3.0-only'; then
        echo "::error file=$f::missing the GPL-3.0-only licence header (copy it from any existing file)"
        missing=1
    fi
done < <(git ls-files '*.swift' '*.py' '*.sh')
exit $missing
