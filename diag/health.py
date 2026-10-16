#!/usr/bin/env python3
"""health.py: did every node stay healthy through a run? Process exits, out-of-memory errors and restart loops.

  python3 diag/health.py <run dir> [--json <file>] [--report-only <node>]... [--loop-min N] [--from HH:MM:SS] [--to HH:MM:SS]
  python3 diag/health.py --watch <rig log dir>        (the rig starts this during the hook; see below)

A run can end with every node on one chain and state, and so PASS, after a node spent the run failing: a node that
exited and was relaunched by the hook, a JVM that hit OutOfMemoryError, or an actor that its supervisor restarted
hundreds of thousands of times (patch-compare run 37306440981, p1-v3: 230779 x `a.actor.OneForOneStrategy - key not
found: 9`, each followed by `ErgoMiningThread - Attempted mining thread restart`, under MATRIX-COMPAT: PASS). This
reads what the run kept and names each such problem per node:

  NODE_EXIT     the node's process ended without the rig stopping it (a `==== [rig] exit <node> ... unplanned ====`
                line in its log, written by the watcher below, or an `exit` event in events.jsonl)
  NODE_OOM      a java.lang.OutOfMemoryError line in the node's log
  JVM_FATAL     the JVM's own fatal-error banner ("A fatal error has been detected by the Java Runtime Environment")
  RESTART_LOOP  one supervisor-restart message logged at least --loop-min (20) times: an ERROR from an Akka
                supervisor strategy (OneForOneStrategy, AllForOneStrategy) or any ERROR or WARN line whose message
                says it restarts (e.g. `ErgoMiningThread - Attempted mining thread restart ...`). Ids (64 hex) are
                folded into <id>, so one cause repeating is one message.

Input, either layout:
  a rig log dir           node_<X>.log (and events.jsonl when present), as rig.sh writes them in $RIG_LOG_DIR;
  a patch-compare run     nodes/node_<X>.log.gz, or, without node logs, errors-node_<X>.txt (the workflow's
                          `uniq -c` of each node's ERROR lines: counts only, no times, so --from/--to do not apply
                          and NODE_OOM / JVM_FATAL are read only where they were logged at ERROR).
--from/--to keep only timestamped log lines inside that clock window (node log times, HH:MM:SS), e.g. a hook's mining
window. --report-only <node>: that node's problems are printed with `(report only)` and do not make the run unhealthy
(a hook that damages a node on purpose and reports, rather than judges, what it then does: corruption).

Prints one `HEALTH <node> ...` line per node and a summary line, `HEALTH: OK nodes=<n>` or
`HEALTH: UNHEALTHY <node>=<CODE>[,<CODE>] ...`. Exit 0 healthy, 1 unhealthy, 2 nothing to read.

--watch: the rig's exit watcher. Every PEERYARD_HEALTH_POLL_S (1) s it reads new `launch` events from events.jsonl
(each carries the node's pid), and when a launched pid has gone (or is a zombie) and is not listed in planned_exits
(the rig writes `<node> <pid>` there before it stops a node: relaunch, crash, fixture saves), it appends an `exit`
event to events.jsonl and a `==== [rig] exit <node> pid=<pid> <time> unplanned ====` line to the node's log, so the
exit is in the record a run keeps even when events.jsonl is not uploaded. Standard library only.
"""
import argparse
import collections
import datetime
import glob
import gzip
import json
import os
import re
import sys
import time

LINE = re.compile(r'^(\d\d:\d\d:\d\d)(?:\.\d+)?\s+(ERROR|WARN)\s+\[[^\]]*\]\s+(\S+)\s+-\s?(.*)$')
COUNTED = re.compile(r'^\s*(\d+) (\S+) - ?(.*)$')       # errors-node_X.txt: `uniq -c` of "<logger> - <message>"
SUPERVISOR = re.compile(r'(?:^|\.)(?:OneForOneStrategy|AllForOneStrategy)$')
RESTARTS = re.compile(r'\brestart', re.I)
OOM = re.compile(r'java\.lang\.OutOfMemoryError')
FATAL = re.compile(r'A fatal error has been detected by the Java Runtime Environment')
EXIT_BANNER = re.compile(r'^==== \[rig\] exit (\S+) pid=(\d+) (\S+) unplanned ====')
LAUNCH_BANNER = re.compile(r'^==== \[rig\] \(re\)launch (\S+) ')
HEX = re.compile(r'[0-9a-f]{64}')


def _open(path):
    return gzip.open(path, 'rt', errors='replace') if path.endswith('.gz') else open(path, errors='replace')


def _sources(run):
    """{node: (kind, path)} with kind 'log' (a full node log) or 'counts' (errors-node_X.txt)."""
    out = {}
    for pat in ('nodes/node_*.log.gz', 'nodes/node_*.log', 'node_*.log.gz', 'node_*.log'):
        for p in sorted(glob.glob(os.path.join(run, pat))):
            n = re.sub(r'\.log(\.gz)?$', '', os.path.basename(p))[len('node_'):]
            out.setdefault(n, ('log', p))
    for p in sorted(glob.glob(os.path.join(run, 'errors-node_*.txt'))):
        n = os.path.basename(p)[len('errors-node_'):-len('.txt')]
        out.setdefault(n, ('counts', p))
    return out


def _restart_key(logger, msg, level):
    if SUPERVISOR.search(logger) and level == 'ERROR':
        return f'{logger} - {HEX.sub("<id>", msg)}'
    if RESTARTS.search(msg):
        return f'{logger} - {HEX.sub("<id>", msg)}'
    return None


def node_health(kind, path, window=(None, None)):
    """One node's counts from its log (or its counted ERROR lines)."""
    lo, hi = window
    h = dict(launches=0, exits=[], oom=0, oom_first=None, fatal=0, restarts=collections.Counter(), source=kind)
    with _open(path) as f:
        for line in f:
            line = line.rstrip('\n')
            if kind == 'counts':
                m = COUNTED.match(line)
                if not m:
                    continue
                c, logger, msg = int(m.group(1)), m.group(2), m.group(3)
                k = _restart_key(logger, msg, 'ERROR')
                if k:
                    h['restarts'][k] += c
                if OOM.search(msg):
                    h['oom'] += c; h['oom_first'] = h['oom_first'] or f'{logger} - {msg}'[:160]
                continue
            if LAUNCH_BANNER.match(line):
                h['launches'] += 1; continue
            m = EXIT_BANNER.match(line)
            if m:
                h['exits'].append({'pid': int(m.group(2)), 'at': m.group(3)}); continue
            m = LINE.match(line)
            ts = m.group(1) if m else None
            if ts and ((lo and ts < lo) or (hi and ts > hi)):
                continue
            if m:
                k = _restart_key(m.group(3), m.group(4), m.group(2))
                if k:
                    h['restarts'][k] += 1
            if OOM.search(line):
                h['oom'] += 1; h['oom_first'] = h['oom_first'] or line.strip()[:160]
            if FATAL.search(line):
                h['fatal'] += 1
    return h


def _event_exits(run):
    """{node: [exit]} from events.jsonl (the watcher's `exit` events), for a dir without node logs."""
    out = collections.defaultdict(list)
    p = os.path.join(run, 'events.jsonl')
    if os.path.exists(p):
        with open(p, errors='replace') as f:
            for line in f:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if e.get('kind') == 'exit' and e.get('node'):
                    out[e['node']].append({'pid': e.get('pid'), 'at': e.get('t')})
    return out


def analyze(run, report_only=(), loop_min=20, window=(None, None)):
    """{'nodes': {node: {...codes...}}, 'unhealthy': {node: [codes]}, 'source': ...} or None when nothing to read."""
    src = _sources(run)
    if not src:
        return None
    ev_exits = _event_exits(run)
    nodes, bad = {}, {}
    for n, (kind, path) in sorted(src.items()):
        h = node_health(kind, path, window)
        if not h['exits'] and ev_exits.get(n):
            h['exits'] = ev_exits[n]
        loops = [(c, k) for k, c in h['restarts'].most_common() if c >= loop_min]
        codes = []
        if h['exits']:
            codes.append('NODE_EXIT')
        if h['oom']:
            codes.append('NODE_OOM')
        if h['fatal']:
            codes.append('JVM_FATAL')
        if loops:
            codes.append('RESTART_LOOP')
        nodes[n] = {'source': h['source'], 'launches': h['launches'], 'exits': h['exits'],
                    'report_only': n in report_only, 'oom': h['oom'], 'oom_first': h['oom_first'],
                    'jvm_fatal': h['fatal'], 'restart_lines': sum(h['restarts'].values()),
                    'restart_loops': [{'count': c, 'message': k[:200]} for c, k in loops], 'codes': codes}
        if codes and n not in report_only:
            bad[n] = codes
    return {'nodes': nodes, 'unhealthy': bad, 'loop_min': loop_min,
            'window': {'from': window[0], 'to': window[1]}}


def report(res):
    lines = []
    for n, h in res['nodes'].items():
        top = h['restart_loops'][0] if h['restart_loops'] else None
        lines.append(f"HEALTH {n} {'UNHEALTHY ' + ','.join(h['codes']) if h['codes'] else 'ok'}"
                     f"{' (report only)' if h['report_only'] and h['codes'] else ''}"
                     f" launches={h['launches']} exits={len(h['exits'])}"
                     f" oom={h['oom']} jvm_fatal={h['jvm_fatal']} restart_lines={h['restart_lines']}"
                     + (f" loop: {top['count']}x {top['message'][:120]}" if top else '')
                     + ('' if h['source'] == 'log' else ' (from counted ERROR lines)'))
    if res['unhealthy']:
        lines.append('HEALTH: UNHEALTHY ' + ' '.join(f"{n}={','.join(c)}" for n, c in res['unhealthy'].items()))
    else:
        lines.append(f"HEALTH: OK nodes={len(res['nodes'])}")
    return lines


# ---- the rig's exit watcher ----
def _alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    try:
        with open(f'/proc/{pid}/stat') as f:
            return f.read().rsplit(')', 1)[1].split()[0] != 'Z'
    except OSError:
        return False


def watch(d, poll=1.0, once=False):
    ev_path, planned_path = os.path.join(d, 'events.jsonl'), os.path.join(d, 'planned_exits')
    off, buf, pids = 0, '', {}
    while True:
        if os.path.exists(ev_path):
            with open(ev_path, errors='replace') as f:
                f.seek(off); chunk = f.read(); off = f.tell()
            buf += chunk
            *done, buf = buf.split('\n')                    # a line still being written stays in buf
            for line in done:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if e.get('kind') == 'launch' and e.get('node') and isinstance(e.get('pid'), int):
                    pids[e['node']] = e['pid']
        planned = set()
        if os.path.exists(planned_path):
            with open(planned_path, errors='replace') as f:
                planned = {tuple(l.split()[:2]) for l in f if len(l.split()) >= 2}
        for n, pid in list(pids.items()):
            if _alive(pid):
                continue
            del pids[n]
            if (n, str(pid)) in planned:
                continue
            now = datetime.datetime.now().astimezone().isoformat(timespec='seconds')
            with open(ev_path, 'a') as f:
                f.write(json.dumps({'t': int(time.time() * 1000), 'kind': 'exit', 'a': None, 'b': None, 'node': n,
                                    'detail': 'unplanned', 'pid': pid}) + '\n')
            with open(os.path.join(d, f'node_{n}.log'), 'a') as f:
                f.write(f'==== [rig] exit {n} pid={pid} {now} unplanned ====\n')
            print(f'[rig] HEALTH {n}: its process (pid {pid}) ended without the rig stopping it', flush=True)
        if once:
            return
        time.sleep(poll)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('run')
    ap.add_argument('--watch', action='store_true')
    ap.add_argument('--json')
    ap.add_argument('--report-only', action='append', default=[])
    ap.add_argument('--loop-min', type=int, default=int(os.environ.get('PEERYARD_HEALTH_LOOP_MIN', 20)))
    ap.add_argument('--from', dest='lo')
    ap.add_argument('--to', dest='hi')
    a = ap.parse_args(argv)
    if a.watch:
        watch(a.run, float(os.environ.get('PEERYARD_HEALTH_POLL_S', 1)))
        return 0
    res = analyze(a.run, set(a.report_only), a.loop_min, (a.lo, a.hi))
    if res is None:
        print(f'HEALTH: NO-INPUT (no node_<X>.log, nodes/node_<X>.log.gz or errors-node_<X>.txt under {a.run})')
        return 2
    for line in report(res):
        print(line)
    if a.json:
        with open(a.json, 'w') as f:
            json.dump(res, f, indent=1)
    return 1 if res['unhealthy'] else 0


if __name__ == '__main__':
    sys.exit(main())
