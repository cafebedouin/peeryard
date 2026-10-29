#!/usr/bin/env node
// browser/run_browser.js: run ../run.js's steps a-d in Chromium, one fresh page per tx. Standalone.
//
// usage: node run_browser.js --pw <dir holding node_modules/playwright> --lib <dir of an ergo-lib-wasm browser pkg>
//                            --label <V0|V1|V2> --corpus <corpus.json> --out <results.json>
//                            [--only <txId>]
//
// Serves page/ (this script's sibling dir), the library dir and the corpus from a static server on 127.0.0.1,
// launches Playwright's Chromium headless (default launch: no args, no --js-flags, default stack), and loads
// page/run.html?tx=<i> in a fresh page for each tx (the Node runner used a fresh child process per tx). The page
// runs the steps a-d on the page's main thread and leaves its JSON in window.__RESULT. The driver
// collects it plus every console message, page error and page crash.
// Set PLAYWRIGHT_BROWSERS_PATH to where `playwright install chromium` put the browser.
'use strict';
const fs = require('fs');
const path = require('path');
const http = require('http');
const crypto = require('crypto');

function arg(name, dflt) {
  const i = process.argv.indexOf('--' + name);
  return i >= 0 ? process.argv[i + 1] : dflt;
}
const PW = path.resolve(arg('pw'));
const LIB = path.resolve(arg('lib'));
const LABEL = arg('label', 'V?');
const CORPUS = path.resolve(arg('corpus'));
const OUT = arg('out');
const ONLY = arg('only');
const PAGE_DIR = path.join(__dirname, 'page');
const TX_TIMEOUT_MS = 300000;

const { chromium } = require(path.join(PW, 'node_modules', 'playwright'));
const pwVersion = JSON.parse(fs.readFileSync(path.join(PW, 'node_modules', 'playwright', 'package.json'))).version;
const sha256 = (buf) => crypto.createHash('sha256').update(buf).digest('hex');

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
               '.wasm': 'application/wasm', '.json': 'application/json', '.ts': 'text/plain' };
let nRequests = 0;
const notFound = [];
function serve(req, res) {
  nRequests++;
  const u = new URL(req.url, 'http://127.0.0.1');
  let file = null;
  if (u.pathname === '/corpus.json') file = CORPUS;
  else if (u.pathname.startsWith('/page/')) file = path.join(PAGE_DIR, path.normalize(u.pathname.slice(6)));
  else if (u.pathname.startsWith('/lib/')) file = path.join(LIB, path.normalize(u.pathname.slice(5)));
  if (!file || (!file.startsWith(PAGE_DIR) && !file.startsWith(LIB) && file !== CORPUS) || !fs.existsSync(file)) {
    notFound.push(u.pathname); res.writeHead(404); res.end('not found'); return;
  }
  res.writeHead(200, { 'content-type': MIME[path.extname(file)] || 'application/octet-stream', 'cache-control': 'no-store' });
  fs.createReadStream(file).pipe(res);
}

function nodeStackProbe() {   // the page's probe, run here for reference only (Node default stack)
  let depth = 0;
  function f() { depth++; f(); }
  try { f(); } catch (e) { return { depth, err: `${e.name}: ${e.message}` }; }
}

async function runPage(browser, base, url) {
  const page = await browser.newPage();
  const ev = { console: [], page_errors: [], crashed: false, request_failed: [] };
  page.on('console', (m) => { if (ev.console.length < 50) ev.console.push({ type: m.type(), text: m.text().slice(0, 1000) }); });
  page.on('pageerror', (e) => ev.page_errors.push(String(e && e.stack || e).slice(0, 2000)));
  page.on('crash', () => { ev.crashed = true; });
  page.on('requestfailed', (r) => ev.request_failed.push(`${r.url()} ${r.failure() && r.failure().errorText}`));
  let out = null; let driverErr = null;
  try {
    await page.goto(base + url, { waitUntil: 'load', timeout: 60000 });
    await page.waitForFunction(() => window.__RESULT !== undefined, null, { timeout: TX_TIMEOUT_MS, polling: 250 });
    out = await page.evaluate(() => window.__RESULT);
  } catch (e) { driverErr = `${e.name}: ${e.message}`.slice(0, 2000); }
  await page.close().catch(() => {});
  return { out, ev, driverErr };
}

async function main() {
  const corpusBytes = fs.readFileSync(CORPUS);
  const corpus = JSON.parse(corpusBytes);
  const pkg = JSON.parse(fs.readFileSync(path.join(LIB, 'package.json')));
  const wasm = fs.readdirSync(LIB).find((f) => f.endsWith('_bg.wasm'));
  const server = http.createServer(serve);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch();   // headless, Playwright defaults, no extra args
  const out = {
    schema: 'sigma-rust-v3-signing-browser-results/1', label: LABEL, lib: LIB, lib_name: pkg.name, lib_version: pkg.version,
    wasm_file: wasm, wasm_sha256: sha256(fs.readFileSync(path.join(LIB, wasm))),
    runtime: { playwright: pwVersion, browser_version: browser.version(), launch: 'chromium.launch() defaults (headless)',
               executable_full_chromium: chromium.executablePath(), node_driver: process.version,
               node_stack_probe_reference: nodeStackProbe() },
    server: base, corpus_sha256: sha256(corpusBytes), started_utc: new Date().toISOString(), results: [], shims: [],
  };
  {
    const ctx = await browser.newPage(); out.runtime.user_agent = await ctx.evaluate(() => navigator.userAgent); await ctx.close();
  }
  for (let i = 0; i < corpus.txs.length; i++) {
    const entry = corpus.txs[i];
    if (ONLY && entry.txId !== ONLY) continue;
    const { out: o, ev, driverErr } = await runPage(browser, base, `/page/run.html?lib=/lib&tx=${i}`);
    let r;
    if (o && o.result) {
      r = o.result;
      (r.shims || []).forEach((s) => { if (!out.shims.includes(s)) out.shims.push(s); });
      delete r.shims;
    } else {
      r = { txId: entry.txId, sets: entry.sets, inclusionHeight: entry.inclusionHeight, page_failed: true };
    }
    r.browser = { page_error: o ? o.page_error || null : null, page_error_stack: o ? o.page_error_stack || null : null,
                  range_error_page: o ? !!o.range_error : null, driver_error: driverErr, crashed: ev.crashed,
                  page_corpus_sha256_ok: o ? o.corpus_sha256 === out.corpus_sha256 : null,
                  load_info: o ? o.load_info : null, load_ms: o ? o.load_ms : null, run_ms: o ? o.run_ms : null,
                  stack_probe_before: o ? o.stack_probe_before : null, stack_probe_after: o ? o.stack_probe_after : null,
                  console: ev.console, page_errors: ev.page_errors, request_failed: ev.request_failed };
    out.results.push(r);
    const ok = !r.page_failed;
    process.stderr.write(`${LABEL} [${i + 1}/${corpus.txs.length}] ${entry.txId.slice(0, 12)} ` +
      (ok ? `a:${r.inputs.filter((x) => x.a.pass).length}/${r.inputs.length} ` +
            `b:${r.inputs.filter((x) => x.b.pass).length}/${r.inputs.length} c:${r.c.pass} d:${r.d.applicable ? r.d.pass : '-'}`
          : `PAGE FAILED ${r.browser.page_error || driverErr || ''} crashed=${ev.crashed}`) +
      ` probe=${o && o.stack_probe_after ? o.stack_probe_after.depth : '?'} run_ms=${o ? o.run_ms : '?'}` +
      (ev.console.length ? ` console=${ev.console.length}` : '') + (ev.page_errors.length ? ` pageerrors=${ev.page_errors.length}` : '') + '\n');
  }
  out.finished_utc = new Date().toISOString();
  out.server_requests = nRequests; out.server_404 = notFound;
  await browser.close();
  server.close();
  fs.writeFileSync(OUT, JSON.stringify(out, null, 1));
}

main().catch((e) => { console.error(e); process.exit(1); });
