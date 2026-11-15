#!/bin/sh
# Pre-seed for the labtwo_hashicorp_packer oracle case (scripts/test-vm-oracle.sh):
# runs as root on both VMs before either side. hashicorp_packer adds the admin
# users to `kvm` and `libvirt`, groups that exist only after vm_server. The
# Ansible vm_server role is not run in this case: its telepatch port is a
# rewrite (src/roles/vm_server.rs keeps only KVM, the libvirt daemon and
# clients, virt-install and bridge-utils; Ansible's also installs ansible,
# ruby and more), so running it would put vm_server's own differences into
# hashicorp_packer's diff. Both VMs get the port's vm_server package set
# instead (the Debian list in src/roles/vm_server.rs), which creates the
# `libvirt` group; the telepatch side's test playbook still runs vm_server
# first, and finds it done.
# Env: PRESEED_ROOT  accepted and unused (the self-test runs this with a stub apt-get)
set -eu
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
apt-get update -q
apt-get install -y -q qemu-system-x86 libvirt-daemon-system libvirt-clients virtinst bridge-utils
