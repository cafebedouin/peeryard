#!/usr/bin/env python3
"""matrix_value.py: what a Matrix (weak-blocks) run's input blocks carried, cost on the wire and fetched again, under
the run's payment load. A report: nothing here judges a run.

  python3 diag/matrix_value.py <run dir> [--from <HH:MM:SS|epoch ms>] [--to <...>] [--matrix A,B] [--json <out>]

<run dir> is a rig output directory (node_X.log, messages.jsonl, txwatch.jsonl, ...) or a patch-compare run artifact
(rig.log, nodes/node_X.log.gz, load/*.jsonl.gz, messages.jsonl.gz); each file is looked up in both layouts. The window
is matrix-compat's: from its last "all miners mining from HH:MM:SS" line to its "window end HH:MM:SS" line (or the
start plus its last "t=Ns" sample) in rig.log, unless --from/--to are given. Log and rig times are HH:MM:SS of the
host's clock (UTC on GitHub runners), anchored to the day of the run's first epoch-ms record.

Sections (each prints what it read, and "n/a: <why>" when its source is absent):
  BYTES     messages.jsonl (diag/wire.py; the rig's PEERYARD_WIRE=1). Per sending node, bytes per minute in the window
            by message group and by message/type, and the same split by the receiver's kind (Matrix or reference).
            Bytes are P2P frame bytes: 9 (magic, code, length) + 4 (checksum) + payload; TCP/IP headers, the
            handshake and retransmissions are not counted. A node is Matrix if it sent an InputBlock (100) or
            OrderingBlock (106) frame, or its log shows input blocks.
  REQUESTS  BlockTransactions (type 102) requests each node sent, per ordering block it received. wire: a
            RequestModifier (22) of type 102 sent by n, tied to the block whose transactions section it names (the
            section ids of every header seen on the wire, wire.py tx_section_id(s)); "received" = a block n got as an
            OrderingBlock (106) or a header (Modifiers 101) and did not send first. log (no wire needed): per node,
            the sum of "Got N modifiers of type 102" lines, the "Applying block transactions [rebuilt ]from
            input-blocks" lines and the "Double application of a modifier is prohibited" lines, over the ordering
            blocks it applied and did not mine ("Valid modifier with header H ... applied to UtxoState", H not in its
            own "New block mined" lines).
  VALUE     Input blocks from the wire (InputBlock 100: ordering parent, previous input block, weak tx ids, uncle
            ids; InputBlockTxIds 102 fills the weak ids an announcement did not carry), with the full transaction ids
            of the blocks the nodes mined where txwatch recorded them ("mined" events). For each uncle u merged by
            input block X: u's transactions already in X's collected prefix (X's ancestors' own transactions and
            their uncles', and X's earlier uncles) are duplicates, the rest are unique (recovered into L). Also, for
            both builds alike, every sibling (an input block under a final-chain ordering block that is not on that
            interval's winning path, the deepest chain under it) and what became of its transactions: on the winning
            path already (duplicate), merged into it (recovered), in a later input block (re-included), or in none;
            and, of those neither on the path nor merged, how many the final chain holds anyway.
            A transaction is matched by its weak id (3 bytes of its id + 3 of its witness id); a payment or a
            final-chain transaction is matched to a weak id by the first 3 bytes of its id (a 1-in-16.7M collision
            per pair, counted as is).
  LOAD      Pool size (txwatch "pool" events), payment attempts and refusals (txload.jsonl), transactions per
            final-chain ordering block (txload_chain.jsonl), per input block (wire weak ids or txwatch), and the
            pool count each Matrix candidate was assembled from ("Assembling a block candidate ... from N
            transactions available"). A window is called saturated (proposed reading) when the pool right after
            ordering blocks is at least the 90th percentile of what an ordering block carried: the interval did
            not take what was waiting.
"""
import glob
import gzip
import json
import os
import re
from bisect import bisect_left
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone

HEX = r"([0-9a-f]{64})"
TS = re.compile(r"^(\d\d):(\d\d):(\d\d)\.(\d{3}) ")
FRAME_OVERHEAD = 9          # magic 4, code 1, length 4
CHECKSUM = 4                # only when the payload is not empty
MATRIX_CODES = {100, 102, 104, 105, 106}
MATRIX_TYPES = {-123, -122, -121}
SECTION_TYPES = {101, 102, 104, 108}


# ---------------------------------------------------------------- files and time
def locate(run, name):
    for sub in ("", "out", "nodes", "load", "wire"):
        for suf in ("", ".gz"):
            p = os.path.join(run, sub, name + suf)
            if os.path.isfile(p):
                return p
    return None


def open_text(path):
    return gzip.open(path, "rt", errors="replace") if path.endswith(".gz") else open(path, errors="replace")


def read_jsonl(path):
    out = []
    if not path:
        return out
    with open_text(path) as fh:
        for line in fh:
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    return out


def node_logs(run):
    logs = {}
    for sub in ("", "out", "nodes"):
        for p in glob.glob(os.path.join(run, sub, "node_*.log*")):
            m = re.match(r"node_([A-Za-z0-9]+)\.log(\.gz)?$", os.path.basename(p))
            if m and m.group(1) not in logs:
                logs[m.group(1)] = p
    return logs


class Clock:
    """HH:MM:SS(.mmm) of the host's clock (UTC) to epoch ms, on the day of an anchor epoch-ms value; a time more than
    12 h from the anchor is moved by a day (a run across midnight)."""

    def __init__(self, anchor_ms):
        d = datetime.fromtimestamp(anchor_ms / 1000, tz=timezone.utc)
        self.day0 = int(datetime(d.year, d.month, d.day, tzinfo=timezone.utc).timestamp() * 1000)
        self.anchor = anchor_ms

    def ms(self, h, m, s, frac=0):
        t = self.day0 + ((h * 60 + m) * 60 + s) * 1000 + frac
        if t - self.anchor > 12 * 3600000:
            t -= 86400000
        elif self.anchor - t > 12 * 3600000:
            t += 86400000
        return t

    def hms(self, text):
        h, m, s = (int(x) for x in text.split(":"))
        return self.ms(h, m, s)


def first_epoch(*recsets):
    for recs in recsets:
        for r in recs:
            t = r.get("t_ms")
            if isinstance(t, (int, float)):
                return int(t)
    return None


def window(run, clock, arg_from=None, arg_to=None):
    def parse(v):
        if v is None:
            return None
        return int(v) if re.fullmatch(r"\d{12,}", v) else clock.hms(v)
    start = end = None
    rl = locate(run, "rig.log")
    if rl:
        last_t = 0
        with open_text(rl) as fh:
            for line in fh:
                m = re.search(r"all miners mining from (\d\d:\d\d:\d\d)$", line.rstrip())
                if m:
                    start = clock.hms(m.group(1))
                m = re.search(r"\[matrix-compat\] window end (\d\d:\d\d:\d\d)", line)
                if m:
                    end = clock.hms(m.group(1))
                m = re.match(r"\[matrix-compat\] t=(\d+)s ", line)
                if m:
                    last_t = int(m.group(1))
        if start is not None and end is None and last_t:
            end = start + last_t * 1000
    start, end = parse(arg_from) or start, parse(arg_to) or end
    return start, end


def pct(vals, q):
    if not vals:
        return None
    v = sorted(vals)
    return v[min(len(v) - 1, int(q * (len(v) - 1) + 0.5))]


def fmt(x, nd=1):
    return "-" if x is None else (f"{x:.{nd}f}" if isinstance(x, float) else str(x))


# ---------------------------------------------------------------- node logs
def scan_log(path, clock):
    """Per node: the lines the sections read, with epoch-ms times."""
    r = {"mined_ordering": set(), "applied": [], "got102": [], "rebuilt": [], "fallback": [], "double": [],
         "available": [], "input_mined": [], "matrix": False}
    pat = {
        "mined": re.compile(r"New block mined, header: .*?\"id\":\"" + HEX),
        "applied": re.compile(r"Valid modifier with header " + HEX + r" .*applied to UtxoState"),
        "got102": re.compile(r"Got (\d+) modifiers of type 102 from"),
        "rebuilt": re.compile(r"Applying block transactions (?:rebuilt )?from input-blocks for " + HEX),
        "fallback": re.compile(r"Downloading block transactions fully for " + HEX),
        "double": re.compile(r"Double application of a modifier is prohibited"),
        "avail": re.compile(r"Assembling a block candidate for block #\d+ from (\d+) transactions available"),
        "imined": re.compile(r"Input-block " + HEX + r" mined @"),
        "matrix": re.compile(r"Processing valid sub-block |Input-block [0-9a-f]{64} mined"),
    }
    with open_text(path) as fh:
        for line in fh:
            m = TS.match(line)
            if not m:
                continue
            t = clock.ms(int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4)))
            if "New block mined" in line:
                x = pat["mined"].search(line)
                if x:
                    r["mined_ordering"].add(x.group(1))
            elif "applied to UtxoState" in line:
                x = pat["applied"].search(line)
                if x:
                    r["applied"].append((t, x.group(1)))
            elif "modifiers of type 102" in line:
                x = pat["got102"].search(line)
                if x:
                    r["got102"].append((t, int(x.group(1))))
            elif "from input-blocks for" in line:
                x = pat["rebuilt"].search(line)
                if x:
                    r["rebuilt"].append((t, x.group(1)))
            elif "Downloading block transactions fully" in line:
                x = pat["fallback"].search(line)
                if x:
                    r["fallback"].append((t, x.group(1)))
            elif "Double application" in line:
                r["double"].append(t)
            elif "Assembling a block candidate" in line:
                x = pat["avail"].search(line)
                if x:
                    r["available"].append((t, int(x.group(1))))
            if not r["matrix"] and pat["matrix"].search(line):
                r["matrix"] = True
            if "Input-block" in line:
                x = pat["imined"].search(line)
                if x:
                    r["input_mined"].append((t, x.group(1)))
    return r


# ---------------------------------------------------------------- wire
def frame_bytes(rec):
    n = rec.get("len") or 0
    return FRAME_OVERHEAD + (CHECKSUM + n if n > 0 else 0)


def group_of(rec):
    code, tid = rec.get("code"), rec.get("type_id")
    if code == 100 or (code in (22, 33, 55) and tid == -123):
        return "input-block"
    if code == 102 or (code in (22, 33, 55) and tid == -122):
        return "input-block-txids"
    if code in (104, 105):
        return "input-block-txs"
    if code == 106 or (code in (22, 33, 55) and tid == -121):
        return "ordering-announce"
    if code in (22, 33, 55) and tid == 102:
        return "block-transactions"
    if code in (22, 33, 55) and tid in SECTION_TYPES:
        return "block-sections-other"
    if code in (22, 33, 55) and tid == 2:
        return "transactions"
    if code == 65:
        return "sync"
    return "other"


def msg_key(rec):
    code, name = rec.get("code"), rec.get("name", "?")
    return f"{name}/{rec.get('type_id')}" if code in (22, 33, 55) else name


def bytes_section(frames, matrix_nodes, start, end):
    mins = (end - start) / 60000.0
    by_group = defaultdict(Counter)
    by_msg = defaultdict(Counter)
    count_msg = defaultdict(Counter)
    by_dest = defaultdict(Counter)        # (sender, receiver kind) -> group bytes
    for r in frames:
        if not start <= r["t_ms"] < end:
            continue
        b, g, s = frame_bytes(r), group_of(r), r.get("from")
        by_group[s][g] += b
        by_msg[s][msg_key(r)] += b
        count_msg[s][msg_key(r)] += 1
        by_dest[(s, "M" if r.get("to") in matrix_nodes else "R")][g] += b
    out = {"minutes": round(mins, 2), "per_node": {}}
    for s in sorted(by_group):
        out["per_node"][s] = {
            "kind": "M" if s in matrix_nodes else "R",
            "total_bytes_per_min": round(sum(by_group[s].values()) / mins, 1),
            "groups_bytes_per_min": {g: round(v / mins, 1) for g, v in sorted(by_group[s].items())},
            "messages_bytes_per_min": {k: round(v / mins, 1) for k, v in sorted(by_msg[s].items())},
            "messages_per_min": {k: round(v / mins, 2) for k, v in sorted(count_msg[s].items())},
            "to_matrix_bytes_per_min": {g: round(v / mins, 1) for g, v in sorted(by_dest[(s, "M")].items())},
            "to_reference_bytes_per_min": {g: round(v / mins, 1) for g, v in sorted(by_dest[(s, "R")].items())},
        }
    # control: Matrix-only messages never go to a reference node, and a reference node never sends them
    leak = Counter()
    for (s, k), gs in by_dest.items():
        for g in ("input-block", "input-block-txids", "input-block-txs", "ordering-announce"):
            if gs.get(g) and (k == "R" or s not in matrix_nodes):
                leak[f"{s}->{k}:{g}"] += gs[g]
    out["matrix_only_to_or_from_reference_bytes"] = dict(leak)
    return out


def requests_wire(frames, start, end):
    section_of = {}          # tx section id -> header id
    first_sender = {}        # header id -> first node seen sending it (106 or Modifiers 101)
    received = defaultdict(dict)   # node -> header id -> first t_ms received
    for r in frames:
        code = r.get("code")
        if code == 106 and r.get("tx_section_id"):
            hs = [(r["ordering_block_id"], r["tx_section_id"])]
        elif code == 33 and r.get("type_id") == 101 and r.get("tx_section_ids"):
            hs = [(h, s) for h, s in zip(r["modifier_ids"], r["tx_section_ids"]) if s]
        else:
            continue
        for h, s in hs:
            section_of[s] = h
            first_sender.setdefault(h, (r["t_ms"], r.get("from")))
            received[r.get("to")].setdefault(h, r["t_ms"])
    if not section_of:
        return "n/a: no header carries a tx_section_id (messages.jsonl decoded by an older wire.py, or no ordering block)"
    requested = defaultdict(lambda: defaultdict(int))   # node -> header -> type-102 ids requested
    delivered = defaultdict(lambda: defaultdict(int))   # node -> header -> type-102 bytes delivered to it
    unmatched = Counter()
    for r in frames:
        if r.get("type_id") != 102 or r.get("code") not in (22, 33):
            continue
        for i in r.get("modifier_ids", []):
            h = section_of.get(i)
            if r["code"] == 22:
                if h is None:
                    unmatched[r.get("from")] += 1
                else:
                    requested[r.get("from")][h] += 1
            elif h is not None:
                delivered[r.get("to")][h] += frame_bytes(r)
    out = {}
    for n in sorted(set(received) | set(requested)):
        if n is None:
            continue
        recv = {h for h, t in received[n].items() if start <= t < end and first_sender.get(h, (0, None))[1] != n}
        req = {h for h in recv if requested[n].get(h)}
        out[n] = {"ordering_blocks_received": len(recv), "with_tx_request_sent": len(req),
                  "share_requested": round(len(req) / len(recv), 3) if recv else None,
                  "tx_section_bytes_received": sum(delivered[n].get(h, 0) for h in recv),
                  "type102_requests_unmatched": unmatched.get(n, 0)}
    return out


def requests_log(logs, start, end):
    out = {}
    for n, L in sorted(logs.items()):
        if not L["matrix"]:
            continue
        recv = {h for t, h in L["applied"] if start <= t < end and h not in L["mined_ordering"]}
        rebuilt = {h for t, h in L["rebuilt"] if start <= t < end and h in recv}
        fb = {h for t, h in L["fallback"] if start <= t < end and h in recv}
        got = sum(k for t, k in L["got102"] if start <= t < end)
        dbl = sum(1 for t in L["double"] if start <= t < end)
        # a rebuilt block whose transactions section also arrived from a peer: a type-102 delivery within 1 s of the
        # rebuild line (time proximity, not an id match: the log names neither the section's block nor its id)
        gt = sorted(t for t, _ in L["got102"])
        near, offs, done = 0, [], set()
        for t, h in L["rebuilt"]:
            if not (start <= t < end and h in recv) or h in done:
                continue
            done.add(h)
            j = bisect_left(gt, t - 1000)
            if j < len(gt) and gt[j] <= t + 1000:
                near += 1
                offs.append(gt[j] - t)
        out[n] = {"ordering_blocks_received": len(recv), "rebuilt_from_input_blocks": len(rebuilt),
                  "rebuilt_with_type102_within_1s": near, "median_offset_ms": pct(offs, .5),
                  "full_download_fallback": len(fb), "type102_sections_received": got,
                  "type102_per_received_block": round(got / len(recv), 3) if recv else None,
                  "double_application_lines": dbl}
    return out


# ---------------------------------------------------------------- value
def input_blocks(frames):
    ib = {}
    txids = {}
    for r in frames:
        if r.get("code") == 100 and r.get("input_block_id"):
            i = r["input_block_id"]
            if i not in ib:
                ib[i] = {"t_ms": r["t_ms"], "from": r.get("from"), "ord": r.get("ordering_parent_id"),
                         "prev": r.get("prev_input_block_id"), "weak": r.get("weak_ids"),
                         "uncles": r.get("uncle_ids") or [], "version": r.get("version")}
            elif ib[i]["weak"] is None and r.get("weak_ids") is not None:
                ib[i]["weak"] = r["weak_ids"]
        elif r.get("code") == 102 and r.get("input_block_id"):
            txids.setdefault(r["input_block_id"], r.get("weak_ids") or [])
    for i, b in ib.items():
        if b["weak"] is None and i in txids:
            b["weak"] = txids[i]
    return ib


def value_section(ib, mined_full, payments, final_txs, final_ords, start, end):
    """ib: input block id -> record (wire); mined_full: id -> full tx ids (txwatch); payments: set of payment tx ids;
    final_txs: set of tx ids on the final chain; final_ords: set of final-chain ordering block ids."""
    pay3 = Counter(p[:6] for p in payments)
    fin3 = Counter(t[:6] for t in final_txs)

    def own(i):
        b = ib.get(i)
        return list(b["weak"]) if b and b["weak"] is not None else None

    # the weak ids of a block, checked against its full ids where txwatch has them (first 3 bytes must agree)
    check = Counter()
    for i, full in mined_full.items():
        w = own(i)
        if w is None or full is None:
            continue
        check["compared"] += 1
        if sorted(x[:6] for x in w) == sorted(x[:6] for x in full):
            check["agree"] += 1

    memo = {}

    def collected(i, depth=0):
        """weak ids in L up to and including input block i: its ancestors' and its own, with every merged uncle's"""
        if i in memo:
            return memo[i]
        b = ib.get(i)
        if b is None or depth > 10000:
            return None
        base = set()
        if b["prev"]:
            p = collected(b["prev"], depth + 1)
            if p is None:
                memo[i] = None
                return None
            base = set(p)
        for u in b["uncles"]:
            ou = own(u)
            if ou is None:
                memo[i] = None
                return None
            base |= set(ou)
        ob = own(i)
        if ob is None:
            memo[i] = None
            return None
        memo[i] = base | set(ob)
        return memo[i]

    merges, unknown = [], 0
    for x, b in ib.items():
        if not b["uncles"] or not start <= b["t_ms"] < end:
            continue
        prefix = collected(b["prev"]) if b["prev"] else set()
        if prefix is None:
            unknown += len(b["uncles"])
            continue
        seen = set(prefix)
        for u in b["uncles"]:
            ou = own(u)
            if ou is None:
                unknown += 1
                continue
            dup = [w for w in ou if w in seen]
            uniq = [w for w in ou if w not in seen]
            seen |= set(ou)
            merges.append({"by": x, "uncle": u, "txs": len(ou), "dup": len(dup), "unique": len(uniq),
                           "unique_payments": sum(1 for w in uniq if pay3.get(w[:6])),
                           "unique_final": sum(1 for w in uniq if fin3.get(w[:6]))})
    tot = sum(m["txs"] for m in merges)
    dup = sum(m["dup"] for m in merges)
    merged = {"merges": len(merges), "merges_with_txs": sum(1 for m in merges if m["txs"]),
              "uncle_txs": tot, "duplicates": dup, "unique": tot - dup,
              "duplicate_share": round(dup / tot, 3) if tot else None,
              "unique_payments": sum(m["unique_payments"] for m in merges),
              "unique_on_final_chain": sum(m["unique_final"] for m in merges),
              "uncles_without_known_txs": unknown}

    # siblings: per final-chain ordering block O, the winning path is the deepest input-block chain under O
    children = defaultdict(list)
    by_ord = defaultdict(list)
    for i, b in ib.items():
        by_ord[b["ord"]].append(i)
        if b["prev"]:
            children[b["prev"]].append(i)
    depth = {}

    def d(i):
        if i not in depth:
            p = ib[i]["prev"]
            depth[i] = 1 + (d(p) if p in ib else 0)
        return depth[i]
    later_weak = defaultdict(list)   # weak id -> t_ms of input blocks carrying it
    for i, b in ib.items():
        for w in b["weak"] or []:
            later_weak[w].append(b["t_ms"])
    sib = Counter()
    sib_blocks = Counter()
    ties = 0
    for o, ids in by_ord.items():
        if o not in final_ords:
            continue
        ids_w = [i for i in ids if start <= ib[i]["t_ms"] < end]
        if not ids_w:
            continue
        top = max(d(i) for i in ids)
        tips = sorted((ib[i]["t_ms"], i) for i in ids if d(i) == top)
        ties += len(tips) > 1
        path, cur = set(), tips[0][1]
        while cur in ib:
            path.add(cur)
            cur = ib[cur]["prev"]
        path_own = set()
        path_merged = set()
        for p in path:
            path_own |= set(own(p) or [])
            for u in ib[p]["uncles"]:
                path_merged.add(u)
        for s in ids_w:
            if s in path:
                continue
            ws = own(s)
            sib_blocks["siblings"] += 1
            if ws is None:
                sib_blocks["txs_unknown"] += 1
                continue
            sib_blocks["merged" if s in path_merged else "not_merged"] += 1
            for w in ws:
                sib["txs"] += 1
                if w in path_own:
                    sib["on_winning_path"] += 1
                elif s in path_merged:
                    sib["recovered_by_merge"] += 1
                elif any(t > ib[s]["t_ms"] for t in later_weak[w]):
                    sib["re_included_later"] += 1
                else:
                    sib["in_no_other_input_block"] += 1
                # a sibling transaction neither on the winning path nor merged that the final chain holds anyway
                # (re-included later, or carried by an ordering block's own part)
                if w not in path_own and s not in path_merged and fin3.get(w[:6]):
                    sib["not_merged_but_on_final_chain"] += 1
    return {"weak_vs_full_ids": dict(check), "merged_uncles": merged,
            "siblings": {"blocks": dict(sib_blocks), "transactions": dict(sib), "winning_path_ties": ties},
            "merges": merges}


# ---------------------------------------------------------------- load
def load_section(txload, watch, chain, logs, ib, start, end):
    out = {}
    pays = [r for r in txload if r.get("kind") == "pay" and start <= r.get("t_ms", 0) < end]
    mins = (end - start) / 60000.0
    errs = Counter((r.get("error") or "")[:60] for r in pays if not r.get("id"))
    out["payments"] = {"attempts_per_min": round(len(pays) / mins, 1), "accepted": sum(1 for r in pays if r.get("id")),
                       "refused": sum(1 for r in pays if not r.get("id")),
                       "refusal_reasons": dict(errs.most_common(4))}
    pool = defaultdict(list)
    for r in watch:
        if r.get("ev") == "pool" and start <= r["t_ms"] < end:
            pool[r["node"]].append((r["t_ms"], r["n"]))
    out["pool"] = {n: {"samples": len(v), "p50": pct([k for _, k in v], .5), "p90": pct([k for _, k in v], .9),
                       "max": max(k for _, k in v)} for n, v in sorted(pool.items())}
    # transactions per final-chain ordering block in the window (ts = header timestamp, ms)
    blk = [(r["ts"], len(r.get("txs") or [])) for r in chain if start <= (r.get("ts") or 0) < end]
    nt = [k for _, k in blk]
    out["ordering_block_txs"] = {"blocks": len(nt), "p50": pct(nt, .5), "p90": pct(nt, .9), "max": max(nt) if nt else None}
    # pool right after each ordering block: per node, the first sample within 5 s after the block's time
    after = []
    for ts, _ in blk:
        for n, v in pool.items():
            nxt = [k for t, k in v if ts <= t < ts + 5000]
            if nxt:
                after.append(nxt[0])
    out["pool_after_ordering_block"] = {"samples": len(after), "p50": pct(after, .5), "p90": pct(after, .9)}
    p90 = out["ordering_block_txs"]["p90"]
    out["saturated"] = (None if not after or p90 is None else pct(after, .5) >= p90)
    # transactions per input block (wire weak ids, else txwatch input/mined events)
    per_ib = [len(b["weak"]) for b in ib.values() if b["weak"] is not None and start <= b["t_ms"] < end]
    src = "wire"
    if not per_ib:
        seen = {}
        for r in watch:
            if r.get("ev") in ("input", "mined") and r.get("txs") is not None and start <= r["t_ms"] < end:
                seen.setdefault(r["id"], len(r["txs"]))
        per_ib, src = list(seen.values()), "txwatch"
    out["input_block_txs"] = {"source": src, "blocks": len(per_ib), "p50": pct(per_ib, .5), "p90": pct(per_ib, .9),
                              "max": max(per_ib) if per_ib else None,
                              "empty_share": round(sum(1 for k in per_ib if k == 0) / len(per_ib), 3) if per_ib else None}
    out["candidate_available"] = {}
    for n, L in sorted(logs.items()):
        if not L["matrix"]:
            continue
        v = [k for t, k in L["available"] if start <= t < end]
        if v:
            out["candidate_available"][n] = {"candidates": len(v), "p50": pct(v, .5), "p90": pct(v, .9), "max": max(v)}
    return out


# ---------------------------------------------------------------- main
def node_kinds(msgs, frames, logs, matrix_arg=None):
    """Which nodes are Matrix: --matrix; else the handshakes (two versions on the network: the higher one is the
    Matrix line's); else any node whose log shows input blocks or that sent an InputBlock or OrderingBlock frame.
    The first two do not read the traffic, so the BYTES control (no Matrix-only message to or from a reference node)
    is a test only then."""
    if matrix_arg:
        return set(matrix_arg.split(",")), "--matrix"
    ver = {}
    for r in msgs:
        if r.get("kind") == "handshake" and r.get("from") and r.get("version"):
            ver[r["from"]] = tuple(int(x) for x in re.findall(r"\d+", r["version"]))
    if len(set(ver.values())) == 2:
        hi = max(ver.values())
        return {n for n, v in ver.items() if v == hi}, "handshake versions"
    if len(set(ver.values())) == 1 and any(r.get("code") in MATRIX_CODES for r in frames):
        return set(ver), "handshake versions (one, with Matrix traffic)"
    return ({r.get("from") for r in frames if r.get("code") in (100, 106)} | {n for n, L in logs.items() if L["matrix"]},
            "traffic and logs")


def analyze(run, arg_from=None, arg_to=None, matrix_arg=None):
    msgs = read_jsonl(locate(run, "messages.jsonl"))
    watch = read_jsonl(locate(run, "txwatch.jsonl"))
    txload = read_jsonl(locate(run, "txload.jsonl"))
    chain = read_jsonl(locate(run, "txload_chain.jsonl"))
    anchor = first_epoch(watch, txload, msgs)
    if anchor is None:
        raise SystemExit("matrix_value: no epoch-ms record (txwatch, txload or messages) to anchor the clock")
    clock = Clock(anchor)
    start, end = window(run, clock, arg_from, arg_to)
    if start is None or end is None or end <= start:
        raise SystemExit("matrix_value: no window (rig.log lines or --from/--to)")
    logs = {n: scan_log(p, clock) for n, p in node_logs(run).items()}
    frames = [r for r in msgs if r.get("kind") == "frame"]
    matrix_nodes, kinds_from = node_kinds(msgs, frames, logs, matrix_arg)
    res = {"run": run, "window": {"from_ms": start, "to_ms": end, "minutes": round((end - start) / 60000, 2)},
           "matrix_nodes": sorted(x for x in matrix_nodes if x), "matrix_nodes_from": kinds_from}
    if frames:
        holes = Counter(r["kind"] for r in msgs if r.get("kind") in ("gap", "desync", "tail"))
        res["wire"] = {"frames": len(frames), "holes": dict(holes),
                       "parse_errors": sum(1 for r in frames if "parse_error" in r)}
        res["bytes"] = bytes_section(frames, matrix_nodes, start, end)
        res["requests_wire"] = requests_wire(frames, start, end)
    else:
        res["bytes"] = res["requests_wire"] = "n/a: no messages.jsonl (run with the wire on)"
    res["requests_log"] = requests_log(logs, start, end) if logs else "n/a: no node logs"
    ib = input_blocks(frames)
    mined_full = {}
    for r in watch:
        if r.get("ev") == "mined":
            mined_full.setdefault(r["id"], r.get("txs"))
    recs = read_jsonl(locate(run, "txrecords.jsonl"))
    payments = {r["id"] for r in recs if r.get("id")} | {r["id"] for r in txload if r.get("id")}
    final_txs = {t for r in chain for t in (r.get("txs") or [])}
    final_ords = {r["id"] for r in chain if r.get("id")}
    if ib:
        v = value_section(ib, mined_full, payments, final_txs, final_ords, start, end)
        res["value"] = {k: v[k] for k in ("weak_vs_full_ids", "merged_uncles", "siblings")}
        res["value_merges"] = v["merges"]
        res["input_blocks_on_wire"] = len(ib)
        res["input_blocks_mined_logged"] = sum(len([1 for t, _ in L["input_mined"] if start <= t < end]) for L in logs.values())
    else:
        res["value"] = "n/a: no InputBlock frames (run with the wire on)"
    res["load"] = load_section(txload, watch, chain, logs, ib, start, end)
    return res


def print_report(res):
    w = res["window"]
    print(f"MATRIX-VALUE window {w['minutes']} min; Matrix nodes {','.join(res['matrix_nodes']) or '-'} "
          f"(from {res['matrix_nodes_from']})")
    if isinstance(res["bytes"], str):
        print(f"BYTES {res['bytes']}")
    else:
        print(f"WIRE frames {res['wire']['frames']} holes {res['wire']['holes'] or 0} parse_errors {res['wire']['parse_errors']}")
        for n, v in res["bytes"]["per_node"].items():
            gs = " ".join(f"{g}={b:.0f}" for g, b in v["groups_bytes_per_min"].items())
            print(f"BYTES {n} ({v['kind']}) total={v['total_bytes_per_min']:.0f} B/min: {gs}")
        print(f"BYTES control Matrix-only messages to or from a reference node: {res['bytes']['matrix_only_to_or_from_reference_bytes'] or 0}")
        rw = res["requests_wire"]
        if isinstance(rw, str):
            print(f"REQUESTS wire {rw}")
        for n, v in (rw.items() if isinstance(rw, dict) else ()):
            print(f"REQUESTS wire {n}: {v['with_tx_request_sent']}/{v['ordering_blocks_received']} received ordering blocks "
                  f"had a BlockTransactions request sent ({fmt(v['share_requested'], 3)}); section bytes received "
                  f"{v['tx_section_bytes_received']}; unmatched type-102 requests {v['type102_requests_unmatched']}")
    if isinstance(res["requests_log"], dict):
        for n, v in res["requests_log"].items():
            print(f"REQUESTS log {n}: received {v['ordering_blocks_received']}, rebuilt {v['rebuilt_from_input_blocks']} "
                  f"(of which {v['rebuilt_with_type102_within_1s']} with a type-102 section delivered within 1 s, median "
                  f"offset {fmt(v['median_offset_ms'])} ms), "
                  f"fallback {v['full_download_fallback']}, type-102 sections received {v['type102_sections_received']} "
                  f"({fmt(v['type102_per_received_block'], 3)} per received block), double-application lines "
                  f"{v['double_application_lines']}")
    if isinstance(res["value"], str):
        print(f"VALUE {res['value']}")
    else:
        v = res["value"]
        print(f"VALUE input blocks on the wire {res['input_blocks_on_wire']} (mined lines in window "
              f"{res['input_blocks_mined_logged']}); weak vs full ids {v['weak_vs_full_ids'] or '-'}")
        m = v["merged_uncles"]
        print(f"VALUE merged uncles {m['merges']} ({m['merges_with_txs']} with txs): uncle txs {m['uncle_txs']}, duplicates "
              f"{m['duplicates']} ({fmt(m['duplicate_share'], 3)}), unique {m['unique']} (payments {m['unique_payments']}, "
              f"on final chain {m['unique_on_final_chain']}); uncles without known txs {m['uncles_without_known_txs']}")
        s = v["siblings"]
        print(f"VALUE siblings {s['blocks'] or 0}; their txs {s['transactions'] or 0}; winning-path ties {s['winning_path_ties']}")
    L = res["load"]
    print(f"LOAD payments {L['payments']['attempts_per_min']}/min accepted {L['payments']['accepted']} refused "
          f"{L['payments']['refused']} {L['payments']['refusal_reasons'] or ''}")
    print(f"LOAD pool {L['pool'] or '-'}")
    print(f"LOAD ordering-block txs {L['ordering_block_txs']}; pool after ordering block {L['pool_after_ordering_block']}; "
          f"saturated {L['saturated']}")
    print(f"LOAD input-block txs {L['input_block_txs']}")
    print(f"LOAD candidate available (pool txs per candidate) {L['candidate_available'] or '-'}")


def main(argv):
    sys.setrecursionlimit(20000)
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    run, opts, i = argv[0], {}, 1
    while i < len(argv):
        opts[argv[i]] = argv[i + 1]
        i += 2
    res = analyze(run, opts.get("--from"), opts.get("--to"), opts.get("--matrix"))
    print_report(res)
    if opts.get("--json"):
        with open(opts["--json"], "w") as fh:
            json.dump(res, fh, indent=1, sort_keys=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
