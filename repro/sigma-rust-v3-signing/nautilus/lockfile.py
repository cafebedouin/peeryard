"""nautilus/lockfile.py: point a Nautilus checkout's ergo-lib-wasm-browser at a local tarball, changing nothing else.

usage: python3 -I lockfile.py <nautilus checkout> <tarball path relative to the checkout>

Adds a pnpm override `ergo-lib-wasm-browser: file:<tarball>` to pnpm-workspace.yaml and makes the four matching
edits in pnpm-lock.yaml (the override, the importer entry, the package entry with the tarball's sha512 integrity,
the snapshot entry), i.e. the ergo-lib lines a non-frozen `pnpm install` writes for that override. A non-frozen
install also re-resolves unrelated peer sets; this keeps the rest of the lockfile byte-identical, so the arm differs
from stock master in the library only. Every edit must match exactly once, or nothing is written.
`pnpm install --frozen-lockfile` afterwards checks the result against package.json, the overrides and the tarball.
"""
import base64
import hashlib
import os
import sys

CO, REL = sys.argv[1], sys.argv[2]
SPEC = f"file:{REL}"
with open(os.path.join(CO, REL), "rb") as f:
    integrity = "sha512-" + base64.b64encode(hashlib.sha512(f.read()).digest()).decode()
with open(os.path.join(CO, "package.json")) as f:
    dep_line = [ln.strip() for ln in f if '"ergo-lib-wasm-browser"' in ln]
print(f"package.json: {dep_line}")
print(f"tarball: {REL} {integrity}")


def edit(text, old, new, what):
    n = text.count(old)
    if n != 1:
        sys.exit(f"lockfile.py: {what}: expected 1 match, found {n}; nothing written")
    return text.replace(old, new)


ws_path = os.path.join(CO, "pnpm-workspace.yaml")
lock_path = os.path.join(CO, "pnpm-lock.yaml")
with open(ws_path) as f:
    ws = f.read()
with open(lock_path) as f:
    lock = f.read()

ws = edit(ws, "\noverrides:\n", f"\noverrides:\n  ergo-lib-wasm-browser: {SPEC}\n", "pnpm-workspace.yaml overrides")
lock = edit(lock, "\noverrides:\n", f"\noverrides:\n  ergo-lib-wasm-browser: {SPEC}\n", "lockfile overrides")
lock = edit(lock,
            "      ergo-lib-wasm-browser:\n        specifier: ^0.28.0\n        version: 0.28.0\n",
            f"      ergo-lib-wasm-browser:\n        specifier: {SPEC}\n        version: {SPEC}\n",
            "lockfile importer entry")
old_pkg = ("  ergo-lib-wasm-browser@0.28.0:\n"
           "    resolution: {integrity: sha512-cAUqywvMWEB8sd/vw+IjWJRXRSJPxpehGvH3MHJDfjGwIUHF5cJzGHnkI+eV7TMdBI+x9PILvw34ztEw3aYV3Q==}\n")
new_pkg = (f"  ergo-lib-wasm-browser@{SPEC}:\n"
           f"    resolution: {{integrity: {integrity}, tarball: {SPEC}}}\n"
           f"    version: 0.29.0\n")
lock = edit(lock, old_pkg, new_pkg, "lockfile package entry")
lock = edit(lock, "  ergo-lib-wasm-browser@0.28.0: {}\n", f"  ergo-lib-wasm-browser@{SPEC}: {{}}\n", "lockfile snapshot entry")

with open(ws_path, "w") as f:
    f.write(ws)
with open(lock_path, "w") as f:
    f.write(lock)
print("lockfile.py: 1 workspace edit, 4 lockfile edits written")
