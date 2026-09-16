#!/usr/bin/env python3
"""Refuse a `@State` that has BOTH an inline default and an assignment inside an `init`.

Since Xcode 27, SwiftUI's `@State` is a macro, and a property with an inline initial value
keeps it: whatever `init` assigns (`self.x = …` or `_x = State(initialValue: …)`) is silently
discarded at runtime — no diagnostic, no crash (Apple TN3211, "Resolving SwiftUI source
incompatibilities for State and ContentBuilder"). On 2026-09-16 this made `PebbleAudioApp`
hand the runtime one `AppSettings` while its views read another.

Usage:  python3 ios/Tools/check_state_init.py            # scans App/, Widgets/, Shared/
        python3 ios/Tools/check_state_init.py path …     # specific files or directories
Exit status is the number of offending properties (0 = clean).

Heuristic, not a Swift parser: it finds each `@State … var name … = default` and reports any
assignment to `name`, `self.name` or `_name` that sits inside the braces of an `init(` in the
same file. Assignments in `body`, closures and actions are fine and are not reported.
"""

import pathlib
import re
import sys

IOS_DIR = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_ROOTS = [IOS_DIR / "App", IOS_DIR / "Widgets", IOS_DIR / "Shared"]

DECL = re.compile(
    r"@State(?:Object)?\s+(?:(?:private|fileprivate|internal|public)(?:\(set\))?\s+)*var\s+(\w+)\b"
    r"(?P<rest>[^\n]*)"
)
INIT_START = re.compile(r"\binit\s*(?:\?|!)?\s*\(")


def init_bodies(src):
    """Yield (start, end) offsets of every `init(...) { ... }` body in `src`."""
    for m in INIT_START.finditer(src):
        # Skip the parameter list, then find the opening brace of the body.
        depth, i = 0, m.end() - 1
        while i < len(src):
            c = src[i]
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        brace = src.find("{", i)
        if brace < 0:
            continue
        # `init(...) throws {`, `init(...) async {` — anything up to the brace is a signature
        # as long as it holds no `;`/newline-terminated statement, which a declaration never does.
        depth, j = 0, brace
        while j < len(src):
            c = src[j]
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    yield brace, j
                    break
            j += 1


def offenders(path):
    src = path.read_text()
    if "@State" not in src or "init" not in src:
        return []
    bodies = list(init_bodies(src))
    if not bodies:
        return []
    found = []
    for d in DECL.finditer(src):
        name, rest = d.group(1), d.group("rest")
        # A default is an `=` after the name/type that is not part of `==` or a closure type.
        if not re.search(r"(?<![=!<>])=(?!=)", rest.split("//")[0]):
            continue
        assign = re.compile(r"(?<![\w.])(?:self\.)?_?" + re.escape(name) + r"\s*(?<![=!<>])=(?!=)")
        for a in assign.finditer(src):
            # `let settings = AppSettings()` inside init is a local that shadows the property,
            # not an assignment to it.
            line_start = src.rfind("\n", 0, a.start()) + 1
            if re.search(r"\b(?:let|var)\s+$", src[line_start:a.start()]):
                continue
            if any(s < a.start() < e for s, e in bodies):
                decl_line = src.count("\n", 0, d.start()) + 1
                line = src.count("\n", 0, a.start()) + 1
                found.append((decl_line, name, line))
                break
    return found


def main(argv):
    roots = [pathlib.Path(a) for a in argv[1:]] or DEFAULT_ROOTS
    files = []
    for r in roots:
        files += [r] if r.is_file() else sorted(r.rglob("*.swift"))
    total = 0
    for f in files:
        for decl_line, name, line in offenders(f):
            total += 1
            rel = f.relative_to(IOS_DIR) if f.is_relative_to(IOS_DIR) else f
            print(f"{rel}:{decl_line}: @State `{name}` has an inline default AND is assigned in "
                  f"init at line {line} — Xcode 27 discards the init value (TN3211). "
                  f"Drop the inline default.")
    if total == 0:
        print(f"check_state_init: clean ({len(files)} files)")
    return min(total, 125)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
