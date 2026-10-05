#!/usr/bin/env python3
"""extmine_parent_cause.py: for each input-block solution an external miner (rig/lib/extminer.py) had refused, what had
replaced the candidate it worked on, read from the node's own log.

  python3 diag/extmine_parent_cause.py <run dir> [<run dir> ...] [--json out.json] [--window]

A run dir holds nodes/node_<X>.log(.gz) and load/extminer_<X>.log(.gz) (patch-compare's run artifact layout, also the
rig's $RIG_LOG_DIR with node_<X>.log and extminer_<X>.log side by side). --window keeps submissions inside the
matrix-compat mining window (rig.log "all miners mining from HH:MM:SS" .. + the largest "[matrix-compat] t=Ns").

Method, per node, per submission (extminer "submit kind=input ... -> <status>"):
  1. The candidate: the extminer names it by the first 16 hex of its msg. The node logs every candidate it builds,
     "Got candidate block at height H with N transactions, msg <64 hex>", so the candidate's build time t_g is the first
     such line for that msg.
  2. The verdict time t_j: the generator logs "Input-block <id> mined @ height" for an input solution it accepts and
     WARN "Input-block solution does not fit the current candidate" for one it refuses as stale, before it replies (the
     "Processed solution" line comes from another thread and can trail the block's application, so it is not used).
     Submissions are sequential per miner (it waits for each reply), so a submission is matched to the latest line of
     its own outcome (mined for a 200 reply, does-not-fit for a refusal) in [reply - 1000 ms, reply + 5 ms] that no
     earlier submission took (on smoke-3 logs the nearest such line sits 0-14 ms before the reply; a wider forward
     slack picks up the next submission's line at high find rates). No line (other refusals, e.g. "Block already
     solved"): t_j = the reply time (counted as unmatched_verdict).
  3. The first event in the node's log in (t_g, t_j) that changes what the node would mine:
       own-input     "Applying N input block transactions for <id>" whose "Input block transaction processing completed:
                     F forward, R rollback" line has F + R > 0 (the best input chain moved; an application on a side
                     fork, 0 forward 0 rollback, leaves the candidate's parent in place and is skipped), id among the
                     node's "Input-block <id> mined" ids
                     (on an external-miner node these are the miner's own accepted input blocks: self-inflicted)
       peer-input    the same line for an id the node did not mine (another node's input block)
       own-ordering  "Valid modifier with header <id> ... applied to UtxoState", id among "New block mined" ids
       peer-ordering the same line for any other id (a new ordering block from another node)
       regen         "Got candidate block ... msg <other msg>" with neither of the above before it: the node rebuilt
                     its candidate on the same parents (for example on new mempool transactions)
       none          no such event: the refusal is not explained by a replacement in the log
     A refused submission whose msg is not in the node log is "unmatched_candidate".
  Control: the same first-event search for ACCEPTED submissions. An accepted solution whose candidate the node had
  already replaced by an input or ordering block before t_j would contradict either the classifier or the node's
  judging rule; their count is printed as accepted_after_block (regen before an accepted verdict is counted apart).
Output: per node and pooled, refused by cause with fractions, the controls, and, when the extminer log carries
"work" lines (extminer.py with per-submission timing), median age_last_ms per cause. Standard library only.
"""
import argparse
import glob
import gzip
import json
import os
import re
import sys
from bisect import bisect_left, bisect_right
from collections import Counter, defaultdict
from datetime import datetime, timezone

HEX = r'([0-9a-f]{64})'
TS = re.compile(r'^(\d\d):(\d\d):(\d\d)\.(\d{3}) ')
R_CAND = re.compile(r'Got candidate block at height \d+ with \d+ transactions, msg ' + HEX)
R_APPLY_INP = re.compile(r'Applying \d+ input block transactions for ' + HEX)
R_OWN_INP = re.compile(r'Input-block ' + HEX + r' mined @ height')
R_ORD_APPLIED = re.compile(r'Valid modifier with header ' + HEX + r' .*applied to UtxoState')
R_OWN_ORD = re.compile(r'New block mined, header: .*?"id":"' + HEX + '"')
R_DONE = re.compile(r'Input block transaction processing completed: (\d+) forward, (\d+) rollback')
R_NOFIT = re.compile(r'Input-block solution does not fit the current candidate')
X_SUB = re.compile(r'^(\d{13}) submit kind=(input|ordering) h=(\d+) msg=([0-9a-f]+) n=([0-9a-f]+) -> (\d+) ?(.*)$')
X_WORK = re.compile(r'^(\d{13}) work kind=(input|ordering) msg=([0-9a-f]+) n=([0-9a-f]+) status=(\d+) (.*)$')
CAUSES = ['peer-input', 'own-input', 'peer-ordering', 'own-ordering', 'regen', 'none', 'unmatched_candidate']


def opener(path):
    return gzip.open(path, 'rt', errors='replace') if path.endswith('.gz') else open(path, errors='replace')


def find(rd, sub, name):
    for p in (os.path.join(rd, sub, name + '.gz'), os.path.join(rd, sub, name), os.path.join(rd, name + '.gz'),
              os.path.join(rd, name)):
        if os.path.exists(p):
            return p
    return None


def tod_ms_of_epoch(ms):
    d = datetime.fromtimestamp(ms / 1000.0, tz=timezone.utc)
    return ((d.hour * 60 + d.minute) * 60 + d.second) * 1000 + d.microsecond // 1000


class Clock:
    """node-log time of day (ms) -> epoch ms, anchored on the extminer's first epoch time (same host clock, UTC)."""
    def __init__(self, anchor_epoch_ms):
        d = datetime.fromtimestamp(anchor_epoch_ms / 1000.0, tz=timezone.utc)
        self.midnight = int(datetime(d.year, d.month, d.day, tzinfo=timezone.utc).timestamp() * 1000)
        self.anchor_tod = tod_ms_of_epoch(anchor_epoch_ms)

    def epoch(self, tod):
        if tod < self.anchor_tod - 12 * 3600 * 1000:   # past midnight relative to the anchor
            tod += 86400 * 1000
        elif tod > self.anchor_tod + 12 * 3600 * 1000:  # before midnight, anchor after it
            tod -= 86400 * 1000
        return self.midnight + tod


def read_extminer(path):
    subs, works = [], {}
    with opener(path) as f:
        for line in f:
            m = X_SUB.match(line)
            if m:
                subs.append(dict(t=int(m.group(1)), kind=m.group(2), msg=m.group(4), n=m.group(5),
                                 status=int(m.group(6)), reply=m.group(7)))
                continue
            m = X_WORK.match(line)
            if m:
                kv = dict(x.split('=', 1) for x in m.group(6).split(' ') if '=' in x and not x.startswith('reply'))
                works[(m.group(3), m.group(4), int(m.group(1)))] = kv
    for s in subs:
        w = works.get((s['msg'], s['n'], s['t']))
        if w:
            s['age_last_ms'] = int(w.get('age_last_ms', -1))
            s['age_first_ms'] = int(w.get('age_first_ms', -1))
    return subs, bool(works)


def read_node(path, clock):
    cand_t = {}                      # msg16 -> first build time (epoch ms)
    ev = []                          # (t, type, id/msg)
    pending = None                   # the last "Applying" event, kept once its "completed" line shows the chain moved
    own_inp, own_ord, verdicts = set(), set(), []
    with opener(path) as f:
        for line in f:
            m = TS.match(line)
            if not m:
                continue
            tod = ((int(m.group(1)) * 60 + int(m.group(2))) * 60 + int(m.group(3))) * 1000 + int(m.group(4))
            if 'Got candidate block' in line:
                mm = R_CAND.search(line)
                if mm:
                    t = clock.epoch(tod); k = mm.group(1)[:16]
                    cand_t.setdefault(k, t); ev.append((t, 'cand', k))
            elif 'Applying' in line and 'input block transactions' in line:
                mm = R_APPLY_INP.search(line)
                if mm:
                    pending = (clock.epoch(tod), 'inp', mm.group(1))
            elif 'Input block transaction processing completed' in line:
                mm = R_DONE.search(line)
                if mm and pending is not None:
                    if int(mm.group(1)) + int(mm.group(2)) > 0:
                        ev.append(pending)
                    pending = None
            elif 'Input-block' in line and 'mined @' in line:
                mm = R_OWN_INP.search(line)
                if mm:
                    own_inp.add(mm.group(1)); verdicts.append((clock.epoch(tod), 'Success'))
            elif 'does not fit the current candidate' in line:
                verdicts.append((clock.epoch(tod), 'Error'))
            elif 'Valid modifier with header' in line:
                mm = R_ORD_APPLIED.search(line)
                if mm:
                    ev.append((clock.epoch(tod), 'ord', mm.group(1)))
            elif 'New block mined' in line:
                mm = R_OWN_ORD.search(line)
                if mm:
                    own_ord.add(mm.group(1))
    ev.sort(key=lambda e: e[0]); verdicts.sort(key=lambda v: v[0])
    return cand_t, ev, own_inp, own_ord, verdicts


def window(rd):
    p = find(rd, '.', 'rig.log')
    if not p:
        return None
    txt = opener(p).read()
    m = re.search(r'all miners mining from (\d\d):(\d\d):(\d\d)', txt)
    ts = [int(x) for x in re.findall(r'\[matrix-compat\] t=(\d+)s', txt)]
    if not m or not ts:
        return None
    start = ((int(m.group(1)) * 60 + int(m.group(2))) * 60 + int(m.group(3))) * 1000
    return start, start + max(ts) * 1000


def classify_node(node_log, ext_log, win_tod=None):
    with opener(ext_log) as f:
        if ' no-weak-route ' in f.read():
            return None              # a node without the input-block route (a release jar): no input solutions judged
    subs, has_work = read_extminer(ext_log)
    subs = [s for s in subs if s['kind'] == 'input']
    if not subs:
        return None
    clock = Clock(subs[0]['t'])
    cand_t, ev, own_inp, own_ord, verdicts = read_node(node_log, clock)
    if win_tod:
        lo, hi = clock.epoch(win_tod[0]), clock.epoch(win_tod[1])
        subs = [s for s in subs if lo <= s['t'] <= hi]
    ev_t = [e[0] for e in ev]
    vt = [v[0] for v in verdicts]
    used = set()
    out = dict(refused=Counter(), accepted=0, accepted_after_block=0, accepted_after_regen=0, unreplied=0,
               unmatched_verdict=0, own_input_blocks=len(own_inp),
               accepted_by_extminer=0, ages=defaultdict(list), refused_by_reply=Counter(), has_work=has_work)
    for s in sorted(subs, key=lambda s: s['t']):
        if s['status'] == 0:
            out['unreplied'] += 1
            continue
        ok = s['status'] == 200
        out['accepted_by_extminer'] += ok
        # verdict time: the latest unused line of this submission's outcome in [reply - 1000 ms, reply + 5 ms]
        i = bisect_right(vt, s['t'] + 5) - 1
        tj = None
        while i >= 0 and vt[i] >= s['t'] - 1000:
            if i not in used and (verdicts[i][1] == 'Success') == ok:
                used.add(i); tj = vt[i]
                break
            i -= 1
        if tj is None:
            out['unmatched_verdict'] += 1; tj = s['t']
        tg = cand_t.get(s['msg'][:16])
        cause = 'unmatched_candidate'
        if tg is not None:
            cause = 'none'
            j = bisect_right(ev_t, tg)
            while j < len(ev) and ev[j][0] < tj:
                t, typ, x = ev[j]
                if typ == 'inp':
                    cause = 'own-input' if x in own_inp else 'peer-input'; break
                if typ == 'ord':
                    cause = 'own-ordering' if x in own_ord else 'peer-ordering'; break
                if typ == 'cand' and x != s['msg'][:16]:
                    cause = 'regen'; break
                j += 1
        if ok:
            out['accepted'] += 1
            if cause in ('own-input', 'peer-input', 'own-ordering', 'peer-ordering'):
                out['accepted_after_block'] += 1
            elif cause == 'regen':
                out['accepted_after_regen'] += 1
        else:
            out['refused'][cause] += 1
            out['refused_by_reply'][re.sub(r'[0-9a-f]{64}', '<id>', (re.search(r'"detail" : "([^"]*)"', s['reply'])
                                                                    or re.search(r'(.*)', s['reply'])).group(1))[:60]] += 1
            if 'age_last_ms' in s:
                out['ages'][cause].append(s['age_last_ms'])
    return out


def merge(a, b):
    if a is None:
        a = dict(refused=Counter(), refused_by_reply=Counter(), ages=defaultdict(list))
    for k, v in b.items():
        if isinstance(v, Counter):
            a[k].update(v)
        elif isinstance(v, defaultdict):
            for kk, vv in v.items():
                a['ages'][kk].extend(vv)
        elif isinstance(v, bool):
            a[k] = a.get(k, False) or v
        else:
            a[k] = a.get(k, 0) + v
    return a


def fmt(o):
    n = sum(o['refused'].values())
    parts = [f"refused={n}"]
    for c in CAUSES:
        k = o['refused'].get(c, 0)
        if k:
            parts.append(f"{c}={k} ({k / n:.3f})" if n else f"{c}={k}")
    parts += [f"accepted={o['accepted']}", f"accepted_after_block={o['accepted_after_block']}",
              f"accepted_after_regen={o['accepted_after_regen']}", f"unreplied={o['unreplied']}",
              f"unmatched_verdict={o['unmatched_verdict']}",
              f"own_input_blocks(log)={o['own_input_blocks']}"]
    s = ' '.join(parts)
    if o.get('has_work') and o['ages']:
        med = {c: sorted(v)[len(v) // 2] for c, v in o['ages'].items() if v}
        s += ' age_last_ms_median=' + ','.join(f"{c}:{m}" for c, m in med.items())
    return s


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('runs', nargs='+')
    ap.add_argument('--json')
    ap.add_argument('--window', action='store_true')
    a = ap.parse_args(argv)
    pooled, res = None, {}
    for rd in a.runs:
        win = window(rd) if a.window else None
        if a.window and not win:
            print(f"{rd}: no mining window in rig.log; skipped", file=sys.stderr); continue
        exts = sorted(glob.glob(os.path.join(rd, 'load', 'extminer_*.log*')) + glob.glob(os.path.join(rd, 'extminer_*.log*')))
        for ext in exts:
            x = re.search(r'extminer_([A-Za-z0-9]+)\.log', ext).group(1)
            nl = find(rd, 'nodes', f'node_{x}.log')
            if not nl:
                continue
            o = classify_node(nl, ext, win)
            if o is None:
                continue
            print(f"{rd} node {x}: {fmt(o)}")
            res[f"{rd}:{x}"] = {k: (dict(v) if isinstance(v, (Counter, defaultdict)) else v) for k, v in o.items()}
            pooled = merge(pooled, o)
    if pooled:
        print(f"POOLED: {fmt(pooled)}")
        print(f"POOLED refusals by reply: {dict(pooled['refused_by_reply'])}")
        res['POOLED'] = {k: (dict(v) if isinstance(v, (Counter, defaultdict)) else v) for k, v in pooled.items()}
    if a.json:
        with open(a.json, 'w') as f:
            json.dump(res, f, indent=1, sort_keys=True)


if __name__ == '__main__':
    main(sys.argv[1:])
