# Run all repo checks on the conversion material.
check-conversion:
    bash scripts/check-conversion.sh

# Build the static x86_64 musl tp-basic into build/tp-basic and check it is static.
musl:
    #!/usr/bin/env bash
    set -euo pipefail
    cargo build --release --target x86_64-unknown-linux-musl --bin tp-basic
    mkdir -p build
    cp target/x86_64-unknown-linux-musl/release/tp-basic build/tp-basic
    info=$(file -b build/tp-basic)
    echo "file: $info"
    case "$info" in
        *"statically linked"*|*"static-pie linked"*) echo "static: yes" ;;
        *) echo "static: NO" >&2; exit 1 ;;
    esac
    build/tp-basic list

# Docker equivalence oracle: build <container>'s chain with Ansible and with
# tp-basic from one pinned base image, diff the resulting image state.
# `just test-container ubuntu2404 dev_base`. Pins the Ansible side to
# `ported_ansible` like test-acceptance (ANSIBLE_SHA overrides).
test-container distro container:
    ANSIBLE_SHA=${ANSIBLE_SHA:-{{ported_ansible}}} bash scripts/test-container.sh {{distro}} {{container}}

# Self-test of the oracle's diff/exit logic (no docker needed).
test-container-selftest:
    bash scripts/test-container.sh --self-test

# Self-tests of both oracles' comparison logic (no docker, VM or network).
test-oracle-selftest:
    bash scripts/test-container.sh --self-test
    bash scripts/test-vm-oracle.sh --self-test

# The ansible commit the ports were made from (conversion/SOURCE at port
# time). The oracle compares against it, not ansible master.
ported_ansible := "79d1ca16bfdeb678496986e1d7a0d407b06f4b45"

# Goal-1 gate: the acceptance set. ubuntu2404 and rockylinux10 for the
# default set, plus ubuntu2604 for latest_kernel_build (the latest set).
test-acceptance:
    ANSIBLE_SHA=${ANSIBLE_SHA:-{{ported_ansible}}} bash scripts/test-container.sh ubuntu2404 dev_base
    ANSIBLE_SHA=${ANSIBLE_SHA:-{{ported_ansible}}} bash scripts/test-container.sh rockylinux10 dev_base
    ANSIBLE_SHA=${ANSIBLE_SHA:-{{ported_ansible}}} bash scripts/test-container.sh ubuntu2404 kernel_build
    ANSIBLE_SHA=${ANSIBLE_SHA:-{{ported_ansible}}} bash scripts/test-container.sh rockylinux10 kernel_build
    ANSIBLE_SHA=${ANSIBLE_SHA:-{{ported_ansible}}} bash scripts/test-container.sh ubuntu2404 rust_build
    ANSIBLE_SHA=${ANSIBLE_SHA:-{{ported_ansible}}} bash scripts/test-container.sh rockylinux10 rust_build
    ANSIBLE_SHA=${ANSIBLE_SHA:-{{ported_ansible}}} bash scripts/test-container.sh ubuntu2604 latest_kernel_build

# Apply container/<container> (dev_base or rust) twice in one container of the
# pinned base image; passes when the second run shows CHANGED 0.
# `just test-idempotent ubuntu2404 dev_base`
test-idempotent distro container:
    bash scripts/test-idempotent.sh {{distro}} {{container}}

# svc proof in an init-less container (plain `sleep infinity`, `docker exec`,
# nothing privileged): desktop_services (docker, vm_server) applied twice from
# the pinned base image. Run 1 must exit 0 and show svc prepare lines (printed
# verbatim), run 2 must show CHANGED 0, and `systemctl is-enabled docker` must
# print enabled afterwards wherever systemctl exists.
# `just test-services ubuntu2404`
test-services distro:
    bash scripts/test-services.sh {{distro}}

# Not a gate: every container of every distro's set; writes build/matrix.md.
test-matrix jobs="3":
    ANSIBLE_SHA=${ANSIBLE_SHA:-{{ported_ansible}}} bash scripts/test-matrix.sh {{jobs}}

# Goal-3 check, a proof of the SSH transport: a fresh VM made with
# ~/repos/jaredeh/vmtool, container/<container> applied twice over SSH (run 1
# exits 0, run 2 STATUS ok and CHANGED 0), then the VM deleted and checked gone
# (unless --keep is passed to the script). The comparison with the docker
# oracle's record is printed and NON-GATING: containers and VMs differ in
# structure (systemd, kernel, udev, cloud-init, a slimmer base); Ansible
# against telepatch on a VM is test-vm-oracle. `just test-vm ubuntu2404 dev_base`
# or `just test-vm ubuntu2404 dev_desktop` (vars/desktop.toml, 30 GB disk, no
# oracle report; per-user working checks for bot and tpdev gate after run 2).
test-vm distro playbook:
    bash scripts/test-vm.sh {{distro}} {{playbook}}

# On demand, not part of test-acceptance: Ansible against telepatch on a VM.
# Two fresh VMs from ubuntu2404.qcow2, one at a time (the original playbook
# with ansible-playbook from this machine on one, tp-basic over SSH on the
# other), their image-state captures diffed as the docker oracle does. Outputs
# in build/test-vm-oracle/<container>-<distro>/. `ubuntu2404 dev_base`, or
# `ubuntu2404 dev_desktop_kept` (admin_users and tmux; the script writes that
# two-role playbook into its own export; captures add the user and sudoers
# sections; intended differences in tests/oracle/intended/dev_desktop_kept.txt).
test-vm-oracle distro container:
    ANSIBLE_SHA=${ANSIBLE_SHA:-{{ported_ansible}}} bash scripts/test-vm-oracle.sh {{distro}} {{container}}
