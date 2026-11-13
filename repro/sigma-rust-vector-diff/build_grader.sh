#!/usr/bin/env bash
# build_grader.sh <santa-checkout> <work-dir>
# Builds santa-grade (this directory's santa-grade/ crate) against the santa-check library of the given SANTA
# checkout: copies the crate to <work-dir>/santa-grade, links <work-dir>/santa-grade/santa to the checkout and runs
# `cargo build --release --locked`. Prints the binary's path last. Pure JSON; no sigma-rust dependency.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
santa="$(cd "$1" && pwd)"
work="$2"
[[ -f "$santa/tools/santa-check/Cargo.toml" ]] || { echo "build_grader: no tools/santa-check in $santa" >&2; exit 1; }
mkdir -p "$work"
work="$(cd "$work" && pwd)"
rm -rf "$work/santa-grade"
mkdir -p "$work/santa-grade"
cp -r "$here/santa-grade/Cargo.toml" "$here/santa-grade/Cargo.lock" "$here/santa-grade/src" "$work/santa-grade/"
ln -s "$santa" "$work/santa-grade/santa"
echo "santa-check from SANTA $(git -C "$santa" rev-parse HEAD 2>/dev/null || echo '(not a git checkout)')" >&2
cargo build --release --locked --quiet --manifest-path "$work/santa-grade/Cargo.toml" >&2
echo "$work/santa-grade/target/release/santa-grade"
