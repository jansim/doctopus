#!/bin/bash
# Keep compiler and assertion results visible in the Actions summary as well as logs.
set -euo pipefail
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
if "$@" 2>&1 | tee "$LOG"; then
    STATUS=0
else
    STATUS=$?
fi
python3 - "$LOG" "$STATUS" <<'PY'
import sys
from pathlib import Path
lines = Path(sys.argv[1]).read_text(errors="replace").splitlines()
failures = list(dict.fromkeys(line for line in lines if "error:" in line or "✗" in line))
reports = [("error", line) for line in failures[:20]] if sys.argv[2] != "0" else []
reports += [("notice", line) for line in lines if "passed," in line and "failed" in line]
for level, line in reports:
    message = line.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print(f"::{level}::{message}")
PY
exit "$STATUS"
