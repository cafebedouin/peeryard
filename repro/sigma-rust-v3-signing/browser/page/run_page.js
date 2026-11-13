// browser/page/run_page.js: ../run.js's steps a-d, ported to a browser page.
// Port rule: errStr, isRangeError, the shims, parseCorpus(), classify() and runOne() are ../run.js's verbatim except the lines
// marked "PORT:" (import mechanism / Node Buffer+crypto replaced by browser equivalents); the workflow prints the diff.
// main() is new: one tx per page load (run.js uses one child process per tx), selected by ?tx=<index>; the result
// is left in window.__RESULT.
import { load } from './load.js';

let L;
const TREE_SHA256 = new Map();
const hex2bytes = (h) => { const u = new Uint8Array(h.length / 2); for (let i = 0; i < u.length; i++) u[i] = parseInt(h.substr(2 * i, 2), 16); return u; };
const bytes2hex = (u) => Array.from(new Uint8Array(u), (x) => x.toString(16).padStart(2, '0')).join('');
const subtleSha256 = async (u) => bytes2hex(await crypto.subtle.digest('SHA-256', u));

const sha256 = (hex) => TREE_SHA256.get(hex);  // PORT: precomputed with crypto.subtle (async) before runOne
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
  // PORT: L is the module-level library loaded by load.js (was: const L = require(LIB);)
  const label = classify(corpus);
  const res = { txId: entry.txId, sets: entry.sets, inclusionHeight: entry.inclusionHeight, setup: {}, inputs: [] };
  const tx = entry.tx;
  const P2PK = entry.inputBoxes.map((b) => b.ergoTree.startsWith('0008cd'));
  const kinds = entry.inputBoxes.map(label);
  res.shape354 = kinds.includes('LD_LiquidityPool') && P2PK.some((x) => x);

  // step a, per input (independent of the rest of the setup)
  entry.inputBoxes.forEach((b, i) => {
    const rec = { index: i, boxId: b.boxId, contract: kinds[i], tree_prefix: b.ergoTree.slice(0, 4),
                  tree_len: b.ergoTree.length / 2, tree_sha256: sha256(b.ergoTree) };  // PORT: was sha256(Buffer.from(b.ergoTree, 'hex'))
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
        sks.add(L.SecretKey.dlog_from_bytes(Uint8Array.from(new Uint8Array(32).fill(1))));  // PORT: was Buffer.alloc(32, 1)
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

// Stack-depth probe: a zero-local recursive JS function counted to RangeError, in this page.
function stackProbe() {
  let depth = 0;
  function f() { depth++; f(); }
  try { f(); return { depth, err: 'no error (unexpected)' }; } catch (e) { return { depth, err: errStr(e) }; }
}

async function main() {
  const out = { started: new Date().toISOString() };
  try {
    const q = new URLSearchParams(location.search);
    const libBase = q.get('lib') || '/lib';
    const t0 = performance.now();
    const ld = await load(libBase);
    L = ld.lib;
    out.load_ms = Math.round(performance.now() - t0);
    out.load_info = ld.info;
    const corpusBytes = new Uint8Array(await (await fetch('/corpus.json')).arrayBuffer());
    out.corpus_sha256 = await subtleSha256(corpusBytes);
    const parsed = parseCorpus(new TextDecoder().decode(corpusBytes));
    const corpus = parsed.corpus;
    out.corpus_unsafe_ints_as_strings = parsed.unsafe_ints_as_strings;
    out.n_txs = corpus.txs.length;
    out.stack_probe_before = stackProbe();
    if (q.has('tx')) {
      const entry = corpus.txs[Number(q.get('tx'))];
      for (const b of entry.inputBoxes) TREE_SHA256.set(b.ergoTree, await subtleSha256(hex2bytes(b.ergoTree)));
      const t1 = performance.now();
      const r = runOne(corpus, entry);
      out.run_ms = Math.round(performance.now() - t1);
      r.shims = SHIMS;
      out.result = r;
    }
    out.stack_probe_after = stackProbe();
  } catch (e) {
    out.page_error = errStr(e); out.page_error_stack = (e && e.stack) ? String(e.stack).slice(0, 4000) : null;
    out.range_error = isRangeError(e);
  }
  out.finished = new Date().toISOString();
  window.__RESULT = out;
}
main();
