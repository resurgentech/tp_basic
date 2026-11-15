#!/bin/sh
# Pre-seed for the src_repos oracle case (T158 adds the case to
# scripts/test-vm-oracle.sh; oracle_config does not accept labtwo_src_repos
# yet, so nothing runs this script today). Runs as root on both VMs. The old
# labtwo result: a separate /etc/apt/sources.list.d/ubuntu-src.sources with
# deb-src entries, which the port removes (it sets deb-src on the distro's own
# sources file instead).
# Env: PRESEED_ROOT  prefix for the file (default none; the self-test's fake root)
set -eu
R=${PRESEED_ROOT:-}
mkdir -p "$R/etc/apt/sources.list.d"
cat >"$R/etc/apt/sources.list.d/ubuntu-src.sources" <<'EOF'
Types: deb-src
URIs: http://archive.ubuntu.com/ubuntu
Suites: noble noble-updates noble-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
