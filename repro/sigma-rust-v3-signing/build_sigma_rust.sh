#!/usr/bin/env bash
# build_sigma_rust.sh: V2 (nodejs) and BV2 (browser) from ergoplatform/sigma-rust at one commit, built with the repo's
# own scripts in bindings/ergo-lib-wasm, as its .github/workflows/release_preflight.yml does: `npm ci`, then
# `npm run build-nodejs` (-> pkg-nodejs/) and `npm run build-browser` (-> pkg-browser/), unchanged; then `npm pack`
# of pkg-browser for the Nautilus arm.
# usage: build_sigma_rust.sh <workdir> [commit]   (commit: 40 hex digits; default $SIGMA_RUST_COMMIT, else the pin below)
#   -> <workdir>/sigma-rust/bindings/ergo-lib-wasm/pkg-nodejs, .../pkg-browser,
#      <workdir>/pack/ergo-lib-wasm-browser-<version>.tgz, and <workdir>/sigma-rust-build.env (key=value lines:
#      commit, versions, the sha256 of each built .wasm and of the tarball)
# needs: git, node + npm, wasm-pack, rustup with the toolchain sigma-rust's rust-toolchain file names and its
# wasm32-unknown-unknown target (INSTALL_RUST_TOOLCHAIN=1 installs both with rustup; CI sets it). The CI job pins
# Node 24.13.1 (npm 11.8.0) and wasm-pack 0.14.0, the versions release_preflight.yml pins at the default commit.
set -euo pipefail
W="$1"; mkdir -p "$W"; W="$(cd "$W" && pwd)"
SHA="${2:-${SIGMA_RUST_COMMIT:-688511dff3e3436dfdd6bd368e3eeef6f67d59e9}}"
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "commit must be 40 lowercase hex digits: $SHA"; exit 2; }
[[ -d "$HOME/.cargo/bin" ]] && export PATH="$HOME/.cargo/bin:$PATH"
filter() { grep -v '^\s*Compiling \|^\s*Downloaded \|^\s*Downloading ' || true; }

echo "== sigma-rust at $SHA"
[[ -d "$W/sigma-rust/.git" ]] || git clone --quiet https://github.com/ergoplatform/sigma-rust.git "$W/sigma-rust"
cd "$W/sigma-rust"
git fetch --quiet origin "$SHA" 2>/dev/null || true
git -c advice.detachedHead=false checkout --quiet "$SHA"
[[ "$(git rev-parse HEAD)" == "$SHA" ]] || { echo "checkout is not $SHA"; exit 1; }
echo "sigma-rust HEAD: $(git rev-parse HEAD)"
echo "tree status (porcelain):"; git status --porcelain | head -5; echo "(end status)"
TC="$(tr -d '[:space:]' < rust-toolchain)"
[[ "$TC" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "rust-toolchain is not a plain version: $TC"; exit 1; }
echo "rust-toolchain: $TC"
if [[ "${INSTALL_RUST_TOOLCHAIN:-}" == 1 ]]; then
  rustup toolchain install "$TC" --profile minimal --target wasm32-unknown-unknown
fi

echo "== toolchain"
node --version; npm --version; wasm-pack --version
rustc --version; cargo --version; rustup target list --installed
rustc --version | grep -q "^rustc $TC " || { echo "rustc is not the $TC that rust-toolchain names"; exit 1; }

cd bindings/ergo-lib-wasm
echo "== the repo's scripts, as run"
for s in build-nodejs build-browser; do echo "$s: $(node -p "require('./package.json').scripts['$s']")"; done
echo "== npm ci"
npm ci --no-audit --no-fund 2>&1 | tail -5
echo "== npm run build-nodejs"
npm run build-nodejs 2>&1 | filter
echo "== npm run build-browser"
npm run build-browser 2>&1 | filter
echo "pkg-browser entry: $(grep -m1 'import \* as wasm' pkg-browser/ergo_lib_wasm.js || echo '(no wasm import line)')"

mkdir -p "$W/pack"; rm -f "$W/pack"/*.tgz
( cd pkg-browser && npm pack --pack-destination "$W/pack" --json > "$W/pack/pack.json" )
TGZ="$W/pack/$(node -p 'require(process.argv[1])[0].filename' "$W/pack/pack.json")"
echo "tree status after build (porcelain):"; git -C "$W/sigma-rust" status --porcelain | head -5; echo "(end status)"

ver() { node -p 'const p=require(process.argv[1]);p.name+"@"+p.version' "$1/package.json"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
P="$W/sigma-rust/bindings/ergo-lib-wasm"
{
  echo "commit=$SHA"
  echo "rust_toolchain=$TC"
  echo "nodejs_package=$(ver "$P/pkg-nodejs")"
  echo "nodejs_wasm_sha256=$(sha "$P/pkg-nodejs/ergo_lib_wasm_bg.wasm")"
  echo "browser_package=$(ver "$P/pkg-browser")"
  echo "browser_wasm_sha256=$(sha "$P/pkg-browser/ergo_lib_wasm_bg.wasm")"
  echo "browser_tarball=$(basename "$TGZ")"
  echo "browser_tarball_sha256=$(sha "$TGZ")"
  echo "browser_tarball_integrity=$(node -p 'require(process.argv[1])[0].integrity' "$W/pack/pack.json")"
} > "$W/sigma-rust-build.env"
echo "== built (sigma-rust-build.env)"
cat "$W/sigma-rust-build.env"
