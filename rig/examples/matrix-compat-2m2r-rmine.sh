# matrix-compat-2m2r-rmine: two reference and two Matrix nodes, only the reference nodes mining; links A-B, A-C, A-D, B-C, B-D, C-D. The run and its PASS rule are in matrix-compat.sh.
# shellcheck source=rig/examples/matrix-compat.sh
source "$(dirname "$(readlink -f "$HOOK")")/matrix-compat.sh"
