#!/usr/bin/env python3
"""fetch_machina.py: the second corpus fetch (corpus-machina.json here is its frozen output; the CI run does not
refetch).

Mainnet transactions that spend boxes at one Machina limit-order address (ErgoTree version 2, header 0x1a): the
transaction that spent the seed box 59f7532a...17ca first, then the spending transactions of every other spent box
at the address, newest box first (explorer globalIndex, descending), each transaction once, at most --n (21).

For every tx, the same record as fetch_corpus.py writes: the signed tx JSON as the node serves it, every input box
and data-input box in node JSON shape, the inclusion block header and the 10 headers before it. Same sources (the
explorer API for enumeration, a public node for transactions, boxes and headers) and the Fetch class of
fetch_corpus.py in this directory. The node is recorded only as "a public mainnet node": headers are hash-linked, so
any node returns the same bytes. Integers are written exactly (Python ints); see README for how the JS runners read
the ones above 2^53. Stdlib only.

usage: fetch_machina.py OUT.json --node URL [--explorer URL] [--n 21]
"""
import argparse
import hashlib
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fetch_corpus import Fetch, log  # noqa: E402

ADDRESS = ("2EPgnhaSQdearoeKGfCu3txjR7cvw9UCyeYJRtN98e4CzTMHdDmLQa18psvQYqnURgF1Cg5r2QzD8xkrPZUi9hx5JGgaWDwVwNAD6g"
           "ZWb2AAX4uMKMxdjQYM6uJ6y5F2zwZCmwCYbRcA5cfPaeJ32TBvtpVS1TgaFvWG3RPToc5dUFoHRZdyaxYuLGmbTkJFXhHYH4L5xwbb8Z"
           "ZYJTEmU38Kpd71Smj7xvzPWr8c36fXo5QkCmCe9TUWLaBLmmc1kuTt6TEm5chqwtGGYsNVvvXVDJxmXfajpjSKhXmxa4R7mtXiV9ema2"
           "YrzkSx6vXqjujGzyemGzctGqaz4yxsZPhPxLJa6TQew5dvHGr2MFK59LZ2kfcA893zCzfRH7k4pwkdWPvT495xEQ7N")
SEED_BOX = "59f7532a3b20f786f92a38d44c5b37cd367472108758d99581ca4f7e253a17ca"
SET = "machina-limit"
NODE_LABEL = "a public mainnet node (headers are hash-linked; any node returns the same bytes)"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--explorer", default="https://api.ergoplatform.com")
    ap.add_argument("--node", required=True, help="any public mainnet node, e.g. one from the ergoplatform peer list")
    ap.add_argument("--n", type=int, default=21)
    a = ap.parse_args()
    f = Fetch(a.explorer, a.node)
    started = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    info = f.node_get("/info")

    boxes, off = [], 0
    while True:
        page = f.ex_get(f"/api/v1/boxes/byAddress/{ADDRESS}?offset={off}&limit=100")
        boxes += page["items"]
        off += 100
        if off >= page["total"] or not page["items"]:
            break
    spent = [b for b in boxes if b.get("spentTransactionId") and b.get("mainChain", True)]
    log("boxes at address:", len(boxes), "spent:", len(spent))
    seed = [b for b in spent if b["boxId"] == SEED_BOX]
    assert seed, "seed box not spent (or not at the address)"
    txids = []
    for b in seed + sorted(spent, key=lambda b: b["globalIndex"], reverse=True):
        if b["spentTransactionId"] not in txids:
            txids.append(b["spentTransactionId"])
    distinct_spending = len(txids)
    txids = txids[: a.n]

    txs = []
    for t in txids:
        m = f.tx_meta(t)
        tx = f.node_tx(m["blockId"], t)
        hdr, prev10 = f.headers(m["inclusionHeight"], m["blockId"])
        txs.append({"txId": t, "sets": [SET], "inclusionHeight": m["inclusionHeight"], "blockId": m["blockId"],
                    "tx": tx, "inputBoxes": [f.box(x["boxId"]) for x in tx["inputs"]],
                    "dataInputBoxes": [f.box(x["boxId"]) for x in tx["dataInputs"]],
                    "blockHeader": hdr, "lastHeaders": prev10})
        log("tx", t[:12], "h", m["inclusionHeight"], "inputs", len(tx["inputs"]))

    trees = {}
    for e in txs:
        for b in e["inputBoxes"]:
            h = hashlib.sha256(bytes.fromhex(b["ergoTree"])).hexdigest()
            d = trees.setdefault(h, {"prefix": b["ergoTree"][:4], "len": len(b["ergoTree"]) // 2, "count": 0})
            d["count"] += 1

    out = {"schema": "sigma-rust-v3-signing-corpus/1", "fetched_utc_start": started,
           "fetched_utc_end": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           "endpoints": {"explorer": a.explorer, "node": NODE_LABEL,
                         "node_info": {k: info.get(k) for k in ("network", "fullHeight")}},
           "resolution": {"address": ADDRESS, "seed_box": SEED_BOX, "boxes_at_address": len(boxes),
                          "spent": len(spent), "distinct_spending_txs": distinct_spending, "max_txs": a.n},
           "selected": {SET: txids}, "distinct_input_trees": trees, "txs": txs}
    with open(a.out, "w") as fh:
        json.dump(out, fh, indent=1, sort_keys=False)
    log("wrote", a.out, len(txs), "txs")


if __name__ == "__main__":
    main()
