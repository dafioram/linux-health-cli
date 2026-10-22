# A small Debian-family image booted with systemd as PID 1, for tests/reboot-test.sh
ARG BASE=debian:bookworm
FROM ${BASE}
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      systemd systemd-sysv procps util-linux bsdutils \
 && rm -rf /var/lib/apt/lists/*
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
