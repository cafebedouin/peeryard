# bringup-phases: bringup.sh's claim as data (rig/PHASES.md). A mines and B follows over the veth: B must be on A's
# chain (same_chain SAME at a height of at least 3) within 90 s, the connected peers must match the topology, and a
# live netem change must apply (a tc failure is a harness failure, INCONCLUSIVE, as in bringup.sh).
#   PHASES_INVERT=1   adds a pass whose expected token is flipped (DIFF after B has synced): the run must FAIL, naming it
# shellcheck source=rig/lib/phases.sh
source "$(dirname "$(readlink -f "$HOOK")")/../lib/phases.sh"
phases <<EOF
wait same_chain A B SAME >= 3 timeout 90
pass topology: topology
link_netem A B delay 40ms
when PHASES_INVERT=1 pass inverted: same_chain A B DIFF
EOF
