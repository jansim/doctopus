#!/bin/bash
# Keep compiler and assertion failures visible in the Actions summary as well as logs.
set -euo pipefail
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT
if "$@" 2>&1 | tee "$LOG"; then
    exit 0
else
    STATUS=$?
    python3 - "$LOG" <<'PY'
import sys
from pathlib import Path
lines = Path(sys.argv[1]).read_text(errors="replace").splitlines()
failures = list(dict.fromkeys(line for line in lines if "error:" in line or "✗" in line))
for line in failures[:20]:
    message = line.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print(f"::error::{message}")
PY
    exit "$STATUS"
fi
