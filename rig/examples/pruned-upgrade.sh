# pruned-upgrade: pruned-restart.sh with pruned-upgrade.json, where C runs the baseline (PEERYARD_JAR_B) before its stop
# and the candidate (PEERYARD_JAR) after it. Everything else, and the checks, are pruned-restart.sh's.
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/pruned-restart.sh"
