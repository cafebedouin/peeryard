#!/usr/bin/env bash
# build_label.sh <work-dir> <out-dir> <label> <change>
# One label of the vector diff: sigma-rust at $SIGMA_RUST_BASE with <change> applied (base | noop | pr:<N> |
# pick:<sha>), the SANTA sigma-rust runner (santa-blitzen) at $RUNNER_COMMIT built against it with the runner's
# declared lenient-parse patch, and its `emit` actuals for every leaf in $LEAVES of SANTA's vectors at
# $SANTA_COMMIT. Writes <out-dir>/actuals/<leaf>/<op>.json, <out-dir>/logs/, the runner's resolved Cargo.lock and
# <out-dir>/manifest.json (always, also on failure; `status` says how far it got). Exit 0 only when status is ok;
# 3 on a merge or cherry-pick conflict. INSTALL_RUST_TOOLCHAIN=1 lets it run `rustup toolchain install`.
set -uo pipefail
work="$1"; out="$2"; label="$3"; change="$4"
: "${SIGMA_RUST_BASE:?}" "${RUNNER_COMMIT:?}" "${SANTA_COMMIT:?}" "${LEAVES:?}"
SIGMA_RUST_URL="${SIGMA_RUST_URL:-https://github.com/ergoplatform/sigma-rust.git}"
RUNNER_URL="${RUNNER_URL:-https://github.com/mwaddip/santa-blitzen.git}"
SANTA_URL="${SANTA_URL:-https://github.com/mwaddip/santa.git}"
for c in "$SIGMA_RUST_BASE" "$RUNNER_COMMIT" "$SANTA_COMMIT"; do
  [[ "$c" =~ ^[0-9a-f]{40}$ ]] || { echo "build_label: '$c' is not a 40-hex commit" >&2; exit 1; }
done
mkdir -p "$work" "$out/actuals" "$out/logs"
work="$(cd "$work" && pwd)"; out="$(cd "$out" && pwd)"
SR="$work/sigma-rust"; RN="$work/blitzen"; SA="$work/santa"   # blitzen's path deps are ../sigma-rust/<crate>

status=started detail="" change_head="" head="" shortstat="" conflicts="" patch_sha="" rust="" rustc_v="" cargo_v=""
lock_sha="" bin_sha="" leaves_tsv="$out/logs/leaves.tsv"
: > "$leaves_tsv"
manifest() {
  jq -n --arg label "$label" --arg change "$change" --arg status "$status" --arg detail "$detail" \
    --arg base "$SIGMA_RUST_BASE" --arg change_head "$change_head" --arg head "$head" --arg shortstat "$shortstat" \
    --arg conflicts "$conflicts" --arg runner "$RUNNER_COMMIT" --arg santa "$SANTA_COMMIT" --arg patch_sha "$patch_sha" \
    --arg rust "$rust" --arg rustc "$rustc_v" --arg cargo "$cargo_v" --arg lock_sha "$lock_sha" --arg bin_sha "$bin_sha" \
    --arg host "$(uname -srm), $(nproc) cpu" --rawfile leaves "$leaves_tsv" '
    def nz: if . == "" then null else . end;
    {schema: "sigma-rust-vector-diff-manifest/1", label: $label, change: $change, status: $status, detail: ($detail|nz),
     sigma_rust_base: $base, change_head: ($change_head|nz), sigma_rust_head: ($head|nz), diff_shortstat: ($shortstat|nz),
     conflicts: ($conflicts | split("\n") | map(select(. != ""))),
     runner: {repo: "mwaddip/santa-blitzen", commit: $runner, lenient_parse_patch_sha256: ($patch_sha|nz),
              cargo_lock_sha256: ($lock_sha|nz), binary_sha256: ($bin_sha|nz)},
     santa: {repo: "mwaddip/santa", commit: $santa},
     toolchain: {rust: ($rust|nz), rustc: ($rustc|nz), cargo: ($cargo|nz)}, host: $host,
     leaves: ($leaves | split("\n") | map(select(. != "") | split("\t")
              | {key: .[0], value: {vector_files: (.[1]|tonumber), actual_files: (.[2]|tonumber),
                                    emit_exit: (.[3]|tonumber), emit_seconds: (.[4]|tonumber)}}) | from_entries)}' \
    > "$out/manifest.json"
}
trap manifest EXIT
fail() { status="$1"; detail="$2"; echo "::error::$label ($change): $2"; exit "${3:-1}"; }
g() { git -c user.name=vector-diff -c user.email=vector-diff@invalid -c advice.detachedHead=false "$@"; }

echo "== sigma-rust $SIGMA_RUST_BASE + $change"
rm -rf "$SR"
g clone -q --no-checkout "$SIGMA_RUST_URL" "$SR" || fail fetch-failed "clone of sigma-rust failed"
g -C "$SR" checkout -q --detach "$SIGMA_RUST_BASE" || fail fetch-failed "base $SIGMA_RUST_BASE not found"
case "$change" in
  base|noop) ;;
  pr:*)
    n="${change#pr:}"
    g -C "$SR" fetch -q origin "refs/pull/$n/head" || fail fetch-failed "refs/pull/$n/head not found"
    change_head="$(git -C "$SR" rev-parse FETCH_HEAD)"
    echo "PR #$n head $change_head"
    if ! g -C "$SR" merge -q --no-edit FETCH_HEAD; then
      conflicts="$(git -C "$SR" diff --name-only --diff-filter=U)"
      g -C "$SR" merge --abort
      fail merge-conflict "PR #$n (head $change_head) does not merge cleanly onto $SIGMA_RUST_BASE: ${conflicts//$'\n'/ }" 3
    fi ;;
  pick:*)
    s="${change#pick:}"
    g -C "$SR" fetch -q origin "$s" || fail fetch-failed "commit $s is not fetchable from ergoplatform/sigma-rust"
    change_head="$s"
    if ! g -C "$SR" cherry-pick "$s" >/dev/null; then
      conflicts="$(git -C "$SR" diff --name-only --diff-filter=U)"
      g -C "$SR" cherry-pick --abort
      fail pick-conflict "$s does not cherry-pick cleanly onto $SIGMA_RUST_BASE: ${conflicts//$'\n'/ }" 3
    fi ;;
  merge:*)
    r="${change#merge:}"; repo="${r%@*}"; s="${r##*@}"
    g -C "$SR" fetch -q "https://github.com/$repo.git" "$s" || fail fetch-failed "commit $s is not fetchable from $repo"
    change_head="$s"
    echo "merge $s from $repo"
    if ! g -C "$SR" merge -q --no-edit FETCH_HEAD; then
      conflicts="$(git -C "$SR" diff --name-only --diff-filter=U)"
      g -C "$SR" merge --abort
      fail merge-conflict "$s (from $repo) does not merge cleanly onto $SIGMA_RUST_BASE: ${conflicts//$'\n'/ }" 3
    fi ;;
  *) fail bad-change "unknown change '$change'" ;;
esac
head="$(git -C "$SR" rev-parse HEAD)"
shortstat="$(git -C "$SR" diff --shortstat "$SIGMA_RUST_BASE" HEAD | sed 's/^ *//')"
echo "sigma-rust HEAD $head (${shortstat:-no change against the base})"

echo "== runner santa-blitzen $RUNNER_COMMIT, SANTA $SANTA_COMMIT"
rm -rf "$RN" "$SA"
g clone -q --no-checkout "$RUNNER_URL" "$RN" && g -C "$RN" checkout -q --detach "$RUNNER_COMMIT" \
  || fail fetch-failed "runner commit $RUNNER_COMMIT not found"
g clone -q --filter=blob:none --no-checkout "$SANTA_URL" "$SA" && g -C "$SA" checkout -q --detach "$SANTA_COMMIT" \
  || fail fetch-failed "SANTA commit $SANTA_COMMIT not found"

patch="$RN/patches/sigma-rust-lenient-parse-body.patch"
patch_sha="$(sha256sum "$patch" | cut -d' ' -f1)"
git -C "$SR" apply "$patch" || fail patch-failed "the runner's lenient-parse patch does not apply on $head"
echo "lenient-parse patch applied (sha256 $patch_sha)"

rust="$(sed -n 's/^rust = "\([0-9.]*\)"$/\1/p' "$RN/mise.toml")"
[[ "$rust" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail build-failed "no rust pin in the runner's mise.toml"
if [[ "${INSTALL_RUST_TOOLCHAIN:-}" == 1 ]]; then
  rustup toolchain install "$rust" --profile minimal --no-self-update >/dev/null || fail build-failed "rustup install $rust failed"
fi
export RUSTUP_TOOLCHAIN="$rust"
rustc_v="$(rustc --version)"; cargo_v="$(cargo --version)"
echo "toolchain $rustc_v, $cargo_v"

echo "== cargo build --release (runner)"
start=$SECONDS
if ! cargo build --release --manifest-path "$RN/Cargo.toml" > "$out/logs/build.txt" 2>&1; then
  tail -60 "$out/logs/build.txt"
  fail build-failed "cargo build --release of the runner failed (logs/build.txt)"
fi
echo "built in $((SECONDS - start)) s"
cp "$RN/Cargo.lock" "$out/Cargo.lock"
lock_sha="$(sha256sum "$RN/Cargo.lock" | cut -d' ' -f1)"
bin="$RN/target/release/blitzen"
bin_sha="$(sha256sum "$bin" | cut -d' ' -f1)"

echo "== emit"
emit_bad=""
for leaf in $LEAVES; do
  [[ -d "$SA/vectors/$leaf" ]] || fail emit-failed "no vectors/$leaf in SANTA $SANTA_COMMIT"
  mkdir -p "$out/actuals/$leaf"
  start=$SECONDS
  "$bin" emit "$SA/vectors/$leaf" "$out/actuals/$leaf" > "$out/logs/emit-${leaf//\//_}.txt" 2>&1
  rc=$?
  nv=$(find "$SA/vectors/$leaf" -maxdepth 1 -type f -name '*.json' | wc -l)
  na=$(find "$out/actuals/$leaf" -maxdepth 1 -type f -name '*.json' | wc -l)
  printf '%s\t%s\t%s\t%s\t%s\n' "$leaf" "$nv" "$na" "$rc" "$((SECONDS - start))" >> "$leaves_tsv"
  echo "$leaf: emit exit $rc, $na of $nv files, $((SECONDS - start)) s"
  if [[ $rc != 0 || $na != "$nv" ]]; then emit_bad+=" $leaf"; fi
done
[[ -z "$emit_bad" ]] || fail emit-failed "emit failed or wrote too few files for:$emit_bad"
status=ok
