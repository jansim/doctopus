#!/usr/bin/env python3
"""Reads `/screenshot` requests out of a PR description or comment.

    /screenshot [window title]
    ```sh
    optional setup code, run before the capture
    ```

Every `/screenshot` line is one capture; the first fenced block after it (and
before the next `/screenshot`) is its setup. Lines inside other fences and
quoted lines (`> /screenshot`, as in a reply) are ignored, so quoting an old
request does not repeat it.

Reads the text from $BODY and writes `specs=<json>` to $GITHUB_OUTPUT, or
prints the JSON when that is not set.
"""
import json
import os
import re
import sys

MAX_SPECS = 6

LANGUAGES = {
    "": "sh", "sh": "sh", "bash": "sh", "shell": "sh", "zsh": "sh",
    "applescript": "applescript", "osascript": "applescript",
    "jxa": "jxa", "javascript": "jxa", "js": "jxa",
}

COMMAND = re.compile(r"^\s*/screenshot(?:\s+(.*?))?\s*$")
FENCE = re.compile(r"^\s*(`{3,}|~{3,})\s*([\w+-]*)")


def parse(body):
    specs, errors = [], []
    current = None
    fence = None  # (marker, lang, lines, owner) while inside a fenced block
    for line in body.replace("\r\n", "\n").split("\n"):
        if fence:
            marker, lang, lines, owner = fence
            closing = line.strip()
            if len(closing) >= len(marker) and set(closing) == {marker[0]}:
                if owner is not None:
                    owner["code"] = "\n".join(lines)
                    owner["lang"] = lang
                fence = None
            else:
                lines.append(line)
            continue
        if line.lstrip().startswith(">"):
            continue
        opened = FENCE.match(line)
        if opened:
            marker, tag = opened.group(1), opened.group(2).lower()
            owner = current if current is not None and current["code"] is None else None
            if owner is not None and tag not in LANGUAGES:
                errors.append(f"unsupported setup language `{tag}` "
                              f"(use sh, applescript or jxa)")
                owner = None
            fence = (marker, LANGUAGES.get(tag, "sh"), [], owner)
            continue
        command = COMMAND.match(line)
        if command:
            current = {"window": (command.group(1) or "").strip(), "lang": "sh", "code": None}
            specs.append(current)
    if len(specs) > MAX_SPECS:
        errors.append(f"only the first {MAX_SPECS} of {len(specs)} screenshots are taken")
        specs = specs[:MAX_SPECS]
    for spec in specs:
        spec["code"] = spec["code"] or ""
    return {"specs": specs, "errors": errors}


def main():
    result = parse(os.environ.get("BODY", ""))
    encoded = json.dumps(result)
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as f:
            f.write(f"specs={encoded}\n")
            f.write(f"count={len(result['specs'])}\n")
    else:
        print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
