#!/usr/bin/env node
// run.js: parse / verify / reduce / sign each corpus transaction with one ergo-lib-wasm nodejs build. Standalone.
//
// usage: node run.js --lib <dir of an ergo-lib-wasm nodejs build> --label <V0|V1|V2>
//                    --corpus <corpus.json> --out <results.json> [--set <name>] [--only <txId>]
//                    [--child-node-flag <flag>]
//
// Inputs: a captured corpus file (fetch_corpus.py or fetch_machina.py output) and the library under test.
// The corpus is parsed by parseCorpus() below (integers above 2^53 - 1 kept exact), not by a bare JSON.parse.
// Output: JSON, per tx, per input, per step: pass/fail + the exact error string.
//
// Each tx runs in its own child Node process (default stack unless --child-node-flag is given),
// so a panic or a stack overflow in one tx cannot poison the wasm instance for the next.
//
// Steps per tx:
//   a  per input: ErgoTree.from_base16_bytes(tree); to_base16_bytes() == tree (byte round-trip);
//      template_bytes() (forces the root expression to have parsed: a tree whose root failed to
//      parse is kept as an "unparsed" tree that still round-trips its bytes).
//   b  per input: verify_tx_input_proof(i, stateContext, tx, inputBoxes, dataInputBoxes)
//   c  ReducedTransaction.from_unsigned_tx(tx with proofs stripped, context extensions kept, ...)
//   d  if the tx has a P2PK (0008cd) input: Wallet(throwaway key).sign_transaction(...); the
//      expected outcome is a signing error located at a P2PK input (the key is missing), not a
//      parse/reduce error at a contract input. Recorded apart, not a pass: c passed and the prover
//      stopped for lack of a secret at a non-P2PK input (key_missing_at_contract).
'use strict';
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');

function arg(name, dflt) {
  const i = process.argv.indexOf('--' + name);
  return i >= 0 ? process.argv[i + 1] : dflt;
}
const LIB = path.resolve(arg('lib'));
const LABEL = arg('label', 'V?');
const CORPUS = path.resolve(arg('corpus'));
const OUT = arg('out');
const ONLY = arg('only');
const SET = arg('set', null);
const CHILD_FLAG = arg('child-node-flag');
const TX_INDEX = arg('tx-index');

const sha256 = (buf) => crypto.createHash('sha256').update(buf).digest('hex');
const errStr = (e) => {
  if (e === undefined || e === null) return String(e);
  if (e instanceof Error) return `${e.name}: ${e.message}`;
  if (typeof e === 'string') return e;
  try { return JSON.stringify(e); } catch (_) { return String(e); }
};
const isRangeError = (e) => e instanceof RangeError || /RangeError|Maximum call stack/.test(errStr(e));

// API shims: every place a version needs a different call goes through here and is logged.
const SHIMS = [];
function shim(note) { if (!SHIMS.includes(note)) SHIMS.push(note); }

// Corpus parsing. JSON.parse reads every number as an IEEE-754 double, so an integer above 2^53 - 1 comes back
// rounded (token amounts up to 2^63 - 1 occur on chain), and a box built from it no longer matches its box id. This is
// a property of JavaScript callers, not of the library. Before parsing, an integer literal of 16 or more digits after
// "amount": or "value": that is above Number.MAX_SAFE_INTEGER is rewritten as a JSON string, which the library's JSON
// accepts; smaller ones stay numbers. After parsing, any number still above Number.MAX_SAFE_INTEGER is an error.
const UNSAFE_INT_RE = /("(?:amount|value)"\s*:\s*)(\d{16,})(?=\s*[,}\]])/g;
function parseCorpus(text) {
  let rewritten = 0;
  const safe = text.replace(UNSAFE_INT_RE, (m, key, digits) => {
    if (BigInt(digits) <= BigInt(Number.MAX_SAFE_INTEGER)) return m;
    rewritten++;
    return `${key}"${digits}"`;
  });
  const corpus = JSON.parse(safe);
  const bad = [];
  const walk = (o, at) => {
    if (typeof o === 'number') { if (Math.abs(o) > Number.MAX_SAFE_INTEGER) bad.push(at); }
    else if (o !== null && typeof o === 'object') Object.keys(o).forEach((k) => walk(o[k], `${at}.${k}`));
  };
  walk(corpus, '$');
  if (bad.length) throw new Error(`corpus: ${bad.length} number(s) above Number.MAX_SAFE_INTEGER after parsing, e.g. ${bad[0]}`);
  return { corpus, unsafe_ints_as_strings: rewritten };
}

// Contract labels. A corpus whose header carries the Lithos fields (pool NFT, vault NFT, provision token) gets the
// Lithos labels; any other corpus labels every non-P2PK input by its tree header byte and length.
function classify(corpus) {
  const r = corpus.resolution || {};
  const lithos = !!(r.pool_assets && r.vault_nft && r['provision_token (pool box tokens(2))']);
  const poolNft = lithos ? r.pool_assets[0].tokenId : null;
  const vaultNft = lithos ? r.vault_nft : null;
  const provTok = lithos ? r['provision_token (pool box tokens(2))'] : null;
  return (box) => {
    const t = box.ergoTree;
    const tok0 = box.assets.length ? box.assets[0].tokenId : null;
    if (t.startsWith('0008cd')) return 'P2PK';
    if (!lithos) return `tree(${t.slice(0, 2)},${t.length / 2}B)`;
    if (tok0 === poolNft) return 'LD_LiquidityPool';
    if (tok0 === vaultNft) return 'LD_FeeVault';
    if (tok0 === provTok) return 'LD_Provision(guard)';
    if (r.control && box.assets.some((a) => a.tokenId === r.control.sigusd_bank_nft))
      return 'SigUSD_bank';
    return `other(header=${t.slice(0, 2)})`;
  };
}

function runOne(corpus, entry) {
  const L = require(LIB);
  const label = classify(corpus);
  const res = { txId: entry.txId, sets: entry.sets, inclusionHeight: entry.inclusionHeight, setup: {}, inputs: [] };
  const tx = entry.tx;
  const P2PK = entry.inputBoxes.map((b) => b.ergoTree.startsWith('0008cd'));
  const kinds = entry.inputBoxes.map(label);
  res.shape354 = kinds.includes('LD_LiquidityPool') && P2PK.some((x) => x);

  // step a, per input (independent of the rest of the setup)
  entry.inputBoxes.forEach((b, i) => {
    const rec = { index: i, boxId: b.boxId, contract: kinds[i], tree_prefix: b.ergoTree.slice(0, 4),
                  tree_len: b.ergoTree.length / 2, tree_sha256: sha256(Buffer.from(b.ergoTree, 'hex')) };
    const a = { pass: false };
    try {
      const t = L.ErgoTree.from_base16_bytes(b.ergoTree);
      a.from_base16_bytes = 'ok';
      try { a.roundtrip = t.to_base16_bytes() === b.ergoTree ? 'equal' : 'DIFFERENT'; }
      catch (e) { a.roundtrip = 'error'; a.err = errStr(e); a.range_error = isRangeError(e); }
      try { t.template_bytes(); a.template_bytes = 'ok'; }
      catch (e) { a.template_bytes = 'error'; a.err = a.err || errStr(e); a.range_error = a.range_error || isRangeError(e); }
      a.pass = a.roundtrip === 'equal' && a.template_bytes === 'ok';
    } catch (e) { a.from_base16_bytes = 'error'; a.err = errStr(e); a.range_error = isRangeError(e); }
    rec.a = a;
    res.inputs.push(rec);
  });

  // setup shared by b, c, d
  let boxes, dataBoxes, stx, ctx, utx;
  const S = res.setup;
  try {
    boxes = L.ErgoBoxes.empty();
    entry.inputBoxes.forEach((b) => boxes.add(L.ErgoBox.from_json(JSON.stringify(b))));
    dataBoxes = L.ErgoBoxes.empty();
    entry.dataInputBoxes.forEach((b) => dataBoxes.add(L.ErgoBox.from_json(JSON.stringify(b))));
    S.boxes = 'ok';
  } catch (e) { S.boxes = 'error'; S.boxes_err = errStr(e); S.range_error = isRangeError(e); }
  try {
    stx = L.Transaction.from_json(JSON.stringify(tx));
    const id = stx.id().to_str();
    S.signed_tx = id === entry.txId ? 'ok' : `ID MISMATCH ${id}`;
  } catch (e) { S.signed_tx = 'error'; S.signed_tx_err = errStr(e); S.range_error = S.range_error || isRangeError(e); }
  try {
    const hdrs = L.BlockHeaders.from_json(entry.lastHeaders);
    const pre = L.PreHeader.from_block_header(L.BlockHeader.from_json(JSON.stringify(entry.blockHeader)));
    ctx = new L.ErgoStateContext(pre, hdrs, L.Parameters.default_parameters());
    S.state_context = 'ok';
  } catch (e) { S.state_context = 'error'; S.state_context_err = errStr(e); }
  try {
    const u = {
      inputs: tx.inputs.map((x) => ({ boxId: x.boxId, extension: (x.spendingProof && x.spendingProof.extension) || {} })),
      dataInputs: tx.dataInputs.map((x) => ({ boxId: x.boxId })),
      outputs: tx.outputs.map((o) => ({ value: o.value, ergoTree: o.ergoTree, assets: o.assets,
                                        additionalRegisters: o.additionalRegisters, creationHeight: o.creationHeight })),
    };
    utx = L.UnsignedTransaction.from_json(JSON.stringify(u));
    const id = utx.id().to_str();
    S.unsigned_tx = id === entry.txId ? 'ok' : `ID MISMATCH ${id}`;
  } catch (e) { S.unsigned_tx = 'error'; S.unsigned_tx_err = errStr(e); S.range_error = S.range_error || isRangeError(e); }
  const setupB = S.boxes === 'ok' && S.signed_tx === 'ok' && S.state_context === 'ok';
  const setupC = S.boxes === 'ok' && S.unsigned_tx === 'ok' && S.state_context === 'ok';

  // step b, per input
  res.inputs.forEach((rec, i) => {
    const b = { pass: false };
    if (!setupB) { b.err = 'setup failed (see setup)'; b.skipped = true; }
    else {
      try {
        const v = L.verify_tx_input_proof(i, ctx, stx, boxes, dataBoxes);
        b.value = v; b.pass = v === true;
      } catch (e) { b.err = errStr(e); b.range_error = isRangeError(e); }
    }
    rec.b = b;
  });

  // step c
  const c = { pass: false };
  if (!setupC) { c.err = 'setup failed (see setup)'; c.skipped = true; }
  else {
    try { L.ReducedTransaction.from_unsigned_tx(utx, boxes, dataBoxes, ctx); c.pass = true; }
    catch (e) { c.err = errStr(e); c.range_error = isRangeError(e); }
  }
  res.c = c;

  // step d
  const d = { applicable: P2PK.some((x) => x), pass: false };
  if (d.applicable) {
    if (!setupC) { d.err = 'setup failed (see setup)'; d.skipped = true; }
    else {
      try {
        const sks = new L.SecretKeys();
        sks.add(L.SecretKey.dlog_from_bytes(Uint8Array.from(Buffer.alloc(32, 1))));
        const w = L.Wallet.from_secrets(sks);
        w.sign_transaction(ctx, utx, boxes, dataBoxes);
        d.outcome = 'SIGNED (unexpected: throwaway key should not own any input)';
      } catch (e) {
        d.err = errStr(e); d.range_error = isRangeError(e);
        const m = /input index:?\s*(\d+)/i.exec(d.err) || /index[^0-9]{0,8}(\d+)/i.exec(d.err);
        d.err_input_index = m ? Number(m[1]) : null;
        d.err_at_p2pk = d.err_input_index !== null && P2PK[d.err_input_index] === true;
        d.err_mentions_parse = /pars|deserializ|NonConsumed/i.test(d.err);
        d.pass = d.err_at_p2pk && !d.err_mentions_parse;
        // Not a pass, recorded apart: reduction passed (step c) and the prover stopped for lack of a secret at a
        // non-P2PK input, i.e. a spend path that needs a key the throwaway wallet does not hold (an owner-only path).
        d.key_missing_at_contract = !d.pass && c.pass && d.err_input_index !== null &&
          P2PK[d.err_input_index] === false && !d.err_mentions_parse && /does not have enough witnesses/i.test(d.err);
      }
    }
  }
  res.d = d;
  return res;
}

function main() {
  const corpusBytes = fs.readFileSync(CORPUS);
  const { corpus, unsafe_ints_as_strings } = parseCorpus(corpusBytes.toString('utf8'));
  if (TX_INDEX !== undefined) {           // child mode
    const r = runOne(corpus, corpus.txs[Number(TX_INDEX)]);
    r.shims = SHIMS;
    process.stdout.write(JSON.stringify(r));
    return;
  }
  const pkg = JSON.parse(fs.readFileSync(path.join(LIB, 'package.json')));
  const wasm = fs.readdirSync(LIB).find((f) => f.endsWith('_bg.wasm'));
  const out = {
    schema: 'sigma-rust-v3-signing-results/1', label: LABEL, lib: LIB, lib_name: pkg.name, lib_version: pkg.version,
    wasm_file: wasm, wasm_sha256: sha256(fs.readFileSync(path.join(LIB, wasm))),
    node: process.version, child_node_flag: CHILD_FLAG || null,
    set: SET, corpus_sha256: sha256(corpusBytes), corpus_unsafe_ints_as_strings: unsafe_ints_as_strings, started_utc: new Date().toISOString(), results: [], shims: [],
  };
  corpus.txs.forEach((entry, i) => {
    if (ONLY && entry.txId !== ONLY) return;
    const nodeArgs = (CHILD_FLAG ? [CHILD_FLAG] : []).concat([__filename, '--lib', LIB, '--label', LABEL,
      '--corpus', CORPUS, '--tx-index', String(i)]);
    const p = spawnSync(process.execPath, nodeArgs, { encoding: 'utf8', maxBuffer: 64 << 20 });
    let r;
    try { r = JSON.parse(p.stdout); }
    catch (_) {
      r = { txId: entry.txId, sets: entry.sets, inclusionHeight: entry.inclusionHeight,
            child_crashed: true, child_status: p.status, child_signal: p.signal,
            child_stderr_tail: (p.stderr || '').slice(-2000),
            range_error: /RangeError|Maximum call stack/.test(p.stderr || '') };
    }
    (r.shims || []).forEach((s) => { if (!out.shims.includes(s)) out.shims.push(s); });
    delete r.shims;
    if (p.stderr && !r.child_crashed) r.child_stderr_tail = p.stderr.slice(-1000);
    out.results.push(r);
    process.stderr.write(`${LABEL} [${i + 1}/${corpus.txs.length}] ${entry.txId.slice(0, 12)} ` +
      `${r.child_crashed ? 'CRASH' : `a:${r.inputs.filter((x) => x.a.pass).length}/${r.inputs.length} ` +
      `b:${r.inputs.filter((x) => x.b.pass).length}/${r.inputs.length} c:${r.c.pass} d:${r.d.applicable ? r.d.pass : '-'}` +
      `${r.d.key_missing_at_contract ? ` (key missing at contract input ${r.d.err_input_index})` : ''}`}\n`);
  });
  out.finished_utc = new Date().toISOString();
  fs.writeFileSync(OUT, JSON.stringify(out, null, 1));
}

main();
