# relay-floor: a relay peer with a lower fee floor than its neighbours, under real wallet load, and whether
# the strict nodes' per-peer transaction budget throttles it. Four nodes, one jar: A mines (fee floor 1,000,000, the
# shipped default), S is strict and does not mine, R relays with a floor of 100,000, Q pays to A and S directly
# (strict floor, its own wallet). S has no link to A: everything S learns about unconfirmed transactions comes from R
# or Q. The "payer behind the relay" is A's wallet: it signs payments without broadcasting them
# (/wallet/transaction/generate, each spending its own confirmed box) and the hook submits them to R's REST API, so
# they enter the network at R and reach A and S as R's peer traffic. For INTERVALS inter-block intervals (A polls its
# miner every 20 s and finds a block on nearly every poll at the rig's fixed devnet difficulty; each burst starts right
# after a new block, once R and S hold it), R receives LOW payments with a fee between the two floors (R accepts and
# forwards, A and S decline) and VALID payments above both, interleaved; Q sends QVALID valid payments. A watcher
# records when each id is first seen in S's and A's pools; a scan of A's blocks records what was mined; S's INFO log
# gives the declines (its `Processing mempool transaction: <id>` lines for low-fee ids, repeats included) and its inv
# processing from R, per interval. Env (defaults): RELAY_FLOOR_INTERVALS (6), RELAY_FLOOR_LOW (60), RELAY_FLOOR_VALID (10),
# RELAY_FLOOR_QVALID (10), RELAY_FLOOR_LOW_FEE (500000), RELAY_FLOOR_VALID_FEE (1100000), RELAY_FLOOR_WAIT_S (120).
# Records in $RIG_LOG_DIR: payments.jsonl, seen.jsonl, mined.jsonl, blocks.jsonl, s_declines.jsonl, s_invs.jsonl, summary.json.
# The last line is machine-readable: RELAY-FLOOR <key=value ...> verdict=<PASS|FAIL>; under diffrun one RESULT_JSON.
INTERVALS=${RELAY_FLOOR_INTERVALS:-6}; LOW=${RELAY_FLOOR_LOW:-60}; VALID=${RELAY_FLOOR_VALID:-10}; QVALID=${RELAY_FLOOR_QVALID:-10}
LOW_FEE=${RELAY_FLOOR_LOW_FEE:-500000}; VALID_FEE=${RELAY_FLOOR_VALID_FEE:-1100000}; WAIT=${RELAY_FLOOR_WAIT_S:-120}
AMT=100000000; BOX=300000000; BOXQ=310000000   # Q's boxes differ in value so one funding transaction's outputs can be told apart
PAY_LOG="$RIG_LOG_DIR/payments.jsonl"; SEEN_LOG="$RIG_LOG_DIR/seen.jsonl"; MINED_LOG="$RIG_LOG_DIR/mined.jsonl"
: > "$PAY_LOG"; : > "$SEEN_LOG"; : > "$MINED_LOG"
VA=$(rest A /info | jq -r .appVersion); VS=$(rest S /info | jq -r .appVersion); VR=$(rest R /info | jq -r .appVersion)
echo "[relay-floor] A=$VA S=$VS R=$VR; $INTERVALS intervals x (low $LOW @ $LOW_FEE, valid $VALID @ $VALID_FEE into R; $QVALID valid from Q)"
echo "[relay-floor] floors: A $(grep -h minimalFeeAmount "$SCRATCH"/conf_A.conf | tr -d ' ') R $(grep -h minimalFeeAmount "$SCRATCH"/conf_R.conf | tr -d ' ') S $(grep -h minimalFeeAmount "$SCRATCH"/conf_S.conf | tr -d ' ')"
end=$((SECONDS + 90)); AA=""; AQ=""; while [[ $SECONDS -lt $end && ( -z "$AA" || -z "$AQ" ) ]]; do AA=$(address A); AQ=$(address Q); [[ -n "$AA" && -n "$AQ" ]] || sleep 3; done
[[ -n "$AA" && -n "$AQ" ]] || { echo "[relay-floor] INCONCLUSIVE: a wallet never reported an address (A '${AA:0:8}' Q '${AQ:0:8}')"; rig_verdict=INCONCLUSIVE; return; }
[[ "$AA" != "$AQ" ]] || { echo "[relay-floor] INCONCLUSIVE: A and Q share an address (mnemonic override did not apply)"; rig_verdict=INCONCLUSIVE; return; }
# gen_via_r <nanoerg> <box id> <fee>: A's wallet signs one payment to S's address spending exactly that box, without
# broadcasting; the signed transaction is posted to R's /transactions. Prints the id R accepted, or R's error text.
gen_via_r(){ local to raw tx; to="$(address S)"
  raw="$(rest A "/utxo/byIdBinary/$2" | jq -r '.bytes // empty')"; [[ -n "$raw" ]] || { echo "box $2 not in A's UTXO set"; return 1; }
  tx="$(wallet A /wallet/transaction/generate "{\"requests\":[{\"address\":\"$to\",\"value\":$1}],\"inputsRaw\":[\"$raw\"],\"fee\":$3}")"
  [[ "$(jq -r '.id // empty' <<< "$tx")" =~ ^[0-9a-f]{64}$ ]] || { echo "generate: $(jq -r '.detail // .reason // tojson' <<< "$tx" | cut -c1-120)"; return 1; }
  wallet R /transactions "$tx" | jq -r 'if type == "string" then . else (.detail // .reason // tojson) end'; }
# tx_outputs <node> <tx id> <nanoerg> <from height>: once the transaction is in a block of <node>'s chain, the ids of
# its outputs of exactly that value (the funding transactions' outputs are the payers' boxes; this does not depend on
# the wallet's own box listing, which reported fewer boxes than the transaction carried in earlier runs)
tx_outputs(){ local n="$1" t="$2" v="$3" k="$4" end=$((SECONDS + 300)) h hid tx
  while [[ $SECONDS -lt $end ]]; do h=$(full_height "$n")
    while [[ $k -le $h ]]; do hid=$(header_at "$n" "$k")
      if [[ -n "$hid" ]]; then tx=$(rest "$n" "/blocks/$hid/transactions" | jq -c --arg t "$t" '.transactions[] | select(.id == $t)' 2>/dev/null)
        [[ -n "$tx" ]] && { jq -r --argjson v "$v" '.outputs[] | select(.value == $v) | .boxId' <<< "$tx"; return 0; }; fi
      k=$((k + 1)); done
    sleep 5; done; return 1; }
# fund_both <count A> <nanoerg each> <count Q> <nanoerg each>: ONE payment from A with <count A> outputs to A's own
# address and <count Q> to Q's (two payments back to back would make the second spend the first's unconfirmed outputs)
fund_both(){ local reqs; reqs="$(jq -n -c --arg a "$(address A)" --arg q "$(address Q)" --argjson va "$2" --argjson ka "$1" --argjson vq "$4" --argjson kq "$3" \
    '[range($ka) | {address: $a, value: $va}] + [range($kq) | {address: $q, value: $vq}]')"
  wallet A /wallet/payment/send "$reqs" | jq -r 'if type == "string" then . else (.detail // .reason // tojson) end'; }
NP=$((INTERVALS * (LOW + VALID) + 20)); NQ=$((INTERVALS * QVALID + 10))
need=$((BOX * NP + BOXQ * NQ + 2000000000))
wait_balance A "$need" 600 >/dev/null || { echo "[relay-floor] INCONCLUSIVE: A never had $need nanoERG spendable"; rig_verdict=INCONCLUSIVE; return; }
HF=$(full_height A); fp=$(fund_both "$NP" "$BOX" "$NQ" "$BOXQ")
echo "[relay-floor] funding A's payer boxes ($NP) and Q's ($NQ) in one transaction: ${fp:0:64}"
[[ "$fp" =~ ^[0-9a-f]{64}$ ]] || { echo "[relay-floor] INCONCLUSIVE: funding rejected: ${fp:0:120}"; rig_verdict=INCONCLUSIVE; return; }
mapfile -t PB < <(tx_outputs A "$fp" "$BOX" "$HF"); mapfile -t QB < <(tx_outputs A "$fp" "$BOXQ" "$HF")
[[ ${#PB[@]} -gt 0 && ${#QB[@]} -gt 0 ]] || { echo "[relay-floor] INCONCLUSIVE: the funding transactions were not mined within 300 s (payer ${#PB[@]}, Q ${#QB[@]} outputs found)"; rig_verdict=INCONCLUSIVE; return; }
wait_balance Q $((BOXQ * NQ)) 300 >/dev/null || { echo "[relay-floor] INCONCLUSIVE: Q's wallet did not see its funding"; rig_verdict=INCONCLUSIVE; return; }
end=$((SECONDS + 180)); while [[ $SECONDS -lt $end ]]; do ha=$(full_height A); [[ -n "$ha" && "$ha" == "$(full_height S)" && "$ha" == "$(full_height R)" && "$ha" == "$(full_height Q)" ]] && break; sleep 2; done
# every payment spends one distinct confirmed box (the funding transactions' outputs), so no payment depends on
# another's unconfirmed change
echo "[relay-floor] funded; heights A=$(full_height A) S=$(full_height S) R=$(full_height R) Q=$(full_height Q); confirmed payer boxes A ${#PB[@]} Q ${#QB[@]}"
[[ ${#PB[@]} -ge $((INTERVALS * (LOW + VALID))) && ${#QB[@]} -ge $((INTERVALS * QVALID)) ]] || { echo "[relay-floor] INCONCLUSIVE: too few confirmed boxes (A ${#PB[@]}, Q ${#QB[@]})"; rig_verdict=INCONCLUSIVE; return; }
pb=0; qb=0
# the watcher: every second, the pools of S and A; first sight of each id is recorded with the node and the time
watch(){ local id now; declare -A seenS=() seenA=()
  while [[ ! -f "$RIG_LOG_DIR/watch.stop" ]]; do now=$(date +%s%3N)
    for id in $(mempool_ids S); do [[ -z "${seenS[$id]:-}" ]] && { seenS[$id]=1; printf '{"t_ms":%s,"node":"S","id":"%s"}\n' "$now" "$id" >> "$SEEN_LOG"; }; done
    for id in $(mempool_ids A); do [[ -z "${seenA[$id]:-}" ]] && { seenA[$id]=1; printf '{"t_ms":%s,"node":"A","id":"%s"}\n' "$now" "$id" >> "$SEEN_LOG"; }; done
    sleep 1; done; }
rm -f "$RIG_LOG_DIR/watch.stop"; watch & WATCH_PID=$!
H0=$(full_height A); T0=$(date +%s%3N); mark load
echo "[relay-floor] load from height $H0"
rejected=0; lowsent=0; pvsent=0; qvsent=0; hprev=$H0; rlag_total=0; rlag_max=0
for ivl in $(seq 1 "$INTERVALS"); do
  # a new block from A, then R and S holding it (a synced relay and a synced strict node), then the burst
  end=$((SECONDS + 120)); while [[ $SECONDS -lt $end ]]; do hnow=$(full_height A); [[ "${hnow:-0}" -gt "$hprev" ]] && break; sleep 1; done
  [[ "${hnow:-0}" -gt "$hprev" ]] || { echo "[relay-floor] INCONCLUSIVE: no new block within 120 s at interval $ivl"; rig_verdict=INCONCLUSIVE; touch "$RIG_LOG_DIR/watch.stop"; return; }
  hprev=$hnow; t_sync=$SECONDS; end=$((SECONDS + 60)); while [[ $SECONDS -lt $end ]] && { [[ "$(full_height R)" != "$hnow" ]] || [[ "$(full_height S)" != "$hnow" ]]; }; do sleep 1; done
  lag=$((SECONDS - t_sync)); rlag_total=$((rlag_total + lag)); (( lag > rlag_max )) && rlag_max=$lag
  t_ivl=$SECONDS; k=0
  for i in $(seq 1 "$LOW"); do
    id=$(gen_via_r "$AMT" "${PB[pb]}" "$LOW_FEE"); pb=$((pb + 1))
    if [[ "$id" =~ ^[0-9a-f]{64}$ ]]; then lowsent=$((lowsent + 1)); printf '{"t_ms":%s,"id":"%s","kind":"low","from":"P","ivl":%s}\n' "$(date +%s%3N)" "$id" "$hnow" >> "$PAY_LOG"
    else rejected=$((rejected + 1)); [[ $rejected -le 5 ]] && echo "  low $ivl/$i rejected by R: ${id:0:100}"; fi
    k=$((k + 1))
    if (( k % (LOW / VALID) == 0 )) && (( pvsent < ivl * VALID )); then
      id=$(gen_via_r "$AMT" "${PB[pb]}" "$VALID_FEE"); pb=$((pb + 1))
      if [[ "$id" =~ ^[0-9a-f]{64}$ ]]; then pvsent=$((pvsent + 1)); printf '{"t_ms":%s,"id":"%s","kind":"valid","from":"P","ivl":%s}\n' "$(date +%s%3N)" "$id" "$hnow" >> "$PAY_LOG"
      else rejected=$((rejected + 1)); echo "  valid $ivl rejected by R: ${id:0:100}"; fi
      id=$(pay_from Q S "$AMT" "${QB[qb]}" "$VALID_FEE"); qb=$((qb + 1))
      if [[ "$id" =~ ^[0-9a-f]{64}$ ]]; then qvsent=$((qvsent + 1)); printf '{"t_ms":%s,"id":"%s","kind":"valid","from":"Q","ivl":%s}\n' "$(date +%s%3N)" "$id" "$hnow" >> "$PAY_LOG"
      else rejected=$((rejected + 1)); echo "  Q valid $ivl rejected: ${id:0:100}"; fi
    fi
  done
  spent=$((SECONDS - t_ivl)); echo "[relay-floor] interval $ivl (block $hnow, R and S synced after ${lag}s): sent in ${spent}s; low $lowsent valid-via-R $pvsent Q-valid $qvsent; height A=$(full_height A) R=$(full_height R) S=$(full_height S); pools S $(mempool_size S) R $(mempool_size R) A $(mempool_size A)"
done
mark load-done; H1=$(full_height A)
echo "[relay-floor] load done at height $H1 (${rejected} rejected; sync lag per interval max ${rlag_max}s, total ${rlag_total}s); waiting ${WAIT}s"
sleep "$WAIT"; touch "$RIG_LOG_DIR/watch.stop"; wait "$WATCH_PID" 2>/dev/null
H2=$(full_height A)
: > "$RIG_LOG_DIR/blocks.jsonl"
for ((h = H0; h <= H2; h++)); do hid=$(header_at A "$h"); [[ -n "$hid" ]] || continue
  blk=$(rest A "/blocks/$hid"); ts=$(jq -r '.header.timestamp' <<< "$blk")
  printf '{"height":%s,"t_ms":%s}\n' "$h" "$ts" >> "$RIG_LOG_DIR/blocks.jsonl"
  jq -r '.blockTransactions.transactions[].id' <<< "$blk" 2>/dev/null | while read -r t; do printf '{"id":"%s","height":%s,"t_ms":%s}\n' "$t" "$h" "$ts"; done >> "$MINED_LOG"
done
SL="$RIG_LOG_DIR/node_S.log"
R_ADDR=$(rest S /peers/connected | jq -r '.[] | select(.name == "R") | .address' | head -1)
[[ -n "$R_ADDR" ]] || R_ADDR="$(rest S /peers/connected | jq -r '.[0].address')"
echo "[relay-floor] R as S sees it: ${R_ADDR:-unknown}; S peers: $(rest S /peers/connected | jq -c '[.[] | .name]')"
python3 - "$RIG_LOG_DIR" "$SL" "${R_ADDR:-none}" "$T0" "$rlag_max" "$H0" > "$RIG_LOG_DIR/summary.json" <<'PY'
import sys, json, re, datetime, statistics
d, slog, raddr, t0, rlag_max, h0 = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
raddr = raddr.replace("/", "").split(":")[0]   # S logs the relay by its IP and an ephemeral port; match the IP
pays = [json.loads(l) for l in open(f"{d}/payments.jsonl") if l.strip()]
seen = {}
for l in open(f"{d}/seen.jsonl"):
    if l.strip():
        r = json.loads(l); seen.setdefault(r["id"], {})[r["node"]] = r["t_ms"]
mined = {}
for l in open(f"{d}/mined.jsonl"):
    if l.strip():
        r = json.loads(l); mined[r["id"]] = (r["height"], r["t_ms"])
blocks = sorted([json.loads(l) for l in open(f"{d}/blocks.jsonl") if l.strip()], key=lambda b: b["height"])
def next_block_after(t):
    for b in blocks:
        if b["t_ms"] > t: return b
    return None
low = [p for p in pays if p["kind"] == "low"]; lowids = {p["id"] for p in low}
pv = [p for p in pays if p["kind"] == "valid" and p["from"] == "P"]
qv = [p for p in pays if p["kind"] == "valid" and p["from"] == "Q"]
def delays(ps):
    out = []
    for p in ps:
        s = seen.get(p["id"], {}).get("S"); nb = next_block_after(p["t_ms"]); m = mined.get(p["id"])
        if s is None: out.append((None, m is not None and (nb is None or m[1] > nb["t_ms"]), m is None))
        else: out.append(((s - p["t_ms"]) / 1000.0, nb is not None and s > nb["t_ms"], m is None))
    return out
dp, dq = delays(pv), delays(qv)
def stats(ds):
    vals = [x[0] for x in ds if x[0] is not None]
    return {"delayed_past_block": sum(1 for x in ds if x[1]), "missing": sum(1 for x in ds if x[2]),
            "delay_s_p50": round(statistics.median(vals), 2) if vals else -1, "delay_s_max": round(max(vals), 2) if vals else -1,
            "unseen_at_s": sum(1 for x in ds if x[0] is None)}
# the node logs local wall-clock time without a date; anchor on the load's start date
day = datetime.datetime.fromtimestamp(t0 / 1000).date()
def ms_of(line):
    m = re.match(r"(\d\d):(\d\d):(\d\d)\.(\d\d\d)", line)
    if not m: return None
    h, mi, s, ms = map(int, m.groups())
    return int(datetime.datetime.combine(day, datetime.time(h, mi, s, ms * 1000)).timestamp() * 1000)
decl, invs = [], []
for line in open(slog, errors="replace"):
    if "Processing mempool transaction:" in line:
        m = re.search(r"Processing mempool transaction: .*?([0-9a-f]{64})", line)
        if m and m.group(1) in lowids: decl.append({"t_ms": ms_of(line), "id": m.group(1)})
    elif "tx invs from" in line and raddr != "none" and ("remote=/" + raddr + ":") in line:
        m = re.search(r"Processing (\d+) tx invs from .*?(\d+) of them are unknown, requesting (.*)$", line.strip())
        invs.append({"t_ms": ms_of(line), "n": int(m.group(1)) if m else -1, "unknown": int(m.group(2)) if m else -1,
                     "requesting_empty": bool(m and m.group(3).strip() in ("List()", "Vector()", "[]"))})
with open(f"{d}/s_declines.jsonl", "w") as f:
    for r in decl: f.write(json.dumps(r) + "\n")
with open(f"{d}/s_invs.jsonl", "w") as f:
    for r in invs: f.write(json.dumps(r) + "\n")
# per load interval: the A block each burst followed (payments carry it); S's log events bucketed by A's block times
bounds = [(b["height"], b["t_ms"]) for b in blocks]
def bucket(t):
    if t is None: return -1
    h = h0
    for hh, bt in bounds:
        if t >= bt: h = hh
    return h
def empty(): return {"sent_low": 0, "sent_valid": 0, "declines": 0, "invs": 0, "invs_empty": 0}
per = {}
for p in pays: per.setdefault(p["ivl"], empty())["sent_low" if p["kind"] == "low" else "sent_valid"] += 1
for r in decl: per.setdefault(bucket(r["t_ms"]), empty())["declines"] += 1
for r in invs:
    e = per.setdefault(bucket(r["t_ms"]), empty()); e["invs"] += 1; e["invs_empty"] += 1 if r["requesting_empty"] else 0
load_keys = sorted(set(p["ivl"] for p in pays))
zero_inv = sum(1 for k in load_keys if per.get(k, {}).get("invs", 0) == 0)
out = {"low_sent": len(low), "low_declined_at_s": len(decl), "declines_interval_max": max([per[k]["declines"] for k in load_keys] or [0]),
       "p_valid_sent": len(pv), "p_valid_mined": sum(1 for p in pv if p["id"] in mined), "q_valid_sent": len(qv), "q_valid_mined": sum(1 for p in qv if p["id"] in mined),
       "r_invs_total": len(invs), "r_invs_intervals_zero": zero_inv, "load_intervals": len(load_keys), "blocks_in_load": len([b for b in blocks if b["t_ms"] >= t0]), "r_sync_lag_s_max": rlag_max,
       "per_interval": {str(k): per.get(k) for k in load_keys}}
sp, sq = stats(dp), stats(dq)
out.update({"p_" + k: v for k, v in sp.items()}); out.update({"q_" + k: v for k, v in sq.items()})
print(json.dumps(out))
PY
S=$(cat "$RIG_LOG_DIR/summary.json")
echo "[relay-floor] per interval (A block: sent low+valid / declines at S / inv batches from R (of them requesting nothing)): $(jq -c '.per_interval | with_entries(.value |= "\(.sent_low)+\(.sent_valid)/\(.declines)/\(.invs)(\(.invs_empty))")' <<< "$S")"
echo "[relay-floor] valid via R: sent $(jq .p_valid_sent <<< "$S") mined $(jq .p_valid_mined <<< "$S") delayed-past-block $(jq .p_delayed_past_block <<< "$S") missing $(jq .p_missing <<< "$S") delay-to-S p50 $(jq .p_delay_s_p50 <<< "$S")s max $(jq .p_delay_s_max <<< "$S")s unseen-at-S $(jq .p_unseen_at_s <<< "$S")"
echo "[relay-floor] Q valid: sent $(jq .q_valid_sent <<< "$S") mined $(jq .q_valid_mined <<< "$S") delayed-past-block $(jq .q_delayed_past_block <<< "$S") missing $(jq .q_missing <<< "$S") delay-to-S p50 $(jq .q_delay_s_p50 <<< "$S")s max $(jq .q_delay_s_max <<< "$S")s unseen-at-S $(jq .q_unseen_at_s <<< "$S")"
echo "[relay-floor] low: sent $(jq .low_sent <<< "$S") declined at S $(jq .low_declined_at_s <<< "$S") (max per interval $(jq .declines_interval_max <<< "$S")); R inv batches at S $(jq .r_invs_total <<< "$S"), load intervals with none $(jq .r_invs_intervals_zero <<< "$S")/$(jq .load_intervals <<< "$S"); sync lag max $(jq .r_sync_lag_s_max <<< "$S")s"
echo "[relay-floor] same_chain(A,S): $(same_chain A S); pools at end R $(mempool_size R) S $(mempool_size S) A $(mempool_size A)"
# activity floor: at least 50 declines at S in at least 4 load intervals, and the sends happened
floor_ok=$(jq '[.per_interval[] | select(.declines >= 50)] | length >= 4' <<< "$S")
sends_ok=$(jq '.p_valid_sent >= 40 and .q_valid_sent >= 40' <<< "$S")
res=FAIL
if [[ "$floor_ok" == true && "$sends_ok" == true ]]; then [[ "$(jq '.p_missing == 0 and .q_missing == 0' <<< "$S")" == true ]] && res=PASS; fi
rig_verdict=$res
echo "RELAY-FLOOR $(jq -r 'del(.per_interval) | to_entries | map("\(.key)=\(.value)") | join(" ")' <<< "$S") verdict=$res"
if [[ -n "${DIFFRUN_ROLE:-}" ]]; then
  if [[ "$floor_ok" != true || "$sends_ok" != true ]]; then echo "[relay-floor] INCONCLUSIVE: activity floor missed (declines>=50 in 4 intervals: $floor_ok; sends: $sends_ok)"; rig_verdict=INCONCLUSIVE; return; fi
  echo "RESULT_JSON $(jq -cn --arg A "$VA" --arg S "$VS" --arg R "$VR" --argjson m "$(jq 'del(.per_interval)' <<< "$S")" \
    '{schema_version: 1, scenario: "relay-floor", versions: {A: $A, S: $S, R: $R}, metrics: ($m | with_entries(select(.value | type == "number")))}')"
fi
