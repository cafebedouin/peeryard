# matrix-compat-2m2r-all-120s: matrix-compat-2m2r-all at a 120 s block interval (the mainnet target), so the 30 input blocks per ordering block arrive at the mainnet rate per second. The run and its PASS rule are in matrix-compat.sh.
# shellcheck source=rig/examples/matrix-compat.sh
source "$(dirname "$(readlink -f "$HOOK")")/matrix-compat.sh"
