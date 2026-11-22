#!/usr/bin/env bash
# Evidence for ergoplatform/ergo pull request #2937 "Validate configured token whitelist entries when settings are read
# (#2935)", head a26b13b798ef672aada809e20f1c34accb1c161a, merge base 46d0beaa33562f099ff3579036238e78d314ed99 (v6.0.11).
# Issue #2935: an entry of ergo.wallet.tokensWhitelist or ergo.node.storageRentTokenWhitelist that is not a 64-character
# lower-case hex token id never matches a token id, so the token it was meant to protect is burned; the pull request
# checks the entries when the settings are read.
# Two node jars are built with peeryard's diffrun/build.sh: the base (the merge base) and the candidate (the merge base
# plus the pull request's production paths only). Then, on JDK 8:
# 1. WhitelistAB.java runs once per jar, with that jar on the class path, and reads the same 35 settings inputs with the
#    jar's ErgoSettingsReader.fromConfig, laid over the jar's own application.conf (as ErgoSettingsSpecification does):
#    the shipped defaults, valid, repeated, malformed (the issue's "example", empty, upper case, two capitals, 63 and 65
#    characters, a non-hex letter, a leading space, a 0x prefix, a HOCON number, a mixed list) entries of each key, both
#    keys bad at once, a string instead of a list, and blacklistedTransactions = ["example"] (out of the PR's scope).
#    The base jar runs twice (the two runs must print the same lines, or the run is void).
# 2. Five node starts with `java -jar <jar> --devnet -c <conf>` (no peers, a private network magic, REST and P2P on
#    127.0.0.1, mining off): base and candidate with both whitelists valid; base with "example" in both; candidate with
#    "example" in the wallet whitelist; candidate with "example" in the storage-rent whitelist. A start counts as up when
#    GET /info answers 200 and, 10 s later, the process still runs and answers again; a stop is the process exiting by
#    itself, with its exit status and its "Failed to start" line.
#
# Claim: (1) for every valid input the two jars print the same line, a settings read; for every malformed entry of either
# key the base reads the settings with the entry as given, and the candidate refuses them with exactly
# "requirement failed: <key> entries must be 64 lower-case hex characters (0-9a-f); invalid value(s): <each distinct bad
# value, quoted, in list order>", thrown from ErgoSettings.validateTokenWhitelist; with both keys bad the candidate names
# the storage-rent key (it is read first); the string-instead-of-a-list and blacklist cases print the same line on both.
# (2) both jars come up with the valid whitelists; the base comes up with "example" in both; the candidate exits by itself
# with status 1 on each bad key, logging "Failed to start Ergo node: requirement failed: <key> entries must be ...
# 'example'", and its REST API never answers.
# What counts against it: any other line, status or message.
# The last line is "VERDICT: as claimed" (exit 0) or "VERDICT: NOT as claimed" (exit 1); exit 2 is a setup failure.
#
# Needs: git, sbt, curl, sha256sum, JDK 8 (JAVA_HOME_8_X64 on a GitHub-hosted runner, else JDK8_HOME), network access to
# github.com and to sbt's repositories, free TCP ports 19052-19061 on 127.0.0.1.
# Touches: only WORKDIR (default: a new temporary directory, printed at the start and kept), apart from sbt's and
# coursier's own caches and sbt's socket directory (XDG_RUNTIME_DIR, default /tmp/sr-<uid>); each node runs with its
# working directory, data directory and java.io.tmpdir inside WORKDIR.
# Stop: Ctrl-C; a node started by the script is killed by its pid on exit.
# Quick mode: none. Two jar builds (cache hits when DIFFRUN_CACHE holds them), three harness runs of a few seconds,
# five node starts of up to three minutes each (an up start is kept 10 s after its first answer).
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; py="$(cd "$here/../.." && pwd)"
WORKDIR="${WORKDIR:-$(mktemp -d)}"; mkdir -p "$WORKDIR"; WORKDIR="$(cd "$WORKDIR" && pwd)"; echo "WORKDIR=$WORKDIR"
for t in git sbt curl sha256sum; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 2; }; done
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/sr-$(id -u)}"; mkdir -p "$XDG_RUNTIME_DIR"

HEAD=a26b13b798ef672aada809e20f1c34accb1c161a; MB=46d0beaa33562f099ff3579036238e78d314ed99
PRODDIRS=(src/main ergo-core/src/main ergo-wallet/src/main avldb/src/main)
J8="${JAVA_HOME_8_X64:-${JDK8_HOME:-}}"
[[ -n $J8 && -x $J8/bin/java ]] || { echo "no JDK 8 (set JDK8_HOME)" >&2; exit 2; }
echo "JDK 8: $J8 ($("$J8/bin/java" -version 2>&1 | head -1))"
echo "CPU: $(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1); $(uname -m)"

R="$WORKDIR/ergo"
[[ -d $R/.git ]] || git clone -q --filter=blob:none https://github.com/ergoplatform/ergo.git "$R" || exit 2
git -C "$R" fetch -q origin "refs/pull/2937/head:pr-2937" || exit 2
echo "PR #2937 head now: $(git -C "$R" rev-parse pr-2937); tested: $HEAD"
for s in "$HEAD" "$MB"; do git -C "$R" cat-file -e "$s^{commit}" 2>/dev/null || git -C "$R" fetch -q origin "$s" || exit 2; done
[[ "$(git -C "$R" merge-base "$MB" "$HEAD")" == "$MB" ]] || { echo "$MB is not an ancestor of $HEAD" >&2; exit 2; }
echo "production change: $(git -C "$R" diff --stat "$MB" "$HEAD" -- "${PRODDIRS[@]}" | tail -1)"
git -C "$R" branch -f pr2937-tested "$HEAD" >/dev/null

export DIFFRUN_ERGO_CLONE="$R" DIFFRUN_CACHE="${DIFFRUN_CACHE:-$WORKDIR/builds}" JAVA8_HOME="$J8" DIFFRUN_NO_LOCK=1
declare -A JAR
JAR[base]="$(bash "$py/diffrun/build.sh" "$MB")" || { echo "base build failed" >&2; exit 2; }
JAR[cand]="$(bash "$py/diffrun/build.sh" "$MB" "$MB...pr2937-tested" -- "${PRODDIRS[@]}")" || { echo "candidate build failed" >&2; exit 2; }
sha256sum "${JAR[base]}" "${JAR[cand]}" "$here/WhitelistAB.java" "$here/run.sh"
bad=()

# 1. the settings reads
SIGUSD=03faf2cb329f2e90d6d23b58d91bbb6c046aa143261cc21f52fbe2824bfcbf04
ID2=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
run_ab() {  # $1 = arm, $2 = jar, $3 = output
  local out="$WORKDIR/classes-$1"; rm -rf "$out"; mkdir -p "$out"
  "$J8/bin/javac" -nowarn -cp "$2" -d "$out" "$here/WhitelistAB.java" || exit 2
  ( cd "$WORKDIR" && "$J8/bin/java" -cp "$out:$2" WhitelistAB ) > "$3.full" 2>&1 || { echo "harness failed on $1:"; tail -20 "$3.full"; exit 2; }
  grep -E '^(JAR|CASE|CASES) ' "$3.full" > "$3"
}
run_ab base "${JAR[base]}" "$WORKDIR/ab-base.txt"
run_ab base-again "${JAR[base]}" "$WORKDIR/ab-base-again.txt"
run_ab cand "${JAR[cand]}" "$WORKDIR/ab-cand.txt"
for a in base cand; do echo "== settings reads, $a jar:"; sed 's/^/   | /' "$WORKDIR/ab-$a.txt"; done
cmp -s "$WORKDIR/ab-base.txt" "$WORKDIR/ab-base-again.txt" || { echo "VOID: two runs of the base jar printed different lines"; exit 2; }
line() { sed -n "s/^CASE $2 //p" "$WORKDIR/ab-$1.txt"; }
rej() {  # $1 = key, $2 = the quoted values
  echo "rejected IllegalArgumentException: requirement failed: $1 entries must be 64 lower-case hex characters (0-9a-f); invalid value(s): $2 at=org.ergoplatform.settings.ErgoSettings\$.validateTokenWhitelist"
}
[[ "$(grep -c '^CASE ' "$WORKDIR/ab-base.txt")" == 35 && "$(grep -c '^CASE ' "$WORKDIR/ab-cand.txt")" == 35 ]] || bad+=("not 35 cases per jar")
SAME=(DEFAULT W-null W-empty-list W-valid1 W-valid2 W-dup-valid N-empty-list N-valid1 N-valid2 N-dup-valid
      W-string-not-list BLACKLIST-example)
for c in "${SAME[@]}"; do
  [[ -n "$(line base "$c")" && "$(line base "$c")" == "$(line cand "$c")" ]] || bad+=("$c: the jars differ")
done
for c in "${SAME[@]}"; do [[ $c == W-string-not-list ]] && continue
  [[ "$(line base "$c")" == "read "* ]] || bad+=("$c: not read"); done
[[ "$(line base W-string-not-list)" == "rejected "* ]] || bad+=("W-string-not-list: read")
[[ "$(line base BLACKLIST-example)" == *"blacklist=[1:'example']" ]] || bad+=("BLACKLIST-example: entry not as given")
declare -A BADV=(
  [example]="'example'" [empty-string]="''" [upper]="'${SIGUSD^^}'" [two-capitals]="'03FAf2cb329f2e90d6d23b58d91bbb6c046aa143261cc21f52fbe2824bfcbf04'"
  [len63]="'${SIGUSD:0:63}'" [len65]="'${SIGUSD}0'" [non-hex-g]="'${SIGUSD:0:63}g'" [leading-space]="' $SIGUSD'"
  [0x-prefix]="'0x$SIGUSD'" [hocon-number]="'123'" [mixed]="'example', '${ID2^^}'"
)
for k in "${!BADV[@]}"; do
  for p in W N; do key=ergo.wallet.tokensWhitelist; [[ $p == N ]] && key=ergo.node.storageRentTokenWhitelist
    [[ "$(line base "$p-$k")" == "read "* ]] || bad+=("$p-$k: the base did not read it")
    if [[ $k != mixed ]]; then want="read wallet=[1:${BADV[$k]}] rent=[0:] blacklist=[0:]"
      [[ $p == N ]] && want="read wallet=None rent=[1:${BADV[$k]}] blacklist=[0:]"
      [[ "$(line base "$p-$k")" == "$want" ]] || bad+=("$p-$k: the base did not read the entry as given"); fi
    [[ "$(line cand "$p-$k")" == "$(rej "$key" "${BADV[$k]}")" ]] || bad+=("$p-$k: the candidate line is not the expected rejection")
  done
done
[[ "$(line base BOTH-example)" == "read "* ]] || bad+=("BOTH-example: the base did not read it")
[[ "$(line cand BOTH-example)" == "$(rej ergo.node.storageRentTokenWhitelist "'example'")" ]] || bad+=("BOTH-example: not the storage-rent rejection")

# 2. node starts
pids=(); trap 'for p in "${pids[@]}"; do kill -9 "$p" 2>/dev/null; done' EXIT
port=19052
launch() {  # $1 = label, $2 = jar, $3 = wallet whitelist (HOCON list), $4 = storage-rent whitelist (HOCON list)
  local d="$WORKDIR/node-$1" rest=$port p2p=$((port + 1)) pid rc=running up=none t0=$SECONDS
  port=$((port + 2)); rm -rf "$d"; mkdir -p "$d/data" "$d/tmp"
  cat > "$d/node.conf" <<EOF
ergo.directory = "$d/data"
ergo.node.mining = false
ergo.node.offlineGeneration = false
ergo.wallet.tokensWhitelist = $3
ergo.node.storageRentTokenWhitelist = $4
scorex.network.bindAddress = "127.0.0.1:$p2p"
scorex.network.knownPeers = []
scorex.network.magicBytes = [112, 101, 101, 114]
scorex.network.upnpEnabled = false
scorex.restApi.bindAddress = "127.0.0.1:$rest"
scorex.restApi.apiKeyHash = "324dcf027dd4a30a932c441f365a25e86b173defa4b8e58948253471b81b72cf"
EOF
  ( cd "$d" && exec "$J8/bin/java" -Xmx512m -Djava.io.tmpdir="$d/tmp" -jar "$2" --devnet -c "$d/node.conf" ) > "$d/stdout.txt" 2>&1 &
  pid=$!; pids+=("$pid")
  while (( SECONDS - t0 < 180 )); do
    if ! kill -0 "$pid" 2>/dev/null; then wait "$pid"; rc=$?; break; fi
    if [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$rest/info")" == 200 ]]; then up=200; break; fi
    sleep 1
  done
  # once up, keep it running 10 s more (a longer log window), then it must still be running and answer again
  if [[ $up == 200 ]]; then sleep 10
    if ! kill -0 "$pid" 2>/dev/null; then wait "$pid"; rc=$?; up=200-then-exited
    elif [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$rest/info")" != 200 ]]; then up=200-then-no-answer; fi
  fi
  if [[ $rc == running ]]; then kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; fi
  local msg; msg="$(grep -o 'Failed to start Ergo node: .*' "$d/stdout.txt" | head -1)"
  echo "exit=$rc rest=$up msg=${msg:-none}" > "$d/launch.txt"
  echo "LAUNCH $1 exit=$rc rest=$up after=$((SECONDS - t0))s msg=${msg:-none}"
  grep -oE ' (ERROR|WARN) .*' "$d/stdout.txt" | sed -E 's/\[[^]]*\] //; s/[0-9]+/N/g' | cut -c1-160 | sort -u > "$d/signatures.txt"
  echo "   log: $(grep -cE ' (ERROR|WARN) ' "$d/stdout.txt") ERROR/WARN lines, $(wc -l < "$d/signatures.txt") signatures (thread name dropped, digits masked):"
  sed 's/^/     /' "$d/signatures.txt"
}
OK="[\"$SIGUSD\"]"; EX='["example"]'
echo "== node starts"
launch base-valid "${JAR[base]}" "$OK" "$OK"
launch cand-valid "${JAR[cand]}" "$OK" "$OK"
launch base-example-both "${JAR[base]}" "$EX" "$EX"
launch cand-example-wallet "${JAR[cand]}" "$EX" "[]"
launch cand-example-rent "${JAR[cand]}" "null" "$EX"
fail() { echo "exit=1 rest=none msg=Failed to start Ergo node: requirement failed: $1 entries must be 64 lower-case hex characters (0-9a-f); invalid value(s): 'example'"; }
want_launch() { [[ "$(cat "$WORKDIR/node-$1/launch.txt")" == "$2" ]] || bad+=("launch $1: not '$2'"); }
want_launch base-valid "exit=running rest=200 msg=none"
want_launch cand-valid "exit=running rest=200 msg=none"
want_launch base-example-both "exit=running rest=200 msg=none"
want_launch cand-example-wallet "$(fail ergo.wallet.tokensWhitelist)"
want_launch cand-example-rent "$(fail ergo.node.storageRentTokenWhitelist)"
echo "== log signatures of the two valid starts: only in base-valid / only in cand-valid (a lead to read, not part of the verdict)"
comm -23 "$WORKDIR/node-base-valid/signatures.txt" "$WORKDIR/node-cand-valid/signatures.txt" | sed 's/^/   base only: /'
comm -13 "$WORKDIR/node-base-valid/signatures.txt" "$WORKDIR/node-cand-valid/signatures.txt" | sed 's/^/   cand only: /'
echo "   ($(comm -3 "$WORKDIR/node-base-valid/signatures.txt" "$WORKDIR/node-cand-valid/signatures.txt" | wc -l) signatures on one side only)"

if (( ${#bad[@]} )); then printf 'MISMATCH: %s\n' "${bad[@]}"; echo "VERDICT: NOT as claimed"; exit 1; fi
echo "VERDICT: as claimed"; exit 0
