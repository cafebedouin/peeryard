#!/usr/bin/env bash
# topo.sh: generate a topology file for rig.sh from a shape, so a question can pick its network instead of
# hand-writing JSON.
#
#   bash rig/topo.sh <shape> <n> [--delay MS] [--loss PCT] [--jitter MS] [--rate KBIT] [--miners K] [--chain PRESET]
#                    [--bottleneck-delay MS] [--poll 500ms] > topology.json
#   shapes:  line      n nodes in a row (1-2, 2-3, ...); the first K mine
#            star      node 1 in the middle, the others attached to it; the middle mines
#            mesh      every pair linked; the first K mine
#            clusters  two full meshes of n/2 (rounded up / down), one bottleneck link between them; one miner per cluster
#   options apply to every link; --bottleneck-delay shapes only the clusters' bottleneck link. Names are N1..Nn.
#   Peers: each node's knownPeers are its link neighbours, so connectivity should equal the link set.
set -euo pipefail
shape="${1:?usage: topo.sh <line|star|mesh|clusters> <n> [options]}"; n="${2:?n}"; shift 2
delay=0; loss=0; jitter=0; rate=0; miners=1; chain=current; bdelay=""; poll=""
while [[ $# -gt 0 ]]; do case "$1" in
  --delay) delay="$2"; shift 2 ;; --loss) loss="$2"; shift 2 ;; --jitter) jitter="$2"; shift 2 ;; --rate) rate="$2"; shift 2 ;;
  --miners) miners="$2"; shift 2 ;; --chain) chain="$2"; shift 2 ;; --bottleneck-delay) bdelay="$2"; shift 2 ;; --poll) poll="$2"; shift 2 ;;
  *) echo "unknown option $1" >&2; exit 2 ;; esac; done
[[ "$n" =~ ^[0-9]+$ && "$n" -ge 2 && "$n" -le 20 ]] || { echo "n must be 2..20" >&2; exit 2; }
links=(); declare -A peers; declare -A mining
name(){ echo "N$1"; }
link(){ links+=("$1 $2 ${3:-$delay}"); peers[$1]+=" $2"; peers[$2]+=" $1"; }
case "$shape" in
  line)  for ((i=1;i<n;i++)); do link "$(name $i)" "$(name $((i+1)))"; done; for ((i=1;i<=miners&&i<=n;i++)); do mining[$(name $i)]=true; done ;;
  star)  for ((i=2;i<=n;i++)); do link "$(name 1)" "$(name $i)"; done; mining[$(name 1)]=true ;;
  mesh)  for ((i=1;i<=n;i++)); do for ((j=i+1;j<=n;j++)); do link "$(name $i)" "$(name $j)"; done; done; for ((i=1;i<=miners&&i<=n;i++)); do mining[$(name $i)]=true; done ;;
  clusters) h=$(( (n+1)/2 ))
    for ((i=1;i<=h;i++)); do for ((j=i+1;j<=h;j++)); do link "$(name $i)" "$(name $j)"; done; done
    for ((i=h+1;i<=n;i++)); do for ((j=i+1;j<=n;j++)); do link "$(name $i)" "$(name $j)"; done; done
    link "$(name 1)" "$(name $((h+1)))" "${bdelay:-$delay}"; mining[$(name 1)]=true; mining[$(name $((h+1)))]=true ;;
  *) echo "unknown shape $shape" >&2; exit 2 ;;
esac
{
  echo "{"; echo "  \"chain\": \"$chain\","; echo "  \"nodes\": ["
  for ((i=1;i<=n;i++)); do nm=$(name $i); m="${mining[$nm]:-false}"
    kp=$(for p in ${peers[$nm]:-}; do printf '"%s",' "$p"; done); kp="[${kp%,}]"
    printf '    { "name": "%s", "mining": %s%s, "knownPeers": %s }%s\n' "$nm" "$m" "$([[ $m == true && -n $poll ]] && printf ', "mine_poll": "%s"' "$poll")" "$kp" "$([[ $i -lt $n ]] && echo ,)"
  done
  echo "  ],"; echo "  \"links\": ["
  for ((k=0;k<${#links[@]};k++)); do set -- ${links[$k]}
    printf '    { "a": "%s", "b": "%s", "delay_ms": %s, "loss_pct": %s, "jitter_ms": %s, "rate_kbit": %s }%s\n' "$1" "$2" "$3" "$loss" "$jitter" "$rate" "$([[ $k -lt $((${#links[@]}-1)) ]] && echo ,)"
  done
  echo "  ]"; echo "}"
} | jq .
