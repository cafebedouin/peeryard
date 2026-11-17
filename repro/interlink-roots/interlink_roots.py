#!/usr/bin/env python3
"""interlink_roots.py: at which headers do the two forms of a NiPoPoW interlinks proof differ?

What this run shows
  An Ergo block keeps its interlinks in the extension section, and the header commits to the Merkle root of
  the whole extension (`extensionHash`). For every header of a NiPoPoW proof served by a node, and for the
  blocks around the latest voting-epoch start, this script rebuilds the Merkle root of the interlinks alone
  and compares it with `extensionHash`.
    equal     -> the extension holds only interlinks: a proof against the interlinks alone is also a proof
                 against the whole extension (the two forms are the same bytes);
    different -> the extension holds other fields too: the two forms differ for this header.

Claim
  The roots differ for the first block of a voting epoch (height divisible by the voting length), whose
  extension also holds system parameters, and for no other header examined.

What counts against it
  A header at any other height whose roots differ (printed as OTHER), or a voting-epoch start whose roots are
  equal (printed as EQUAL-AT-START). Either gives verdict NOT_AS_STATED and exit status 1.

What it reads and writes
  Reads GET /info, GET /nipopow/proof/{m}/{k} and GET /nipopow/popowHeaderByHeight/{h} of the node given
  (four to six small requests in the default mode; one request per block with --from/--to). Writes nothing.
  Python 3.6+, standard library only. Fixed before the runs: m = 6, k = 10 (the values nodes exchange),
  voting length 1024 (mainnet).

Usage
  python3 interlink_roots.py                                    # node at http://127.0.0.1:9053
  python3 interlink_roots.py --node http://HOST:9053
  python3 interlink_roots.py --from 1916900 --to 1918400        # also every block of a range, one request each
  python3 interlink_roots.py --proof-file proof.json            # a saved /nipopow/proof answer, no network
"""
import argparse
import hashlib
import json
import sys
import time
import urllib.request

INTERLINKS_PREFIX = 0x01


def blake2b256(data):
    return hashlib.blake2b(data, digest_size=32).digest()


def merkle_root(leaves):
    """Root of the Merkle tree Ergo builds over extension fields (leaf prefix 0, inner prefix 1; a node
    without a right sibling is hashed alone)."""
    if not leaves:
        return blake2b256(b"")
    level = [blake2b256(b"\x00" + leaf) for leaf in leaves]
    while True:
        nxt = []
        for i in range(0, len(level), 2):
            right = level[i + 1] if i + 1 < len(level) else b""
            nxt.append(blake2b256(b"\x01" + level[i] + right))
        if len(nxt) == 1:
            return nxt[0]
        level = nxt


def interlinks_root(interlinks):
    """Root of the interlinks alone, packed as the node packs them into the extension: one field per run of
    equal ids, key = (prefix, index of the run's first id), value = (length of the run, id)."""
    leaves = []
    i = 0
    while i < len(interlinks):
        link = interlinks[i]
        run = interlinks.count(link)
        key = bytes([INTERLINKS_PREFIX, i & 0xFF])
        value = bytes([run & 0xFF]) + bytes.fromhex(link)
        leaves.append(bytes([len(key)]) + key + value)
        i += run
    return merkle_root(leaves)


def get(node, path, pause):
    time.sleep(pause)
    request = urllib.request.Request(node.rstrip("/") + path, headers={"User-Agent": "interlink-roots"})
    with urllib.request.urlopen(request, timeout=120) as answer:
        return json.loads(answer.read().decode("utf-8"))


def classify(popow_header, voting_length):
    """-> (height, kind) with kind in GENESIS, EQUAL, DIFFER-AT-START, OTHER, EQUAL-AT-START."""
    header = popow_header["header"]
    height = int(header["height"])
    interlinks = popow_header["interlinks"]
    if height == 1 or not interlinks:
        return height, "GENESIS"
    same = interlinks_root(interlinks).hex() == header["extensionHash"].lower()
    start = height % voting_length == 0
    if same:
        return height, "EQUAL-AT-START" if start else "EQUAL"
    return height, "DIFFER-AT-START" if start else "OTHER"


def main():
    ap = argparse.ArgumentParser(description="Compare the root of the interlinks alone with the extension root.")
    ap.add_argument("--node", default="http://127.0.0.1:9053")
    ap.add_argument("--voting-length", type=int, default=1024)
    ap.add_argument("--m", type=int, default=6)
    ap.add_argument("--k", type=int, default=10)
    ap.add_argument("--from", dest="lo", type=int)
    ap.add_argument("--to", dest="hi", type=int)
    ap.add_argument("--proof-file", help="a saved answer of GET /nipopow/proof/{m}/{k}; no request is made")
    ap.add_argument("--pause", type=float, default=0.3, help="seconds between requests")
    args = ap.parse_args()
    if args.voting_length < 2 or (args.lo is None) != (args.hi is None):
        ap.error("--voting-length must be at least 2, and --from and --to go together")

    results = []  # (source, height, kind)
    try:
        if args.proof_file:
            with open(args.proof_file, encoding="utf-8") as f:
                proof = json.load(f)
            print("proof: file %s" % args.proof_file)
        else:
            info = get(args.node, "/info", 0)
            print("node reports: appVersion %s  network %s  fullHeight %s" % (
                info.get("appVersion"), info.get("network"), info.get("fullHeight")))
            proof = get(args.node, "/nipopow/proof/%d/%d" % (args.m, args.k), args.pause)
        popow_headers = list(proof["prefix"]) + [proof["suffixHead"]]
        tip = int(proof["suffixTail"][-1]["height"]) if proof.get("suffixTail") else int(proof["suffixHead"]["header"]["height"])
        print("proof: m=%s k=%s continuous=%s, %d headers with interlinks, tip %d" % (
            proof.get("m"), proof.get("k"), proof.get("continuous"), len(popow_headers), tip))
        for ph in popow_headers:
            results.append(("proof",) + classify(ph, args.voting_length))

        if not args.proof_file:
            start = tip - tip % args.voting_length
            heights = [h for h in (start - 1, start, start + 1) if h > 1]
            if args.lo is not None:
                heights = sorted(set(heights) | set(range(max(2, args.lo), args.hi + 1)))
            for h in heights:
                ph = get(args.node, "/nipopow/popowHeaderByHeight/%d" % h, args.pause)
                results.append(("block",) + classify(ph, args.voting_length))
    except Exception as e:  # network, JSON or shape: nothing can be concluded
        print("RESULT verdict=INCONCLUSIVE reason=%s: %s" % (type(e).__name__, e))
        return 2

    for source in ("proof", "block"):
        rows = [r for r in results if r[0] == source]
        if not rows:
            continue
        by_kind = {}
        for _, height, kind in rows:
            by_kind.setdefault(kind, []).append(height)
        print("%s headers: %d; roots equal: %d; differ at a voting-epoch start: %s; genesis: %d" % (
            source, len(rows), len(by_kind.get("EQUAL", [])), sorted(by_kind.get("DIFFER-AT-START", [])),
            len(by_kind.get("GENESIS", []))))
        for bad in ("OTHER", "EQUAL-AT-START"):
            if by_kind.get(bad):
                print("  %s: %s" % (bad, sorted(by_kind[bad])))

    kinds = [kind for _, _, kind in results]
    equal, differ = kinds.count("EQUAL"), kinds.count("DIFFER-AT-START")
    against = kinds.count("OTHER") + kinds.count("EQUAL-AT-START")
    if against:
        verdict, status = "NOT_AS_STATED", 1
    elif equal == 0 or differ == 0:
        # no ordinary header matched (the root computation is unconfirmed) or no voting-epoch start was seen
        verdict, status = "INCONCLUSIVE", 2
    else:
        verdict, status = "AS_STATED", 0
    print("RESULT headers=%d equal=%d differ_at_voting_epoch_start=%d against=%d verdict=%s" % (
        len(results), equal, differ, against, verdict))
    return status


if __name__ == "__main__":
    sys.exit(main())
