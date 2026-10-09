#!/usr/bin/env bash
# ci/rig-setup-check.sh <rig exit code> <run dir>: a workflow's guard after `bash rig/rig.sh`. A rig that exits 2
# (a setup error: bad input, missing jar, a node that never answered at bring-up) or leaves no node log behind did
# not run the experiment, which is neither a verdict nor a pass. Then it writes <run dir>/SETUP-ERROR (the reason and
# the rig log's last lines) and exits 1, so the job fails; any other exit code (0 PASS, 1 FAIL, 3 INCONCLUSIVE: the
# experiment ran) exits 0 and leaves the run as before. Node logs are looked for where patch-compare keeps them
# (<run dir>/nodes/node_*.log.gz) and in the rig's output (<run dir>/scratch/out/node_*.log).
rc="${1:?usage: rig-setup-check.sh <rig exit code> <run dir>}"; run="${2:?usage: rig-setup-check.sh <rig exit code> <run dir>}"
why=""
[[ "$rc" == 2 ]] && why="rig exit 2 (setup error)"
if [[ -z "$why" ]] && ! compgen -G "$run/nodes/node_*.log.gz" >/dev/null && ! compgen -G "$run/scratch/out/node_*.log" >/dev/null; then
  why="no node log: no node started (rig exit $rc)"; fi
[[ -z "$why" ]] && exit 0
{ echo "SETUP-ERROR: $why"; [[ -f "$run/rig.log" ]] && { echo "--- rig.log (last 5 lines)"; tail -5 "$run/rig.log"; }; } | tee "$run/SETUP-ERROR"
exit 1
