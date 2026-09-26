#!/usr/bin/env bash
# run.sh: run one scenario against a base jar and a candidate jar, N times each (alternating), and write a verdict.
#
#   bash diffrun/run.sh <manifest.json> --base <jar> --candidate <jar> [-n N] [--out DIR]
#
# Each jar needs a sidecar <jar>.json (from build.sh or register.sh). See diffrun/README.md for the scenario
# contract, the manifest format and the verdict rules.
#
# Exit codes: 0 verdict written (whatever the verdict); 2 runner ERROR (no verdict.json); 4 REFUSED before
# launching (tier guard or input lint); 5 REFUSED to write outputs (output lint hit; no verdict.json).
# The lint is an optional deny-list (DIFFRUN_TERMS); without one it is skipped.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/lib"
SCEN="$(realpath -e "$HERE/scenarios")"
CMDLINE=("$0" "$@")

err(){ echo "diffrun: ERROR: $*" >&2; exit 2; }
refuse(){ echo "diffrun: REFUSED: $1" >&2; exit "${2:-4}"; }
jql(){ jq -L "$LIB" "$@"; }
usage(){ echo "usage: $0 <manifest.json> --base <jar> --candidate <jar> [-n N] [--out DIR]" >&2; exit 2; }

# ---------------- arguments ----------------
[[ $# -ge 1 ]] || usage
MAN_ARG="$1"; shift
BASE=""; CAND=""; N_OVR=""; OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) BASE="${2:-}"; shift 2 ;;
    --candidate) CAND="${2:-}"; shift 2 ;;
    -n) N_OVR="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$BASE" && -n "$CAND" ]] || usage
[[ -z "$N_OVR" || "$N_OVR" =~ ^[1-9][0-9]*$ ]] || err "-n must be a positive integer"

# ---------------- manifest: validated before anything runs; parsed, never eval'd ----------------
MAN="$(realpath -e "$MAN_ARG" 2>/dev/null)" || err "manifest not found: $MAN_ARG"
jq -e 'type == "object"' "$MAN" >/dev/null 2>&1 || err "manifest is not a JSON object: $MAN"
errs="$(jql -r 'include "diffrun"; validate_manifest[]' "$MAN")" || err "manifest validation failed to run: $MAN"
if [[ -n "$errs" ]]; then
  while IFS= read -r e; do echo "diffrun: manifest: $e" >&2; done <<< "$errs"
  err "manifest rejected: $MAN"
fi
NAME="$(jq -r .name "$MAN")"; TIER="$(jq -r .tier "$MAN")"
SCRIPT="$(realpath -e "$SCEN/$(jq -r .script "$MAN")" 2>/dev/null)" || err "manifest: script does not resolve: $(jq -r .script "$MAN")"
[[ "$SCRIPT" == "$SCEN"/* && -f "$SCRIPT" ]] || err "manifest: script resolves outside diffrun/scenarios/: $SCRIPT"
# Optional precheck (a floor gate): a script under diffrun/scenarios/ run before each scenario run with the same jar,
# env and a WORKDIR of its own. If it exits nonzero, that run is INCONCLUSIVE (setup) and the scenario is not run.
PRECHECK=""; PRE_TIMEOUT=0; PRE_NAME=""
if [[ "$(jq -r 'has("precheck")' "$MAN")" == true ]]; then
  PRE_NAME="$(jq -r .precheck "$MAN")"
  PRECHECK="$(realpath -e "$SCEN/$PRE_NAME" 2>/dev/null)" || err "manifest: precheck does not resolve: $PRE_NAME"
  [[ "$PRECHECK" == "$SCEN"/* && -f "$PRECHECK" ]] || err "manifest: precheck resolves outside diffrun/scenarios/: $PRECHECK"
  PRE_TIMEOUT="$(jq -r '.precheck_timeout_seconds // 300' "$MAN")"
fi
N_MAN="$(jq -r .n "$MAN")"; N="${N_OVR:-$N_MAN}"
# Sequential rule (max_n + stop_when): N is the minimum number of pairs; after each pair from N on, stop once
# every stop_when predicate holds over the valid runs so far, or at max_n. Without it, exactly N pairs run.
SEQ="$(jq -r 'has("stop_when")' "$MAN")"
MAXN="$(jq -r --argjson n "$N" '[.max_n // $n, $n] | max' "$MAN")"
TIMEOUT="$(jq -r '.timeout_seconds // 900' "$MAN")"
mapfile -t ENVKV < <(jq -r '(.env // {}) | to_entries[] | "\(.key)=\(.value)"' "$MAN")

# ---------------- tier guard and input lint ----------------
if [[ "$TIER" == private && ( -n "${CI:-}" || -n "${GITHUB_ACTIONS:-}" ) ]]; then
  refuse "tier: private manifest ($NAME) refused under CI/GITHUB_ACTIONS"
fi
if [[ "$TIER" == public ]]; then
  bash "$HERE/lint.sh" "$MAN" "$SCRIPT" ${PRECHECK:+"$PRECHECK"}; rc=$?
  [[ $rc == 0 ]] || { [[ $rc == 1 ]] && refuse "input lint hit on a public-tier manifest or its script (see above)"; err "lint could not run"; }
fi

# ---------------- jars: sidecar and sha256 checked before any launch ----------------
declare -A JAR SHA EXPV
JAR[base]="$BASE"; JAR[candidate]="$CAND"
for role in base candidate; do
  j="${JAR[$role]}"; sc="$j.json"
  [[ -f "$j" ]] || err "$role jar not found: $j"
  [[ -f "$sc" ]] || err "$role sidecar not found: $sc (use build.sh or register.sh)"
  jq -e '.sidecar_schema_version == 1 and (.jar_sha256 | type == "string") and (.expected_app_version | type == "string" and length > 0)' \
    "$sc" >/dev/null 2>&1 || err "$role sidecar malformed: $sc"
  actual="$(sha256sum "$j" | cut -d' ' -f1)"; want="$(jq -r .jar_sha256 "$sc")"
  [[ "$actual" == "$want" ]] || err "$role jar sha256 $actual does not match its sidecar ($want): $j"
  SHA[$role]="$actual"; EXPV[$role]="$(jq -r .expected_app_version "$sc")"
done

# ---------------- output directory ----------------
if [[ -z "$OUT" ]]; then OUT="$(mktemp -d "${TMPDIR:-/tmp}/diffrun.$NAME.XXXXXX")" || err "cannot create an output dir"
else
  [[ ! -e "$OUT" || -z "$(ls -A "$OUT" 2>/dev/null)" ]] || err "--out exists and is not empty: $OUT"
  mkdir -p "$OUT" || err "cannot create --out: $OUT"
fi
OUT="$(realpath -e "$OUT")"; mkdir -p "$OUT/runs" || err "cannot create $OUT/runs"
cp "$MAN" "$OUT/manifest.json" && cp "$BASE.json" "$OUT/base.sidecar.json" && cp "$CAND.json" "$OUT/candidate.sidecar.json" \
  || err "cannot snapshot the manifest and sidecars"
TERMS="${DIFFRUN_TERMS:-}"
# run_meta.json is private: it holds local paths and is never uploaded or linted.
jq -n --arg rev "$(git -C "$HERE" rev-parse HEAD 2>/dev/null || echo unknown)" \
      --arg dirty "$(git -C "$HERE" status --porcelain -- . 2>/dev/null | head -c 2000)" \
      --arg terms_sha "$(sha256sum "$TERMS" 2>/dev/null | cut -d' ' -f1)" \
      --arg man "$MAN" --arg script "$SCRIPT" --arg pre "$PRECHECK" --arg base "$BASE" --arg cand "$CAND" \
      --argjson n "$N" --argjson n_man "$N_MAN" --arg started "$(date -u +%FT%TZ)" \
      --argjson cmd "$(printf '%s\n' "${CMDLINE[@]}" | jq -R . | jq -s .)" \
      '{diffrun_git_rev: $rev, diffrun_dirty: $dirty, command_line: $cmd, term_list_sha256: $terms_sha,
        manifest_path: $man, script_path: $script, precheck_path: (if $pre == "" then null else $pre end),
        base_jar: $base, candidate_jar: $cand, n_min: $n, n_manifest: $n_man,
        started: $started}' > "$OUT/run_meta.json" || err "cannot write run_meta.json"
# the A/A rate is a per-host number, so verdict.json records the host's shape; not its name (verdict.json is shared)
HOSTJ="$(jq -cn --arg k "$(uname -r)" --arg c "$(nproc)" --arg m "$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)" '{kernel:$k, cpus:($c|tonumber), mem_mb:($m|tonumber? // null)}')"
MIXED="$(jq -r '.mixed_jars // false' "$MAN")"   # a scenario that puts both jars on one network reports both versions
echo "diffrun: $NAME ($TIER) n=$N$([[ $SEQ == true ]] && echo " (sequential, cap $MAXN)") timeout=${TIMEOUT}s${PRECHECK:+ precheck=$PRE_NAME (${PRE_TIMEOUT}s)} out=$OUT" >&2

# ---------------- one run ----------------
CUR_TPID=""
on_signal(){ [[ -n "$CUR_TPID" ]] && kill -TERM "$CUR_TPID" 2>/dev/null; echo "diffrun: ERROR: interrupted; no verdict written" >&2; exit 2; }
trap on_signal INT TERM HUP

# Processes that belong to a run: in the timeout's process group, or with the run's WORKDIR in their command line.
# The WORKDIR is passed to awk through the environment, so awk's own command line does not match itself.
leftovers(){ local wd="$1" pg="$2"
  ps -eo pid=,pgid=,args= | W="$wd" G="$pg" awk -v me="$$" '$1 != me && ($2 == ENVIRON["G"] || index($0, ENVIRON["W"])) {print}'; }

# launch <timeout> <workdir> <script> <jar> <stdout> <stderr>: run the script under `timeout` in its own process group
# (TERM, then KILL of the whole group 30 s later), with WORKDIR and the manifest env. Sets RC, T0, T1, TIMED_OUT, TPID.
launch(){ local to="$1" wd="$2" script="$3" j="$4" so="$5" se="$6"
  T0=$(date +%s)
  ( cd "$wd" && exec timeout -s TERM -k 30 "$to" env -u FC_INNER -u RIG_INNER WORKDIR="$wd" DIFFRUN_ROLE="$CUR_ROLE" DIFFRUN_BASE_JAR="${JAR[base]}" DIFFRUN_CANDIDATE_JAR="${JAR[candidate]}" "${ENVKV[@]}" bash "$script" "$j" ) \
    > "$so" 2> "$se" &
  CUR_TPID=$!
  wait "$CUR_TPID"; RC=$?
  T1=$(date +%s); TPID="$CUR_TPID"; CUR_TPID=""
  TIMED_OUT=0; [[ $RC == 124 || ( $RC == 137 && $((T1 - T0)) -ge $to ) ]] && TIMED_OUT=1
}
# settle <workdir> <pgid> <run dir> <label>: a surviving process keeps its network namespace alive, so any process
# left after 20 s is killed and stops the suite (runner ERROR, no verdict).
settle(){ local wd="$1" pg="$2" d="$3" label="$4" end=$((SECONDS + ${DIFFRUN_SETTLE_SECONDS:-60})) left
  while left="$(leftovers "$wd" "$pg")"; [[ -n "$left" && $SECONDS -lt $end ]]; do sleep 1; done
  [[ -z "$left" ]] && return 0
  echo "$left" > "$d/leftover_processes.txt"
  echo "diffrun: leftover processes after $label:" >&2; echo "$left" >&2
  awk '{print $1}' <<< "$left" | xargs -r kill -KILL 2>/dev/null
  err "leftover processes after $label (killed; listed in $d/leftover_processes.txt); suite stopped, no verdict"
}

run_one(){ local role="$1" i="$2" j="${JAR[$1]}" d wd t0 t1 rc timed_out=0 nrj cls reason detail="" rj; CUR_ROLE="$role"
  local pre=null pre_rc=null pre_elapsed=null pd
  d="$OUT/runs/$role-$i"; wd="$d/work"; mkdir -p "$wd" || err "cannot create WORKDIR $wd"
  echo "diffrun: [$role $i/$MAXN] start" >&2
  local start; start="$(date -u +%FT%TZ)"

  # precheck: same jar and env, its own WORKDIR; a failure makes the run INCONCLUSIVE (setup) without running the scenario
  if [[ -n "$PRECHECK" ]]; then
    pd="$d/precheck"; mkdir -p "$pd" || err "cannot create precheck WORKDIR $pd"
    launch "$PRE_TIMEOUT" "$pd" "$PRECHECK" "$j" "$d/precheck.stdout.txt" "$d/precheck.stderr.txt"
    pre_rc=$RC; pre_elapsed=$((T1 - T0))
    settle "$pd" "$TPID" "$d" "the precheck of $role-$i"
    if [[ $RC == 0 ]]; then pre=pass; rm -rf "$pd"; else pre=fail; fi
    echo "diffrun: [$role $i/$MAXN] precheck $pre in ${pre_elapsed}s" >&2
  fi

  if [[ $pre == fail ]]; then
    rc=$pre_rc; timed_out=$TIMED_OUT; t0=$T0; t1=$T1
    cls=INCONCLUSIVE; reason=setup
    detail="precheck failed: $(grep -m1 -oE 'INCONCLUSIVE: .*' "$d/precheck.stdout.txt" || echo "exit=$pre_rc timed_out=$timed_out")"
    : > "$d/stdout.txt"; : > "$d/stderr.txt"   # the scenario did not run
  else
    launch "$TIMEOUT" "$wd" "$SCRIPT" "$j" "$d/stdout.txt" "$d/stderr.txt"
    rc=$RC; timed_out=$TIMED_OUT; t0=$T0; t1=$T1
    settle "$wd" "$TPID" "$d" "run $role-$i"

    # classify
    other=candidate; [[ "$role" == candidate ]] && other=base
    nrj="$(grep -c '^RESULT_JSON ' "$d/stdout.txt")"
    if [[ "$nrj" == 0 ]]; then
      cls=INCONCLUSIVE
      if [[ $timed_out == 0 && $rc == 3 ]] && detail="$(grep -m1 -oE 'INCONCLUSIVE: .*' "$d/stdout.txt")"; then reason=setup
      else reason=no-result; detail="exit=$rc timed_out=$timed_out"; fi
    elif [[ "$nrj" != 1 ]]; then cls=INCONCLUSIVE; reason=malformed; detail="$nrj RESULT_JSON lines"
    else
      rj="$(sed -n 's/^RESULT_JSON //p' "$d/stdout.txt")"
      if ! verrs="$(jq -r -L "$LIB" --slurpfile m "$MAN" 'include "diffrun"; validate_result($m[0])[]' <<< "$rj" 2>&1)"; then
        cls=INCONCLUSIVE; reason=malformed; detail="invalid JSON"
      elif [[ -n "$verrs" ]]; then cls=INCONCLUSIVE; reason=malformed; detail="$(tr '\n' ';' <<< "$verrs")"
      else
        jq -c . <<< "$rj" > "$d/result.json"
        if [[ $rc != 0 ]]; then cls=INCONCLUSIVE; reason=post-result-exit; detail="exit=$rc timed_out=$timed_out"
        elif [[ "$MIXED" == true ]] && jq -e --arg v "${EXPV[$role]}" --arg o "${EXPV[$other]}" '.versions | (any(.[]; . == $v)) and (any(.[]; . == $o))' "$d/result.json" >/dev/null; then cls=VALID; reason=""
        elif [[ "$MIXED" != true ]] && jq -e --arg v "${EXPV[$role]}" '.versions | all(.[]; . == $v)' "$d/result.json" >/dev/null; then cls=VALID; reason=""
        else cls=VOID; reason=version-mismatch; detail="expected ${EXPV[$role]}$([[ "$MIXED" == true ]] && echo " and ${EXPV[$other]} (mixed_jars)")"; fi
      fi
    fi
  fi

  # named cause: a code from a fixed vocabulary, never free text (verdict.json carries no free text). Preference:
  # a hook's own cause ("[rig] CAUSE (hook) X"), a scenario's die code ("CAUSE X"), then the rig classifier's
  # ("[rig] CAUSE X: evidence", diag/diagnose.py). The evidence stays in metadata.json.
  cause="$( { grep -m1 -oE '^\[rig\] CAUSE \(hook\) [A-Z_]+' "$d/stdout.txt"; grep -m1 -oE '^CAUSE [A-Z_]+' "$d/stdout.txt"; \
             grep -m1 -oE '^\[rig\] CAUSE [A-Z_]+' "$d/stdout.txt"; } 2>/dev/null | head -1 | grep -oE '[A-Z_]+$')"
  [[ "$cause" =~ ^[A-Z_]{3,40}$ ]] || cause=""
  cause_ev="$(grep -m1 -oE '^\[rig\] CAUSE [A-Z_]+: .*' "$d/stdout.txt" 2>/dev/null | cut -c1-600)"
  jq -n --arg role "$role" --argjson index "$i" --arg start "$start" --arg end "$(date -u +%FT%TZ)" \
        --argjson elapsed "$((t1 - t0))" --argjson rc "$rc" --argjson timed_out "$timed_out" \
        --arg jar_sha "${SHA[$role]}" --arg script_sha "$(sha256sum "$SCRIPT" | cut -d' ' -f1)" \
        --arg pre_sha "$([[ -n "$PRECHECK" ]] && sha256sum "$PRECHECK" | cut -d' ' -f1)" \
        --argjson pre "$(jq -n --arg o "$pre" --argjson rc "$pre_rc" --argjson el "$pre_elapsed" \
                         'if $o == "null" then null else {outcome: $o, exit_code: $rc, elapsed_s: $el} end')" \
        --arg cls "$cls" --arg reason "$reason" --arg detail "$detail" --arg cause "$cause" --arg cause_ev "$cause_ev" \
        '{role: $role, index: $index, start: $start, end: $end, elapsed_s: $elapsed,
          exit_code: $rc, signal: (if $rc > 128 and $rc < 160 then $rc - 128 else null end), timed_out: ($timed_out == 1),
          jar_sha256: $jar_sha, script_sha256: $script_sha, precheck_sha256: (if $pre_sha == "" then null else $pre_sha end),
          precheck: $pre, class: $cls, reason: $reason, detail: $detail,
          cause: (if $cause == "" then null else $cause end), cause_evidence: (if $cause_ev == "" then null else $cause_ev end)}' > "$d/metadata.json"
  # the runs list that feeds verdict.json: no paths, no free text
  jq -cn --arg role "$role" --argjson index "$i" --arg cls "$cls" --arg reason "$reason" --arg pre "$pre" --arg cause "$cause" \
     --slurpfile r <(cat "$d/result.json" 2>/dev/null || true) \
     '{role: $role, index: $index, class: $cls, reason: (if $reason == "" then null else $reason end),
       cause: (if $cause == "" then null else $cause end),
       precheck: (if $pre == "null" then null else $pre end),
       versions: ($r[0].versions // null), metrics: ($r[0].metrics // null)}' >> "$OUT/runs.jsonl"
  # A VALID run's work dir (node data) is removed, but its node logs are kept, gzipped: logab.sh compares the base
  # and candidate runs' logs after the verdict, and a VALID run whose metrics fail the expectation is the one someone
  # has to diagnose. DIFFRUN_KEEP_WORK=1 keeps everything.
  if [[ $cls == VALID && "${DIFFRUN_KEEP_WORK:-0}" != 1 ]]; then
    mkdir -p "$d/logs"; ( cd "$wd" && find . -name '*.log' -size -50M -exec cp --parents -t "$d/logs" {} + ) 2>/dev/null
    find "$d/logs" -name '*.log' -exec gzip -f {} + 2>/dev/null
    rm -rf "$wd"
  fi
  echo "diffrun: [$role $i/$MAXN] $cls${reason:+ ($reason)} in $((t1 - t0))s" >&2
}

N_RUN=0; STOPPED_BY=fixed
for ((i = 1; i <= MAXN; i++)); do
  run_one base "$i"; run_one candidate "$i"; N_RUN=$i
  if [[ $SEQ != true ]]; then [[ $i -ge $N ]] && break; continue; fi
  if [[ $i -ge $N ]] && jql -e -n --slurpfile m "$MAN" --slurpfile runs "$OUT/runs.jsonl" \
       'include "diffrun"; should_stop($m[0]; $runs)' >/dev/null; then
    STOPPED_BY=rule; echo "diffrun: stop_when holds after $i pairs" >&2; break
  fi
  [[ $i -ge $MAXN ]] && { STOPPED_BY=cap; echo "diffrun: cap of $MAXN pairs reached; stop_when never held" >&2; }
done
MINV="$(jq -r --argjson n "$N_RUN" '.min_valid_runs // (((2 * $n) + 2) / 3 | floor)' "$MAN")"   # ceil(2n/3) of pairs run

# ---------------- verdict ----------------
PEND="$OUT/.pending"; mkdir -p "$PEND" || err "cannot create $PEND"
jql -n --slurpfile m "$MAN" --slurpfile runs "$OUT/runs.jsonl" --argjson minv "$MINV" --argjson n "$N_RUN" --argjson nmin "$N" --argjson maxn "$MAXN" --arg stopped "$STOPPED_BY" \
    --arg bsha "${SHA[base]}" --arg csha "${SHA[candidate]}" --arg bv "${EXPV[base]}" --arg cv "${EXPV[candidate]}" \
    --arg ssha "$(sha256sum "$SCRIPT" | cut -d' ' -f1)" --arg psha "$([[ -n "$PRECHECK" ]] && sha256sum "$PRECHECK" | cut -d' ' -f1)" \
    --arg rev "$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)" --argjson host "$HOSTJ" \
    --arg fbv "$(tr -d '[:space:]' < "$HERE/../VERSION" 2>/dev/null || echo unknown)" '
  include "diffrun";
  $m[0] as $m
  | { base: role_summary($m; "base"; $runs), candidate: role_summary($m; "candidate"; $runs) } as $pr
  | { verdict_schema_version: 1, scenario: $m.name, tier: $m.tier, verdict: decide($pr; $minv),
      precedence: ["DEGENERATE", "AGAINST", "NULL", "SUPPORTS"],
      same_jar: ($bsha == $csha),
      provenance: { scenario_script_sha256: $ssha, precheck_sha256: (if $psha == "" then null else $psha end),
                    env: ($m.env // {}), peeryard_version: $fbv, runner_rev: $rev, host: $host },
      precheck: (if $m | has("precheck") then { script: $m.precheck, failed: ([$runs[] | select(.precheck == "fail")] | length) } else null end),
      n_manifest: $m.n, n_min: $nmin, n_run: $n, n_overridden: ($nmin != $m.n), min_valid_runs: $minv,
      sequential: (if $m | has("stop_when") then { max_n: $m.max_n, max_n_effective: $maxn, stop_when: $m.stop_when, stopped_by: $stopped } else null end),
      expect: $m.expect,
      jars: { base: { jar_sha256: $bsha, expected_app_version: $bv }, candidate: { jar_sha256: $csha, expected_app_version: $cv } },
      per_role: $pr, runs: $runs }' > "$PEND/verdict.json" || err "verdict evaluation failed"

{ jql -r 'include "diffrun";
         "scenario \(.scenario) (\(.tier))   verdict: \(.verdict)   [\({SUPPORTS: (if .expect.base == .expect.candidate then "both roles met the same expectation: an agreement scenario, not a before/after difference" else "the base showed the effect and the candidate did not" end), AGAINST: "the candidate failed its predicate", NULL: "the effect was not reproduced on the base", DEGENERATE: "too few valid runs"}[.verdict] // "")]\(if .same_jar then "   [A/A control: the same jar in both roles; not evidence about a change]" else "" end)\(if .n_overridden and .verdict == "SUPPORTS" then "   [n overridden: not citable]" else "" end)",
         "n=\(.n_run) (manifest \(.n_manifest)\(if .n_overridden then ", OVERRIDDEN" else "" end))   min_valid_runs=\(.min_valid_runs)\(if .sequential then "   sequential: min \(.n_min), cap \(.sequential.max_n_effective)\(if .sequential.max_n_effective != .sequential.max_n then " (manifest \(.sequential.max_n), raised by -n)" else "" end), stopped by \(.sequential.stopped_by)" else "" end)\(if .precheck then "   precheck: \(.precheck.script), failed \(.precheck.failed)" else "" end)",
         "",
         "\("role" | pad(10)) \("valid" | pad(6)) \("void" | pad(5)) \("inconcl" | pad(8)) \("pass" | pad(6)) expect",
         (["base", "candidate"][] as $r | .per_role[$r] as $p
           | "\($r | pad(10)) \($p.valid | pad(6)) \($p.void | pad(5)) \($p.inconclusive | pad(8)) \($p.pass | pad(6)) \(.expect[$r] | tojson)"),
         "",
         "\("run" | pad(14)) \("class" | pad(32)) \("cause" | pad(28)) metrics",
         (.runs[] | "\("\(.role)-\(.index)" | pad(14)) \(.class + (if .reason then " (" + .reason + (if .precheck == "fail" then ": precheck" else "" end) + ")" else "" end) | pad(32)) \((.cause // "-") | pad(28)) \(.metrics // {} | tojson)")' \
    "$PEND/verdict.json"; } > "$PEND/table.txt" || err "table rendering failed"

# output lint: the leak path. Nothing is written if either file carries a listed term.
bash "$HERE/lint.sh" "$PEND/verdict.json" "$PEND/table.txt"; rc=$?
if [[ $rc != 0 ]]; then
  rm -rf "$PEND"
  [[ $rc == 1 ]] && refuse "output lint hit; verdict.json and table.txt NOT written" 5
  err "output lint could not run; verdict.json and table.txt NOT written"
fi
mv "$PEND/verdict.json" "$PEND/table.txt" "$OUT/" && rmdir "$PEND" || err "cannot move outputs into $OUT"
cat "$OUT/table.txt"
echo "diffrun: verdict written: $OUT/verdict.json" >&2
# the node logs of the base and candidate runs, compared (does not change the verdict; DIFFRUN_LOGAB=0 skips it)
[[ "${DIFFRUN_LOGAB:-1}" == 1 ]] && { bash "$HERE/logab.sh" "$OUT" || echo "diffrun: log comparison failed (exit $?)" >&2; }
