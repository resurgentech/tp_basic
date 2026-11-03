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
telepatch on a VM is `just test-vm-oracle`. Outputs land in
`build/test-vm/dev_base-ubuntu2404/`; `scripts/test-vm.sh --self-test` checks
the report alone.

**Ansible against telepatch on a VM:** `just test-vm-oracle ubuntu2404 dev_base`
(on demand; not part of `test-acceptance`) proves that the original Ansible
playbook and `tp-basic` do the same thing on the base that is actually
deployed to. It creates two fresh VMs from the same image, one at a time
(about twice the time of `test-vm`, since each VM is created, onboarded and
provisioned in turn): the first gets `ansible-playbook` (from this machine,
as `bot` with become, on the `../ansible` commit `ported_ansible`, exported
with `git archive`), the second gets `tp-basic run --host`. Each side runs
twice, the second pass on the converged host, and both passes are timed
from this machine; `timings.txt` tabulates first-run and second-run wall
clock and what the second pass still reported as changed (informational).
It deletes each VM after capturing its state, and fails on any difference
between `ansible.state` and `telepatch.state` (versions are informational).
Outputs land in `build/test-vm-oracle/dev_base-ubuntu2404/`;
`scripts/test-vm-oracle.sh --self-test` checks the diff, the inventory
writer and the timing table alone.
