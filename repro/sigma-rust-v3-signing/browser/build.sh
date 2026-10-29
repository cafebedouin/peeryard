#!/usr/bin/env bash
# browser/build.sh: the three browser builds of ergo-lib-wasm. BV0, BV1 from npm (integrity checked); BV2 from
# sigma-rust develop at a fixed commit with the repo's own `build-browser` npm script, then `npm pack`ed.
# usage: build.sh <workdir> [bv0] [bv1] [bv2] [pw]     (nothing named = bv0 bv1 bv2)
#   bv0, bv1 -> <workdir>/bv0, bv1 (npm installs of ergo-lib-wasm-browser)
#   bv2      -> <workdir>/sigma-rust/bindings/ergo-lib-wasm/pkg-browser and <workdir>/pack/ergo-lib-wasm-browser-0.29.0.tgz
#   pw       -> <workdir>/pw (Playwright 1.64.1 from npm, integrity checked) and its Chromium
# needs: node + npm; for bv2 also git, the rust toolchain sigma-rust's rust-toolchain file names (with the
# wasm32-unknown-unknown target) and wasm-pack on PATH.
set -euo pipefail
W="$1"; shift; mkdir -p "$W"; W="$(cd "$W" && pwd)"
want=("$@"); (( ${#want[@]} )) || want=(bv0 bv1 bv2)
SHA=8120eddd0d066c8e566e9c30507a359edad62200
NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
# shellcheck disable=SC1091
if [[ -s "$NVM_DIR/nvm.sh" ]]; then export NVM_DIR; . "$NVM_DIR/nvm.sh" >/dev/null; fi
[[ -d "$HOME/.cargo/bin" ]] && export PATH="$HOME/.cargo/bin:$PATH"
has() { local x; for x in "${want[@]}"; do [[ "$x" == "$1" ]] && return 0; done; return 1; }

echo "== toolchain"
node --version; npm --version
if has bv2; then WP="$(command -v wasm-pack)"; "$WP" --version; fi

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

if has bv2; then
  echo "== BV2"
  [[ -d "$W/sigma-rust/.git" ]] || git clone --quiet https://github.com/ergoplatform/sigma-rust.git "$W/sigma-rust"
  cd "$W/sigma-rust"; git fetch --quiet origin "$SHA" 2>/dev/null || true; git checkout --quiet "$SHA"
  echo "sigma-rust HEAD: $(git rev-parse HEAD)"
  echo "tree status (porcelain):"; git status --porcelain | head -5; echo "(end status)"
  echo "rust-toolchain: $(cat rust-toolchain* 2>/dev/null)"
  cd bindings/ergo-lib-wasm
  rustc --version; cargo --version
  rustup target list --installed
  # The repo's build-browser script, run as written except for its cross-env wrapper (the env var is set directly).
  # Its `--target browser` is not in wasm-pack 0.15.0's --help list, but is accepted and emits the bundler form.
  echo "repo build-browser script: $(node -e 'console.log(require("./package.json").scripts["build-browser"])')"
  rm -rf ./pkg-browser
  WASM_BINDGEN_WEAKREF=1 "$WP" build --target browser --out-dir pkg-browser --features rest 2>&1 \
    | grep -v '^\s*Compiling \|^\s*Downloaded \|^\s*Downloading '
  ( cd pkg-browser && node ../scripts/publish_helper -browser >/dev/null && node ../scripts/set_exports >/dev/null )
  echo "pkg-browser entry: $(grep -m1 'import \* as wasm' pkg-browser/ergo_lib_wasm.js)"
  mkdir -p "$W/pack"; rm -f "$W/pack"/*.tgz
  ( cd pkg-browser && npm pack --pack-destination "$W/pack" --json > "$W/pack/pack.json" )
  tgz="$W/pack/$(node -e 'console.log(require(process.argv[1])[0].filename)' "$W/pack/pack.json")"
  echo "tarball: $(basename "$tgz") integrity $(node -e 'console.log(require(process.argv[1])[0].integrity)' "$W/pack/pack.json")"
  echo "tarball sha256: $(sha256sum "$tgz" | cut -d' ' -f1)"
  echo "tree status after build (porcelain):"; git -C "$W/sigma-rust" status --porcelain | head -5; echo "(end status)"
  arts+=("$W/sigma-rust/bindings/ergo-lib-wasm/pkg-browser/ergo_lib_wasm_bg.wasm"); vers+=("$W/sigma-rust/bindings/ergo-lib-wasm/pkg-browser/package.json")
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
