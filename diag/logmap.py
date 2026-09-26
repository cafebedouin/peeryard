#!/usr/bin/env python3
"""logmap.py: which line of the node's source wrote this log line?

Scans a source checkout of the node for `log.<level>(...)` calls whose message starts with a string literal (about 93%
of them in ergo 6.0.x), turns each message into a pattern (literal text kept, `$x` / `${...}` interpolations and `+ ...`
concatenations as wildcards), and records its file, line, level, enclosing class or object, and enclosing def.
A log line is matched on its level and message first; the logger's class (the part before " - ") breaks ties. The
class alone is not enough: a trait's log line carries the runtime class that mixes it in.

  python3 diag/logmap.py build <source dir> [-o index.json]
  python3 diag/logmap.py find <index.json | source dir> '<a log line>'

Standard library only.
"""
import argparse
import json
import os
import re
import sys
from typing import Dict, List, Optional

CALL = re.compile(r'\blog\.(trace|debug|info|warn|error)\((s?)"((?:[^"\\]|\\.)*)"(.*)$')
DEF = re.compile(r"^\s*(?:(?:override|private|protected|final|implicit|lazy)(?:\[[^\]]*\])?\s+)*def\s+([A-Za-z_][A-Za-z0-9_]*)")
OWNER = re.compile(r"^\s*(?:(?:final|abstract|sealed|case|private|protected|implicit)\s+)*(class|object|trait)\s+([A-Za-z_][A-Za-z0-9_]*)")
OPEN_CALL = re.compile(r"\blog\.(trace|debug|info|warn|error)\(\s*$")
INTERP = re.compile(r"\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*")
LOG_LINE = re.compile(r"^\d\d:\d\d:\d\d\.\d{3} +([A-Z]+) +\[[^\]]*\] +(\S+) - (.*)$")


def _pattern(interp: bool, literal: str, rest: str) -> str:
    text = literal.replace('\\"', '"').replace("\\\\", "\\")
    parts = INTERP.split(text) if interp else [text]
    rx = ".*?".join(re.escape(p) for p in parts)
    if re.match(r"\s*\+", rest):   # "literal" + value ...
        rx += ".*"
    return rx


def build(src: str) -> List[dict]:
    entries = []
    for d, _, files in os.walk(src):
        if "/test/" in d + "/" or "/.git" in d:
            continue
        for f in files:
            if not f.endswith(".scala"):
                continue
            path = os.path.join(d, f)
            owner: Optional[str] = None
            fn: Optional[str] = None
            with open(path, errors="replace") as fh:
                lines = fh.readlines()
            for i, line in enumerate(lines, 1):
                m = OWNER.match(line)
                if m:
                    owner = m.group(2)
                m = DEF.match(line)
                if m:
                    fn = m.group(1)
                m = CALL.search(line)
                if not m and OPEN_CALL.search(line):
                    # log.info(  on its own, the message literal on one of the next lines
                    nxt = "".join(l.strip() for l in lines[i:i + 3])
                    m = CALL.search(OPEN_CALL.search(line).group(0).rstrip() + nxt)
                if m:
                    level, interp, literal, rest = m.groups()
                    entries.append({"file": os.path.relpath(path, src), "line": i, "level": level.upper(),
                                    "owner": owner, "def": fn, "pattern": _pattern(bool(interp), literal, rest),
                                    "literal_chars": len(INTERP.sub("", literal))})
    return entries


def load(index_or_src: str) -> List[dict]:
    if os.path.isdir(index_or_src):
        return build(index_or_src)
    with open(index_or_src) as f:
        return json.load(f)


class LogMap:
    def __init__(self, entries: List[dict]):
        self.by_level: Dict[str, List[tuple]] = {}
        for e in entries:
            self.by_level.setdefault(e["level"], []).append((re.compile(e["pattern"] + r"\s*$", re.S), e))

    def find(self, line: str) -> List[dict]:
        """Source sites that could have written `line` (best first); empty if none."""
        m = LOG_LINE.match(line.rstrip("\n"))
        if not m:
            return []
        level, logger, msg = m.groups()
        cls = logger.split(".")[-1].split("$")[0]
        hits = [e for rx, e in self.by_level.get(level, []) if rx.match(msg)]
        # most literal text first (the most specific pattern), then the one whose owner or file names the logger's class
        hits.sort(key=lambda e: (-e["literal_chars"], e["owner"] != cls and not e["file"].endswith(f"/{cls}.scala")))
        return hits

    def site(self, line: str) -> str:
        hits = self.find(line)
        if not hits:
            return "(no source site)"
        e = hits[0]
        more = f" (+{len(hits) - 1} other sites)" if len(hits) > 1 else ""
        return f"{e['file']}:{e['line']} in {e['owner'] or '?'}.{e['def'] or '?'}{more}"


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    b = sub.add_parser("build")
    b.add_argument("src")
    b.add_argument("-o", "--out")
    f = sub.add_parser("find")
    f.add_argument("index")
    f.add_argument("line")
    a = ap.parse_args(argv)
    if a.cmd == "build":
        entries = build(a.src)
        text = json.dumps(entries, indent=0)
        if a.out:
            with open(a.out, "w") as fh:
                fh.write(text)
            print(f"logmap: {len(entries)} log calls indexed -> {a.out}")
        else:
            print(text)
        return 0
    lm = LogMap(load(a.index))
    hits = lm.find(a.line)
    for e in hits:
        print(f"{e['file']}:{e['line']}  {e['level']}  {e['owner']}.{e['def']}")
    return 0 if hits else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
