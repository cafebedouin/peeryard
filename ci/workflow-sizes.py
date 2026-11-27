#!/usr/bin/env python3
"""workflow-sizes.py: the runner-time size of one dispatch of each workflow in .github/workflows/, read from the files.

    python3 ci/workflow-sizes.py            # print the table (Markdown)
    python3 ci/workflow-sizes.py --write    # put it into docs/workflows.md between <!-- sizes:begin --> and <!-- sizes:end -->
    python3 ci/workflow-sizes.py --check    # exit 1 when the table in docs/workflows.md is not the one generated here

Per workflow: each job's timeout-minutes, how many jobs it makes at the dispatch defaults, the matrix's max-parallel, and
an upper bound in runner-minutes (the sum of timeout-minutes over the jobs one dispatch makes, as docs/workflows.md
defines it). What is read, and how:
- A job without timeout-minutes is listed as "none" and left out of the sums (GitHub applies its own default limit).
- A job whose `if` uses only inputs, github.event_name (taken as workflow_dispatch), needs.<job>.result (success, or
  skipped for a job skipped here) and the status functions is evaluated at the input defaults; a job skipped there
  counts 0 jobs, and so does a job that needs a skipped job without always(), failure() or cancelled() in its `if`, as
  GitHub skips it. Any other `if` is counted as running and marked "if".
- A matrix axis that is a static list counts its entries; `include` alone counts its entries.
- An axis `${{ fromJSON(needs.<job>.outputs.<X>) }}` is dynamic. It counts the default of input X when that is a whole
  number and the job that writes output X builds it as 1..N (`X=$(seq 1 ...` or `range(1; ...`, checked in that job's
  steps); the input's documented range "(lo-hi)" gives its largest value. Any other dynamic axis stays a name in the
  bound (e.g. "60 x examples"), explained in the prose of docs/workflows.md.
- An input description saying "<a> x <b> ... is at most N", where a, b, ... are the outputs a job's matrix is built
  from, caps that job's count at N for the largest-value column.
- A timeout-minutes that is an expression is dynamic and stays a name in the bound.
Standard library only: the YAML reader below handles the subset these files use (block mappings and sequences, flow
collections on one line, quoted and plain scalars, block scalars, comments); no anchors, tags or multi-line flow.
"""
import argparse, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WF = os.path.join(ROOT, ".github", "workflows")
DOC = os.path.join(ROOT, "docs", "workflows.md")
BEGIN, END = "<!-- sizes:begin -->", "<!-- sizes:end -->"


# ---- a reader for the YAML subset the workflow files use ----------------------------------------------------------------

def scalar(s):
    s = s.strip()
    if s and s[0] in "'\"":
        q = s[0]
        if not (len(s) >= 2 and s.endswith(q)):
            raise ValueError(f"unterminated quoted scalar: {s[:60]}")
        body = s[1:-1]
        return body.replace("''", "'") if q == "'" else bytes(body, "utf-8").decode("unicode_escape")
    if s in ("", "~", "null", "Null", "NULL"):
        return None
    if s in ("true", "True", "TRUE"):
        return True
    if s in ("false", "False", "FALSE"):
        return False
    if re.fullmatch(r"[-+]?[0-9]+", s):
        return int(s)
    return s


def strip_comment(s):
    """The line without a trailing comment (a # after whitespace, outside quotes)."""
    q = None
    for i, c in enumerate(s):
        if q:
            if c == q:
                q = None
        elif c in "'\"" and (i == 0 or s[i - 1] in " \t[{,:"):
            q = c
        elif c == "#" and (i == 0 or s[i - 1] in " \t"):
            return s[:i].rstrip()
    return s.rstrip()


def flow(s):
    """A one-line flow collection ([a, b] or {k: v}) or a scalar."""
    s = s.strip()
    pos = 0

    def ws():
        nonlocal pos
        while pos < len(s) and s[pos] in " \t":
            pos += 1

    def item(stop):
        nonlocal pos
        ws()
        if s[pos] == "[":
            pos += 1; out = []
            while True:
                ws()
                if s[pos] == "]":
                    pos += 1; return out
                out.append(item(",]")); ws()
                if s[pos] == ",":
                    pos += 1
        if s[pos] == "{":
            pos += 1; out = {}
            while True:
                ws()
                if s[pos] == "}":
                    pos += 1; return out
                k = item(":,}"); ws()
                v = None
                if s[pos] == ":":
                    pos += 1; v = item(",}")
                out[k] = v; ws()
                if s[pos] == ",":
                    pos += 1
        if s[pos] in "'\"":
            q, j = s[pos], pos + 1
            while True:
                j = s.index(q, j)
                if q == "'" and s[j + 1:j + 2] == "'":
                    j += 2; continue
                break
            tok = s[pos:j + 1]; pos = j + 1
            return scalar(tok)
        j = pos
        while j < len(s) and not (s[j] in stop and (s[j] != ":" or s[j + 1:j + 2] in (" ", ""))):
            j += 1
        tok = s[pos:j]; pos = j
        return scalar(tok)

    if s and s[0] in "[{":
        v = item("")
        ws()
        if pos != len(s):
            raise ValueError(f"trailing text after a flow collection: {s[:60]}")
        return v
    return scalar(s)


def key_value(text):
    """(key, rest) for 'key: rest' or 'key:', else None. The key may be quoted."""
    m = re.match(r"""^('(?:[^']|'')*'|"(?:[^"\\]|\\.)*"|[^'"\s][^:#]*?|[^'"\s])\s*:(\s+|$)(.*)$""", text)
    if not m:
        return None
    return scalar(m.group(1)), m.group(3)


def load_yaml(text):
    lines = []
    for raw in text.split("\n"):
        lines.append(raw.rstrip("\r"))
    n = len(lines)
    i = 0

    def indent(s):
        return len(s) - len(s.lstrip(" "))

    def blank(s):
        return not s.strip() or s.lstrip().startswith("#")

    def skip():
        nonlocal i
        while i < n and blank(lines[i]):
            i += 1

    def block_scalar(header, parent_indent):
        nonlocal i
        style, chomp = header[0], ""
        for c in header[1:]:
            if c in "+-":
                chomp = c
        body, ind = [], None
        while i < n:
            s = lines[i]
            if s.strip():
                if ind is None:
                    ind = indent(s)
                    if ind <= parent_indent:
                        break
                if indent(s) < ind:
                    break
                body.append(s[ind:])
            else:
                body.append("")
            i += 1
        while body and body[-1] == "" and chomp != "+":
            body.pop()
        if style == "|":
            out = "\n".join(body)
        else:
            out, prev_blank = "", True
            for b in body:
                if not b:
                    out += "\n"; prev_blank = True
                else:
                    out += ("" if prev_blank else " ") + b; prev_blank = False
        return out + ("" if chomp == "-" or not body else "\n")

    def value(rest, ind):
        """The value after 'key:' or '- ' at indentation ind: inline, a block scalar, or a nested block."""
        nonlocal i
        rest = strip_comment(rest).strip()
        if rest and rest[0] in "|>":
            return block_scalar(rest, ind)
        if rest:
            return flow(rest)
        skip()
        if i < n and (indent(lines[i]) > ind or (indent(lines[i]) == ind and lines[i].lstrip().startswith("- "))):
            return node(indent(lines[i]))
        return None

    def node(ind):
        nonlocal i
        skip()
        if lines[i].lstrip().startswith("- ") or lines[i].strip() == "-":
            out = []
            while True:
                skip()
                if i >= n or indent(lines[i]) != ind or not (lines[i].lstrip().startswith("- ") or lines[i].strip() == "-"):
                    return out
                s = lines[i]; after = s[ind + 1:]
                inner = ind + 1 + (len(after) - len(after.lstrip(" ")))
                content = strip_comment(after).strip()
                kv = key_value(content) if not content or content[0] not in "[{'\"" else None
                if kv:                                  # "- key: value" opens a mapping at the item's indentation
                    lines[i] = " " * inner + after.lstrip(" ")
                    out.append(node(inner))
                else:
                    i += 1
                    out.append(value(content, ind))
        out = {}
        while True:
            skip()
            if i >= n or indent(lines[i]) != ind:
                return out
            s = lines[i]
            kv = key_value(s.strip())
            if not kv:
                raise ValueError(f"line {i + 1}: not a mapping entry: {s.strip()[:60]}")
            i += 1
            out[kv[0]] = value(kv[1], ind)

    skip()
    return node(indent(lines[i])) if i < n else None


# ---- `if` expressions, evaluated at the dispatch defaults ----------------------------------------------------------------

class Unknown(Exception):
    pass


def evaluate(expr, inputs, results=None):
    """The value of a GitHub `if` expression at the input defaults; raises Unknown for anything it cannot know.
    results: {job: 'success' or 'skipped'} for the job's direct needs; needs.<job>.result of a job not listed is null,
    as on GitHub, where the needs context holds only the direct needs. Without results (a bare expression) it is success."""
    expr = re.sub(r"^\$\{\{(.*)\}\}$", r"\1", expr.strip()).strip()
    toks = re.findall(r"'(?:[^']|'')*'|==|!=|&&|\|\||[!()]|[A-Za-z_][\w.-]*\(\)|[A-Za-z_][\w.-]*|\d+", expr)
    if re.sub(r"\s", "", expr) != "".join(toks):
        raise Unknown(expr)
    pos = 0

    def atom():
        nonlocal pos
        t = toks[pos]; pos += 1
        if t == "(":
            v = disj()
            pos += 1
            return v
        if t == "!":
            return not truthy(atom())
        if t.startswith("'"):
            return t[1:-1].replace("''", "'")
        if t.isdigit():
            return int(t)
        if t in ("always()", "success()"):
            return True
        if t in ("failure()", "cancelled()"):
            return False
        if t == "github.event_name":
            return "workflow_dispatch"
        m = re.fullmatch(r"inputs\.([\w-]+)", t)
        if m:
            d = (inputs.get(m.group(1)) or {}).get("default")
            return "" if d is None else d
        m = re.fullmatch(r"needs\.([\w-]+)\.result", t)
        if m:
            return "success" if results is None else results.get(m.group(1))
        raise Unknown(t)

    def truthy(v):
        return v not in ("", 0, False, None)

    def comp():
        nonlocal pos
        a = atom()
        while pos < len(toks) and toks[pos] in ("==", "!="):
            op = toks[pos]; pos += 1
            b = atom()
            eq = str(a).lower() == str(b).lower()
            a = eq if op == "==" else not eq
        return a

    def conj():
        nonlocal pos
        a = comp()
        while pos < len(toks) and toks[pos] == "&&":
            pos += 1
            b = comp()
            a = b if truthy(a) else a
        return a

    def disj():
        nonlocal pos
        a = conj()
        while pos < len(toks) and toks[pos] == "||":
            pos += 1
            b = conj()
            a = a if truthy(a) else b
        return a

    v = disj()
    if pos != len(toks):
        raise Unknown(expr)
    return truthy(v)


# ---- sizes ----------------------------------------------------------------------------------------------------------------

DYN = re.compile(r"^\$\{\{\s*fromJSON\(\s*needs\.([\w-]+)\.outputs\.([\w-]+)\s*\)\s*\}\}$")


def run_text(job):
    return "\n".join(str(s.get("run") or "") for s in (job.get("steps") or []) if isinstance(s, dict))


def input_range(inp):
    m = re.search(r"\((\d+)-(\d+)\b", str((inp or {}).get("description") or ""))
    return (int(m.group(1)), int(m.group(2))) if m else None


def axis(name, v, w, inputs):
    """(count at the defaults or None, largest count or None, name for a symbolic bound, note for the table)."""
    if isinstance(v, list):
        return len(v), len(v), name, None
    m = DYN.match(str(v).strip())
    if not m:
        return None, None, name, f"{name} dynamic"
    src, out = m.groups()
    inp = inputs.get(out)
    d = (inp or {}).get("default")
    counted = re.search(rf"""\b{re.escape(out)}=\$\((?:seq 1 |jq\b[^\n]*range\(1;)""", run_text(w["jobs"].get(src) or {}))
    if inp is not None and counted and re.fullmatch(r"\d+", str(d)):
        rng = input_range(inp)
        hi = rng[1] if rng else None
        return int(d), hi, out, f"{name}: input {out}, default {d}" + (f", 1-{hi}" if hi else ", no documented range")
    return None, None, out, f"{name} dynamic"


def job_rows(w):
    on = w.get("on") or {}
    inputs = ((on.get("workflow_dispatch") or {}).get("inputs") or {}) if isinstance(on, dict) else {}
    caps = []
    for inp in inputs.values():
        for m in re.finditer(r"\b([a-z_]+(?: x [a-z_]+)+) is at most (\d+)", str((inp or {}).get("description") or "")):
            caps.append((set(m.group(1).split(" x ")), int(m.group(2))))
    rows, results = [], {}
    for jid, job in (w.get("jobs") or {}).items():
        t = job.get("timeout-minutes")
        if isinstance(t, str):                            # an expression: named after what it reads
            mm = re.search(r"(?:outputs|matrix)\.([\w-]+)", t)
            t = mm.group(1) if mm else "timeout"
        cond, runs = job.get("if"), True
        needs = job.get("needs") or []
        needs = [needs] if isinstance(needs, str) else needs
        if any(results.get(n) == "skipped" for n in needs) and not re.search(r"\b(always|failure|cancelled)\(\)", str(cond or "")):
            runs, cond = False, None                      # GitHub skips a job whose need was skipped, unless its if says otherwise
        elif cond is not None:
            try:
                runs, cond = evaluate(str(cond), inputs, {n: results.get(n, "success") for n in needs}), None
            except Unknown:
                pass                                      # counted as running, marked "if"
        results[jid] = "success" if runs else "skipped"
        strategy = job.get("strategy") or {}
        m = strategy.get("matrix")
        r = {"job": jid, "timeout": t, "runs": runs, "if": cond, "max_parallel": strategy.get("max-parallel"),
             "matrix": isinstance(m, dict), "known": 1, "known_most": 1, "names": [], "names_most": [], "notes": [], "cap": None}
        if isinstance(m, dict):
            axes = {k: v for k, v in m.items() if k not in ("include", "exclude")} or (
                {"include": m["include"]} if "include" in m else {})
            outs = set()
            for k, v in axes.items():
                c, hi, label, note = axis(k, v, w, inputs)
                dm = None if isinstance(v, list) else DYN.match(str(v).strip())
                if dm:
                    outs.add(dm.group(2))
                if note:
                    r["notes"].append(note)
                if c is None:
                    r["names"].append(label)
                else:
                    r["known"] *= c
                if hi is None:
                    r["names_most"].append(label)
                else:
                    r["known_most"] *= hi
            if isinstance(m.get("exclude"), list) and m["exclude"]:
                r["notes"].append(f"exclude {len(m['exclude'])} (not subtracted)")
            for terms, cap in caps:
                if outs and terms == outs:
                    r["cap"] = cap
                    r["notes"].append(f"at most {cap} jobs")
        rows.append(r)
    return rows


def fmt(n):
    return f"{n:,}"


def count_text(r, most):
    known, names = (r["known_most"], r["names_most"]) if most else (r["known"], r["names"])
    if not names:
        n = known if not (most and r["cap"]) else min(known, r["cap"])
        return n, str(n)
    if most and r["cap"]:
        return r["cap"], str(r["cap"])
    return None, " x ".join(([str(known)] if known != 1 else []) + names)


def sum_minutes(rows, most):
    """The upper bound: a number when every running job's limit and count are known, else the known part plus terms."""
    total, terms = 0, []
    for r in rows:
        if not r["runs"] or r["timeout"] is None:
            continue
        n, ntext = count_text(r, most)
        t = r["timeout"]
        if isinstance(t, int) and n is not None:
            total += t * n
        else:
            terms.append(f"{t}" + ("" if ntext == "1" else f" x {ntext}"))
    return (fmt(total) if total or not terms else "") + (" + " if total and terms else "") + " + ".join(terms)


def table():
    out = ["| workflow | jobs: timeout-minutes x jobs at the defaults | max-parallel | upper bound at the defaults, min | largest: input ranges and caps, min |",
           "|---|---|---|---|---|"]
    for fn in sorted(os.listdir(WF)):
        if not fn.endswith((".yml", ".yaml")):
            continue
        with open(os.path.join(WF, fn)) as f:
            w = load_yaml(f.read())
        rows = job_rows(w)
        cells, mp = [], []
        for r in rows:
            ts = "none" if r["timeout"] is None else str(r["timeout"])
            if not r["runs"]:
                cells.append(f"{r['job']} {ts} x 0 (skipped at the defaults)")
                continue
            _, ntext = count_text(r, False)
            c = f"{r['job']} {ts}" + (f" x {ntext}" if r["matrix"] else "")
            if r["notes"]:
                c += f" ({'; '.join(r['notes'])})"
            if r["if"] is not None:
                c += " (if)"
            cells.append(c)
            if r["max_parallel"]:
                mp.append(f"{r['job']} {r['max_parallel']}")
        lo, hi = sum_minutes(rows, False), sum_minutes(rows, True)
        out.append(f"| `{fn}` | {'; '.join(cells)} | {', '.join(mp) or '-'} | {lo} | {hi if hi != lo else 'same'} |")
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--check", action="store_true", help="exit 1 when docs/workflows.md's table differs from the generated one")
    g.add_argument("--write", action="store_true", help="write the table into docs/workflows.md between the markers")
    a = ap.parse_args()
    t = table()
    if not (a.check or a.write):
        sys.stdout.write(t)
        return 0
    with open(DOC) as f:
        doc = f.read()
    if doc.count(BEGIN) != 1 or doc.count(END) != 1 or doc.index(BEGIN) > doc.index(END):
        print(f"workflow-sizes: {DOC} needs one {BEGIN} line and one {END} line after it", file=sys.stderr)
        return 2
    head, rest = doc.split(BEGIN, 1)
    old, tail = rest.split(END, 1)
    new = head + BEGIN + "\n" + t + END + tail
    if a.check:
        if old == "\n" + t:
            print("workflow-sizes: the table in docs/workflows.md is up to date")
            return 0
        print("workflow-sizes: the table in docs/workflows.md is STALE (run: python3 ci/workflow-sizes.py --write)", file=sys.stderr)
        return 1
    with open(DOC, "w") as f:
        f.write(new)
    print("workflow-sizes: wrote the table into docs/workflows.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
