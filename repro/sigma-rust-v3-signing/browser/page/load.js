// browser/page/load.js: load a wasm-pack bundler-target package in a plain page, doing by hand what a bundler does
// for its entry file ergo_lib_wasm.js:
//   import * as wasm from "./ergo_lib_wasm_bg.wasm";   -> instantiate the .wasm with its imports bound to bg.js
//   import { __wbg_set_wasm } from "./ergo_lib_wasm_bg.js"; __wbg_set_wasm(wasm);
//   wasm.__wbindgen_start();                            -> called iff the package's own entry file calls it
//   export * from "./ergo_lib_wasm_bg.js";              -> the library object returned is bg.js's namespace
// No library code is changed; the package's own bg.js glue and .wasm are loaded unmodified.
export async function load(base) {
  const entryText = await (await fetch(`${base}/ergo_lib_wasm.js`)).text();
  const bg = await import(`${base}/ergo_lib_wasm_bg.js`);
  const resp = await fetch(`${base}/ergo_lib_wasm_bg.wasm`);
  const wasmBytes = await resp.arrayBuffer();
  const module = await WebAssembly.compile(wasmBytes);
  const imports = {};
  const importModules = new Set();
  for (const imp of WebAssembly.Module.imports(module)) {
    if (imp.module !== './ergo_lib_wasm_bg.js') throw new Error(`unexpected wasm import module ${imp.module}`);
    if (!(imp.name in bg)) throw new Error(`bg.js lacks import ${imp.name}`);
    (imports[imp.module] = imports[imp.module] || {})[imp.name] = bg[imp.name];
    importModules.add(imp.module);
  }
  const instance = await WebAssembly.instantiate(module, imports);
  bg.__wbg_set_wasm(instance.exports);
  const callsStart = /wasm\.__wbindgen_start\(\)/.test(entryText);
  if (callsStart) instance.exports.__wbindgen_start();
  return { lib: bg, info: { base, wasm_bytes: wasmBytes.byteLength, wasm_content_type: resp.headers.get('content-type'),
                            import_modules: [...importModules], called_wbindgen_start: callsStart } };
}
