#!/bin/sh
# Pre-seed for the labtwo_maasfix oracle case (scripts/test-vm-oracle.sh): runs
# as root on both VMs before either side. A MAAS Ubuntu 24.04 image keeps live
# entries in /etc/apt/sources.list next to /etc/apt/sources.list.d/ubuntu.sources;
# the stock cloud image has only the pointer comment. maasfix replaces the file
# with that comment, so the seed gives it something to replace.
# Env: PRESEED_ROOT  prefix for the file (default none; the self-test's fake root)
set -eu
R=${PRESEED_ROOT:-}
mkdir -p "$R/etc/apt"
cat >"$R/etc/apt/sources.list" <<'EOF'
deb http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu noble-security main restricted universe multiverse
EOF
