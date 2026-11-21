#!/usr/bin/env bash
# sigma-rust issue #964: three serialized headers (headers.hex) through Header::check_pow and pow_hit on seven
# sigma-rust trees, and through the ergo v6.0.8 reference jar. Ends with a VERDICT line; exits 1 if a claim fails.
#   control          real mainnet header, height 1,915,819, as mined
#   zero_index       the same header with nonce 20,713,447: one of its 32 table indexes is 0; no work for its target
#   zero_index_work  mainnet header at 1,914,880 with nBits set to difficulty 4 and nonce 45,878,571: an index of 0,
#                    and a hit under the difficulty-4 target
# Claims checked: (1) on develop and v0.30.0 both index-0 headers panic check_pow and the control passes; (2) on every
# tree with #847 or #965, each header gives the jar's hit and the jar's verdict; (3) header_zero_index_test.rs, a
# check_pow test pinned to the jar's hit, fails on develop at the panic and passes on develop with #847 or #965.
# Needs: git, rustup/cargo (each tree's rust-toolchain file picks the compiler), curl, sha256sum, jshell (JDK 11+).
# Usage: ./run.sh [workdir]   (or WORKDIR=...; JAR=/path/to/ergo-6.0.8.jar skips the download; JSHELL=... picks jshell)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${1:-${WORKDIR:-$(mktemp -d)}}
mkdir -p "$WORK"
OUT="$WORK/readings.txt"
: > "$OUT"
echo "workdir $WORK"

DEVELOP=e8689340518030c023ab8ba0bfd831ab6682512e   # develop, 2026-11-16
V030=4792b842e684beee9896fe3397b694830fe6ae3a      # v0.30.0
PR847=6e76e8233497eef51ebf64b1c34f6e389404d69c     # #847 head
PR965=34466d3d159a3138386ffdfabcb28fe9ab91c7a7     # #965 head
JAR_SHA=e1269f3c9b1c75d29f1f1bded720101792db41118757016123de113668353346
JAR_URL=https://github.com/ergoplatform/ergo/releases/download/v6.0.8/ergo-6.0.8.jar
sha256sum "$HERE"/headers.hex "$HERE"/zero_index.rs "$HERE"/reference.jsh "$HERE"/header_zero_index_test.rs "$HERE"/run.sh

SRC="$WORK/sigma-rust"
[ -d "$SRC" ] || git clone -q https://github.com/ergoplatform/sigma-rust "$SRC"
git -C "$SRC" fetch -q origin develop v0.30.0 pull/847/head pull/965/head

tree() {  # name base [commit to cherry-pick onto base]
  local d="$WORK/t-$1"
  [ -d "$d" ] || git -C "$SRC" worktree add -q --detach "$d" "$2"
  if [ -n "${3:-}" ] && [ "$(git -C "$d" rev-parse HEAD)" = "$2" ]; then
    git -C "$d" -c user.name=repro -c user.email=repro@localhost cherry-pick -x "$3" >/dev/null
  fi
  echo "tree $1: base ${2:0:10}${3:+ + ${3:0:10}} -> $(git -C "$d" log -1 --format='%h %s') ($(cd "$d" && rustc --version))"
}

for spec in "develop $DEVELOP" "v0.30.0 $V030" "pr847 $PR847" "pr965 $PR965" \
            "v0.30.0+847 $V030 $PR847" "develop+847 $DEVELOP $PR847" "develop+965 $DEVELOP $PR965"; do
  set -- $spec
  tree "$@"
  d="$WORK/t-$1"
  # v0.30.0 (and #847's March base) ship no Cargo.lock and require core2 0.4.0, which is yanked, so they do not
  # resolve from a fresh checkout. Build-only workaround: point the `core2` name at core3 =0.1.2, the crate develop
  # moved to.
  if grep -q '^core2 = { version = "0.4.0"' "$d/Cargo.toml"; then
    sed -i 's/^core2 = { version = "0.4.0",/core2 = { package = "core3", version = "=0.1.2",/' "$d/Cargo.toml"
    echo "[$1] build workaround: core2 -> core3 =0.1.2 in the workspace Cargo.toml"
  fi
  mkdir -p "$d/ergo-chain-types/examples"
  cp "$HERE/zero_index.rs" "$d/ergo-chain-types/examples/zero_index.rs"
  (cd "$d" && cargo run -q --release -p ergo-chain-types --example zero_index -- "$HERE/headers.hex" 2>"$WORK/build-$1.log") \
    | sed "s/^/[$1] /" | tee -a "$OUT" \
    || { echo "[$1] build or run failed:"; tail -20 "$WORK/build-$1.log"; echo "VERDICT: VOID (build failed: $1)"; exit 1; }
  case "$1" in develop+*)  # the PR on today's develop: its regression test and the crate's suite (default features)
    (cd "$d" && cargo test --release -p ergo-chain-types 2>&1 || true) | grep -E '^test result|^test .*zero|FAILED|panicked' \
      | sed "s/^/[$1 cargo test] /" | tee -a "$OUT" || true ;;
  esac
  case "$1" in develop|develop+*)  # the offered test (header_zero_index_test.rs, appended to header.rs): red, then green
    grep -q zero_index_pow_tests "$d/ergo-chain-types/src/header.rs" || cat "$HERE/header_zero_index_test.rs" >> "$d/ergo-chain-types/src/header.rs"
    (cd "$d" && cargo test --release -p ergo-chain-types zero_index_pow 2>&1 || true) \
      | { grep -E '^test header::zero_index|panicked at' || true; } | sed "s/^/[$1 offered test] /" | tee -a "$OUT" ;;
  esac
done

JAR=${JAR:-$WORK/ergo-6.0.8.jar}
[ -f "$JAR" ] || curl -sSL -o "$JAR" "$JAR_URL"
got=$(sha256sum "$JAR" | cut -d' ' -f1)
echo "jar sha256 $got"
[ "$got" = "$JAR_SHA" ] || { echo "VERDICT: VOID (jar sha256 mismatch)"; exit 1; }
JSHELL=${JSHELL:-$(for j in "${JAVA_HOME_21_X64:-}" "${JAVA_HOME_17_X64:-}"; do [ -x "$j/bin/jshell" ] && { echo "$j/bin/jshell"; break; }; done)}
JSHELL=${JSHELL:-jshell}
{ HEADERS="$HERE/headers.hex" "$JSHELL" -q --class-path "$JAR" "$HERE/reference.jsh" 2>&1 || true; } \
  | { grep -E '^(control|zero_index)' || true; } | sed 's/^/[scala v6.0.8] /' | tee -a "$OUT"

# ---- verdict
fail=0
hit_of() { grep -F "[$1] $2 " "$OUT" | grep -oE "$3=(Ok\()?[0-9]+" | grep -oE '[0-9]+$'; }
for h in control zero_index zero_index_work; do
  ref_hit=$(hit_of "scala v6.0.8" $h hit)
  case "$(grep -F "[scala v6.0.8] $h " "$OUT")" in *validate=Success*) ref_ok=true ;; *validate=Failure*) ref_ok=false ;; *) ref_ok=missing ;; esac
  [ -n "$ref_hit" ] && [ "$ref_ok" != missing ] || { echo "no reference reading for $h"; fail=1; continue; }
  for t in develop v0.30.0; do
    line=$(grep -F "[$t] $h " "$OUT" || true)
    if [ $h = control ]; then
      [[ "$line" == *"check_pow=Ok(true)"* && "$(hit_of $t $h pow_hit)" = "$ref_hit" ]] || { echo "UNEXPECTED [$t] $h: $line"; fail=1; }
    else
      [[ "$line" == *"check_pow=PANIC("*"autolykos_pow_scheme.rs:248"* ]] || { echo "UNEXPECTED [$t] $h (expected a panic): $line"; fail=1; }
    fi
  done
  for t in pr847 pr965 v0.30.0+847 develop+847 develop+965; do
    line=$(grep -F "[$t] $h " "$OUT" || true)
    [[ "$line" == *"check_pow=Ok($ref_ok)"* && "$(hit_of $t $h pow_hit)" = "$ref_hit" ]] || { echo "UNEXPECTED [$t] $h (expected Ok($ref_ok), hit $ref_hit): $line"; fail=1; }
  done
done
grep -q 'FAILED\|panicked' <(grep 'cargo test' "$OUT") && { echo "UNEXPECTED: a cargo test failed"; fail=1; }
for t in develop+847 develop+965; do
  grep -q "^\[$t cargo test\] test result: ok\. [1-9]" "$OUT" || { echo "UNEXPECTED: no passing cargo test result for $t"; fail=1; }
done
grep -q '^\[develop offered test\] test header::zero_index_pow_tests::.* FAILED' "$OUT" \
  && grep -q '^\[develop offered test\] .*panicked at .*autolykos_pow_scheme.rs:248' "$OUT" \
  || { echo "UNEXPECTED: the offered test does not fail on develop at autolykos_pow_scheme.rs:248"; fail=1; }
for t in develop+847 develop+965; do
  grep -q "^\[$t offered test\] test header::zero_index_pow_tests::.* ok" "$OUT" || { echo "UNEXPECTED: the offered test does not pass on $t"; fail=1; }
done
if [ $fail = 0 ]; then
  echo "VERDICT: PASS (develop and v0.30.0 panic on both index-0 headers; #847 and #965, on their heads, on develop and #847 on v0.30.0, give the v6.0.8 jar's hit and verdict on all three; the offered test fails on develop and passes with each)"
else
  echo "VERDICT: FAIL"; exit 1
fi
