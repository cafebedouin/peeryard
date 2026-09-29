#!/usr/bin/env python3
"""diagnose.py: names why a group of nodes did not reach its goal, from a short history of their sampled /info.

A port of ConvergenceDiagnosis (the classifier written for upstream's integration tests, where every failing run
ended as a bare timeout): the same causes, rule order, persistence window and spans. A round is one sample of every
node; the history is oldest first. Rules, in order: infrastructure first (a node that is down explains everything
after it), then the defect that needs no history (#525), then the ways a chain can stop moving, then "it was still
moving".

  python3 diag/diagnose.py <samples.jsonl> [--no-expect-peers] [--json]

Beside samples.jsonl it reads, when present: events.jsonl + effective.json (a node every one of whose links ends cut
- a partition with no later heal - is PARTITIONED: the run's cause is then PARTITIONED, naming the node, and the
samples-based cause is kept as `observed`), and messages.jsonl + wire/*.stats.json (diag/wire.py: a
LIGHTER_FORK_NOT_SWITCHING is split by what crossed the wire, below). The rig runs this only on a non-PASS verdict.

Wire split of LIGHTER_FORK_NOT_SWITCHING (descriptive; no stage asserts a code-level reason). Per lower node, over the
window from its last height change (else the whole run) to the end, on its links to the nodes on a higher chain
("back" = frames from a higher node), the first stage that fails names it: NO_SYNC (no SyncInfo either way),
SYNC_NO_INV (no Inv back), INV_NOT_REQUESTED (no RequestModifier from the lower node), REQUEST_NOT_ANSWERED (no
Modifiers back), else DELIVERED_NO_HEIGHT_CHANGE (block sections arrived; not a claim they were the needed ones). Inv,
RequestModifier and Modifiers count only for block-section type ids (101, 102, 104, 108); SyncInfo always counts. A
stage passes if it passes on any of the links. The labels are absence claims, so a verdict counts only when those
links show no gap, no desync and no capture drop in the window; otherwise it is `unreliable`.

samples.jsonl: one round per line, {"t": <ms>, "nodes": [{"name", "state", "answered", "headersHeight", "fullHeight",
"bestHeaderId", "bestFullHeaderId", "peers", "mining"}]}; state is "running", "paused", "unknown" or anything else for
a node that is not running (e.g. "down", "exited(137)"). Missing values are null. Standard library only.
"""
import glob
import json
import os
import sys
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence, Tuple

RUNNING, PAUSED, UNKNOWN_STATE = "running", "paused", "unknown"

NODE_DOWN = "NODE_DOWN"
NODE_UNRESPONSIVE = "NODE_UNRESPONSIVE"
NO_PEERS = "NO_PEERS"
NODE_LAGGING = "NODE_LAGGING"
BEST_CHAIN_INCONSISTENT = "BEST_CHAIN_INCONSISTENT"
EQUAL_HEIGHT_TIE = "EQUAL_HEIGHT_TIE"
HEADERS_AHEAD_FULL_STUCK = "HEADERS_AHEAD_FULL_STUCK"
LIGHTER_FORK_NOT_SWITCHING = "LIGHTER_FORK_NOT_SWITCHING"
CHAIN_STALLED = "CHAIN_STALLED"
STILL_PROGRESSING = "STILL_PROGRESSING"
PARTITIONED = "PARTITIONED"
UNKNOWN = "UNKNOWN"
# wire stages of LIGHTER_FORK_NOT_SWITCHING, in ladder order
NO_SYNC, SYNC_NO_INV, INV_NOT_REQUESTED = "NO_SYNC", "SYNC_NO_INV", "INV_NOT_REQUESTED"
REQUEST_NOT_ANSWERED, DELIVERED_NO_HEIGHT_CHANGE = "REQUEST_NOT_ANSWERED", "DELIVERED_NO_HEIGHT_CHANGE"
UNRELIABLE = "unreliable"
BLOCK_SECTIONS = (101, 102, 104, 108)

PERSIST_ROUNDS = 3          # rounds a condition must hold before it is named (one slow answer is not a cause)
PROGRESS_SPAN_MS = 30_000   # progress is judged over this span, so early progress cannot mask a later stall
LAG_SPAN_MS = 30_000        # a node frozen over this span while another gained LAG_BLOCKS is lagging
LAG_BLOCKS = 3


@dataclass(frozen=True)
class NodeSample:
    name: str
    at: int
    state: str
    answered: bool
    headers: Optional[int]
    full: Optional[int]
    header_id: Optional[str]
    full_id: Optional[str]
    peers: Optional[int]
    mining: Optional[bool]

    @property
    def running(self) -> bool:
        # a paused node still exists (silence, not death); an unknown state proves nothing
        return self.state in (RUNNING, PAUSED, UNKNOWN_STATE)

    @property
    def best_chain_inconsistent(self) -> bool:
        # full block and header at the same height but on different forks (issue #525)
        return (self.full is not None and self.full == self.headers and self.full_id is not None
                and self.header_id is not None and self.full_id != self.header_id)

    def render(self) -> str:
        def short(v):
            return v[:8] if v else "-"

        def num(v):
            return "-" if v is None else str(v)
        mining = "-" if self.mining is None else str(self.mining).lower()
        return (f"{self.name}[{self.state}] headers={num(self.headers)}:{short(self.header_id)} "
                f"full={num(self.full)}:{short(self.full_id)} peers={num(self.peers)} mining={mining}")


@dataclass(frozen=True)
class Diagnosis:
    cause: str
    evidence: str
    observed: Optional[str] = None                 # the samples-based cause, when an event-based one overrides it
    wire: List[dict] = field(default_factory=list)  # the wire split, one entry per lower node

    def __str__(self) -> str:
        return f"{self.cause}: {self.evidence}"

    def as_json(self) -> dict:
        d = {"cause": self.cause, "evidence": self.evidence}
        if self.observed is not None:
            d["observed"] = self.observed
        if self.wire:
            d["wire"] = self.wire
        return d


Round = Sequence[NodeSample]


def _find(rnd: Round, name: str) -> Optional[NodeSample]:
    return next((n for n in rnd if n.name == name), None)


def _window(history: Sequence[Round], span_ms: int) -> List[Round]:
    last = history[-1]
    cutoff = max(n.at for n in last) - span_ms
    return [r for r in history if any(n.at >= cutoff for n in r)]


def lagging(history: Sequence[Round]) -> List[Tuple[NodeSample, int]]:
    """Nodes frozen over the last LAG_SPAN while the group moved: out of the network, or wedged."""
    if not history or not history[-1]:
        return []
    last = history[-1]
    window = _window(history, LAG_SPAN_MS)
    if len(window) < 2:
        return []

    def gain(name):
        first, end = _find(window[0], name), _find(last, name)
        if first is None or end is None or first.full is None or end.full is None:
            return None
        return end.full - first.full
    gains = [g for g in (gain(n.name) for n in last) if g is not None]
    best = max(gains) if gains else 0
    if best < LAG_BLOCKS:
        return []
    out = []
    for n in last:
        f = _find(window[0], n.name)
        moved = f is not None and (f.full != n.full or f.headers != n.headers)
        if n.answered and not moved:
            out.append((n, best))
    return out


def full_stuck_behind_headers(history: Sequence[Round]) -> List[NodeSample]:
    """Nodes whose full height did not move over LAG_SPAN while their headers stayed ahead of it."""
    if not history or not history[-1]:
        return []
    last = history[-1]
    cutoff = max(n.at for n in last) - LAG_SPAN_MS
    window = _window(history, LAG_SPAN_MS)
    if len(window) < 2 or min(n.at for n in window[0]) > cutoff + LAG_SPAN_MS // 2:
        return []
    out = []
    for n in last:
        start = _find(window[0], n.name)
        start_full = start.full if start else None
        behind = n.headers is not None and n.full is not None and n.headers > n.full
        if n.answered and behind and start_full is not None and start_full == n.full:
            out.append(n)
    return out


def partitioned(events: Sequence[dict], links: Sequence[Tuple[str, str]]) -> List[str]:
    """Nodes every one of whose links ends cut: its last partition/heal event is a partition (relaunches, crashes and
    netem changes are not cuts). A node with no link is never partitioned."""
    cut: Dict[frozenset, bool] = {}
    for e in events:
        if e.get("kind") in ("partition", "heal"):
            cut[frozenset((e.get("a"), e.get("b")))] = e["kind"] == "partition"
    nodes = []
    for n in dict.fromkeys(x for ln in links for x in ln):
        mine = [frozenset(ln) for ln in links if n in ln]
        if mine and all(cut.get(k, False) for k in mine):
            nodes.append(n)
    return nodes


def wire_split(history: Sequence[Round], lower: str, higher: Sequence[str], messages: Sequence[dict],
               drop_seconds: Dict[str, List[int]]) -> dict:
    """The wire ladder for one lower node (module doc). drop_seconds: link -> times (ms) of stats seconds with drops; a link
    absent from it has no stats file, so its drops are unknown and the stage is unreliable."""
    t_change = None
    prev = None
    for rnd in history:
        s = _find(rnd, lower)
        if s is None or not s.answered:
            continue
        cur = (s.headers, s.full)
        if prev is not None and cur != prev:
            t_change = s.at
        prev = cur
    hs = set(higher)
    ms = [m for m in messages if (t_change is None or m.get("t_ms", 0) >= t_change)
          and {m.get("from"), m.get("to")} in ({lower, h} for h in hs)]
    links = sorted({m["link"] for m in messages if {m.get("from"), m.get("to")} in ({lower, h} for h in hs)})

    def frames(name, frm=None, sections=True):
        return [m for m in ms if m.get("kind") == "frame" and m.get("name") == name
                and (frm is None or (m.get("from") in hs if frm == "higher" else m.get("from") == lower))
                and (not sections or m.get("type_id") in BLOCK_SECTIONS)]
    counts = {"sync": len(frames("SyncInfo", sections=False)), "inv_back": len(frames("Inv", "higher")),
              "request": len(frames("RequestModifier", "lower")), "modifiers_back": len(frames("Modifiers", "higher"))}
    stage = (NO_SYNC if not counts["sync"] else SYNC_NO_INV if not counts["inv_back"] else
             INV_NOT_REQUESTED if not counts["request"] else REQUEST_NOT_ANSWERED if not counts["modifiers_back"]
             else DELIVERED_NO_HEIGHT_CHANGE)
    gaps = sum(1 for m in ms if m.get("kind") in ("gap", "desync"))
    drops = sum(1 for ln in links for t in drop_seconds.get(ln, []) if t_change is None or t >= t_change - 1000)
    no_stats = [ln for ln in links if ln not in drop_seconds]   # no stats file: drops unknown, not zero
    out = {"lower": lower, "higher": sorted(hs), "links": links, "window_from_ms": t_change, "counts": counts,
           "gaps_or_desyncs": gaps, "drop_seconds": drops, "links_without_stats": no_stats}
    if not links:
        out["stage"] = UNRELIABLE
        out["why"] = "no captured link between the lower node and a higher one"
    elif no_stats:
        out["stage"] = UNRELIABLE
        out["why"] = "no capture stats for a link in the window: its drops are unknown, so an absence is not firm"
        out["would_be"] = stage
    elif gaps or drops:
        out["stage"] = UNRELIABLE
        out["why"] = "gap, desync or capture drop in the window: an absence may be a loss of capture"
        out["would_be"] = stage
    else:
        out["stage"] = stage
    return out


def diagnose(history: Sequence[Round], expect_peers: bool = True, events: Optional[Sequence[dict]] = None,
             links: Optional[Sequence[Tuple[str, str]]] = None, messages: Optional[Sequence[dict]] = None,
             drop_seconds: Optional[Dict[str, List[int]]] = None) -> Diagnosis:
    d = _diagnose_samples(history, expect_peers)
    cut = partitioned(events, links) if events is not None and links else []
    if cut:   # never split: a cut explains the absence of traffic
        return Diagnosis(PARTITIONED, f"{', '.join(cut)} cut from every peer at the run's end (each of its links' "
                                      f"last partition/heal event is a partition); samples read {d.cause}: "
                                      f"{d.evidence}", observed=d.cause)
    if messages and d.cause == LIGHTER_FORK_NOT_SWITCHING and history and history[-1]:
        last = history[-1]
        top = max((n.full for n in last if n.full is not None), default=None)
        split = []
        for lo in (n for n in last if n.full is not None and n.full == n.headers and top is not None and n.full < top):
            hi = [n.name for n in last if n.full is not None and n.full > lo.full and n.full_id != lo.full_id]
            split.append(wire_split(history, lo.name, hi, messages, drop_seconds or {}))
        stages = "; ".join(f"{w['lower']} {w['stage']}" + (f" (would be {w['would_be']})" if "would_be" in w else "")
                           for w in split)
        d = Diagnosis(d.cause, f"{d.evidence} Wire: {stages}.", wire=split)
    return d


def _diagnose_samples(history: Sequence[Round], expect_peers: bool = True) -> Diagnosis:
    if not history or not history[-1]:
        return Diagnosis(UNKNOWN, "no samples were taken")
    last = history[-1]
    tail = history[-PERSIST_ROUNDS:]

    def persistent(name, pred) -> bool:
        # named only when it held in every retained round, and there were at least two
        return len(tail) >= 2 and all((s := _find(r, name)) is not None and pred(s) for r in tail)

    down = [n for n in last if persistent(n.name, lambda s: not s.running)]
    silent = [n for n in last if n.running and persistent(n.name, lambda s: not s.answered)]
    lonely = [n for n in last if persistent(n.name, lambda s: s.peers == 0)] if expect_peers else []
    inconsistent = [n for n in last if persistent(n.name, lambda s: s.best_chain_inconsistent)]
    stuck_full = full_stuck_behind_headers(history)
    laggers = [(n, g) for n, g in lagging(history) if not any(s.name == n.name for s in stuck_full)]

    def r(ns):
        return "; ".join(n.render() for n in ns)
    if down:
        return Diagnosis(NODE_DOWN, r(down))
    if silent:
        return Diagnosis(NODE_UNRESPONSIVE, f"no REST answer for {PERSIST_ROUNDS} rounds: {r(silent)}")
    if lonely:
        return Diagnosis(NO_PEERS, f"0 connected peers for {PERSIST_ROUNDS} rounds: {r(lonely)}")
    if inconsistent:
        return Diagnosis(BEST_CHAIN_INCONSISTENT,
                         f"full block and header on different forks at one height (#525): {r(inconsistent)}")
    if stuck_full:
        return Diagnosis(HEADERS_AHEAD_FULL_STUCK,
                         f"full height unchanged for {LAG_SPAN_MS // 1000} s while headers are ahead of it: "
                         f"{r(stuck_full)}. All: {r(last)}")
    if laggers:
        return Diagnosis(NODE_LAGGING,
                         f"heights unchanged for {LAG_SPAN_MS // 1000} s while others gained {laggers[0][1]} blocks "
                         f"(a removed link keeps its TCP peers listed for minutes, so a peer count is no proof of "
                         f"connectivity): {r([n for n, _ in laggers])}")
    return _progress(history, last)


def _progress(history: Sequence[Round], last: Round) -> Diagnosis:
    window = _window(history, PROGRESS_SPAN_MS)
    first = window[0] if len(window) >= 2 else history[0]
    span_s = (max(n.at for n in last) - min(n.at for n in first)) / 1000.0

    def heights(rnd):
        return {n.name: (n.headers, n.full) for n in rnd if n.answered}
    before, now = heights(first), heights(last)
    common = set(before) & set(now)
    moved = len(history) >= 2 and any(before[n] != now[n] for n in common)
    everyone = "; ".join(n.render() for n in last)
    if moved:
        # per node, over the nodes present in both rounds (a node that fell silent does not count as a loss)
        gains = [now[n][1] - before[n][1] for n in common if before[n][1] is not None and now[n][1] is not None]
        per_min = (sum(gains) / len(gains) / span_s * 60) if span_s > 0 and gains else 0.0
        return Diagnosis(STILL_PROGRESSING,
                         f"heights were still moving ({per_min:.1f} blocks/min per node over the last {span_s:.0f} s): "
                         f"raise the timeout, or the machine is slow. {everyone}")
    if len(history) < 2:
        return Diagnosis(UNKNOWN, f"one round only, progress cannot be judged. {everyone}")
    tips = {n.full_id for n in last if n.full_id is not None}
    full_heights = {n.full for n in last if n.full is not None}
    anyone_mining = any(n.mining is True for n in last)
    stuck_behind = [n for n in last if n.headers is not None and n.full is not None and n.headers > n.full]
    top = max((n.full for n in last if n.full is not None), default=None)
    lower_unaware = [n for n in last if n.full is not None and n.full == n.headers and top is not None and n.full < top]
    frozen = f"no height moved for {span_s:.0f} s"
    mining = "on" if anyone_mining else "off"
    if stuck_behind:
        return Diagnosis(HEADERS_AHEAD_FULL_STUCK,
                         f"{frozen}; headers ahead of full blocks on: {'; '.join(n.render() for n in stuck_behind)}. "
                         f"All: {everyone}")
    if len(tips) > 1 and len(full_heights) == 1:
        why = ("A miner is on and no block came: the miner may be wedged. " if anyone_mining else
               "Nothing breaks the tie unless someone mines; with mining off this is a property of the scenario, "
               "not a node defect. ")
        return Diagnosis(EQUAL_HEIGHT_TIE, f"{frozen}; equal heights, different tips, mining={mining}. {why}{everyone}")
    if len(tips) > 1 and lower_unaware:
        return Diagnosis(LIGHTER_FORK_NOT_SWITCHING,
                         f"{frozen}; a lower node never took the higher chain's headers: "
                         f"{'; '.join(n.render() for n in lower_unaware)}. All: {everyone}")
    if len(tips) <= 1:
        return Diagnosis(CHAIN_STALLED, f"{frozen} and tips agree: nobody is producing blocks (mining={mining}). {everyone}")
    return Diagnosis(UNKNOWN, f"{frozen}. {everyone}")


def report(history: Sequence[Round], goal: str, expect_peers: bool = True) -> str:
    """The report a failing run prints: the named cause, then the last rounds in full."""
    last_rounds = list(history)[-PERSIST_ROUNDS:]
    lines = [f"  round -{len(last_rounds) - 1 - i}: " + "; ".join(n.render() for n in rnd)
             for i, rnd in enumerate(last_rounds)]
    return f"{goal}. CAUSE {diagnose(history, expect_peers)}\n" + "\n".join(lines)


def load_beside(samples_path: str) -> dict:
    """events, links, messages and drop_seconds from the run dir holding samples.jsonl (each absent -> None / {})."""
    d = os.path.dirname(os.path.abspath(samples_path))
    out: dict = {"events": None, "links": None, "messages": None, "drop_seconds": {}}

    def jsonl(p):
        with open(p) as fh:
            return [json.loads(line) for line in fh if line.strip()]
    if os.path.exists(os.path.join(d, "events.jsonl")):
        out["events"] = jsonl(os.path.join(d, "events.jsonl"))
    if os.path.exists(os.path.join(d, "effective.json")):
        with open(os.path.join(d, "effective.json")) as fh:
            out["links"] = [(ln["a"], ln["b"]) for ln in json.load(fh).get("links", [])]
    if os.path.exists(os.path.join(d, "messages.jsonl")):
        out["messages"] = jsonl(os.path.join(d, "messages.jsonl"))
        for sp in glob.glob(os.path.join(d, "wire", "*.stats.json")):
            with open(sp) as fh:
                st = json.load(fh)
            out["drop_seconds"][os.path.basename(sp)[:-len(".stats.json")]] = [x[0] for x in st.get("series", []) if x[2]]
    return out


def load(path: str) -> List[List[NodeSample]]:
    history = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            if row.get("event"):
                continue  # an out-of-cycle sample taken at a rig event: rounds stay one sampling interval apart
            t = int(row.get("t", 0))
            history.append([NodeSample(name=n["name"], at=int(n.get("t", t)), state=n.get("state", RUNNING),
                                       answered=bool(n.get("answered")), headers=n.get("headersHeight"),
                                       full=n.get("fullHeight"), header_id=n.get("bestHeaderId"),
                                       full_id=n.get("bestFullHeaderId"), peers=n.get("peers"),
                                       mining=n.get("mining")) for n in row.get("nodes", [])])
    return history


def main(argv: List[str]) -> int:
    args = [a for a in argv if not a.startswith("--")]
    if len(args) != 1:
        print(__doc__.strip().splitlines()[4], file=sys.stderr)
        return 2
    d = diagnose(load(args[0]), expect_peers="--no-expect-peers" not in argv, **load_beside(args[0]))
    print(json.dumps(d.as_json()) if "--json" in argv else str(d))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
