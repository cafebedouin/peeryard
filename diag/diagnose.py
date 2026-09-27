#!/usr/bin/env python3
"""diagnose.py: names why a group of nodes did not reach its goal, from a short history of their sampled /info.

A port of ConvergenceDiagnosis (the classifier written for upstream's integration tests, where every failing run
ended as a bare timeout): the same causes, rule order, persistence window and spans. A round is one sample of every
node; the history is oldest first. Rules, in order: infrastructure first (a node that is down explains everything
after it), then the defect that needs no history (#525), then the ways a chain can stop moving, then "it was still
moving".

  python3 diag/diagnose.py <samples.jsonl> [--no-expect-peers] [--json]

samples.jsonl: one round per line, {"t": <ms>, "nodes": [{"name", "state", "answered", "headersHeight", "fullHeight",
"bestHeaderId", "bestFullHeaderId", "peers", "mining"}]}; state is "running", "paused", "unknown" or anything else for
a node that is not running (e.g. "down", "exited(137)"). Missing values are null. Standard library only.
"""
import json
import sys
from dataclasses import dataclass
from typing import List, Optional, Sequence, Tuple

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
UNKNOWN = "UNKNOWN"

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

    def __str__(self) -> str:
        return f"{self.cause}: {self.evidence}"


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


def diagnose(history: Sequence[Round], expect_peers: bool = True) -> Diagnosis:
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
    d = diagnose(load(args[0]), expect_peers="--no-expect-peers" not in argv)
    print(json.dumps({"cause": d.cause, "evidence": d.evidence}) if "--json" in argv else str(d))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
