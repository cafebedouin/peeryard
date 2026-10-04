#!/usr/bin/env python3
"""extminer.py: an external Autolykos v2 miner for one node, getting work the way a pool or a mining proxy does.

  extminer.py --url http://127.0.0.1:<rest port> --poll 4s [--rate 0] [--api-key hello] [--seed S]

Every --poll it reads GET /mining/candidate ({msg, b, h, pk}); between reads it searches nonces on the last
candidate it read. A nonce whose hit is below b (the ordering-block target) is posted to POST /mining/solution as
{"n": <nonce hex>}; the node puts its own key into the solution (Autolykos v2 solutions carry no pk from outside).
On a Matrix node (ergo's weak-blocks line), whose /info parameters carry subblocksPerBlock = k, a nonce whose hit is
below b * k but not below b is an input-block solution: it goes to POST /mining/weakSolution, the node's route for
input blocks. Nothing tells an external miner when the node's candidate changed, so a solution found between two
reads may belong to a candidate the node has already replaced; the node judges it. After any submission the miner
reads the candidate again at once (its own block changed the work), then keeps the --poll schedule.

The node must run with ergo.node.mining = true and ergo.node.useExternalMiner = true (no internal CPU miner). The
hit is computed as the node's verifier computes it (AutolykosPowScheme.hitForVersion2ForMessage). --rate caps the
nonces per second (0: as fast as one core runs the Python hash, about 2,000-3,000 a second).

Output, one line per event on stdout (the rig writes it to $RIG_LOG_DIR/extminer_<node>.log):
  <epoch ms> cand msg=<16 hex> h=<height> k=<subblocksPerBlock or -> changed=<0|1>
  <epoch ms> submit kind=<ordering|input> h=<height> msg=<16 hex> n=<nonce> -> <http status> <reply, 160 chars>
  <epoch ms> poll-error <text>
and on exit (SIGTERM) one summary line:
  <epoch ms> EXTMINER-SUMMARY polls=<n> cand_changes=<n> nonces=<n> ordering_sent=<n> ordering_ok=<n>
            input_sent=<n> input_ok=<n> poll_s=<poll> rate=<rate>
Standard library only.
"""
import argparse
import hashlib
import json
import os
import random
import signal
import sys
import time
import urllib.error
import urllib.request

# AutolykosPowScheme(k = 32, n = 26), the parameters every rig node runs (ergo.chain.powScheme)
K = 32
N_BASE = 2 ** 26
INCREASE_START = 600 * 1024
INCREASE_PERIOD = 50 * 1024
N_INCREASE_MAX_HEIGHT = 4198400
M = b"".join(i.to_bytes(8, "big") for i in range(1024))


def blake(b):
    return hashlib.blake2b(b, digest_size=32).digest()


def calc_n(height, version=2):
    """AutolykosPowScheme.calcN for a version-2+ header."""
    if version == 1:
        return N_BASE
    h = min(N_INCREASE_MAX_HEIGHT, height)
    if h < INCREASE_START:
        return N_BASE
    n = N_BASE
    for _ in range((h - INCREASE_START) // INCREASE_PERIOD + 1):
        n = n // 100 * 105
    return n


def hit_v2(msg, nonce, height, n=None):
    """AutolykosPowScheme.hitForVersion2ForMessage: msg (32 bytes), nonce (8 bytes), height (int)."""
    if n is None:
        n = calc_n(height)
    hb = height.to_bytes(4, "big")
    prei8 = int.from_bytes(blake(msg + nonce)[-8:], "big")
    i = (prei8 % n).to_bytes(4, "big")
    f = blake(i + hb + M)[1:]
    seed_hash = blake(f + msg + nonce)
    ext = seed_hash + seed_hash[:3]
    total = 0
    for j in range(K):
        idx = int.from_bytes(ext[j:j + 4], "big") % n
        total += int.from_bytes(blake(idx.to_bytes(4, "big") + hb + M)[1:], "big")
    return int.from_bytes(blake(total.to_bytes(32, "big")), "big")


def parse_poll(s):
    s = s.strip()
    if s.endswith("ms"):
        return float(s[:-2]) / 1000.0
    if s.endswith("s"):
        return float(s[:-1])
    return float(s)


def now_ms():
    return int(time.time() * 1000)


class Node:
    def __init__(self, url, api_key):
        self.url = url.rstrip("/")
        self.api_key = api_key

    def call(self, path, body=None, timeout=10):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.url + path, data=data, method="GET" if body is None else "POST")
        req.add_header("api_key", self.api_key)
        if body is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.status, r.read().decode(errors="replace")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode(errors="replace")


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", required=True)
    ap.add_argument("--poll", default="4s")
    ap.add_argument("--rate", type=float, default=0.0, help="nonces per second, 0 = unlimited")
    ap.add_argument("--api-key", default="hello")
    ap.add_argument("--seed", default=None)
    a = ap.parse_args(argv)
    poll_s = parse_poll(a.poll)
    node = Node(a.url, a.api_key)
    rnd = random.Random(a.seed if a.seed is not None else os.urandom(8))
    st = dict(polls=0, cand_changes=0, nonces=0, ordering_sent=0, ordering_ok=0, input_sent=0, input_ok=0)

    def summary(*_):
        print(f"{now_ms()} EXTMINER-SUMMARY " + " ".join(f"{k}={v}" for k, v in st.items())
              + f" poll_s={poll_s} rate={a.rate}", flush=True)
        sys.exit(0)

    signal.signal(signal.SIGTERM, summary)
    signal.signal(signal.SIGINT, summary)

    cand = None          # (msg bytes, b int, h int, n int, k int|None)
    next_poll = 0.0
    nonce = rnd.getrandbits(64)
    t_rate0, n_rate0 = time.time(), 0

    def poll():
        nonlocal cand, nonce
        st["polls"] += 1
        try:
            s, body = node.call("/mining/candidate")
            if s != 200:
                print(f"{now_ms()} poll-error candidate {s} {body[:160]}", flush=True)
                return
            c = json.loads(body)
            msg = bytes.fromhex(c["msg"])
            h = int(c["h"])
            b = int(c["b"])
            k = None
            s2, ib = node.call("/info")
            if s2 == 200:
                v = (json.loads(ib).get("parameters") or {}).get("subblocksPerBlock")
                k = int(v) if v else None
        except (OSError, ValueError, KeyError, TypeError) as e:
            print(f"{now_ms()} poll-error {type(e).__name__} {str(e)[:160]}", flush=True)
            return
        changed = cand is None or cand[0] != msg
        if changed:
            st["cand_changes"] += 1
            nonce = rnd.getrandbits(64)
        cand = (msg, b, h, calc_n(h), k)
        print(f"{now_ms()} cand msg={msg.hex()[:16]} h={h} k={k if k else '-'} changed={int(changed)}", flush=True)

    def submit(kind, nb):
        msg, _, h, _, _ = cand
        path = "/mining/solution" if kind == "ordering" else "/mining/weakSolution"
        st[kind + "_sent"] += 1
        try:
            s, body = node.call(path, {"n": nb.hex()}, timeout=30)
        except OSError as e:
            s, body = 0, f"{type(e).__name__} {e}"
        if s == 200:
            st[kind + "_ok"] += 1
        body = body.replace("\n", " ")[:160]
        print(f"{now_ms()} submit kind={kind} h={h} msg={msg.hex()[:16]} n={nb.hex()} -> {s} {body}", flush=True)

    while True:
        t = time.time()
        if t >= next_poll or cand is None:
            poll()
            next_poll = t + poll_s
            if cand is None:
                time.sleep(min(poll_s, 1.0))
                continue
        msg, b, h, n, k = cand
        for _ in range(20):
            nonce = (nonce + 1) & 0xFFFFFFFFFFFFFFFF
            nb = nonce.to_bytes(8, "big")
            hit = hit_v2(msg, nb, h, n)
            st["nonces"] += 1
            n_rate0 += 1
            if hit < b:
                submit("ordering", nb)
                next_poll = 0.0
                break
            if k and hit < b * k:
                submit("input", nb)
                next_poll = 0.0
                break
        if a.rate > 0:
            ahead = n_rate0 / a.rate - (time.time() - t_rate0)
            if ahead > 0:
                time.sleep(ahead)
            if time.time() - t_rate0 > 10:
                t_rate0, n_rate0 = time.time(), 0


if __name__ == "__main__":
    main(sys.argv[1:])
