# peeryard in a container: the run card's packages (Ubuntu 24.04, iproute2 with netem, util-linux, jq, curl, unzip,
# git, python3), a Java 21 runtime for the nodes, and JDK 8 plus sbt for candidate builds. The rig still needs
# unprivileged user namespaces, which Docker's default seccomp and AppArmor profiles block, so run it with
#   docker build -t peeryard docker/
#   docker run --rm -it --security-opt seccomp=unconfined --security-opt apparmor=unconfined -v "$PWD":/peeryard peeryard
# (no --privileged, no root inside; the host must have sch_netem loaded: `sudo modprobe sch_netem`). The clone is
# mounted at /peeryard; the quick start's commands run unchanged from there. Jar caches persist in the mount.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg jq iproute2 util-linux procps coreutils unzip git python3 shellcheck \
      openjdk-21-jre-headless openjdk-8-jdk-headless \
    && curl -fsSL "https://github.com/sbt/sbt/releases/download/v1.11.1/sbt-1.11.1.tgz" -o /tmp/sbt.tgz \
    && mkdir -p /opt && tar -xzf /tmp/sbt.tgz -C /opt && ln -s /opt/sbt/bin/sbt /usr/local/bin/sbt \
    && rm -f /tmp/sbt.tgz && rm -rf /var/lib/apt/lists/*
# an unprivileged user: the rig creates its own user namespace from here
RUN (userdel -r ubuntu 2>/dev/null || true) && useradd -m -u 1000 -s /bin/bash peer
USER 1000
ENV JAVA8_HOME=/usr/lib/jvm/java-8-openjdk-amd64 HOME=/home/peer
WORKDIR /peeryard
CMD ["bash"]
