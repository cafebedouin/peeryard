#!/usr/bin/env bash
# build.sh: install V0, V1 from npm (integrity checked); build V2 from sigma-rust develop at a fixed commit.
# usage: build.sh <workdir> [v0] [v1] [v2]     (workdir holds v0/, v1/, sigma-rust/; created if missing;
#                                               no version named = all three)
# needs: node + npm; for v2 also git, the rust toolchain that sigma-rust's rust-toolchain file names (with the
# wasm32-unknown-unknown target) and wasm-pack on PATH.
set -euo pipefail
W="$1"; shift; mkdir -p "$W"
want=("$@"); (( ${#want[@]} )) || want=(v0 v1 v2)
SHA=8120eddd0d066c8e566e9c30507a359edad62200
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
# shellcheck disable=SC1091
if [[ -s "$NVM_DIR/nvm.sh" ]]; then export NVM_DIR; . "$NVM_DIR/nvm.sh" >/dev/null; fi
[[ -d "$HOME/.cargo/bin" ]] && export PATH="$HOME/.cargo/bin:$PATH"
has() { local x; for x in "${want[@]}"; do [[ "$x" == "$1" ]] && return 0; done; return 1; }

echo "== toolchain"
node --version; npm --version
if has v2; then WP="$(command -v wasm-pack)"; "$WP" --version; fi

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

if has v2; then
  echo "== V2"
  [[ -d "$W/sigma-rust/.git" ]] || git clone --quiet https://github.com/ergoplatform/sigma-rust.git "$W/sigma-rust"
  cd "$W/sigma-rust"; git fetch --quiet origin "$SHA" 2>/dev/null || true; git checkout --quiet "$SHA"
  echo "sigma-rust HEAD: $(git rev-parse HEAD)"; git status --porcelain | head -5
  echo "rust-toolchain: $(cat rust-toolchain* 2>/dev/null)"
  cd bindings/ergo-lib-wasm
  rustc --version; cargo --version
  rustup target list --installed
  "$WP" build --target nodejs 2>&1 | grep -v '^\s*Compiling \|^\s*Downloaded \|^\s*Downloading '
  arts+=("$W/sigma-rust/bindings/ergo-lib-wasm/pkg/ergo_lib_wasm_bg.wasm"); vers+=("$W/sigma-rust/bindings/ergo-lib-wasm/pkg/package.json")
fi

echo "== artifacts (sha256)"
sha256sum "${arts[@]}"
grep -H '"version"' "${vers[@]}"
