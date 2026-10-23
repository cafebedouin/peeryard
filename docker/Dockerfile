# peeryard in a container: the run card's packages (Ubuntu 24.04, iproute2 with netem, util-linux, jq, curl, unzip,
# git, python3, gh for review/pick.sh and PR threads), a Java 21 runtime for the nodes, JDK 8 plus sbt for candidate
# builds, and tini as PID 1 (orphaned processes are reaped; without an init, a finished run can leave <defunct>
# children that diffrun counts as leftovers). No credentials are baked in: docker/run.sh passes GH_TOKEN through if set.
#
# Start it with the wrapper, which carries every flag the rig needs:
#   bash docker/run.sh                       # builds the image on first use, then a shell at /peeryard
#   bash docker/run.sh -- bash rig/preflight.sh
# The flags, for a hand-written `docker run` (docker/run.sh prints the line it runs):
#   --init                                  an init as PID 1 (the image's tini does the same when --init is absent)
#   --security-opt seccomp=unconfined       the rig's own user namespace (unshare -Urmn) is blocked by the default profile
#   --security-opt apparmor=unconfined      same, on hosts with AppArmor
#   --security-opt systempaths=unconfined   `ip netns exec` remounts /sys; Docker's masked /sys paths make that
#                                           "mount of /sys failed: Operation not permitted" (seen on Docker Desktop)
# No --privileged and no root inside. The clone is mounted at /peeryard; the quick start's commands run unchanged from
# there. The container's home (/home/peer) is a mounted host directory, so jar, sbt and coursier caches survive restarts.
# The host (on Docker Desktop, its VM) must have netem: rig/preflight.sh's "netem in a namespace" row says whether it does.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg jq iproute2 util-linux procps coreutils unzip git python3 shellcheck tini gh \
      openjdk-21-jre-headless openjdk-8-jdk-headless \
    && curl -fsSL "https://github.com/sbt/sbt/releases/download/v1.11.1/sbt-1.11.1.tgz" -o /tmp/sbt.tgz \
    && mkdir -p /opt && tar -xzf /tmp/sbt.tgz -C /opt && ln -s /opt/sbt/bin/sbt /usr/local/bin/sbt \
    && rm -f /tmp/sbt.tgz && rm -rf /var/lib/apt/lists/*
# an unprivileged user: the rig creates its own user namespace from here
RUN (userdel -r ubuntu 2>/dev/null || true) && useradd -m -u 1000 -s /bin/bash peer
USER 1000
ENV JAVA8_HOME=/usr/lib/jvm/java-8-openjdk-amd64 HOME=/home/peer
WORKDIR /peeryard
# -s: when docker run --init already made docker-init PID 1, tini registers as a subreaper instead of warning
ENTRYPOINT ["/usr/bin/tini", "-s", "--"]
CMD ["bash"]
