#!/usr/bin/env node
// negative_check.js: discrimination check on step b of run.js. Informational; not one of the run's controls.
// Question: can step b (verify_tx_input_proof) return anything but true on this corpus and context, or does it
// pass vacuously? For each chosen tx, take output 0 (the contract's successor box), subtract 1 nanoERG from its
// value, and re-verify every input. A contract input that constrains its successor should now verify false (or
// error); a P2PK input should verify false because the tx bytes it signed changed.
//
// usage: node negative_check.js --lib <dir> --corpus corpus.json --tx <txId> [--tx <txId> ...]
'use strict';
const fs = require('fs');
const path = require('path');
const argv = process.argv;
const LIB = path.resolve(argv[argv.indexOf('--lib') + 1]);
const corpus = JSON.parse(fs.readFileSync(argv[argv.indexOf('--corpus') + 1]));
const txs = argv.map((a, i) => (a === '--tx' ? argv[i + 1] : null)).filter(Boolean);
const L = require(LIB);
const errStr = (e) => (e instanceof Error ? `${e.name}: ${e.message}` : typeof e === 'string' ? e : JSON.stringify(e));

function verifyAll(entry, tx) {
  const boxes = L.ErgoBoxes.empty();
  entry.inputBoxes.forEach((b) => boxes.add(L.ErgoBox.from_json(JSON.stringify(b))));
  const dbs = L.ErgoBoxes.empty();
  entry.dataInputBoxes.forEach((b) => dbs.add(L.ErgoBox.from_json(JSON.stringify(b))));
  const ctx = new L.ErgoStateContext(
    L.PreHeader.from_block_header(L.BlockHeader.from_json(JSON.stringify(entry.blockHeader))),
    L.BlockHeaders.from_json(entry.lastHeaders), L.Parameters.default_parameters());
  const stx = L.Transaction.from_json(JSON.stringify(tx));
  return entry.inputBoxes.map((b, i) => {
    try { return { i, tree: b.ergoTree.slice(0, 6), v: L.verify_tx_input_proof(i, ctx, stx, boxes, dbs) }; }
    catch (e) { return { i, tree: b.ergoTree.slice(0, 6), err: errStr(e).slice(0, 300) }; }
  });
}

const out = { lib: LIB, version: JSON.parse(fs.readFileSync(path.join(LIB, 'package.json'))).version, cases: [] };
for (const id of txs) {
  const entry = corpus.txs.find((e) => e.txId === id);
  const orig = verifyAll(entry, entry.tx);
  const mut = JSON.parse(JSON.stringify(entry.tx));
  mut.outputs[0].value = Number(mut.outputs[0].value) - 1;
  // the signed-tx JSON carries the tx id and output box ids, which the library checks; recompute them
  const u = L.UnsignedTransaction.from_json(JSON.stringify({
    inputs: mut.inputs.map((x) => ({ boxId: x.boxId, extension: x.spendingProof.extension || {} })),
    dataInputs: mut.dataInputs,
    outputs: mut.outputs.map((o) => ({ value: o.value, ergoTree: o.ergoTree, assets: o.assets,
      additionalRegisters: o.additionalRegisters, creationHeight: o.creationHeight })) }));
  mut.id = u.id().to_str();
  const cands = u.output_candidates();
  mut.outputs.forEach((o, i) => { o.transactionId = mut.id; o.boxId = L.ErgoBox.from_box_candidate(cands.get(i),
    L.TxId.from_str(mut.id), i).box_id().to_str(); });
  const mutated = verifyAll(entry, mut);
  out.cases.push({ txId: id, mutation: 'outputs[0].value -= 1', original: orig, mutated });
}
console.log(JSON.stringify(out, null, 1));
