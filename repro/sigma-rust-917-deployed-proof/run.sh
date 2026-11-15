#!/usr/bin/env bash
# Runs one NiPoPoW proof served by a mainnet Scala node through sigma-rust's verifier at two commits:
#   v0.30.0 branch  4792b842e684beee9896fe3397b694830fe6ae3a
#   PR #917 head    1196317c0445ef44635e7390879c7ae973fc1f56
# and prints, for each, whether the verifier kept the proof and which proof headers fail the interlink check.
# Claim: the v0.30.0 branch keeps the proof with no failing header; PR #917 does not keep it, one header fails
# (height 1821696, a multiple of 1024) and `validate` reports the interlink proofs. The last line is
# "VERDICT: as claimed" (exit 0) or "VERDICT: NOT as claimed" (exit 1) with the lines that differ.
# The tests print and assert nothing: this is evidence, not a regression test.
#
# Needs: git, curl, sha256sum, tar, a Rust toolchain (cargo), about 3 GB of disk, network access to github.com,
# raw.githubusercontent.com, static.crates.io and crates.io. Takes a few minutes per commit (two cold builds).
# Writes only under WORKDIR (default: a new temporary directory, printed at the start and kept), apart from what
# cargo and rustup keep in their own caches (the repository pins a toolchain, which rustup may install).
#
#   bash run.sh            # deployed_proof.rs and deployed_proof_validate.rs must sit beside this script
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_SRC="$HERE/deployed_proof.rs"; [[ -f "$TEST_SRC" ]] || { echo "missing $TEST_SRC" >&2; exit 2; }
TEST_VAL="$HERE/deployed_proof_validate.rs"; [[ -f "$TEST_VAL" ]] || { echo "missing $TEST_VAL" >&2; exit 2; }
WORKDIR="${WORKDIR:-$(mktemp -d)}"; mkdir -p "$WORKDIR"; WORKDIR="$(cd "$WORKDIR" && pwd)"; echo "WORKDIR=$WORKDIR"
for t in git curl sha256sum tar cargo; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 2; }; done

V030=4792b842e684beee9896fe3397b694830fe6ae3a
PR917=1196317c0445ef44635e7390879c7ae973fc1f56
# The proof: arkadianet/ergo's fixture, captured from a mainnet Scala reference node and re-emitted through
# Scala's own serializer (their README). Pinned by commit and by hash.
FIXTURE_URL=https://raw.githubusercontent.com/arkadianet/ergo/97fafbd965b58a31e703e4cdb33677606eda726a/test-vectors/mainnet/nipopow/proof_m6_k10.scala.bin
FIXTURE_SHA=44c4fb7d81bdcd8b42e70359c08be3ec4038b27b75b8f5fb47f4c7a9af63ae7f
# sigma-ser at these commits requires core2 ^0.4.0, whose only 0.4 release is yanked from crates.io, so a fresh
# resolve fails; the archived crate is used through [patch.crates-io]. No source under test is changed.
CORE2_URL=https://static.crates.io/crates/core2/core2-0.4.0.crate
CORE2_SHA=b49ba7ef1ad6107f8824dbe97de947cbaac53c44e7f9756a1fba0d37c1eec505

fetch(){ curl -fsSL -o "$2" "$1"; echo "$3  $2" | sha256sum -c - >/dev/null || { echo "sha256 mismatch: $2" >&2; exit 3; }; }
fetch "$FIXTURE_URL" "$WORKDIR/proof.bin" "$FIXTURE_SHA"
fetch "$CORE2_URL" "$WORKDIR/core2-0.4.0.crate" "$CORE2_SHA"
tar xzf "$WORKDIR/core2-0.4.0.crate" -C "$WORKDIR"

git clone -q --no-checkout https://github.com/ergoplatform/sigma-rust.git "$WORKDIR/sigma-rust"
git -C "$WORKDIR/sigma-rust" fetch -q origin "$V030" "refs/pull/917/head"
git -C "$WORKDIR/sigma-rust" cat-file -e "$PR917^{commit}" || git -C "$WORKDIR/sigma-rust" fetch -q origin "$PR917"

expected_v030='RESULT parse=OK m=6 k=10 prefix=122 suffix_tail=9
RESULT interlink_checks=123 failing=0
RESULT process=Ok(()) best_proof_kept=true'
expected_pr917='RESULT parse=OK m=6 k=10 prefix=122 suffix_tail=9
RESULT interlink_checks=123 failing=1
RESULT failing_height=1821696 mod1024=0
RESULT process=Ok(()) best_proof_kept=false
RESULT validate=Err(InvalidProofStructure("interlink proofs"))'

status=0
for pair in "v0.30.0:$V030" "PR917:$PR917"; do
  name="${pair%%:*}"; sha="${pair##*:}"; wt="$WORKDIR/wt-$name"
  git -C "$WORKDIR/sigma-rust" worktree add -q --detach "$wt" "$sha"
  [[ "$(git -C "$wt" rev-parse HEAD)" == "$sha" ]] || { echo "wrong commit in $wt" >&2; exit 3; }
  mkdir -p "$wt/ergo-nipopow/tests"; cp "$TEST_SRC" "$wt/ergo-nipopow/tests/deployed_proof.rs"
  tests=(--test deployed_proof); expected="$expected_v030"
  if [[ "$name" == PR917 ]]; then
    cp "$TEST_VAL" "$wt/ergo-nipopow/tests/deployed_proof_validate.rs"; tests+=(--test deployed_proof_validate); expected="$expected_pr917"
  fi
  printf '\n[patch.crates-io]\ncore2 = { path = "%s/core2-0.4.0" }\n' "$WORKDIR" >> "$wt/Cargo.toml"
  log="$WORKDIR/run-$name.log"
  echo "=== $name ($sha)"
  # one test thread, so the two test binaries' lines come in a fixed order
  if ( cd "$wt" && NIPOPOW_PROOF_BIN="$WORKDIR/proof.bin" cargo test -p ergo-nipopow --all-features "${tests[@]}" -- --nocapture --test-threads=1 ) > "$log" 2>&1; then
    got="$(grep -o 'RESULT .*' "$log" || true)"; echo "$got"
    if [[ "$got" != "$expected" ]]; then status=1; echo "--- differs from the claim; expected:"; echo "$expected"; fi
  else
    echo "build or test failed; see $log"; status=1
  fi
done
if [[ $status == 0 ]]; then echo "VERDICT: as claimed"; else echo "VERDICT: NOT as claimed"; fi
exit $status
