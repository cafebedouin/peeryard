"""history.py: one small snapshot of the duplicate data per day (history/<date>.json, history/index.json), read back
from the published site, so a baseline accumulates. Part of queue/build.py (see its docstring)."""
import json, os, re, time, urllib.error, urllib.request


SCHEMA_VERSION = 1
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def fetch_json(url, tries=4):
    """GET url as JSON; None on 404; raises on anything else after retries (a history that cannot be read must not be
    overwritten with a shorter one)."""
    for attempt in range(tries):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "peeryard-queue"}), timeout=60) as r:
                return json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            if attempt == tries - 1:
                raise
        except (urllib.error.URLError, TimeoutError):
            if attempt == tries - 1:
                raise
        time.sleep(10 * (attempt + 1))


def load_history(source):
    """The snapshots published so far, {date: snapshot}. source is the base URL of the published site (the Pages deploy
    replaces the whole site each run, so the previous days are read back from it), or a local directory holding
    history/. No index yet means no history yet; an index whose listed days cannot all be read is an error."""
    if not source:
        return {}
    if not source.startswith(("http://", "https://")):
        d = os.path.join(source, "history")
        return {f[:-5]: json.load(open(os.path.join(d, f))) for f in sorted(os.listdir(d))
                if DATE_RE.match(f[:-5]) and f.endswith(".json")} if os.path.isdir(d) else {}
    base, bust = source.rstrip("/") + "/history/", f"?t={int(time.time())}"   # past the Pages CDN cache (10 min)
    idx = fetch_json(base + "index.json" + bust)
    if idx is None:
        return {}
    out = {}
    for day in idx.get("dates", []):
        if not DATE_RE.match(day):
            continue
        snap = fetch_json(base + day + ".json" + bust)
        if snap is None:
            raise RuntimeError(f"history: {day} is in the published index but not served")
        out[day] = snap
    return out


def snapshot(generated_at, repo, allprs, rows, exact, related, sc_error, uncompared, cov=None, out_counts=None):
    """Today's duplicate data, small: the groups by number, not the rows; since 2026-11-09 also the coverage counts and the
    outcome counts, so a burn-down can be read from history/."""
    return {"schema_version": SCHEMA_VERSION, "date": generated_at[:10], "generated_at": generated_at, "repo": repo,
            "open_prs": len(allprs), "open_ready_prs": len(rows), "coverage": cov, "outcomes": out_counts,
            "same_change": [{"patch_id": g["patch_id"], "prs": g["prs"], "files": len(g["files"]),
                             "changed_lines": g.get("changed_lines")} for g in exact],
            "same_issue": [{"issue": g["issue"], "prs": g["prs"], "pairs": [p["prs"] for p in g["pairs"]]} for g in related],
            "same_change_error": sc_error, "same_change_uncompared": uncompared}


def write_history(out, prior, snap):
    """Writes every prior snapshot and today's (today's replaces an earlier run of the same day) to <out>/history/, with
    history/index.json listing the dates, oldest first."""
    days = dict(prior)
    days[snap["date"]] = snap
    d = os.path.join(out, "history")
    os.makedirs(d, exist_ok=True)
    for day, s in days.items():
        with open(os.path.join(d, day + ".json"), "w") as f:
            json.dump(s, f, separators=(",", ":"))
    dates = sorted(days)
    with open(os.path.join(d, "index.json"), "w") as f:
        json.dump({"schema_version": SCHEMA_VERSION, "repo": snap["repo"], "dates": dates, "latest": dates[-1],
                   "path": "history/<date>.json"}, f, indent=1)
    return dates
