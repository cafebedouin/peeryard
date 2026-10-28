#!/usr/bin/env node
// run.js: parse / verify / reduce / sign each corpus transaction with one ergo-lib-wasm nodejs build. Standalone.
//
// usage: node run.js --lib <dir of an ergo-lib-wasm nodejs build> --label <V0|V1|V2>
//                    --corpus <corpus.json> --out <results.json> [--only <txId>] [--child-node-flag <flag>]
//
// Inputs: the captured corpus file (fetch_corpus.py output) and the library under test.
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
//      parse/reduce error at a contract input.
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

function classify(corpus) {
  const r = corpus.resolution;
  const poolNft = r.pool_assets[0].tokenId;
  const vaultNft = r.vault_nft;
  const provTok = r['provision_token (pool box tokens(2))'];
  return (box) => {
    const t = box.ergoTree;
    const tok0 = box.assets.length ? box.assets[0].tokenId : null;
    if (t.startsWith('0008cd')) return 'P2PK';
    if (tok0 === poolNft) return 'LD_LiquidityPool';
    if (tok0 === vaultNft) return 'LD_FeeVault';
    if (tok0 === provTok) return 'LD_Provision(guard)';
    if (corpus.resolution.control && box.assets.some((a) => a.tokenId === corpus.resolution.control.sigusd_bank_nft))
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
      }
    }
  }
  res.d = d;
  return res;
}

function main() {
  const corpusBytes = fs.readFileSync(CORPUS);
  const corpus = JSON.parse(corpusBytes);
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
    corpus_sha256: sha256(corpusBytes), started_utc: new Date().toISOString(), results: [], shims: [],
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
      `b:${r.inputs.filter((x) => x.b.pass).length}/${r.inputs.length} c:${r.c.pass} d:${r.d.applicable ? r.d.pass : '-'}`}\n`);
  });
  out.finished_utc = new Date().toISOString();
  fs.writeFileSync(OUT, JSON.stringify(out, null, 1));
}

main();
