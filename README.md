# tp_basic

Playbooks and roles for [telepatch](https://github.com/resurgentech/telepatch):
the basic development workstation, build container and server configurations
that the [ansible](https://github.com/resurgentech/ansible) repo used to hold.

telepatch is the engine. This repo is what runs on it, the way a playbook
repo relates to Ansible itself.

**Status:** being ported. The Ansible originals are pulled into
`conversion/` as they are worked on, each with a short document of what the
playbook and its roles are for, whether the methods they use are still the
right ones, and the decisions made. A role leaves `conversion/` when its
telepatch version exists; the understanding goes into the code as comments.

**Over SSH:** `just test-vm ubuntu2404 dev_base` creates a fresh Ubuntu 24.04
VM with `~/repos/jaredeh/vmtool` (named `tp-dev_base-<UTC stamp>`), runs
`tp-basic run container/dev_base --host bot@<ip> --ssh-key <vmtool's key>`
against it twice, and deletes the VM. It proves the SSH transport: it passes
when the first run exits 0 and the second reports `STATUS ok`, `CHANGED 0`.
It also prints a non-gating comparison with the docker oracle's record (if
`just test-container ubuntu2404 dev_base` has been run): containers and VMs
differ in structure (systemd, kernel, udev, cloud-init, a slimmer base), so
the packages a useful playbook adds cannot match 1:1; Ansible against
telepatch on a VM is a separate check (`just test-vm-oracle`, to come). Outputs land in
`build/test-vm/dev_base-ubuntu2404/`; `scripts/test-vm.sh --self-test` checks
the report alone.
