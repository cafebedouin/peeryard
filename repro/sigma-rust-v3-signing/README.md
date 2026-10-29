# sigma-rust v3 signing

Can sigma-rust's wasm binding (`ergo-lib-wasm`, the library Nautilus and other JS wallets sign with) parse,
verify, reduce and sign real mainnet transactions that spend Lithos contracts, whose ErgoTrees are version 3
(header `0x1b`)? Three builds side by side, on one frozen corpus of 84 transactions:

| label | build |
|---|---|
| V0 | `ergo-lib-wasm-nodejs@0.28.0` from npm (integrity checked) |
| V1 | `ergo-lib-wasm-nodejs@0.29.0-alpha-2f840d3` from npm (integrity checked) |
| V2 | `ergoplatform/sigma-rust` `develop` at `8120eddd0d066c8e566e9c30507a359edad62200`, `bindings/ergo-lib-wasm`, `wasm-pack 0.15.0 build --target nodejs` (release profile), rust 1.91.1 as sigma-rust's `rust-toolchain` file names |

Public issue: [nautls/nautilus-wallet#354](https://github.com/nautls/nautilus-wallet/issues/354) ("sign_tx fails on
v3 ErgoTrees (ergo-lib-wasm 0.28): NonConsumedBytes"). This directory reproduces that behaviour on V0 and checks
the same path on V1 and V2. It is not a node scenario and needs no rig; peeryard carries it because the run is meant
to be re-run on GitHub-hosted runners (`.github/workflows/sigma-rust-v3-signing.yml`). It adds Node and, for V2, a
Rust toolchain: they are the library under test.

## The corpus

`corpus.json`, frozen, sha256 `17064042ef93dea429b36c8c865b1bfb565ca605299ce48736bd085fee1c4c5c`. Fetched once
(2026-10-28T13:49:40Z to 13:53:33Z) by `fetch_corpus.py` from third-party endpoints (the explorer API and a public
node; both named in the file's `endpoints`). It holds, newest first, up to 60 transactions spending the Lithos pool
NFT box, 20 spending the fee-vault NFT box and 20 spending a provision-contract box (83 distinct), plus one control
transaction spending the SigUSD bank box (pre-v3 trees). For each: the signed tx as the node serves it, every input
and data-input box, the inclusion block header and the 10 headers before it. `resolution` records how the vault NFT,
the provision token and the provision guard hash were read from the unspent pool box. Its `schema` field reads an
older working name; nothing reads it. The CI run checks the sha256 and never refetches: on-chain inclusion is the
acceptance oracle, so every input proof here was accepted by the network.

## Steps (`run.js`, one child `node` process per transaction, Node's default stack)

- **a**, per input: `ErgoTree.from_base16_bytes`, the bytes round-trip, and `template_bytes()`. All three must
  pass. The third is needed because a tree whose root expression fails to parse is kept as an "unparsed" tree that
  still round-trips its bytes.
- **b**, per input: `verify_tx_input_proof` against a state context built from the captured headers and
  `Parameters.default_parameters()`.
- **c**, per tx: `ReducedTransaction.from_unsigned_tx` on the tx with proofs stripped (context extensions kept).
- **d**, per tx with a P2PK (`0008cd`) input: `Wallet.sign_transaction` with a fixed throwaway key (scalar `0x01..01`).
  Passes when the error names a P2PK input index (the key is missing) and does not mention parsing; a parse or reduce
  error at a contract input fails it. `shape354` marks the issue's shape: a pool input plus a P2PK input.

The run is void unless its controls hold (`summarize.py` prints them under `== controls`): V0 fails step a on the pool
tree with `NonConsumedBytes` (the issue's error); every P2PK input verifies true on every build (a P2PK proof signs the
tx bytes, so this checks the tx reconstruction and the verifier wiring); the SigUSD control passes a to c on every
build. `negative_check.js` is a separate, informational check that step b can return false: it lowers output 0 of
four transactions (one swap, one claim, the resize, one flush) by 1 nanoERG, recomputes the ids and re-verifies every
input.

Not covered here: a browser runtime (the next section covers Chromium); mainnet chain parameters (the default
parameters are used; none of the three builds exposes a constructor from chain parameters).

## In a browser (`browser/`, workflow jobs `browser-build` and `browser`)

Nautilus signs in a Chromium (or Firefox) extension page, on the browser's JS stack, with the bundler-form package
`ergo-lib-wasm-browser`. The same steps a-d run there on the three browser builds:

| label | build |
|---|---|
| BV0 | `ergo-lib-wasm-browser@0.28.0` from npm (integrity checked; Nautilus's current pin) |
| BV1 | `ergo-lib-wasm-browser@0.29.0-alpha-2f840d3` from npm (integrity checked) |
| BV2 | sigma-rust `develop` `8120eddd`, the repo's own `build-browser` npm script (`WASM_BINDGEN_WEAKREF=1 wasm-pack build --target browser --out-dir pkg-browser --features rest`, then its `publish_helper -browser` and `set_exports`; only the `cross-env` wrapper is dropped), then `npm pack` |

BV2 differs from V2 by construction (target, the `rest` feature, the env var), so the comparison is of verdicts, not
bytes. `--target browser` is not in wasm-pack 0.15.0's `--help` list; it is accepted and emits the bundler form.
`browser-build` builds BV2 once and shares `pkg-browser/` and the tarball with `browser` and `nautilus` as an artifact.

- `browser/run_browser.js` serves `browser/page/`, the library and the corpus from a static server on 127.0.0.1 and
  opens one fresh page per transaction (the counterpart of `run.js`'s child process per transaction) in Playwright
  1.64.1's Chromium, `chromium.launch()` defaults (headless; no launch arguments, no `--js-flags`). The steps run
  synchronously on the page's main thread. The driver records every console message, page error and page crash.
- `browser/page/run_page.js` is `run.js`'s `errStr`, `classify` and `runOne` verbatim except three lines marked
  `PORT:` (no `require`, no `Buffer`; tree sha256 by `crypto.subtle`, computed before the steps). The job prints the
  diff (`port-diff.txt`). The page checks the corpus sha256 it fetched against the driver's.
- `browser/page/load.js` loads a bundler-form package without a bundler: none of the three entry files loads in
  Chromium by a plain `import()` (strict MIME check on the `.wasm` module import), so it does by hand what a bundler
  does with the entry file: compile the package's own `.wasm`, bind its imports to the package's own unmodified
  `ergo_lib_wasm_bg.js`, call `__wbg_set_wasm`, and call `__wbindgen_start()` when the entry file does.
- Stack-depth probe: in every page, before and after the steps, a zero-local recursive function counted to
  `RangeError`; the driver runs the same function in its Node process as a reference. The unit is frames of that
  function, not bytes, and it varies within a page, so the report gives the range. It reads "no stack error on the
  corpus" against a measured budget.
- `browser/compare.py` compares, per transaction, per input, per step, each browser verdict with the Node verdict
  of the same row (BV0 with V0, BV1 with V1, BV2 with V2; from the `run` jobs' results), every exact error string,
  and scans every browser record for `RangeError`, "Maximum call stack", wasm traps, page crashes and console
  errors or warnings. Its `== checks` fail the job when a control fails (BV0 fails step a on the pool tree with
  `NonConsumedBytes` on every pool input; every P2PK input verifies true; the SigUSD control passes a-c), when any
  verdict differs from Node, or on any stack/trap/crash/console hit. Error-string differences are printed, not
  checked. `browser/compare_selftest.sh` plants a verdict flip with a `RangeError`, a `RuntimeError: unreachable`,
  a console error and a page crash in scratch copies of the results and passes only if `compare.py` reports every
  one and exits 1.

Not covered: Firefox; a real extension page (approximated by a normal `http://127.0.0.1` page); full Chrome as
opposed to Playwright's headless shell; a Web Worker.

## In Nautilus's unit tests (`nautilus/`, workflow job `nautilus`)

`nautilus/upgrade.patch` (sha256 `e32864da296e299099fa094635d0ae4cd3e1825543023112840fb256413f979a`, checked
before use) is two commits against `nautls/nautilus-wallet` at `01969af4680c6e95c4a2be0edfb0d22ff787bf50`:
1/2 moves the dependency line to `"ergo-lib-wasm-browser": "^0.29.0"`; 2/2 adds `tests/unit/prover.spec.ts` and its
fixture, a mainnet Lithos deposit (`666028b4…9eee`: input 0 the pool box, ErgoTree v3; input 1 the depositor's
P2PK box). The test calls Nautilus's own `extractAddressesFromInputs` and `Prover` (`signInputs`, the
`sign_tx_input` path; `signTransaction`) with headers fed through fleet-sdk's `ErgoGraphQLProvider.getHeaders`
(fetch stubbed with the fixture), and expects: the depositor's address is extracted, the pool input's proof equals
its on-chain proof, and signing the whole tx fails only at input 1 for the missing key.

`nautilus/run.sh` runs one arm per call, on Node 26 (Nautilus's CI version; the job pins 26.13.0) with pnpm
12.16.1 and `pnpm install --frozen-lockfile`:
- `stock`: patch 2/2 only, stock dependencies (0.28.0 from Nautilus's lockfile). Expected: the test fails 3 of 3,
  with `NonConsumedBytes`.
- `develop`: both commits, the dependency resolved to BV2's tarball by a local pnpm override that is not part of the
  patch. `nautilus/lockfile.py` adds the override to `pnpm-workspace.yaml` and makes the four matching edits to
  `pnpm-lock.yaml` (the ergo-lib lines a non-frozen install writes for it; a non-frozen install would also
  re-resolve unrelated peer sets), so the arm differs from stock in the library only; the script prints that diff.
  Expected: the test passes 3 of 3 and the full `pnpm run test:unit` passes.

`run.sh` exits 1 when the arm's outcome is not the expected one; the witness output is `witness-<arm>.txt`.

## Run it locally

Needs Node (the published runs used 25.1.0), npm and python3; for V2 also git, rustup with toolchain 1.91.1 and
target `wasm32-unknown-unknown`, and `wasm-pack` 0.15.0 (`cargo install wasm-pack --version 0.15.0 --locked`).
From the peeryard root:
```
D=repro/sigma-rust-v3-signing; W=$(mktemp -d)
echo "17064042ef93dea429b36c8c865b1bfb565ca605299ce48736bd085fee1c4c5c  $D/corpus.json" | sha256sum -c
bash $D/build.sh "$W" v0 v1 v2                     # or any subset; V0 and V1 take seconds, V2 compiles sigma-rust
node $D/run.js --lib "$W/v0/node_modules/ergo-lib-wasm-nodejs" --label V0 --corpus $D/corpus.json --out results-V0.json
node $D/run.js --lib "$W/v1/node_modules/ergo-lib-wasm-nodejs" --label V1 --corpus $D/corpus.json --out results-V1.json
node $D/run.js --lib "$W/sigma-rust/bindings/ergo-lib-wasm/pkg" --label V2 --corpus $D/corpus.json --out results-V2.json
python3 -I $D/summarize.py $D/corpus.json results-V0.json results-V1.json results-V2.json
node $D/negative_check.js --lib <lib dir> --corpus $D/corpus.json \
  --tx 31d34067ed51143caf64be16b1b78f919ddae5a6792fbbfebe33d85ba3011547 --tx 568bdafe39312f32db46d3334dc8493d2d748a4249c812189779299cdda24cf8 \
  --tx 4c91124c7e8aab2f24838493c85ee3fcfcedf7aa5e5ab1272af0efa68fede2ce --tx de0c557d86f6346ddbbec61009bbbc8d0499d4983f4894f39fc76c1a5f3675a6
```
The browser half, from the peeryard root (Chromium's system libraries: `playwright install --with-deps`, or
`PW_WITH_DEPS=1`; the Nautilus arms need Node 26 and pnpm 12.16.1 on PATH):
```
bash $D/browser/build.sh "$W" bv0 bv1 bv2 pw            # PLAYWRIGHT_BROWSERS_PATH, if set, is where Chromium goes
for x in V0:$W/bv0/node_modules/ergo-lib-wasm-browser V1:$W/bv1/node_modules/ergo-lib-wasm-browser \
         V2:$W/sigma-rust/bindings/ergo-lib-wasm/pkg-browser; do
  node $D/browser/run_browser.js --pw "$W/pw" --lib "${x#*:}" --label "${x%%:*}" --corpus $D/corpus.json \
    --out "results-browser-${x%%:*}.json"
done
python3 -I $D/browser/compare.py . .                       # the Node results-V*.json and the browser ones, here
bash $D/browser/compare_selftest.sh . . "$(mktemp -d)"
bash $D/nautilus/run.sh stock "$W/n-stock" out
bash $D/nautilus/run.sh develop "$W/n-develop" out "$W/pack/ergo-lib-wasm-browser-0.29.0.tgz"
```
`run.js` prints one line per transaction to stderr (`V0 [n/84] <txid> a:<parsed>/<inputs> b:<verified>/<inputs> c:<bool> d:<bool|->`).

## What it emits

- `results-<label>.json` (`schema: sigma-rust-v3-signing-results/1`): the build (`lib_name`, `lib_version`,
  `wasm_sha256`), `node`, `corpus_sha256`, `shims` (API differences worked around; empty for these three builds), and
  `results[]`, one per transaction: `txId`, `sets`, `inclusionHeight`, `shape354`, `setup` (box, tx, state-context
  construction), `inputs[]` (each with `contract` label, tree prefix, length and sha256, and `a`, `b` records:
  `pass` plus the exact error string), `c` and `d` records. A crashed child is recorded as `child_crashed` with its
  exit status and stderr tail; any `RangeError` is flagged `range_error`.
- `summarize.py`'s text report: `== versions`, `== controls`, `== per version, per contract` (step a / b counts per
  contract label), `== per version: step c / step d` (with all-steps-pass counts per tx kind, the kind read from
  context variable 0 of the Lithos inputs), `== tx kinds in corpus`, the per-tx table (markdown), and every distinct
  failure string with its count.
- `negative_check.js`: JSON, per transaction, every input's verification on the original and on the mutated tx.
- `results-browser-<label>.json` (`schema: sigma-rust-v3-signing-browser-results/1`): as `results-<label>.json`,
  plus `runtime` (Playwright and Chromium versions, user agent, the driver's Node stack-probe reference) and, per
  transaction, `browser` (page error, crash, console messages, failed requests, the page-side corpus check, load
  information, `run_ms`, the stack probe before and after the steps).
- `compare.txt` and `compare.json` (`browser/compare.py`): controls, counts, verdict and error-string diffs, the
  stack/trap/crash/console scan, the stack-probe ranges, and `== checks`.
- `nautilus`: per arm, `run-<arm>.txt` (the pins, the applied commits, the local override's diff, the installed wasm
  sha256), `witness-<arm>.txt` (vitest output), `test-unit-develop.txt` and the install log.

The V2 and BV2 `.wasm` sha256 (and the BV2 tarball's) on a runner need not equal a local build's: the build embeds
paths of the build host.
