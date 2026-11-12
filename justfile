# Run all repo checks on the conversion material.
check-conversion:
    bash scripts/check-conversion.sh

# Review playbooks/edge against the edge list, then syntax-check it. No VM.
check-edge:
    bash scripts/check-edge-playbook.sh
    ansible-playbook --syntax-check playbooks/edge/edge.yml

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

# The dist ../docker_images builds images with (bake context `tp`, TP_DIST
# overrides): build/dist/{tp-basic, vars/container.toml, PROVENANCE}. The
# binary is built as `just musl` builds it; PROVENANCE names this repo's URL
# and commit, the [patch] telepatch commit (each `_dirty` when its tree has
# changes), the binary's sha256 and rustc. The recipe prints the file and
# fails on a missing field. `just dist`
dist:
    bash scripts/dist.sh

# Self-tests of the comparison logic (scripts/lib/compare.sh), the VM oracle,
# test-vm.sh, docker-vm.sh's arguments and the docker guard (no daemon, VM or
# network: a stub docker). The production acceptance runners were retired.
test-oracle-selftest:
    bash scripts/lib/compare.sh --self-test
    bash scripts/test-vm-oracle.sh --self-test
    bash scripts/test-vm.sh --self-test
    bash scripts/docker-vm.sh --self-test
    bash scripts/lib/docker-guard.sh --self-test

# Run a docker recipe of this justfile against the daemon of a fresh 1 GiB
# tp-* VM (scripts/docker-vm.sh: docker.io in ubuntu2404, the socket forwarded
# over ssh, the VM deleted afterwards). Every docker recipe refuses to run
# outside it (exit 2). `just docker-vm test-services ubuntu2404`
docker-vm +recipe:
    bash scripts/docker-vm.sh run -- just {{recipe}}

# The ansible commit the ports were made from (conversion/SOURCE at port
# time). The oracle compares against it, not ansible master.
ported_ansible := "79d1ca16bfdeb678496986e1d7a0d407b06f4b45"

# The docker_images commit the oracle's Ansible side is built from: its
# docker-bake.hcl, Dockerfiles/ansible.* and build context are exported from
# this commit with `git archive` (build/docker_images/<sha>/), never read from
# the sibling's working tree. DI_SHA overrides.
ported_docker_images := "5df316b67429370105efec0e5c5ac29a6ccbd71a"

# Apply container/<container> (dev_base, rust or latest_kernel_build, the last
# on ubuntu2604 only) twice in one container of the pinned base image; passes
# when the second run shows CHANGED 0.
# `just test-idempotent ubuntu2404 dev_base`
test-idempotent distro container:
    bash scripts/lib/docker-guard.sh
    DI_SHA=${DI_SHA:-{{ported_docker_images}}} bash scripts/test-idempotent.sh {{distro}} {{container}}

# svc proof in an init-less container (plain `sleep infinity`, `docker exec`,
# nothing privileged): desktop_services (docker, vm_server) applied twice from
# the pinned base image. Run 1 must exit 0 and show svc prepare lines (printed
# verbatim), run 2 must show CHANGED 0, and `systemctl is-enabled docker` must
# print enabled afterwards wherever systemctl exists.
# `just test-services ubuntu2404`
test-services distro:
    bash scripts/lib/docker-guard.sh
    DI_SHA=${DI_SHA:-{{ported_docker_images}}} bash scripts/test-services.sh {{distro}}

# Goal-3 check, a proof of the SSH transport: a fresh VM made with
# ~/repos/jaredeh/vmtool, container/<container> applied twice over SSH (run 1
# exits 0, run 2 STATUS ok and CHANGED 0), then the VM deleted and checked gone
# (unless --keep is passed to the script). The production acceptance runner
# was retired; this script does not compare against a container record.
# Ansible against telepatch on a VM is test-vm-oracle. `just test-vm ubuntu2404 dev_base`
# or `just test-vm ubuntu2404 dev_desktop` (vars/desktop.toml, 30 GB disk;
# per-user working checks for bot and tpdev gate after run 2).
test-vm distro playbook:
    bash scripts/test-vm.sh {{distro}} {{playbook}}

# On demand: Ansible against telepatch on a VM. The production acceptance
# runner was retired. Not part of any default gate.
# Two fresh VMs from ubuntu2404.qcow2, one at a time (the original playbook
# with ansible-playbook from this machine on one, tp-basic over SSH on the
# other), their image-state captures diffed as the docker oracle does. Outputs
# in build/test-vm-oracle/<container>-<distro>/. `ubuntu2404 dev_base`, or
# `ubuntu2404 dev_desktop_kept` (admin_users and tmux; the script writes that
# two-role playbook into its own export; captures add the user and sudoers
# sections; intended differences in tests/oracle/intended/dev_desktop_kept.txt).
test-vm-oracle distro container:
    ANSIBLE_SHA=${ANSIBLE_SHA:-{{ported_ansible}}} bash scripts/test-vm-oracle.sh {{distro}} {{container}}
