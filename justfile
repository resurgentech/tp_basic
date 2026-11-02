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
# `just test-container ubuntu2404 dev_base`
test-container distro container:
    bash scripts/test-container.sh {{distro}} {{container}}

# Self-test of the oracle's diff/exit logic (no docker needed).
test-container-selftest:
    bash scripts/test-container.sh --self-test

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

# Not a gate: every container of every distro's set; writes build/matrix.md.
test-matrix jobs="3":
    ANSIBLE_SHA=${ANSIBLE_SHA:-{{ported_ansible}}} bash scripts/test-matrix.sh {{jobs}}

# Goal-3 check, a proof of the SSH transport: a fresh VM made with
# ~/repos/jaredeh/vmtool, container/<container> applied twice over SSH (run 1
# exits 0, run 2 STATUS ok and CHANGED 0), then the VM deleted and checked gone
# (unless --keep is passed to the script). The comparison with the docker
# oracle's record is printed and NON-GATING: containers and VMs differ in
# structure (systemd, kernel, udev, cloud-init, a slimmer base); Ansible
# against telepatch on a VM is a separate check (test-vm-oracle, to come). Only `just test-vm ubuntu2404 dev_base`.
test-vm distro container:
    bash scripts/test-vm.sh {{distro}} {{container}}
