# matrix-compat-m2: two Matrix miners; links A-B. The run and its PASS rule are in matrix-compat.sh.
# shellcheck source=rig/examples/matrix-compat.sh
source "$(dirname "$(readlink -f "$HOOK")")/matrix-compat.sh"
