# rig/lib/topology.sh: the one validation pass over a topology, and the CPU-list helper it shares with rig.sh. Sourced
# by rig.sh at its start; rig.sh runs validate_topology before it re-executes itself under `unshare`, so a topology that
# fails here stops the run before any namespace, veth or node exists.
#
#   validate_topology <topology.json> <default jar>
#
# Prints one `FAIL: topology <file>: <error>` line on stderr per problem found (all of them, not only the first) and
# returns 2 when there is any, 0 when there is none. <default jar> is the jar a jvm node without its own runs (the
# topology's "jar", else PEERYARD_JAR, as rig.sh resolved it; may be empty). Checked:
#   - the file is a JSON object with a non-empty "nodes" list of objects, each with a string "name"
#   - a name is 1-5 letters or digits (veth names are ve_<a>_<b>, at most 15 characters) and appears once
#   - "kind" is jvm (default), arkadianet or ergo-node-rust; a non-jvm node needs the chain preset rust-devnet; the
#     chain preset (PEERYARD_CHAIN, else "chain") is one rig.sh knows
#   - "knownPeers" is a list of names of this topology's nodes (conf.sh reads IP[<peer>] under set -u: an unknown name
#     would drop that peer and every later one from the node's config unnoticed)
#   - "links" is a list (absent = none) of objects whose "a" and "b" are distinct node names, one link per pair of
#     nodes (each link is one veth pair named after its ends), at most 236 links (each takes 10.9.<20+i>.0/30)
#   - "cpus" is a CPU list inside the rig's own affinity mask (never silently unpinned); "java_opts" only on jvm nodes
#   - each jvm node has a jar file (nodes[].jar, else <default jar>) and each other node an executable binary
#     (nodes[].bin, else PEERYARD_ARKADIANET_BIN / PEERYARD_ERGO_NODE_RUST_BIN); a "${VAR}" in a jar or bin path that
#     expands to nothing is an error, never a fall-back to the default
# A structural error (a node that is not an object, a name that is not a string) skips that node's file checks.

# cpu_ids <list>: the CPU ids of a taskset list ("0-2,5" -> 0 1 2 5), one per line
cpu_ids(){ local IFS=, part; for part in $1; do if [[ "$part" == *-* ]]; then seq "${part%-*}" "${part#*-}"; else echo "$part"; fi; done; }

# shellcheck disable=SC2016  # a jq program: $-names are jq's
_TOPO_JQ='
def names: [.nodes[] | objects | .name | strings];
def cpu_re: "^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$";
def node_errors($names; $preset):
  .nodes | to_entries[] | .key as $i | .value
  | if type != "object" then "nodes[\($i)] is not an object"
    elif (.name | type) != "string" then "nodes[\($i)].name is missing or not a string"
    else .name as $n | (.kind // "jvm") as $k
      | (if ($n | test("^[A-Za-z0-9]{1,5}$")) then empty
         else "node name \u0027\($n)\u0027 (nodes[\($i)]) must be 1-5 letters or digits (veth names are ve_<a>_<b>, at most 15 characters)" end),
        (if ($k | IN("jvm", "arkadianet", "ergo-node-rust")) then empty
         else "node \($n): unknown kind \u0027\($k | tostring)\u0027 (jvm | arkadianet | ergo-node-rust)" end),
        (if $k != "jvm" and ($k | IN("arkadianet", "ergo-node-rust")) and $preset != "rust-devnet"
         then "node \($n) is kind \($k); a non-jvm node needs the chain preset rust-devnet (its chain parameters are compiled in; preset is \u0027\($preset)\u0027)" else empty end),
        ((.knownPeers // []) as $kp
         | if ($kp | type) != "array" then "knownPeers in node \u0027\($n)\u0027 is not a list: \($kp | tojson)"
           else $kp | to_entries[] | select((.value | type) != "string" or (.value | IN($names[]) | not))
             | "unknown peer \u0027\(.value | tostring)\u0027 in nodes[\($i)].knownPeers[\(.key)] (node \u0027\($n)\u0027; knownPeers names nodes of this topology)" end),
        (if (.java_opts // "") != "" and $k != "jvm" then "node \($n): java_opts is for jvm nodes only (kind \($k))" else empty end),
        (if (.cpus // "") != "" and ((.cpus | tostring) | test(cpu_re) | not)
         then "node \($n): cpus \u0027\(.cpus | tostring)\u0027 is not a CPU list (e.g. \"2-3\" or \"0,4\")" else empty end)
    end;
def dup_names:
  [.nodes | to_entries[] | select((.value | type) == "object" and (.value.name | type) == "string") | {i: .key, n: .value.name}]
  | group_by(.n)[] | select(length > 1) | "node name \u0027\(.[0].n)\u0027 appears \(length) times (nodes[\(map(.i | tostring) | join(","))])";
def link_errors($names):
  (.links // []) as $links
  | if ($links | type) != "array" then "links is not a list"
    elif ($links | length) > 236 then "\($links | length) links: at most 236 (each takes 10.9.<20+i>.0/30)"
    else
      ($links | to_entries[] | .key as $i | .value
       | if type != "object" then "links[\($i)] is not an object"
         else (("a", "b") as $e | .[$e] as $v
               | if ($v | type) != "string" then "links[\($i)].\($e) is missing or not a string"
                 elif ($v | IN($names[]) | not) then "unknown node \u0027\($v)\u0027 in links[\($i)].\($e)"
                 else empty end),
              (if (.a | type) == "string" and .a == .b then "links[\($i)] joins node \u0027\(.a)\u0027 to itself" else empty end)
         end),
      ([$links | to_entries[] | select((.value | type) == "object" and (.value.a | type) == "string" and (.value.b | type) == "string" and .value.a != .value.b)
        | {i: .key, k: ([.value.a, .value.b] | sort | join("<->"))}]
       | group_by(.k)[] | select(length > 1)
       | "links[\(.[1:] | map(.i | tostring) | join(","))] \(if length > 2 then "repeat" else "repeats" end) links[\(.[0].i)] (\(.[0].k)): one link per pair of nodes")
    end;
if type != "object" then "the topology is not a JSON object"
elif (.nodes | type) != "array" or (.nodes | length) == 0 then "nodes is missing or not a non-empty list"
else names as $names | node_errors($names; $preset), dup_names, link_errors($names) end'

validate_topology(){ local cfg="$1" defjar="$2" errs=() preset raw_top n kind raw j rawb b cpus c affinity
  local -A ok_cpu=()
  if ! jq -e . "$cfg" >/dev/null 2>&1; then echo "FAIL: topology $cfg: not valid JSON" >&2; return 2; fi
  preset="${PEERYARD_CHAIN:-$(jq -r 'if (.chain | type) == "string" then .chain elif (.chain | type) == "object" then (.chain.preset // "current") else "current" end' "$cfg" 2>/dev/null)}"
  case "$preset" in current|matrix|devnet|rust-devnet) ;; *) errs+=("unknown chain preset '$preset' (current | matrix | devnet | rust-devnet)") ;; esac
  mapfile -t -O "${#errs[@]}" errs < <(jq -r --arg preset "$preset" "$_TOPO_JQ" "$cfg")
  # the artifacts and the CPU mask, for each node whose structure passed (an object with a valid name and kind)
  raw_top="$(jq -r 'if type == "object" then (.jar // "") else "" end' "$cfg")"
  [[ -n "$raw_top" && -z "$defjar" ]] && errs+=("\"jar\" is '$raw_top' but expands to nothing (unset variable?)")
  # the CPUs this rig may use; a third argument names them instead (tests: a shipped topology's pins are checked
  # against the host that runs it, not the one that tests the file)
  affinity="${3:-$(awk '/^Cpus_allowed_list:/ {print $2}' /proc/$$/status)}"
  for c in $(cpu_ids "$affinity"); do ok_cpu[$c]=1; done
  # shellcheck disable=SC2016  # jq programs: $ENV and $-names are jq's
  # fields joined by \x1f, not a tab: IFS whitespace (a tab) collapses empty fields, which would shift a bin into the jar's
  while IFS=$'\x1f' read -r n kind raw j rawb b cpus; do
    case "$kind" in
      jvm)
        if [[ -n "$raw" && -z "$j" ]]; then errs+=("node $n: jar is '$raw' but expands to nothing (unset variable?)")
        else j="${j:-$defjar}"; [[ -f "$j" ]] || errs+=("no node jar for $n: set nodes[].jar, \"jar\" in the topology, or PEERYARD_JAR (got '$j')"); fi ;;
      arkadianet|ergo-node-rust)
        if [[ -n "$rawb" && -z "$b" ]]; then errs+=("node $n: bin is '$rawb' but expands to nothing (unset variable?)")
        else
          if [[ -z "$b" ]]; then case "$kind" in arkadianet) b="${PEERYARD_ARKADIANET_BIN:-}" ;; ergo-node-rust) b="${PEERYARD_ERGO_NODE_RUST_BIN:-}" ;; esac; fi
          [[ -x "$b" ]] || errs+=("no node binary for $n (kind $kind): set nodes[].bin or PEERYARD_$(tr 'a-z-' 'A-Z_' <<< "$kind")_BIN (got '$b')")
        fi ;;
      *) continue ;;   # an unknown kind is reported above
    esac
    if [[ -n "$cpus" && "$cpus" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]]; then
      for c in $(cpu_ids "$cpus"); do [[ -n "${ok_cpu[$c]:-}" ]] || { errs+=("cpus outside rig affinity: node=$n requested=$cpus allowed=$affinity"); break; }; done
    fi
  done < <(jq -r 'def xp: if type == "string" then gsub("\\$\\{(?<v>[A-Za-z_][A-Za-z0-9_]*)\\}"; ($ENV[.v] // "")) else . end;
      if type == "object" and (.nodes | type) == "array" then .nodes[] else empty end
      | select(type == "object" and (.name | type) == "string" and (.name | test("^[A-Za-z0-9]{1,5}$")))
      | [.name, (.kind // "jvm" | tostring), (.jar // ""), ((.jar // "") | xp), (.bin // ""), ((.bin // "") | xp), (.cpus // "" | tostring)] | join("\u001f")' "$cfg")
  [[ ${#errs[@]} -eq 0 ]] && return 0
  for c in "${errs[@]}"; do echo "FAIL: topology $cfg: $c" >&2; done
  return 2; }
