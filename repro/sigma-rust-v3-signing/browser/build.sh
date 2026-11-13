#!/usr/bin/env bash
# browser/build.sh: BV0, BV1 (ergo-lib-wasm-browser from npm, integrity checked) and Playwright. BV2 is built, with
# V2, by ../build_sigma_rust.sh (the repo's own `build-browser` npm script, then `npm pack`).
# usage: build.sh <workdir> [bv0] [bv1] [pw]     (nothing named = bv0 bv1)
#   bv0, bv1 -> <workdir>/bv0, bv1 (npm installs of ergo-lib-wasm-browser)
#   pw       -> <workdir>/pw (Playwright 1.64.1 from npm, integrity checked) and its Chromium
# needs: node + npm.
set -euo pipefail
W="$1"; shift; mkdir -p "$W"; W="$(cd "$W" && pwd)"
want=("$@"); (( ${#want[@]} )) || want=(bv0 bv1)
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
# shellcheck disable=SC1091
if [[ -s "$NVM_DIR/nvm.sh" ]]; then export NVM_DIR; . "$NVM_DIR/nvm.sh" >/dev/null; fi
has() { local x; for x in "${want[@]}"; do [[ "$x" == "$1" ]] && return 0; done; return 1; }

echo "== toolchain"
node --version; npm --version

install() {  # dir version expected-integrity
  mkdir -p "$W/$1"; cd "$W/$1"
  [[ -f package.json ]] || echo '{"name":"sigma-rust-v3-'"$1"'","private":true}' > package.json
  npm install --no-audit --no-fund --ignore-scripts "ergo-lib-wasm-browser@$2"
  got=$(node -e 'const p=require("./package-lock.json").packages["node_modules/ergo-lib-wasm-browser"];console.log(p.version+" "+p.integrity)')
  echo "$1 lock: $got"
  [[ "$got" == "$2 $3" ]] || { echo "INTEGRITY MISMATCH for $1"; exit 1; }
}
arts=(); vers=()
if has bv0; then
  echo "== BV0"; install bv0 0.28.0 'sha512-cAUqywvMWEB8sd/vw+IjWJRXRSJPxpehGvH3MHJDfjGwIUHF5cJzGHnkI+eV7TMdBI+x9PILvw34ztEw3aYV3Q=='
  arts+=("$W/bv0/node_modules/ergo-lib-wasm-browser/ergo_lib_wasm_bg.wasm"); vers+=("$W/bv0/node_modules/ergo-lib-wasm-browser/package.json")
fi
if has bv1; then
  echo "== BV1"; install bv1 0.29.0-alpha-2f840d3 'sha512-m8teK1Xf8ArTksDG+s9xAl40gmnWir4bdVWh93mNVryRbG0XhYj/2w/T1IeuE3iq2ibDs+q64BK7BAJVSxLAUg=='
  arts+=("$W/bv1/node_modules/ergo-lib-wasm-browser/ergo_lib_wasm_bg.wasm"); vers+=("$W/bv1/node_modules/ergo-lib-wasm-browser/package.json")
fi

if has pw; then   # Playwright (the browser driver), integrity checked, and its Chromium build
  echo "== Playwright"
  mkdir -p "$W/pw"; cd "$W/pw"
  [[ -f package.json ]] || echo '{"name":"sigma-rust-v3-pw","private":true}' > package.json
  npm install --no-audit --no-fund --ignore-scripts playwright@1.64.1
  got=$(node -e 'const p=require("./package-lock.json").packages;console.log(["playwright","playwright-core"].map((k)=>k+"@"+p["node_modules/"+k].version+" "+p["node_modules/"+k].integrity).join(" "))')
  echo "pw lock: $got"
  [[ "$got" == "playwright@1.64.1 sha512-HCrVhHr5QQuwYoswEUGTb7gGp522yflbv/ST8nF4sFWGuLjQCt17Q/EubpGGSNKYn1tsTCPZxqHhHCfVURu7UA== playwright-core@1.64.1 sha512-BC4s8y6SEVA6Q1rSxZTto8hI1KUI3xXlHGZgvGqP4IqPdI/a6FX9H29IDNz7vKo9l21b6LfYosScPL6M3xxyDQ==" ]] \
    || { echo "INTEGRITY MISMATCH for playwright"; exit 1; }
  # PLAYWRIGHT_BROWSERS_PATH, when set, is where the browser goes; PW_WITH_DEPS=1 also installs its system packages (CI).
  ./node_modules/.bin/playwright install ${PW_WITH_DEPS:+--with-deps} chromium
fi

if (( ${#arts[@]} )); then
  echo "== artifacts (sha256)"
  sha256sum "${arts[@]}"
  grep -H '"version"\|"name"' "${vers[@]}"
fi
