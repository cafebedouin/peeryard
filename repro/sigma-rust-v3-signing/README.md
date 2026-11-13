# sigma-rust v3 signing

Can sigma-rust's wasm binding (`ergo-lib-wasm`, the library Nautilus and other JS wallets sign with) parse,
verify, reduce and sign real mainnet transactions whose input ErgoTrees are version 2 or 3? Three builds side by side,
on two frozen corpora of recorded mainnet transactions:

| label | build |
|---|---|
| V0 | `ergo-lib-wasm-nodejs@0.28.0` from npm (integrity checked) |
| V1 | `ergo-lib-wasm-nodejs@0.29.0-alpha-2f840d3` from npm (integrity checked) |
| V2 | `ergoplatform/sigma-rust` at the workflow's `sigma_rust_commit` input (default `688511dff3e3436dfdd6bd368e3eeef6f67d59e9`, on `develop`), `bindings/ergo-lib-wasm`, the repo's own `npm run build-nodejs` (see "The V2 / BV2 build") |

Public issue: [nautls/nautilus-wallet#354](https://github.com/nautls/nautilus-wallet/issues/354) ("sign_tx fails on
v3 ErgoTrees (ergo-lib-wasm 0.28): NonConsumedBytes"). This directory reproduces that behaviour on V0 and checks
the same path on V1 and V2. It is not a node scenario and needs no rig; peeryard carries it because the run is meant
to be re-run on GitHub-hosted runners (`.github/workflows/sigma-rust-v3-signing.yml`). It adds Node and, for V2, a
Rust toolchain and wasm-pack: they are the library under test.

Earlier runs of this directory (2026-10-28 to 11-02) used V2 at `8120eddd0d066c8e566e9c30507a359edad62200`, built by
a direct `wasm-pack 0.15.0 build`, and the Lithos corpus only.

## The corpora

Both are fetched once and frozen; the CI run checks each sha256 and never refetches. On-chain inclusion is the
acceptance oracle: every input proof in them was accepted by the network. Each holds, per transaction, the signed tx
as the node serves it, every input and data-input box, the inclusion block header and the 10 headers before it. The
serving node is recorded only as "a public mainnet node": headers are hash-linked, so any node returns the same bytes.

- `corpus.json` (set `lithos`), sha256 `17064042ef93dea429b36c8c865b1bfb565ca605299ce48736bd085fee1c4c5c`. Fetched
  2026-10-28T13:49:40Z to 13:53:33Z by `fetch_corpus.py`. Newest first, up to 60 transactions spending the Lithos
  pool NFT box, 20 spending the fee-vault NFT box and 20 spending a provision-contract box (83 distinct), plus one
  control transaction spending the SigUSD bank box (pre-v3 trees); Lithos trees are version 3 (header `0x1b`).
  `resolution` records how the vault NFT, the provision token and the provision guard hash were read from the unspent
  pool box.
- `corpus-machina.json` (set `machina`), sha256 `3eb60c6b373deca64c9996ab96c62b1beaad0bf4f3bcd65279e2a53ac8d7d942`.
  Fetched 2026-11-12T23:27:42Z to 23:28:20Z by `fetch_machina.py`. Selection rule: transactions that spend boxes at
  one Machina limit-order address (in `resolution.address`; its tree is version 2, header `0x1a`), the transaction
  that spent the seed box `59f7532a3b20f786f92a38d44c5b37cd367472108758d99581ca4f7e253a17ca` first, then the spending
  transactions of the other spent boxes at the address, newest box first, each transaction once, at most 21. At fetch
  time the address held 34 boxes, 33 spent, in 15 distinct spending transactions, so the set is all 15: 84 inputs
  (54 on version-2 trees of 288 bytes, 16 on version-2 trees of 247 bytes, 9 on a 412-byte version-1 tree, 5 P2PK). Some
  of its token amounts are above 2^53 (for example 9223372036196379593); the file keeps them as plain JSON numbers.

## Steps (`run.js`, one child `node` process per transaction, Node's default stack)

- **a**, per input: `ErgoTree.from_base16_bytes`, the bytes round-trip, and `template_bytes()`. All three must
  pass. The third is needed because a tree whose root expression fails to parse is kept as an "unparsed" tree that
  still round-trips its bytes.
- **b**, per input: `verify_tx_input_proof` against a state context built from the captured headers and
  `Parameters.default_parameters()`.
- **c**, per tx: `ReducedTransaction.from_unsigned_tx` on the tx with proofs stripped (context extensions kept).
- **d**, per tx with a P2PK (`0008cd`) input: `Wallet.sign_transaction` with a fixed throwaway key (scalar `0x01..01`).
  Passes when the error names a P2PK input index (the key is missing) and does not mention parsing; a parse or reduce
  error at a contract input fails it. Recorded apart, and not counted as a pass: step c passed and the prover stopped
  with "prover does not have enough witnesses" at a non-P2PK input (`d.key_missing_at_contract`), i.e. a spend path
  that needs a key the throwaway wallet does not hold, such as an owner-only close of a limit order. The summary
  counts these as "key missing at a contract input" (`K` in the per-tx table). `shape354` marks the issue's shape: a
  Lithos pool input plus a P2PK input.

Contract labels: on the Lithos corpus, inputs are labelled from the header fields (pool, fee vault, provision, SigUSD
bank, P2PK); on a corpus without those fields every non-P2PK input is labelled by its tree header byte and length,
e.g. `tree(1a,288B)`.

Integers above 2^53: `JSON.parse` reads every JSON number as a double, so a token amount above
`Number.MAX_SAFE_INTEGER` comes back rounded, and the library then rejects the box ("Box id parsed from JSON ...
differs from calculated"). This is a property of JavaScript callers, not of the library: any JS caller that passes
such a box through `JSON.parse` meets it. The runners (`run.js` and the page) therefore parse a corpus with
`parseCorpus()`: before `JSON.parse`, an integer literal of 16 or more digits after `"amount":` or `"value":` that is
above `Number.MAX_SAFE_INTEGER` is rewritten as a JSON string (the library's JSON accepts token amounts as strings;
values have not needed it, as no corpus value is that large), smaller ones stay numbers; after parsing, any number
still above `Number.MAX_SAFE_INTEGER` stops the run with an error. Results record the count of rewritten literals
(`corpus_unsafe_ints_as_strings`: 18 on the Machina corpus, 0 on the Lithos corpus). `negative_check.js` runs on the
Lithos corpus only and parses it with plain `JSON.parse`.

The run is void unless its controls hold (`summarize.py` prints them under `== controls`, once per corpus): on both
corpora V0 fails step a with `NonConsumedBytes` on every input whose tree version is 2 or more, and every P2PK input
verifies true on every build (a P2PK proof signs the tx bytes, so this checks the tx reconstruction and the verifier
wiring); on the Lithos corpus also V0 fails step a on the pool tree with `NonConsumedBytes` (the issue's error) and
the SigUSD control passes a to c on every build. `negative_check.js` is a separate, informational check that step b
can return false: it lowers output 0 of four Lithos transactions (one swap, one claim, the resize, one flush) by 1
nanoERG, recomputes the ids and re-verifies every input.

Not covered: signing with a real key (step d only shows how far signing gets before a missing key); mainnet chain
parameters (the default parameters are used; none of the three builds exposes a constructor from chain parameters);
contracts other than those in the two corpora.

## The V2 / BV2 build (`build_sigma_rust.sh`, workflow job `build`)

One job builds both sigma-rust packages at the input commit with the repo's own scripts in `bindings/ergo-lib-wasm`,
as sigma-rust's `.github/workflows/release_preflight.yml` does at the default commit: `npm ci`, then
`npm run build-nodejs` (writes `pkg-nodejs/`, package `ergo-lib-wasm-nodejs`) and `npm run build-browser` (writes
`pkg-browser/`, package `ergo-lib-wasm-browser`; the script runs `wasm-pack build --target browser --features rest`
with `WASM_BINDGEN_WEAKREF=1`, then the repo's `publish_helper` and `set_exports`), unchanged; then `npm pack` of
`pkg-browser` for the Nautilus arm. Tool pins, as in that file: Node 24.13.1 with npm 11.8.0 (asserted), wasm-pack
0.14.0 from its release archive (sha256 checked), and the Rust toolchain the commit's `rust-toolchain` file names
(1.91.1 at the default commit) with the `wasm32-unknown-unknown` target. The job prints the sha256 of each built
`.wasm` and of the tarball, writes them to `sigma-rust-build.env` and to the job outputs, and shares `pkg-nodejs/`,
`pkg-browser/` and the tarball as one artifact; the V2, browser and Nautilus jobs check that the artifact is at the
input commit. The Nautilus `develop` arm expects the browser package version 0.29.0 (the version at the default
commit; `nautilus/run.sh` stops on another tarball name).

V2 and BV2 differ by construction (target, the `rest` feature), so the browser comparison is of verdicts, not bytes.
The `.wasm` sha256 on a runner need not equal a local build's: the build embeds paths of the build host.

## In a browser (`browser/`, workflow job `browser`)

Nautilus signs in a Chromium (or Firefox) extension page, on the browser's JS stack, with the bundler-form package
`ergo-lib-wasm-browser`. The same steps a-d run there on the three browser builds, on both corpora:

| label | build |
|---|---|
| BV0 | `ergo-lib-wasm-browser@0.28.0` from npm (integrity checked; Nautilus's current pin) |
| BV1 | `ergo-lib-wasm-browser@0.29.0-alpha-2f840d3` from npm (integrity checked) |
| BV2 | sigma-rust at the input commit, `npm run build-browser` (job `build`) |

- `browser/run_browser.js` serves `browser/page/`, the library and the corpus from a static server on 127.0.0.1 and
  opens one fresh page per transaction (the counterpart of `run.js`'s child process per transaction) in Playwright
  1.64.1's Chromium, `chromium.launch()` defaults (headless; no launch arguments, no `--js-flags`). The steps run
  synchronously on the page's main thread. The driver records every console message, page error and page crash.
- `browser/page/run_page.js` is `run.js`'s `errStr`, `parseCorpus`, `classify` and `runOne` verbatim except three
  lines marked `PORT:` (no `require`, no `Buffer`; tree sha256 by `crypto.subtle`, computed before the steps). The job
  prints the diff (`port-diff.txt`). The page checks the corpus sha256 it fetched against the driver's.
- `browser/page/load.js` loads a bundler-form package without a bundler: none of the three entry files loads in
  Chromium by a plain `import()` (strict MIME check on the `.wasm` module import), so it does by hand what a bundler
  does with the entry file: compile the package's own `.wasm`, bind its imports to the package's own unmodified
  `ergo_lib_wasm_bg.js`, call `__wbg_set_wasm`, and call `__wbindgen_start()` when the entry file does.
- Stack-depth probe: in every page, before and after the steps, a zero-local recursive function counted to
  `RangeError`; the driver runs the same function in its Node process as a reference. The unit is frames of that
  function, not bytes, and it varies within a page, so the report gives the range. It reads "no stack error on the
  corpus" against a measured budget.
- `browser/compare.py --set <lithos|machina>` compares, per transaction, per input, per step, each browser verdict
  with the Node verdict of the same row (BV0 with V0, BV1 with V1, BV2 with V2; from the `run` jobs' results), every
  exact error string, and scans every browser record for `RangeError`, "Maximum call stack", wasm traps, page crashes
  and console errors or warnings. Its `== checks` fail the job when a control fails (on both corpora: BV0 fails step a
  with `NonConsumedBytes` on every input whose tree version is 2 or more, every P2PK input verifies true; on the
  Lithos corpus also BV0 fails on every pool input and the SigUSD control passes a-c), when any verdict differs from
  Node, or on any stack/trap/crash/console hit. Error-string differences are printed, not checked.
  `browser/compare_selftest.sh` plants a verdict flip with a `RangeError`, a `RuntimeError: unreachable`, a console
  error and a page crash in scratch copies of the results and passes only if `compare.py` reports every one and exits
  1 (the job runs it on the Lithos results).

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
- `develop`: both commits, the dependency resolved to the BV2 tarball built in the same run at the input commit, by
  a local pnpm override that is not part of the patch. `nautilus/lockfile.py` adds the override to
  `pnpm-workspace.yaml` and makes the four matching edits to `pnpm-lock.yaml` (the ergo-lib lines a non-frozen
  install writes for it; a non-frozen install would also re-resolve unrelated peer sets), so the arm differs from
  stock in the library only; the script prints that diff. Expected: the test passes 3 of 3 and the full
  `pnpm run test:unit` passes.

`run.sh` exits 1 when the arm's outcome is not the expected one; the witness output is `witness-<arm>.txt`.

## Run it locally

Needs Node (the published runs used 25.1.0 for the runners), npm and python3; for V2/BV2 also git, rustup and
wasm-pack (CI: Node 24.13.1 and wasm-pack 0.14.0 for the build, as above). From the peeryard root:
```
D=repro/sigma-rust-v3-signing; W=$(mktemp -d); C=688511dff3e3436dfdd6bd368e3eeef6f67d59e9
echo "17064042ef93dea429b36c8c865b1bfb565ca605299ce48736bd085fee1c4c5c  $D/corpus.json" | sha256sum -c
echo "3eb60c6b373deca64c9996ab96c62b1beaad0bf4f3bcd65279e2a53ac8d7d942  $D/corpus-machina.json" | sha256sum -c
bash $D/build.sh "$W" v0 v1                       # npm installs, seconds
bash $D/build_sigma_rust.sh "$W" "$C"             # V2 and BV2; INSTALL_RUST_TOOLCHAIN=1 to let it run rustup
P=$W/sigma-rust/bindings/ergo-lib-wasm
for s in lithos:corpus.json machina:corpus-machina.json; do n=${s%%:*}
  for x in V0:$W/v0/node_modules/ergo-lib-wasm-nodejs V1:$W/v1/node_modules/ergo-lib-wasm-nodejs V2:$P/pkg-nodejs; do
    node $D/run.js --lib "${x#*:}" --label "${x%%:*}" --set $n --corpus $D/${s#*:} --out results-$n-${x%%:*}.json
  done
  python3 -I $D/summarize.py $D/${s#*:} results-$n-V0.json results-$n-V1.json results-$n-V2.json
done
node $D/negative_check.js --lib <lib dir> --corpus $D/corpus.json \
  --tx 31d34067ed51143caf64be16b1b78f919ddae5a6792fbbfebe33d85ba3011547 --tx 568bdafe39312f32db46d3334dc8493d2d748a4249c812189779299cdda24cf8 \
  --tx 4c91124c7e8aab2f24838493c85ee3fcfcedf7aa5e5ab1272af0efa68fede2ce --tx de0c557d86f6346ddbbec61009bbbc8d0499d4983f4894f39fc76c1a5f3675a6
```
The browser half, from the peeryard root (Chromium's system libraries: `playwright install --with-deps`, or
`PW_WITH_DEPS=1`; the Nautilus arms need Node 26 and pnpm 12.16.1 on PATH):
```
bash $D/browser/build.sh "$W" bv0 bv1 pw                # PLAYWRIGHT_BROWSERS_PATH, if set, is where Chromium goes
for s in lithos:corpus.json machina:corpus-machina.json; do n=${s%%:*}
  for x in V0:$W/bv0/node_modules/ergo-lib-wasm-browser V1:$W/bv1/node_modules/ergo-lib-wasm-browser V2:$P/pkg-browser; do
    node $D/browser/run_browser.js --pw "$W/pw" --lib "${x#*:}" --label "${x%%:*}" --set $n --corpus $D/${s#*:} \
      --out "results-browser-$n-${x%%:*}.json"
  done
  python3 -I $D/browser/compare.py . . --set $n            # the Node results-<set>-V*.json and the browser ones, here
done
bash $D/browser/compare_selftest.sh . . "$(mktemp -d)" lithos
bash $D/nautilus/run.sh stock "$W/n-stock" out
bash $D/nautilus/run.sh develop "$W/n-develop" out "$W/pack/ergo-lib-wasm-browser-0.29.0.tgz"
```
`run.js` prints one line per transaction to stderr (`V0 [n/84] <txid> a:<parsed>/<inputs> b:<verified>/<inputs> c:<bool> d:<bool|->`,
plus `(key missing at contract input <i>)` when that case applies).

To refetch a corpus (the result will differ once the chain has moved on): `python3 $D/fetch_corpus.py OUT.json --node
<url>` or `python3 $D/fetch_machina.py OUT.json --node <url>`, with any public mainnet node.

## What it emits

- `results-<set>-<label>.json` (`schema: sigma-rust-v3-signing-results/1`): the build (`lib_name`, `lib_version`,
  `wasm_sha256`), `node`, `set`, `corpus_sha256`, `corpus_unsafe_ints_as_strings`, `shims` (API differences worked
  around; empty for these builds), and `results[]`, one per transaction: `txId`, `sets`, `inclusionHeight`,
  `shape354`, `setup` (box, tx, state-context construction), `inputs[]` (each with `contract` label, tree prefix,
  length and sha256, and `a`, `b` records: `pass` plus the exact error string), `c` and `d` records (`d` with
  `key_missing_at_contract`). A crashed child is recorded as `child_crashed` with its exit status and stderr tail; any
  `RangeError` is flagged `range_error`.
- `summarize.py`'s text report, per corpus: `== set`, `== versions`, `== controls`, `== per version, per contract`
  (step a / b counts per contract label), `== per version: step c / step d` (with the key-missing-at-contract count
  and all-steps-pass counts per tx kind; on the Lithos corpus the kind is read from context variable 0 of the Lithos
  inputs, elsewhere it is the set name), `== tx kinds in corpus`, the per-tx table (markdown), and every distinct
  failure string with its count.
- `negative_check.js`: JSON, per transaction, every input's verification on the original and on the mutated tx.
- `sigma-rust-build.env` and `build.txt` (job `build`): commit, toolchain, package names and versions, the sha256 of
  each built `.wasm` and of the tarball.
- `results-browser-<set>-<label>.json` (`schema: sigma-rust-v3-signing-browser-results/1`): as the Node results,
  plus `runtime` (Playwright and Chromium versions, user agent, the driver's Node stack-probe reference) and, per
  transaction, `browser` (page error, crash, console messages, failed requests, the page-side corpus check, load
  information, `run_ms`, the stack probe before and after the steps).
- `compare-<set>.txt` and `compare-<set>.json` (`browser/compare.py`): controls, counts, verdict and error-string
  diffs, the stack/trap/crash/console scan, the stack-probe ranges, and `== checks`.
- `nautilus`: per arm, `run-<arm>.txt` (the pins, the applied commits, the local override's diff, the installed wasm
  sha256), `witness-<arm>.txt` (vitest output), `test-unit-develop.txt` and the install log.
