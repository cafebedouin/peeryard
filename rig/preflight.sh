#!/usr/bin/env bash
# preflight.sh [nodes]: can this host run the rig? Checks, in order: bash 4.4 or later; unprivileged user + mount + net
# namespaces;
# netem shaping inside such a namespace (needs the sch_netem module); a tmpfs mounted over /run inside the
# namespace, where `ip netns` keeps its bind mounts (rig.sh does the same at start); `ip netns exec` inside such a
# namespace, the way every node, curl and tc call is made (it remounts /sys, which a container's masked /sys paths can
# refuse); an init as PID 1 when running in a container (orphans are reaped; else <defunct> children survive a run);
# the commands the rig and devnet.sh call (procps pkill/pgrep/ps, util-linux nsenter/mount among them); the Java
# runtime (PEERYARD_JAVA, default `java`) and its version; free memory against [nodes] JVMs (default 4) at
# about 350 MB each. Prints one line per check and exits 1 on any miss. No node is started; a few seconds.
set -uo pipefail
N="${1:-4}"; JAVA_BIN="${PEERYARD_JAVA:-java}"; fail=0
row(){ printf '%-34s %s\n' "$1" "$2"; }
ok(){ row "$1" "ok $2"; }; miss(){ row "$1" "MISSING $2"; fail=1; }
in_container(){ [ -f /.dockerenv ] || [ -f /run/.containerenv ] || grep -qE 'docker|containerd|podman|lxc' /proc/1/cgroup 2>/dev/null; }
hint_container(){ in_container && echo "; in a container: run it with docker/run.sh, or add --security-opt systempaths=unconfined (Docker Desktop needs it)"; }
if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then ok "bash 4.4 or later" "($BASH_VERSION)"
else miss "bash 4.4 or later" "(this is $BASH_VERSION; the scripts need 4.4 for empty-array expansion under set -u)"; fi
if unshare -Urmn true 2>/dev/null; then ok "user namespaces" "(unshare -Urmn)"
else miss "user namespaces" "(unshare -Urmn failed; Ubuntu 23.10+: sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0)"; fi
if unshare -Urmn bash -c 'ip link add v0 type veth peer name v1 && tc qdisc add dev v0 root netem delay 1ms loss 1%' 2>/dev/null; then ok "netem in a namespace" "(veth + tc qdisc netem)"
else miss "netem in a namespace" "(sudo modprobe sch_netem; iproute2 with tc)"; fi
if unshare -Urmn bash -c 'mount --make-rprivate / 2>/dev/null; mount -t tmpfs tmpfs /run && mkdir -p /run/netns && ip netns add pypreflight && ip netns del pypreflight' 2>/dev/null
then ok "tmpfs /run + ip netns" "(mount -t tmpfs over /run in the namespace)"
else miss "tmpfs /run + ip netns" "(mount -t tmpfs tmpfs /run or ip netns add failed inside unshare -Urmn)"; fi
# the call the rig makes for every node, curl and tc: `ip netns exec` remounts /sys for the namespace, which fails
# with "mount of /sys failed: Operation not permitted" where /sys carries masked paths it may not replace (Docker)
if nsx_err="$(unshare -Urmn bash -c 'mount --make-rprivate / 2>/dev/null; mount -t tmpfs tmpfs /run && mkdir -p /run/netns && ip netns add pypreflight && ip netns exec pypreflight ip link show lo >/dev/null; rc=$?; ip netns del pypreflight 2>/dev/null; exit $rc' 2>&1 >/dev/null)"
then ok "ip netns exec" "(a command ran inside a namespace)"
else miss "ip netns exec" "($(echo "$nsx_err" | tail -1 | cut -c1-80)$(hint_container))"; fi
if in_container; then
  p1="$(ps -o comm= -p 1 2>/dev/null | tr -d ' ')"
  case "$p1" in
    bash|sh|dash|zsh|"") miss "init as PID 1 (container)" "(PID 1 is '${p1:-unknown}', which does not reap orphans; <defunct> children would survive a run: use docker/run.sh, or docker run --init)" ;;
    *) ok "init as PID 1 (container)" "($p1)" ;;
  esac
fi
for c in jq curl unzip ip tc unshare nsenter mount pkill pgrep ps timeout sha256sum realpath; do command -v "$c" >/dev/null && ok "command $c" "($(command -v "$c"))" || miss "command $c" ""; done
j8=""; for c in "${JAVA8_HOME:-}" /usr/lib/jvm/java-8-* /usr/lib/jvm/java-1.8.0* /usr/lib/jvm/temurin-8-* /usr/lib/jvm/zulu8* /usr/lib/jvm/jdk1.8.0* /usr/lib/jvm/openjdk-8*; do [ -n "$c" ] && [ -x "$c/bin/java" ] && { j8="$c"; break; }; done
if [ -n "$j8" ]; then ok "JDK 8 (candidate builds only)" "($j8)"; else ok "JDK 8 (candidate builds only)" "(not found under /usr/lib/jvm; set JAVA8_HOME before diffrun/build.sh; the rig does not need it)"; fi
if command -v sbt >/dev/null; then ok "sbt (candidate builds only)" "($(command -v sbt))"; else ok "sbt (candidate builds only)" "(not found; needed by diffrun/build.sh and review/revert-check.sh only)"; fi
if command -v "$JAVA_BIN" >/dev/null; then ok "java" "($("$JAVA_BIN" -version 2>&1 | head -1); the node is built and tested on JDK 8, published runs used 21)"
else miss "java" "($JAVA_BIN not found; set PEERYARD_JAVA)"; fi
avail=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0); need=$((N * 350))
if [ "$avail" -ge "$need" ]; then ok "memory for $N nodes" "(${avail} MB available, ~${need} MB needed)"
elif [ "$avail" -ge 700 ]; then ok "memory for 2 nodes" "(${avail} MB available; the ${N}-node examples need ~${need} MB, the two-node ones ~700 MB)"
else miss "memory for $N nodes" "(${avail} MB available, ~${need} MB needed)"; fi
[ -w "${TMPDIR:-/tmp}" ] && ok "scratch dir" "(${TMPDIR:-/tmp})" || miss "scratch dir" "(${TMPDIR:-/tmp} not writable)"
[ $fail = 0 ] && echo "PREFLIGHT: OK" || echo "PREFLIGHT: FAIL"
exit $fail
