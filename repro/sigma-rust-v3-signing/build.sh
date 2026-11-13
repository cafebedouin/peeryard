#!/usr/bin/env bash
# build.sh: install V0, V1 from npm (integrity checked). V2 is built by build_sigma_rust.sh.
# usage: build.sh <workdir> [v0] [v1]     (workdir holds v0/, v1/; created if missing; nothing named = both)
# needs: node + npm.
set -euo pipefail
W="$1"; shift; mkdir -p "$W"
want=("$@"); (( ${#want[@]} )) || want=(v0 v1)
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
# shellcheck disable=SC1091
if [[ -s "$NVM_DIR/nvm.sh" ]]; then export NVM_DIR; . "$NVM_DIR/nvm.sh" >/dev/null; fi
has() { local x; for x in "${want[@]}"; do [[ "$x" == "$1" ]] && return 0; done; return 1; }

echo "== toolchain"
node --version; npm --version

install() {  # dir version expected-integrity
  mkdir -p "$W/$1"; cd "$W/$1"
  [[ -f package.json ]] || echo '{"name":"sigma-rust-v3-'"$1"'","private":true}' > package.json
  npm install --no-audit --no-fund --ignore-scripts "ergo-lib-wasm-nodejs@$2"
  got=$(node -e 'const l=require("./package-lock.json");console.log(l.packages["node_modules/ergo-lib-wasm-nodejs"].version+" "+l.packages["node_modules/ergo-lib-wasm-nodejs"].integrity)')
  echo "$1 lock: $got"
  [[ "$got" == "$2 $3" ]] || { echo "INTEGRITY MISMATCH for $1"; exit 1; }
}
arts=(); vers=()
if has v0; then
  echo "== V0"; install v0 0.28.0 'sha512-APQEac2IISTtQ/3Wi9EnyyV4rkXvC+jrovLEpt1vqJLNCK9E5bMOttZws70VTqu9CY0g5wzSTNJdOjM0GuDZbA=='
  arts+=("$W/v0/node_modules/ergo-lib-wasm-nodejs/ergo_lib_wasm_bg.wasm"); vers+=("$W/v0/node_modules/ergo-lib-wasm-nodejs/package.json")
fi
if has v1; then
  echo "== V1"; install v1 0.29.0-alpha-2f840d3 'sha512-XCVZsPsPXBCOsZBkHj9+9I/nPV7gQM8fYZddj5K4d82gGGEyTBPxuuU+BXRbFIuJRRmJp7EFPTnOxEB4ILWEdg=='
  arts+=("$W/v1/node_modules/ergo-lib-wasm-nodejs/ergo_lib_wasm_bg.wasm"); vers+=("$W/v1/node_modules/ergo-lib-wasm-nodejs/package.json")
fi

if (( ${#arts[@]} )); then
  echo "== artifacts (sha256)"
  sha256sum "${arts[@]}"
  grep -H '"version"' "${vers[@]}"
fi
