#!/bin/zsh
# MPPKit: Microsoft Project (.mpp) files in Swift
# Copyright (C) 2026 Henrik Petersen
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU Affero General Public License version 3 as
# published by the Free Software Foundation. It is distributed WITHOUT ANY
# WARRANTY; see the LICENSE file for details. https://mppstudio.com
#
# SPDX-License-Identifier: AGPL-3.0-only
#
# Compare MPPKit's reading of a .mpp with MPXJ's, field by field.
#
#   Tools/mpxj-oracle/oracle.sh <file.mpp>
#
# Needs: a JRE (JAVA_HOME) and a Python venv with `pip install mpxj jpype1`
# (MPXJ_VENV, default Tools/mpxj-oracle/.venv). MPXJ is LGPL and only ever
# runs here as an external tool — it is never linked into MPPKit.
set -euo pipefail
here=${0:A:h}
root=${here:h:h}
venv=${MPXJ_VENV:-$here/.venv}
file=${1:A}
tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT
(cd $root && swift run -q mppdump json "$file") > $tmp/mppkit.json
(cd $tmp && "$venv/bin/python" -I "$here/mpxj_dump.py" "$file" "$tmp/mpxj.json" >/dev/null 2>&1)
python3 -I "$here/compare.py" "$tmp/mpxj.json" "$tmp/mppkit.json" 200
