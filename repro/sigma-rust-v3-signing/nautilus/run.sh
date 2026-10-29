#!/usr/bin/env bash
# nautilus/run.sh: Nautilus's own unit test framework on ErgoTree-v3 signing, one arm per call.
# usage: run.sh stock   <workdir> <outdir>
#        run.sh develop <workdir> <outdir> <ergo-lib-wasm-browser-0.29.0.tgz>   (browser/build.sh bv2 makes it)
#   stock:   nautls/nautilus-wallet at $SHA + upgrade.patch 2/2 only (the test + fixture), stock dependencies
#            (ergo-lib-wasm-browser 0.28.0 from the lockfile). Expected: the test fails 3 of 3, with NonConsumedBytes.
#   develop: $SHA + both commits of upgrade.patch (the dependency line ^0.29.0, then the test), the dependency
#            resolved to the tarball by a local pnpm override (lockfile.py), not by the registry. Expected: the test
#            passes 3 of 3, and the full `pnpm run test:unit` passes.
# Exits 1 when the arm's outcome is not the expected one. needs: node, pnpm, git, python3.
set -euo pipefail
ARM="$1"; W="$2"; OUT="$3"; TGZ="${4:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHA=01969af4680c6e95c4a2be0edfb0d22ff787bf50
PATCH="$HERE/upgrade.patch"
PATCH_SHA256=e32864da296e299099fa094635d0ae4cd3e1825543023112840fb256413f979a
[[ "$ARM" == stock || "$ARM" == develop ]] || { echo "arm must be stock or develop"; exit 2; }
[[ "$ARM" == stock || -f "$TGZ" ]] || { echo "develop needs the tarball"; exit 2; }
mkdir -p "$W" "$OUT"; W="$(cd "$W" && pwd)"; OUT="$(cd "$OUT" && pwd)"

echo "== toolchain"
echo "node $(node --version)"; echo "pnpm $(pnpm --version)"; git --version
echo "== patch"
echo "$PATCH_SHA256  $PATCH" | sha256sum -c
rm -rf "$W/mails"; mkdir -p "$W/mails"; git mailsplit -o"$W/mails" "$PATCH" >/dev/null
grep -h '^Subject:' "$W/mails"/*

echo "== nautilus at $SHA, arm $ARM"
[[ -d "$W/nautilus/.git" ]] || git clone --quiet https://github.com/nautls/nautilus-wallet.git "$W/nautilus"
cd "$W/nautilus"
git am --abort >/dev/null 2>&1 || true
git -c advice.detachedHead=false checkout --quiet --force "$SHA"; git clean -fdq   # a reused clone starts clean
G=(git -c user.name=repro -c user.email=repro@localhost)
if [[ "$ARM" == stock ]]; then
  "${G[@]}" am --quiet "$W/mails/0002"
else
  "${G[@]}" am --quiet "$W/mails/0001" "$W/mails/0002"
  [[ "$(basename "$TGZ")" == ergo-lib-wasm-browser-0.29.0.tgz ]] || { echo "unexpected tarball name $(basename "$TGZ")"; exit 2; }
  mkdir -p "$W/pack"; cp "$TGZ" "$W/pack/ergo-lib-wasm-browser-0.29.0.tgz"
  echo "tarball sha256: $(sha256sum "$W/pack/ergo-lib-wasm-browser-0.29.0.tgz" | cut -d' ' -f1)"
  echo "tarball wasm sha256: $(tar -xOzf "$W/pack/ergo-lib-wasm-browser-0.29.0.tgz" package/ergo_lib_wasm_bg.wasm | sha256sum | cut -d' ' -f1)"
  python3 -I "$HERE/lockfile.py" . ../pack/ergo-lib-wasm-browser-0.29.0.tgz
fi
git log --oneline -3
echo "-- committed diff vs $SHA (stat)"; git diff --stat "$SHA" HEAD
echo "-- uncommitted (the local override, develop only)"; git status --porcelain; git diff | sed -n '1,80p'
sha256sum tests/unit/prover.spec.ts tests/unit/fixtures/lithos-deposit.json

echo "== pnpm install --frozen-lockfile"
pnpm install --frozen-lockfile > "$OUT/install-$ARM.txt" 2>&1 || { tail -30 "$OUT/install-$ARM.txt"; exit 1; }
tail -3 "$OUT/install-$ARM.txt"
LIBDIR="$(readlink -f node_modules/ergo-lib-wasm-browser)"
echo "installed: ergo-lib-wasm-browser $(node -p 'require(process.argv[1]).version' "$LIBDIR/package.json") wasm sha256 $(sha256sum "$LIBDIR/ergo_lib_wasm_bg.wasm" | cut -d' ' -f1)"

echo "== witness: pnpm exec vitest run tests/unit/prover.spec.ts"
set +e
pnpm exec vitest run tests/unit/prover.spec.ts > "$OUT/witness-$ARM.txt" 2>&1; rc=$?
set -e
cat "$OUT/witness-$ARM.txt"; echo "exit=$rc"
ok=1
if [[ "$ARM" == stock ]]; then
  ncb=$(grep -c 'NonConsumedBytes' "$OUT/witness-$ARM.txt" || true)
  [[ $rc -ne 0 ]] && grep -Eq 'Tests +3 failed \(3\)' "$OUT/witness-$ARM.txt" && (( ncb >= 3 )) || ok=0
  echo "stock: expected exit!=0, 3 of 3 failed, NonConsumedBytes in each failure: exit=$rc, NonConsumedBytes lines=$ncb"
else
  [[ $rc -eq 0 ]] && grep -Eq 'Tests +3 passed \(3\)' "$OUT/witness-$ARM.txt" || ok=0
  echo "develop: expected exit 0, 3 of 3 passed: exit=$rc"
  echo "== full unit suite: pnpm run test:unit"
  set +e
  pnpm run test:unit > "$OUT/test-unit-$ARM.txt" 2>&1; urc=$?
  set -e
  grep -E 'Test Files|Tests |FAIL|×' "$OUT/test-unit-$ARM.txt" || true; echo "exit=$urc"
  [[ $urc -eq 0 ]] || ok=0
fi
if (( ok )); then echo "RESULT $ARM: as expected"; else echo "RESULT $ARM: NOT as expected"; exit 1; fi
