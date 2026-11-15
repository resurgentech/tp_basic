#!/bin/sh
# Pre-seed for the labtwo_cuda oracle case (scripts/test-vm-oracle.sh): runs as
# root on both VMs before either side. The Ansible role's toolkit task notifies
# `systemctl restart docker`, which fails where no docker unit exists, so both
# VMs get docker.io first (a host that runs the cuda role has docker, as the
# playbook's docker role precedes it on servers).
# Env: PRESEED_ROOT  accepted and unused (the self-test runs this with a stub apt-get)
set -eu
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
apt-get update -q
apt-get install -y -q docker.io
