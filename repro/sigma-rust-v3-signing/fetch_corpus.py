#!/usr/bin/env python3
"""fetch_corpus.py: the corpus fetch (corpus.json here is its frozen output; the CI run does not refetch).

Builds the mechanically defined corpus: mainnet transactions, newest first, that spend
  - a box holding the Lithos pool NFT (up to 60),
  - a box holding the fee-vault NFT (up to 20),
  - a provision-contract box (holds the provision token, not at the pool address; up to 20),
plus one control tx: the most recent SigUSD bank-box spend.

For every tx: the signed tx JSON as the node serves it, every input box and data-input box in
node JSON shape, the inclusion block header and the 10 headers before it.

Sources: explorer API v1 (enumeration, block id of a tx) and a public node (block transactions,
boxes via extraIndex, headers). Both are third-party endpoints; the ones used are written into
the output. Stdlib only.

usage: fetch_corpus.py OUT.json [--explorer URL] [--node URL]
"""
import argparse
import hashlib
import json
import sys
import time
import urllib.error
import urllib.request

POOL_NFT = "c0b21ac51481a5d242809d9b1e189a8baf3803fe347ca01833c1aeb380e6eb29"
SIGUSD_BANK_NFT = "7d672d1def471720ca5782fd6473e47e796d9ac0c138d9911346f118b2f6d9d9"
N_POOL, N_VAULT, N_PROV = 60, 20, 20


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def get(url, tries=6):
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "sigma-rust-v3-signing-corpus/1"})
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.loads(r.read())
        except urllib.error.HTTPError as e:
            if e.code == 404:
                raise LookupError(url)
            log(f"  retry {i+1} {url}: {e}")
            time.sleep(2 * (i + 1))
        except Exception as e:  # noqa: BLE001
            log(f"  retry {i+1} {url}: {e}")
            time.sleep(2 * (i + 1))
    raise RuntimeError(f"failed: {url}")


def signed_byte(b):
    return b & 0xFF


class Fetch:
    def __init__(self, explorer, node):
        self.ex = explorer.rstrip("/")
        self.node = node.rstrip("/")
        self.blocktx = {}
        self.boxes = {}

    def ex_get(self, path):
        time.sleep(0.15)
        return get(f"{self.ex}{path}")

    def node_get(self, path):
        time.sleep(0.1)
        return get(f"{self.node}{path}")

    def boxes_by_token(self, token_id):
        first = self.ex_get(f"/api/v1/boxes/byTokenId/{token_id}?offset=0&limit=1")
        total = first["total"]
        items, off = [], 0
        while off < total:
            page = self.ex_get(f"/api/v1/boxes/byTokenId/{token_id}?offset={off}&limit=100")
            items += page["items"]
            if not page["items"]:
                break
            off += 100
        return total, items

    def spending_txs(self, boxes, n, exclude_address=None):
        """Distinct spending tx ids of the given boxes, newest spend first."""
        spent = [b for b in boxes if b.get("spentTransactionId") and b.get("mainChain", True)
                 and (exclude_address is None or b["address"] != exclude_address)]
        spent.sort(key=lambda b: b["globalIndex"], reverse=True)
        out = []
        for b in spent:
            t = b["spentTransactionId"]
            if t not in out:
                out.append(t)
        # newest *spend* first: order by the spending tx's inclusion, resolved later
        return out

    def tx_meta(self, txid):
        t = self.ex_get(f"/api/v1/transactions/{txid}")
        return {"blockId": t["blockId"], "inclusionHeight": t["inclusionHeight"],
                "globalIndex": t.get("globalIndex"), "timestamp": t.get("timestamp")}

    def node_tx(self, block_id, txid):
        if block_id not in self.blocktx:
            bt = self.node_get(f"/blocks/{block_id}/transactions")
            self.blocktx[block_id] = {t["id"]: t for t in bt["transactions"]}
        tx = self.blocktx[block_id][txid]
        return {k: tx[k] for k in ("id", "inputs", "dataInputs", "outputs")}

    def box(self, box_id):
        if box_id not in self.boxes:
            b = self.node_get(f"/blockchain/box/byId/{box_id}")
            self.boxes[box_id] = {k: b[k] for k in ("boxId", "value", "ergoTree", "assets", "creationHeight",
                                                    "additionalRegisters", "transactionId", "index")}
        return self.boxes[box_id]

    def headers(self, height, block_id):
        hs = self.node_get(f"/blocks/chainSlice?fromHeight={height-11}&toHeight={height}")
        hs.sort(key=lambda h: h["height"])
        assert hs[-1]["height"] == height and hs[-1]["id"] == block_id, (height, block_id, hs[-1]["id"])
        assert len(hs) == 11, len(hs)
        for a, b in zip(hs, hs[1:]):
            assert b["parentId"] == a["id"]
        return hs[-1], list(reversed(hs[:-1]))  # inclusion header; previous 10 newest first


def const_coll32(constants_text):
    """Parse explorer's decoded-constants text for 32-byte Coll[Byte] constants.

    The explorer renders this text in two shapes ("15: Coll(...)" and "15: Coll[SByte$] = Coll(...)"
    style); match the index and the byte list only."""
    import re
    out = []
    for m in re.finditer(r"(\d+):[^\n]*?Coll\(([-\d,\s]+)\)", constants_text):
        vals = [int(x) for x in m.group(2).replace(" ", "").split(",") if x]
        if len(vals) == 32:
            out.append((int(m.group(1)), bytes(signed_byte(v) for v in vals).hex()))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--explorer", default="https://api.ergoplatform.com")
    ap.add_argument("--node", default="http://76.119.196.68:9053")
    a = ap.parse_args()
    f = Fetch(a.explorer, a.node)
    started = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    node_info = f.node_get("/info")

    # --- resolution: pool box, its tree, and the vault NFT / provision token -----------------------
    total_pool, pool_boxes = f.boxes_by_token(POOL_NFT)
    unspent = [b for b in pool_boxes if not b.get("spentTransactionId")]
    assert len(unspent) == 1, len(unspent)
    pool = unspent[0]
    pool_tree = pool["ergoTree"]
    pool_addr = pool["address"]
    prov_token = pool["assets"][2]["tokenId"]
    c32 = const_coll32(pool["ergoTreeConstants"])
    resolution = {"pool_box_unspent": pool["boxId"], "pool_tree_len": len(pool_tree) // 2,
                  "pool_tree_prefix": pool_tree[:4], "pool_tree_sha256": hashlib.sha256(bytes.fromhex(pool_tree)).hexdigest(),
                  "pool_address": pool_addr, "pool_assets": pool["assets"],
                  "provision_token (pool box tokens(2))": prov_token, "tree_coll32_constants": []}
    vault_nft = None
    guard_hash = None
    for idx, hexid in c32:
        tok = None
        try:
            tok = f.ex_get(f"/api/v1/tokens/{hexid}")
        except LookupError:
            guard_hash = hexid
        name = tok.get("name") if tok else None
        resolution["tree_coll32_constants"].append({"index": idx, "hex": hexid, "token_name": name})
        if tok is not None:
            assert vault_nft is None, "two token constants"
            vault_nft = hexid
    assert vault_nft, "vault NFT not resolved"
    assert guard_hash, "provision guard hash not resolved"
    resolution["provision_guard_hash (non-token coll32 constant)"] = guard_hash
    resolution["vault_nft"] = vault_nft
    resolution["all_pool_tree_versions_seen"] = sorted({b["ergoTree"][:4] for b in pool_boxes})
    resolution["pool_boxes_total"] = total_pool
    log("resolution", json.dumps(resolution, indent=1))

    # --- enumerate ---------------------------------------------------------------------------------
    sets = {}
    sets["pool"] = f.spending_txs(pool_boxes, N_POOL)
    _, vault_boxes = f.boxes_by_token(vault_nft)
    resolution["vault_boxes_total"] = len(vault_boxes)
    resolution["vault_address"] = sorted({b["address"] for b in vault_boxes})[:3]
    sets["vault"] = f.spending_txs(vault_boxes, N_VAULT)
    _, prov_boxes = f.boxes_by_token(prov_token)
    resolution["provtoken_boxes_not_at_pool_by_tree"] = {}
    for b in prov_boxes:
        if b["address"] == pool_addr:
            continue
        th = hashlib.blake2b(bytes.fromhex(b["ergoTree"]), digest_size=32).hexdigest()
        k = f"blake2b256={th} guard={th == guard_hash}"
        resolution["provtoken_boxes_not_at_pool_by_tree"][k] = resolution["provtoken_boxes_not_at_pool_by_tree"].get(k, 0) + 1
    prov_boxes = [b for b in prov_boxes if b["address"] != pool_addr and
                  hashlib.blake2b(bytes.fromhex(b["ergoTree"]), digest_size=32).hexdigest() == guard_hash]
    resolution["provision_boxes_total (tree hash == guard hash)"] = len(prov_boxes)
    resolution["provision_tree_sha256s"] = sorted({hashlib.sha256(bytes.fromhex(b["ergoTree"])).hexdigest()
                                                   for b in prov_boxes})
    sets["provision"] = f.spending_txs(prov_boxes, N_PROV)

    # newest first by spending tx inclusion: resolve metadata, then cut
    meta = {}
    selected = {}
    for name, n in (("pool", N_POOL), ("vault", N_VAULT), ("provision", N_PROV)):
        ids = sets[name]
        # candidate list is ordered by spent box globalIndex desc; take a margin, then sort by inclusion
        cand = ids[: n + 20]
        for t in cand:
            if t not in meta:
                meta[t] = f.tx_meta(t)
        cand.sort(key=lambda t: (meta[t]["inclusionHeight"], meta[t]["globalIndex"] or 0), reverse=True)
        selected[name] = cand[:n]
        log(name, len(ids), "spending txs on chain;", len(selected[name]), "selected")
    resolution["spending_tx_counts_on_chain"] = {k: len(v) for k, v in sets.items()}

    # control: most recent SigUSD bank-box spend = the tx that created the unspent bank box
    bank = f.ex_get(f"/api/v1/boxes/unspent/byTokenId/{SIGUSD_BANK_NFT}")["items"]
    assert len(bank) == 1
    ctrl_tx = bank[0]["transactionId"]
    meta[ctrl_tx] = f.tx_meta(ctrl_tx)
    bank_tok = f.ex_get(f"/api/v1/tokens/{SIGUSD_BANK_NFT}")
    resolution["control"] = {"sigusd_bank_nft": SIGUSD_BANK_NFT, "token_name": bank_tok.get("name"),
                             "unspent_bank_box": bank[0]["boxId"], "control_tx": ctrl_tx}

    # --- fetch each tx ------------------------------------------------------------------------------
    order = []
    tags = {}
    for name in ("pool", "vault", "provision"):
        for t in selected[name]:
            tags.setdefault(t, []).append(name)
            if t not in order:
                order.append(t)
    tags.setdefault(ctrl_tx, []).append("control_sigusd_bank")
    order.append(ctrl_tx)

    txs = []
    for i, t in enumerate(order):
        m = meta[t]
        log(f"[{i+1}/{len(order)}] {t} h={m['inclusionHeight']} {tags[t]}")
        tx = f.node_tx(m["blockId"], t)
        ins = [f.box(x["boxId"]) for x in tx["inputs"]]
        dins = [f.box(x["boxId"]) for x in tx["dataInputs"]]
        hdr, prev10 = f.headers(m["inclusionHeight"], m["blockId"])
        txs.append({"txId": t, "sets": tags[t], "inclusionHeight": m["inclusionHeight"], "blockId": m["blockId"],
                    "tx": tx, "inputBoxes": ins, "dataInputBoxes": dins,
                    "blockHeader": hdr, "lastHeaders": prev10})

    # distinct input-tree set
    trees = {}
    for e in txs:
        for b in e["inputBoxes"]:
            h = hashlib.sha256(bytes.fromhex(b["ergoTree"])).hexdigest()
            d = trees.setdefault(h, {"prefix": b["ergoTree"][:4], "len": len(b["ergoTree"]) // 2, "count": 0})
            d["count"] += 1

    out = {"schema": "sigma-rust-v3-signing-corpus/1", "fetched_utc_start": started,
           "fetched_utc_end": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           "endpoints": {"explorer": a.explorer, "node": a.node,
                         "node_info": {k: node_info.get(k) for k in ("name", "appVersion", "network", "fullHeight",
                                                                      "bestFullHeaderId", "parameters")}},
           "resolution": resolution, "selected": selected, "distinct_input_trees": trees, "txs": txs}
    with open(a.out, "w") as fh:
        json.dump(out, fh, indent=1, sort_keys=False)
    log("wrote", a.out, len(txs), "txs")


if __name__ == "__main__":
    main()
