#!/usr/bin/env python3
"""Takes the screenshots `parse.py` asked for, on a macOS runner.

Each one starts from a fresh launch with the preferences wiped and only the
demo library registered, runs its setup block, then captures the requested
window's rectangle — a rectangle rather than the window itself, so a sheet or
popover open over it is in the picture.

Environment: SPECS (parse.py's JSON), APP, LIBRARY, WINDOWS (the compiled
windows.swift), OUT (directory for PNGs and results.json).
"""
import json
import os
import subprocess
import time

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.environ["APP"]
DOCTOPUS = os.path.join(APP, "Contents/MacOS/Doctopus")
LIBRARY = os.environ["LIBRARY"]
WINDOWS = os.environ["WINDOWS"]
OUT = os.environ["OUT"]
BUNDLE_ID = "io.doctopus.app"
SETUP_TIMEOUT = 120
# The first launch indexes and OCRs the demo library; later ones reopen it.
FIRST_SETTLE, SETTLE = 15, 4


def run(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


def windows():
    """Doctopus's windows, front to back, as dicts."""
    found = []
    for line in run([WINDOWS, "Doctopus"]).stdout.splitlines():
        wid, x, y, w, h, title = line.split("\t", 5)
        found.append({"id": int(wid), "x": int(x), "y": int(y), "w": int(w), "h": int(h),
                      "title": title})
    if found and not any(w["title"] for w in found):
        # No Screen Recording for the helper means no titles; System Events
        # knows them, if Accessibility is granted instead.
        script = ('tell application "System Events" to tell process "Doctopus" to '
                  'get {name, position, size} of every window')
        names = run(["osascript", "-s", "s", "-e", script]).stdout
        titled = parse_system_events(names)
        for window in found:
            for name, (x, y, w, h) in titled:
                if (x, y, w, h) == (window["x"], window["y"], window["w"], window["h"]):
                    window["title"] = name
    return found


def parse_system_events(text):
    """`{{"a", "b"}, {{0, 25}, {10, 30}}, {{800, 600}, {400, 300}}}` → [(name, bounds)]."""
    try:
        data = json.loads(text.strip().replace("{", "[").replace("}", "]"))
        names, positions, sizes = data
        return [(n, (p[0], p[1], s[0], s[1])) for n, p, s in zip(names, positions, sizes)]
    except (ValueError, TypeError):
        return []


def wait_for(predicate, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.5)
    return False


def relaunch(first):
    run(["pkill", "-x", "Doctopus"])
    wait_for(lambda: run(["pgrep", "-x", "Doctopus"]).returncode != 0, 15)
    run(["defaults", "delete", BUNDLE_ID])
    made = run([DOCTOPUS, "--new-library", LIBRARY])
    if made.returncode != 0:
        raise RuntimeError(f"--new-library failed: {made.stdout}{made.stderr}")
    run(["open", APP])
    name = os.path.basename(LIBRARY.rstrip("/")).lower()
    # Titles may be unreadable, so any window at all counts as launched.
    if not wait_for(lambda: any(name in w["title"].lower() or not w["title"]
                                for w in windows()), 90):
        raise RuntimeError("Doctopus did not open a window within 90s")
    time.sleep(FIRST_SETTLE if first else SETTLE)


def setup(spec, index):
    code = spec["code"]
    if not code.strip():
        return ""
    env = dict(os.environ, APP=APP, DOCTOPUS=DOCTOPUS, LIBRARY=LIBRARY, WINDOWS=WINDOWS)
    path = os.path.join(OUT, f"setup-{index}")
    with open(path, "w") as f:
        f.write(code + "\n")
    if spec["lang"] == "applescript":
        args = ["osascript", path]
    elif spec["lang"] == "jxa":
        args = ["osascript", "-l", "JavaScript", path]
    else:
        # -e, so a helper that failed is reported instead of the capture
        # quietly showing the window as it was.
        args = ["bash", "-e", "-c", 'source "$1"; source "$2"', "setup",
                os.path.join(HERE, "helpers.sh"), path]
    try:
        done = subprocess.run(args, env=env, capture_output=True, text=True,
                              timeout=SETUP_TIMEOUT)
    except subprocess.TimeoutExpired as e:
        raise RuntimeError(f"setup ran longer than {SETUP_TIMEOUT}s") from e
    finally:
        os.remove(path)
    log = (done.stdout + done.stderr).strip()
    if done.returncode != 0:
        raise RuntimeError(f"setup exited {done.returncode}" + (f":\n{tail(log)}" if log else ""))
    return log


def tail(text, lines=20):
    return "\n".join(text.splitlines()[-lines:])


def pick(spec):
    found = windows()
    wanted = spec["window"]
    if wanted:
        match = [w for w in found if wanted.lower() in w["title"].lower()]
    else:
        # A sheet is an untitled window of its own; prefer what it hangs off.
        match = [w for w in found if w["title"]] or found
    if not match:
        titles = ", ".join(f'"{w["title"]}"' for w in found) or "none"
        raise RuntimeError(f'no window matching "{wanted}" (open windows: {titles})')
    return match[0]


def capture(spec, index):
    path = os.path.join(OUT, f"screenshot-{index + 1}.png")
    if spec["window"] == "--screen":
        args = ["screencapture", "-x", path]
        title = "Screen"
    else:
        window = pick(spec)
        rect = f'{window["x"]},{window["y"]},{window["w"]},{window["h"]}'
        args = ["screencapture", "-x", "-R", rect, path]
        title = window["title"] or spec["window"] or "Doctopus"
    done = run(args)
    if done.returncode != 0 or not os.path.exists(path):
        raise RuntimeError(f"screencapture failed: {done.stderr.strip()}")
    return os.path.basename(path), title


def main():
    specs = json.loads(os.environ["SPECS"])["specs"]
    os.makedirs(OUT, exist_ok=True)
    results = []
    for index, spec in enumerate(specs):
        result = {"window": spec["window"], "lang": spec["lang"], "code": spec["code"]}
        try:
            relaunch(first=index == 0)
            log = setup(spec, index)
            if log:
                result["log"] = tail(log)
            time.sleep(1)
            result["file"], result["title"] = capture(spec, index)
        except Exception as e:  # reported in the comment, not the job log alone
            result["error"] = str(e)
            # What was on screen is usually the fastest way to see why.
            debug = os.path.join(OUT, f"screen-{index + 1}.png")
            if run(["screencapture", "-x", debug]).returncode == 0 and os.path.exists(debug):
                result["screen"] = os.path.basename(debug)
        print(json.dumps(result))
        results.append(result)
    run(["pkill", "-x", "Doctopus"])
    with open(os.path.join(OUT, "results.json"), "w") as f:
        json.dump(results, f, indent=2)


if __name__ == "__main__":
    main()
