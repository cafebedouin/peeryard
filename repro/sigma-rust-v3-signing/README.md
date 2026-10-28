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

Not covered: a browser runtime (Nautilus's own; stack depth there can differ from Node's); mainnet chain parameters
(the default parameters are used; none of the three builds exposes a constructor from chain parameters).

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

The V2 `.wasm` sha256 on a runner need not equal a local build's: the build embeds paths of the build host.
