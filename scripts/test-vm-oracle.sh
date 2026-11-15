#!/usr/bin/env bash
# VM equivalence check, on demand: Ansible against telepatch on the base that
# is actually deployed to. Two fresh VMs from the same image (ubuntu2404.qcow2
# with ~/repos/jaredeh/vmtool), one at a time: the first gets the original
# Ansible playbook (ansible-playbook from this machine, as bot with become),
# the second gets `tp-basic run --host`. Their scripts/image-state.sh captures
# are diffed by scripts/lib/compare.sh. The production acceptance runner was
# retired. Not part of any default gate.
#
#   scripts/test-vm-oracle.sh [--keep] <distro> <container>   (ubuntu2404; dev_base, dev_desktop_kept or
#                                  labtwo_<role>: maasfix, systemd_time, root_user, hashicorp_packer,
#                                  h11ssl_reboot_fix, cuda)
#   scripts/test-vm-oracle.sh --self-test
#
# Env: ANSIBLE_SHA  the ../ansible commit to run (default: conversion/SOURCE's).
#      It is exported with `git archive`; ../ansible is only read.
# Needs: build/tp-basic (`just musl`), vars/container.toml, vmtool,
#        ansible-playbook on this machine.
#
# labtwo_<role>: one role of ansible_labtwo_2's labtwo.yml. A wrapper playbook
# (hosts all, the role) is written into the export, as for dev_desktop_kept. An
# optional pre-seed script (scripts/oracle-preseed/<case>.sh) runs as root on
# both VMs before the pre-state capture: maasfix a MAAS-style sources.list, cuda
# docker.io, hashicorp_packer vm_server's packages (for its groups). The tp-basic
# playbook of the same name is added by T151-T156.
#
# Each side runs twice on its VM: the first run does the work, the second
# should change nothing. Both are timed (wall clock, from this machine) and
# the second run's "changed" count is recorded, so the two tools can be
# compared on a fresh host and on a converged one. The states are captured
# after the second run.
#
# Exit: 2 on usage or environment problems (unknown commit, no VM IP, no
# onboarding); 1 when ansible-playbook or tp-basic fails, on a gating diff of
# ansible.state against telepatch.state, or when a VM of this run is still
# listed after the cleanup. Versions, timings and the second run's changed
# count are informational; whether the two pre-states match is printed, not
# gated.
#
# The VMs are tp-<container>-ansible-<UTC stamp> and
# tp-<container>-telepatch-<UTC stamp> (each `_` of the container as `-`:
# dev_desktop_kept -> tp-dev-desktop-kept-...); each is deleted after its side, and a
# trap deletes whichever still exists on every exit, unless --keep. The SSH key
# is vmtool's, used in place from .machines/veritech04/<vm>/; the inventory
# names its path. The guest is reached through vmtool's tunnel: a ProxyCommand
# in the inventory's ansible_ssh_common_args and in tp-basic's --ssh-option
# (scripts/lib/vm.sh). Each VM is created, commissioned and checked first.
#
# Outputs (gitignored): build/test-vm-oracle/<container>-<distro>/
#   ansible-src/ (with inventories/vm.yml), ansible-version.txt, ansible{,2}.log,
#   telepatch{,2}.jsonl, telepatch{,2}.out, {ansible,telepatch}-{create,onboard,wait,prep}.log,
#   {ansible,telepatch}-pre.state, {ansible,telepatch}.{state,versions},
#   gating.diff, versions.diff, pre.diff, comparison.txt, timings.txt, known_hosts
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ANSIBLE_REPO=$ROOT/../ansible
VM_TAG=test-vm-oracle

die() { echo "test-vm-oracle: $*" >&2; exit 2; }

# shellcheck source=lib/vm.sh
source "$ROOT/scripts/lib/vm.sh"
# compare_captures and intended_for (scripts/lib/compare.sh)
# shellcheck source=lib/compare.sh
source "$ROOT/scripts/lib/compare.sh"

# ---- the comparison (also used by --self-test) -------------------------------

# compare_pre <dir> : NON-GATING. Whether ansible-pre.state and
# telepatch-pre.state are identical; when not, their diff, which explains a
# post diff caused by the environment rather than the roles.
compare_pre() {
    local dir=$1
    if diff -u --label ansible-pre.state --label telepatch-pre.state "$dir/ansible-pre.state" "$dir/telepatch-pre.state" >"$dir/pre.diff"; then
        echo "NON-GATING: pre-states identical (both VMs started from the same state)"
    else
        echo "NON-GATING: pre-states differ (ansible VM vs telepatch VM before the runs):"
        cat "$dir/pre.diff"
    fi
}

# oracle_compare <dir> [<intended file> [<distro>]] : compare_pre, then compare_captures,
# printed and written to <dir>/comparison.txt. Returns compare_captures' code.
oracle_compare() {
    local dir=$1 rc=0
    compare_pre "$dir" >"$dir/comparison.txt"
    compare_captures "$dir" "${2:-}" "${3:-}" >>"$dir/comparison.txt" || rc=$?
    cat "$dir/comparison.txt"
    return $rc
}

# ---- timings ------------------------------------------------------------------

# now_s : seconds since the epoch, with the fraction (bash 5's EPOCHREALTIME).
now_s() { echo "$EPOCHREALTIME"; }

# fmt_secs <seconds> : "4m35.4s" or "2.1s".
fmt_secs() {
    awk -v s="$1" 'BEGIN { if (s >= 60) printf "%dm%04.1fs\n", int(s / 60), s - 60 * int(s / 60); else printf "%.1fs\n", s }'
}

# timings_table <file> <a1> <a2> <ac> <t1> <t2> <tc> : writes and prints the
# table. a1/t1 are the first-run seconds, a2/t2 the second-run seconds, ac/tc
# the second run's changed count on each side.
timings_table() {
    local file=$1 a1=$2 a2=$3 ac=$4 t1=$5 t2=$6 tc=$7
    {
        echo "TIMINGS (non-gating; wall clock from this machine, ssh included):"
        printf '  %-10s %12s %12s   %s\n' side "first run" "second run" "changed on the second run"
        printf '  %-10s %12s %12s   %s\n' ansible "$(fmt_secs "$a1")" "$(fmt_secs "$a2")" "$ac"
        printf '  %-10s %12s %12s   %s\n' telepatch "$(fmt_secs "$t1")" "$(fmt_secs "$t2")" "$tc"
    } | tee "$file"
}

# ansible_changed <log> : the changed= count from the PLAY RECAP, or "?".
ansible_changed() {
    sed -n '/^PLAY RECAP/,$p' "$1" | sed -n 's/.*changed=\([0-9]*\).*/\1/p' | head -1 | grep . || echo "?"
}

# telepatch_changed <out> : the CHANGED column of the host row, or "?".
telepatch_changed() {
    awk '/^HOST +STATUS/ { for (i = 1; i <= NF; i++) if ($i == "CHANGED") c = i; next }
         c && NF >= c && !done { print $c; done = 1 }
         END { if (!done) print "?" }' "$1"
}

# write_inventory <file> <vm name> <key path> <known_hosts> : the Ansible
# inventory for one VM. It names the key's path, never its contents. The host
# is reached by its VM name (ansible_host: <vm name>, never resolved: the
# ProxyCommand, vmtool's tunnel, is VM_PROXY_COMMAND). ansible_ssh_common_args
# is shlex-split by Ansible, so the ProxyCommand is one double-quoted word
# (its inner single quotes are literal there; the quotes around it are \" in
# the YAML string). vm_proxy_command admits no character that breaks this.
write_inventory() {
    local file=$1 host=$2 key=$3 kh=$4
    {
        echo "# Written by scripts/test-vm-oracle.sh for one VM of one run."
        echo "all:"
        echo "  hosts:"
        echo "    $host:"
        echo "      ansible_host: $host"
        echo "      ansible_user: bot"
        echo "      ansible_become: true"
        echo "      ansible_ssh_private_key_file: $key"
        echo "      ansible_python_interpreter: /usr/bin/python3"
        echo "      ansible_ssh_common_args: \"-o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$kh -o \\\"ProxyCommand=$VM_PROXY_COMMAND\\\"\""
    } >"$file"
}

# tpb_ssh_args <key> <known_hosts> : fills TPB_SSH_ARGS, the ssh arguments of
# `tp-basic run --host bot@<vm>`. The guest is reached through vmtool's tunnel:
# VM_PROXY_COMMAND (scripts/lib/vm.sh) is the ProxyCommand option, which the
# telepatch ssh master takes as an ordinary option (only mux channels override
# ProxyCommand, with their own, to reuse the master).
tpb_ssh_args() {
    TPB_SSH_ARGS=(--ssh-key "$1" --ssh-option StrictHostKeyChecking=accept-new
        --ssh-option UserKnownHostsFile="$2" --ssh-option "ProxyCommand=$VM_PROXY_COMMAND")
}

# oracle_config <container> : the allowlist. Sets OC_PLAYBOOK (the Ansible
# playbook, relative to the export), OC_TP (the tp-basic playbook), OC_VARS,
# OC_EXTRA (ansible --extra-vars JSON), OC_USERS (image-state.sh --users,
# empty for none), OC_ROLES (the Ansible roles of a wrapper playbook written
# into the export, space-separated and in order; empty when OC_PLAYBOOK is a
# playbook of the export) and OC_PRESEED (a script under scripts/oracle-preseed/
# run as root on both VMs before either side, empty for none). Returns 1 for
# any other name.
#
# labtwo_<role>: one role of ansible_labtwo_2/playbooks/labtwo.yml, the case
# name lowercase because the VM name allows only tp-[a-z0-9-]+ (so the role
# dir H11SSL_reboot_fix is case labtwo_h11ssl_reboot_fix). OC_TP is the
# tp-basic test playbook of the same name (T151-T156 add them). OC_VARS is
# vars/container.toml until a step adds a vars file of its own (cuda's small
# lists: vars/labtwo_cuda.toml, T156; hashicorp_packer's login user:
# vars/labtwo_hashicorp_packer.toml, T154).
#
# dev_desktop_kept: the roles of playbooks/dev_desktop.yml that were kept as
# ports, admin_users and tmux (the others were rewritten and have no Ansible
# side to diff, and the real playbook needs unpinned Galaxy roles). The
# playbook is written into this run's export only; ../ansible is not touched.
oracle_config() {
    OC_ROLES= OC_PRESEED=
    local pre=scripts/oracle-preseed
    case $1 in
        labtwo_maasfix)
            OC_PLAYBOOK=playbooks/tp_labtwo_maasfix.yml OC_TP=labtwo_maasfix OC_VARS=vars/container.toml
            OC_EXTRA='{}' OC_USERS= OC_ROLES=maasfix OC_PRESEED=$pre/labtwo_maasfix.sh ;;
        labtwo_systemd_time)
            OC_PLAYBOOK=playbooks/tp_labtwo_systemd_time.yml OC_TP=labtwo_systemd_time OC_VARS=vars/container.toml
            OC_EXTRA='{"iana_tz":"America/Los_Angeles"}' OC_USERS= OC_ROLES=systemd_time ;;
        labtwo_root_user)
            OC_PLAYBOOK=playbooks/tp_labtwo_root_user.yml OC_TP=labtwo_root_user OC_VARS=vars/container.toml
            OC_EXTRA='{}' OC_USERS= OC_ROLES=root_user ;;
        labtwo_hashicorp_packer)
            # the tp side's vars file names the same login user as the extra vars;
            # vm_server's groups come from the pre-seed on both VMs (the Ansible
            # vm_server is not run: its port is a rewrite, see the pre-seed)
            OC_PLAYBOOK=playbooks/tp_labtwo_hashicorp_packer.yml OC_TP=labtwo_hashicorp_packer OC_VARS=vars/labtwo_hashicorp_packer.toml
            OC_EXTRA='{"admin_users":["bot"]}' OC_USERS= OC_ROLES=hashicorp_packer OC_PRESEED=$pre/labtwo_hashicorp_packer.sh ;;
        labtwo_h11ssl_reboot_fix)
            OC_PLAYBOOK=playbooks/tp_labtwo_h11ssl_reboot_fix.yml OC_TP=labtwo_h11ssl_reboot_fix OC_VARS=vars/container.toml
            OC_EXTRA='{}' OC_USERS= OC_ROLES=H11SSL_reboot_fix ;;
        labtwo_cuda)
            # small lists (no driver, so no `restart host`; one package from the
            # archive) keep the run short; the tp side sets the same in its vars file
            OC_PLAYBOOK=playbooks/tp_labtwo_cuda.yml OC_TP=labtwo_cuda OC_VARS=vars/labtwo_cuda.toml
            OC_EXTRA='{"nvidia_driver_packages":[],"cuda_packages":["nvtop"]}' OC_USERS= OC_ROLES=cuda OC_PRESEED=$pre/labtwo_cuda.sh ;;
        dev_base)
            OC_PLAYBOOK=playbooks/container/dev_base.yml OC_TP=container/dev_base OC_VARS=vars/container.toml
            OC_EXTRA='{"admin_users":["root"],"vnc_users":["root"],"full_users":["root"]}' OC_USERS= ;;
        dev_desktop_kept)
            OC_PLAYBOOK=playbooks/tp_dev_desktop_kept.yml OC_TP=dev_desktop_kept OC_VARS=vars/desktop.toml
            OC_EXTRA='{"admin_users":["bot","tpdev"],"default_password":""}' OC_USERS=bot,tpdev ;;
        *) return 1 ;;
    esac
}

# write_kept_playbook <file> : the two-role playbook for dev_desktop_kept, with
# the original's hosts and remote_user (the inventory's ansible_user and
# become decide the connection, as for dev_base).
write_kept_playbook() {
    printf '%s\n' '---' '# Written by scripts/test-vm-oracle.sh: the kept roles of playbooks/dev_desktop.yml.' \
        '- name: dev_desktop, kept roles' '  hosts: all' '  remote_user: root' '  roles:' '    - admin_users' '    - tmux' >"$1"
}

# ---- the labtwo cases (also used by --self-test) -----------------------------

# selftest_labtwo <scratch dir> : the six labtwo cases, their wrapper playbooks,
# the pre-seed scripts and the image-state.sh single-file sections. Returns 1
# on any failure. Nothing here reads the real /etc: image-state.sh runs on a
# fake root (IMAGE_STATE_ROOT) with a stub sshd, the seed scripts on a fake
# root (PRESEED_ROOT) with a stub apt-get.
selftest_labtwo() {
    local t=$1 fails=0 got c role want side
    # case -> "playbook|tp|vars|roles|preseed" (extra is checked below)
    local -A expect=(
        [labtwo_maasfix]='playbooks/tp_labtwo_maasfix.yml|labtwo_maasfix|vars/container.toml|maasfix|scripts/oracle-preseed/labtwo_maasfix.sh'
        [labtwo_systemd_time]='playbooks/tp_labtwo_systemd_time.yml|labtwo_systemd_time|vars/container.toml|systemd_time|'
        [labtwo_root_user]='playbooks/tp_labtwo_root_user.yml|labtwo_root_user|vars/container.toml|root_user|'
        [labtwo_hashicorp_packer]='playbooks/tp_labtwo_hashicorp_packer.yml|labtwo_hashicorp_packer|vars/labtwo_hashicorp_packer.toml|hashicorp_packer|scripts/oracle-preseed/labtwo_hashicorp_packer.sh'
        [labtwo_h11ssl_reboot_fix]='playbooks/tp_labtwo_h11ssl_reboot_fix.yml|labtwo_h11ssl_reboot_fix|vars/container.toml|H11SSL_reboot_fix|'
        [labtwo_cuda]='playbooks/tp_labtwo_cuda.yml|labtwo_cuda|vars/labtwo_cuda.toml|cuda|scripts/oracle-preseed/labtwo_cuda.sh'
    )
    for c in "${!expect[@]}"; do
        got=$(oracle_config "$c" && echo "$OC_PLAYBOOK|$OC_TP|$OC_VARS|$OC_ROLES|$OC_PRESEED")
        if [[ $got == "${expect[$c]}" ]]; then echo "ok   oracle_config $c"; else echo "FAIL oracle_config $c -> '$got'"; fails=1; fi
        # the VM names of both sides pass vm.sh's guard (lowercase, no `_`)
        for side in ansible telepatch; do
            got=$(vm_name_for "$c" "$side" 20261114t051210z)
            vm_name_ok "$got" || { echo "FAIL vm name '$got' refused by vm_name_ok"; fails=1; }
        done
    done
    got=$(oracle_config labtwo_systemd_time && echo "$OC_EXTRA")
    [[ $got == '{"iana_tz":"America/Los_Angeles"}' ]] || { echo "FAIL systemd_time extra: $got"; fails=1; }
    got=$(oracle_config labtwo_hashicorp_packer && echo "$OC_EXTRA")
    [[ $got == '{"admin_users":["bot"]}' ]] || { echo "FAIL hashicorp_packer extra: $got"; fails=1; }
    # both sides get the same admin_users (the extra vars' and the vars file's)
    got=$(sed -n 's/^admin_users *= *//p' "$ROOT/vars/labtwo_hashicorp_packer.toml")
    [[ $got == '["bot"]' ]] || { echo "FAIL hashicorp_packer vars file admin_users: $got"; fails=1; }
    got=$(oracle_config labtwo_cuda && echo "$OC_EXTRA")
    [[ $got == *'"nvidia_driver_packages":[]'* && $got == *'"cuda_packages":["nvtop"]'* ]] || { echo "FAIL cuda extra (small lists): $got"; fails=1; }
    # the old cases are unchanged by the new fields: no roles, no pre-seed
    got=$(oracle_config dev_base && echo "[$OC_ROLES][$OC_PRESEED]")
    [[ $got == '[][]' ]] || { echo "FAIL dev_base has roles or a pre-seed: $got"; fails=1; }
    for c in labtwo_H11SSL_reboot_fix labtwo_zsh labtwo_ labtwo_src_repos; do
        if (oracle_config "$c") >/dev/null 2>&1; then echo "FAIL oracle_config accepted $c"; fails=1; fi
    done
    echo "ok   oracle_config refuses uppercase, unknown and not-yet-added labtwo cases"

    # wrapper playbooks: hosts all, remote_user root, the roles in order
    mkdir -p "$t/wrap"
    for c in "${!expect[@]}"; do
        oracle_config "$c"
        write_role_playbook "$t/wrap/$c.yml" $OC_ROLES
        want=$(printf '%s\n' '---' '# Written by scripts/test-vm-oracle.sh: one labtwo role of ansible_labtwo_2/playbooks/labtwo.yml.' \
            "- name: labtwo, ${OC_ROLES##* }" '  hosts: all' '  remote_user: root' '  roles:'
            for role in $OC_ROLES; do echo "    - $role"; done)
        if [[ $(cat "$t/wrap/$c.yml") == "$want" ]]; then echo "ok   wrapper playbook $c"
        else echo "FAIL wrapper playbook $c:"; sed 's/^/     | /' "$t/wrap/$c.yml"; fails=1; fi
    done
    grep -qx '    - H11SSL_reboot_fix' "$t/wrap/labtwo_h11ssl_reboot_fix.yml" || { echo "FAIL h11ssl wrapper lacks the real role dir name"; fails=1; }
    # vm_server is a rewrite with no Ansible equivalent: the pre-seed stands in
    if [[ $(grep -n '^    - ' "$t/wrap/labtwo_hashicorp_packer.yml" | tr '\n' ' ') == '7:    - hashicorp_packer ' ]]
    then echo "ok   hashicorp_packer wrapper: the role alone"; else echo "FAIL hashicorp_packer wrapper roles"; fails=1; fi

    # the pre-seed scripts, on a fake root with a stub apt-get on PATH
    local r=$t/seed-root bin=$t/seed-bin
    mkdir -p "$r/etc/apt/sources.list.d" "$bin"
    printf '%s\n' '#!/bin/sh' 'echo "apt-get $*" >>"$APT_LOG"' >"$bin/apt-get"; chmod +x "$bin/apt-get"
    for c in labtwo_maasfix labtwo_cuda labtwo_src_repos labtwo_hashicorp_packer; do
        sh -n "$ROOT/scripts/oracle-preseed/$c.sh" || { echo "FAIL $c pre-seed does not parse"; fails=1; }
    done
    PRESEED_ROOT=$r sh "$ROOT/scripts/oracle-preseed/labtwo_maasfix.sh" >/dev/null
    if grep -qE '^deb http://[^ ]+ noble main' "$r/etc/apt/sources.list" \
        && grep -qE '^deb http://[^ ]+ noble-security ' "$r/etc/apt/sources.list" \
        && [[ $(grep -cE '^deb ' "$r/etc/apt/sources.list") -ge 3 ]]
    then echo "ok   maasfix pre-seed: sources.list with live entries"; else echo "FAIL maasfix pre-seed:"; sed 's/^/     | /' "$r/etc/apt/sources.list"; fails=1; fi
    PRESEED_ROOT=$r sh "$ROOT/scripts/oracle-preseed/labtwo_maasfix.sh" >/dev/null
    [[ $(grep -cE '^deb ' "$r/etc/apt/sources.list") -eq 3 ]] || { echo "FAIL maasfix pre-seed not idempotent"; fails=1; }
    : >"$t/apt.log"
    PATH=$bin:$PATH APT_LOG=$t/apt.log PRESEED_ROOT=$r sh "$ROOT/scripts/oracle-preseed/labtwo_cuda.sh" >/dev/null
    if grep -qE '^apt-get .*install .*docker\.io' "$t/apt.log"; then echo "ok   cuda pre-seed installs docker.io"
    else echo "FAIL cuda pre-seed: apt-get calls: $(cat "$t/apt.log")"; fails=1; fi
    : >"$t/apt.log"
    PATH=$bin:$PATH APT_LOG=$t/apt.log PRESEED_ROOT=$r sh "$ROOT/scripts/oracle-preseed/labtwo_hashicorp_packer.sh" >/dev/null
    if grep -qE '^apt-get .*install .*libvirt-daemon-system' "$t/apt.log"; then echo "ok   hashicorp_packer pre-seed installs vm_server's packages"
    else echo "FAIL hashicorp_packer pre-seed: apt-get calls: $(cat "$t/apt.log")"; fails=1; fi
    PRESEED_ROOT=$r sh "$ROOT/scripts/oracle-preseed/labtwo_src_repos.sh" >/dev/null
    if grep -q '^Types: deb-src' "$r/etc/apt/sources.list.d/ubuntu-src.sources"
    then echo "ok   src_repos pre-seed: ubuntu-src.sources (not yet a case; T158)"; else echo "FAIL src_repos pre-seed"; fails=1; fi

    # image-state.sh single-file sections on a fake root
    local fr=$t/fake-root st
    mkdir -p "$fr/etc/systemd/system/b.service.d" "$fr/etc/systemd/system/a.service.d" "$fr/etc/profile.d" "$fr/boot/grub"
    ln -s /usr/share/zoneinfo/America/Los_Angeles "$fr/etc/localtime"
    printf '%s\n' '#!/bin/sh' 'printf "%s\n" "port 22" "permitrootlogin yes" "passwordauthentication no" "pubkeyauthentication yes"' >"$t/sshd-stub"
    chmod +x "$t/sshd-stub"
    printf '%s\n' 'Defaults	env_reset' 'Defaults	secure_path="/usr/local/sbin:/usr/bin"' '@includedir /etc/sudoers.d' 'root ALL=(ALL) ALL' >"$fr/etc/sudoers"
    printf '[Service]\nExecStart=\n' >"$fr/etc/systemd/system/b.service.d/override.conf"
    printf '[Unit]\n' >"$fr/etc/systemd/system/a.service.d/x.conf"
    printf '%s\n' 'menuentry "Ubuntu" {' '	linux	/boot/vmlinuz-6.8.0 root=UUID=1234 ro quiet reboot=efi console=tty1' '}' \
        'menuentry "Recovery" {' '	linux	/boot/vmlinuz-6.8.0 root=UUID=1234 ro recovery nomodeset' '}' '# linux is not a line' >"$fr/boot/grub/grub.cfg"
    printf '%s\n' 'root:x:0:' 'kvm:x:36:zed,bot' 'libvirt:x:100:' >"$fr/etc/group"
    printf 'export CUDA_HOME=/x\n' >"$fr/etc/profile.d/cuda.sh"
    local sha_u1 sha_u2 sha_c
    sha_u1=$(sha256sum <"$fr/etc/systemd/system/a.service.d/x.conf" | cut -d' ' -f1)
    sha_u2=$(sha256sum <"$fr/etc/systemd/system/b.service.d/override.conf" | cut -d' ' -f1)
    sha_c=$(sha256sum <"$fr/etc/profile.d/cuda.sh" | cut -d' ' -f1)
    st=$(IMAGE_STATE_ROOT=$fr SSHD=$t/sshd-stub sh "$ROOT/scripts/image-state.sh" --only 2>&1)
    want=$(printf '%s\n' '== timezone ==' '/usr/share/zoneinfo/America/Los_Angeles' \
        '== sshd ==' 'passwordauthentication no' 'permitrootlogin yes' \
        '== sudoers ==' '@includedir /etc/sudoers.d' 'Defaults	secure_path="/usr/local/sbin:/usr/bin"' \
        '== units ==' "/etc/systemd/system/a.service.d/x.conf $sha_u1" "/etc/systemd/system/b.service.d/override.conf $sha_u2" \
        '== grub ==' 'arg console=tty1' 'arg nomodeset' 'arg quiet' 'arg reboot=efi' 'arg recovery' 'arg ro' \
        '== groups ==' 'docker (no group)' 'kvm: bot zed' 'libvirt: ' \
        '== profile.d ==' "cuda.sh $sha_c")
    if [[ $st == "$want" ]]; then echo "ok   image-state single-file sections (fake root, stub sshd)"
    else echo "FAIL image-state single-file sections; diff of wanted vs got:"; diff <(echo "$want") <(echo "$st") | sed 's/^/     | /'; fails=1; fi
    # each section's body is in LC_ALL=C order
    local sec bad=0
    for sec in timezone sshd sudoers units grub groups profile.d; do
        printf '%s\n' "$st" | sed -n "/^== $sec ==\$/,/^== /p" | grep -v '^==' | LC_ALL=C sort -c 2>/dev/null || { echo "FAIL section $sec not sorted"; bad=1; }
    done
    if [[ $bad -eq 0 ]]; then echo "ok   image-state sections sorted with LC_ALL=C"; else fails=1; fi
    # an empty root: every section has a header and a stated body, never an error
    mkdir -p "$t/empty-root"
    st=$(IMAGE_STATE_ROOT=$t/empty-root SSHD=/nonexistent/sshd sh "$ROOT/scripts/image-state.sh" --only 2>&1)
    want=$(printf '%s\n' '== timezone ==' '(none)' '== sshd ==' '(none)' '== sudoers ==' '(none)' '== units ==' '(none)' \
        '== grub ==' '(none)' '== groups ==' 'docker (no group)' 'kvm (no group)' 'libvirt (no group)' '== profile.d ==' '(none)')
    if [[ $st == "$want" ]]; then echo "ok   image-state single-file sections on an empty root"
    else echo "FAIL image-state on an empty root:"; diff <(echo "$want") <(echo "$st") | sed 's/^/     | /'; fails=1; fi
    # one sudoers section only (--users used to print its own)
    got=$(grep -c 'section "sudoers"' "$ROOT/scripts/image-state.sh" || true)
    if [[ $got -eq 1 ]]; then echo "ok   image-state has one sudoers section"; else echo "FAIL sudoers section defined $got times"; fails=1; fi
    return $fails
}

# write_role_playbook <file> <role>... : the wrapper playbook of a labtwo case:
# hosts all, the roles in order, the
# original's remote_user. Written into this run's export only.
write_role_playbook() {
    local f=$1 r; shift
    {
        printf '%s\n' '---' '# Written by scripts/test-vm-oracle.sh: one labtwo role of ansible_labtwo_2/playbooks/labtwo.yml.' \
            "- name: labtwo, ${*: -1}" '  hosts: all' '  remote_user: root' '  roles:'
        for r in "$@"; do echo "    - $r"; done
    } >"$f"
}

# vm_name_for <container> <side> <stamp> : the VM's name, tp-<container>-<side>-<stamp>,
# with every `_` of the container as `-` (vm.sh accepts only tp-[a-z0-9-]+).
vm_name_for() { echo "tp-${1//_/-}-$2-$3"; }

self_test() {
    local t fails=0
    t=$(mktemp -d)
    trap 'rm -rf "$t"' RETURN
    local state=$'== packages ==\nbash amd64\ncurl amd64\n== /usr/local/bin ==\nuv\n'
    local vers=$'== packages ==\nbash amd64 5.2\ncurl amd64 8.5\n'
    local pre=$'== packages ==\nbash amd64\n'
    expect() { # name expected-rc
        local name=$1 want=$2 rc=0
        oracle_compare "$t" >"$t/out" 2>&1 || rc=$?
        if [[ $rc -eq $want ]]; then echo "ok   $name (exit $rc)"; else echo "FAIL $name: exit $rc, wanted $want"; fails=1; fi
        sed 's/^/     | /' "$t/out"
    }
    printf '%s' "$pre" >"$t/ansible-pre.state"; cp "$t/ansible-pre.state" "$t/telepatch-pre.state"
    # equal -> 0
    printf '%s' "$state" >"$t/ansible.state"; cp "$t/ansible.state" "$t/telepatch.state"
    printf '%s' "$vers" >"$t/ansible.versions"; cp "$t/ansible.versions" "$t/telepatch.versions"
    expect "equal" 0
    grep -q '^NON-GATING: pre-states identical' "$t/out" || { echo "FAIL equal: no 'pre-states identical' line"; fails=1; }
    # a package missing on the telepatch side -> 1, diff printed
    printf '%s' "$state" | grep -v '^curl' >"$t/telepatch.state"
    expect "package missing" 1
    grep -q '^-curl amd64' "$t/out" || { echo "FAIL package missing: diff not printed"; fails=1; }
    # version-only change -> 0, side diff printed
    cp "$t/ansible.state" "$t/telepatch.state"
    printf '%s' "${vers/8.5/8.6}" >"$t/telepatch.versions"
    expect "version only" 0
    grep -q '^+curl amd64 8.6' "$t/out" || { echo "FAIL version only: side diff not printed"; fails=1; }
    # pre-states differ -> 0, the non-gating pre diff printed
    cp "$t/ansible.versions" "$t/telepatch.versions"
    printf '%s' "${pre}snapd amd64"$'\n' >"$t/telepatch-pre.state"
    expect "pre-states differ" 0
    grep -q '^NON-GATING: pre-states differ' "$t/out" || { echo "FAIL pre-states differ: no 'pre-states differ' line"; fails=1; }
    grep -q '^+snapd amd64' "$t/out" || { echo "FAIL pre-states differ: pre diff not printed"; fails=1; }
    [[ -s $t/comparison.txt ]] || { echo "FAIL comparison.txt not written"; fails=1; }

    # the shared cases: intended differences, and no local compare_captures
    selftest_intended oracle_compare "$t" || fails=1
    selftest_no_local_copy "${BASH_SOURCE[0]}" || fails=1

    # the inventory writer: host vars present, the key's path only, the guest
    # reached by its VM name through vmtool's tunnel (one ProxyCommand value)
    local key=$t/machines/veritech04/tp-x/id_ed25519
    mkdir -p "$(dirname "$key")"
    printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----' 'c2VjcmV0LWZpeHR1cmU=' '-----END OPENSSH PRIVATE KEY-----' >"$key"
    mkdir -p "$t/src/inventories"
    local pc="sh -c 'cd /v && exec ./vmtool tunnel veritech04/tp-x'"
    (VM_PROXY_COMMAND=$pc; write_inventory "$t/src/inventories/vm.yml" tp-x "$key" "$t/known_hosts")
    local inv=$t/src/inventories/vm.yml want ok=1
    for want in 'ansible_host: tp-x' 'ansible_user: bot' 'ansible_become: true' \
        "ansible_ssh_private_key_file: $key" 'ansible_python_interpreter: /usr/bin/python3' \
        'IdentitiesOnly=yes' 'StrictHostKeyChecking=accept-new' "UserKnownHostsFile=$t/known_hosts"; do
        grep -qF -- "$want" "$inv" || { echo "FAIL inventory lacks '$want'"; ok=0; }
    done
    if grep -qE 'PRIVATE KEY|c2VjcmV0LWZpeHR1cmU=|ProxyJump' "$inv"; then echo "FAIL inventory holds key material or a ProxyJump"; ok=0; fi
    if [[ $ok -eq 1 ]]; then echo "ok   inventory writer (host vars, key path only, no ProxyJump)"; else fails=1; fi
    sed 's/^/     | /' "$inv"
    local inv_want
    inv_want=$(printf '%s\n' '# Written by scripts/test-vm-oracle.sh for one VM of one run.' 'all:' '  hosts:' '    tp-x:' \
        '      ansible_host: tp-x' '      ansible_user: bot' '      ansible_become: true' \
        "      ansible_ssh_private_key_file: $key" '      ansible_python_interpreter: /usr/bin/python3' \
        "      ansible_ssh_common_args: \"-o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$t/known_hosts -o \\\"ProxyCommand=$pc\\\"\"")
    if [[ $(cat "$inv") == "$inv_want" ]] && [[ $(grep -c 'ansible_ssh_common_args' "$inv") -eq 1 ]]
    then echo "ok   inventory text: the exact lines, the ProxyCommand inside the one common_args value"
    else echo "FAIL inventory text:"; diff <(echo "$inv_want") "$inv" | sed 's/^/     | /'; fails=1; fi
    # what ansible sees: the YAML value, shlex-split, is -o options with the ProxyCommand as ONE word
    if python3 -c 'import yaml' 2>/dev/null; then
        got=$(python3 -I - "$inv" <<'PYEOF'
import shlex, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
v = d["all"]["hosts"]["tp-x"]
for w in shlex.split(v["ansible_ssh_common_args"]):
    print(w)
PYEOF
        ) || got=
        if [[ $got == "$(printf '%s\n' -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$t/known_hosts" -o "ProxyCommand=$pc")" ]]
        then echo "ok   inventory: YAML then shlex gives -o ... -o ProxyCommand=<one word>"
        else echo "FAIL inventory shlex split: '$got'"; fails=1; fi
    else echo "skip inventory YAML+shlex check (python3 yaml not installed here)"; fi

    # the tp-basic ssh argv: the key, accept-new, the known_hosts, the ProxyCommand; no ProxyJump
    local -a a_want=(--ssh-key /k/id --ssh-option StrictHostKeyChecking=accept-new --ssh-option UserKnownHostsFile=/o/known_hosts
        --ssh-option "ProxyCommand=$pc")
    # (in an `if`: a bare failing subshell would end the self-test under set -e without its FAIL line)
    if (VM_PROXY_COMMAND=$pc; tpb_ssh_args /k/id /o/known_hosts; [[ $(printf '%s\x1f' "${TPB_SSH_ARGS[@]}") == "$(printf '%s\x1f' "${a_want[@]}")" ]])
    then echo "ok   tp-basic ssh argv: ProxyCommand=<vmtool tunnel>, no ProxyJump"; else echo "FAIL tp-basic ssh argv"; fails=1; fi

    # timings: the formatter, the changed-count readers, the table
    local got
    got=$(fmt_secs 275.37); [[ $got == 4m35.4s ]] || { echo "FAIL fmt_secs 275.37 -> '$got'"; fails=1; }
    got=$(fmt_secs 2.06); [[ $got == 2.1s ]] || { echo "FAIL fmt_secs 2.06 -> '$got'"; fails=1; }
    printf '%s\n' 'PLAY RECAP ****' 'vm : ok=6    changed=4    unreachable=0    failed=0' >"$t/a.log"
    got=$(ansible_changed "$t/a.log"); [[ $got == 4 ]] || { echo "FAIL ansible_changed -> '$got'"; fails=1; }
    got=$(ansible_changed /dev/null); [[ $got == '?' ]] || { echo "FAIL ansible_changed on empty -> '$got'"; fails=1; }
    printf '%s\n' 'HOST                 STATUS    OK CHANGED FAILED NOT RUN  DETAIL' 'bot@192.0.2.7  ok         2       0      0       0' >"$t/t.out"
    got=$(telepatch_changed "$t/t.out"); [[ $got == 0 ]] || { echo "FAIL telepatch_changed -> '$got'"; fails=1; }
    got=$(telepatch_changed /dev/null); [[ $got == '?' ]] || { echo "FAIL telepatch_changed on empty -> '$got'"; fails=1; }
    timings_table "$t/timings.txt" 275.37 130.2 1 250.0 2.06 0 >"$t/out"
    if grep -qE '^  ansible +4m35.4s +2m10.2s +1$' "$t/timings.txt" && grep -qE '^  telepatch +4m10.0s +2.1s +0$' "$t/timings.txt"; then
        echo "ok   timings (fmt_secs, changed readers, table)"
    else
        echo "FAIL timings table:"; fails=1
    fi
    sed 's/^/     | /' "$t/timings.txt"

    # the playbook allowlist and the dev_desktop_kept playbook the script writes
    got=$(oracle_config dev_base && echo "$OC_PLAYBOOK|$OC_TP|$OC_VARS|$OC_EXTRA|$OC_USERS")
    if [[ $got == 'playbooks/container/dev_base.yml|container/dev_base|vars/container.toml|{"admin_users":["root"],"vnc_users":["root"],"full_users":["root"]}|' ]]; then
        echo "ok   oracle_config dev_base"; else echo "FAIL oracle_config dev_base -> '$got'"; fails=1; fi
    got=$(oracle_config dev_desktop_kept && echo "$OC_PLAYBOOK|$OC_TP|$OC_VARS|$OC_EXTRA|$OC_USERS")
    if [[ $got == 'playbooks/tp_dev_desktop_kept.yml|dev_desktop_kept|vars/desktop.toml|{"admin_users":["bot","tpdev"],"default_password":""}|bot,tpdev' ]]; then
        echo "ok   oracle_config dev_desktop_kept"; else echo "FAIL oracle_config dev_desktop_kept -> '$got'"; fails=1; fi
    if (oracle_config dev_desktop) >/dev/null 2>&1; then echo "FAIL oracle_config dev_desktop accepted"; fails=1
    else echo "ok   oracle_config dev_desktop refused"; fi
    mkdir -p "$t/src/playbooks"
    write_kept_playbook "$t/src/playbooks/tp_dev_desktop_kept.yml"
    if diff <(printf '%s\n' '---' '# Written by scripts/test-vm-oracle.sh: the kept roles of playbooks/dev_desktop.yml.' \
        '- name: dev_desktop, kept roles' '  hosts: all' '  remote_user: root' '  roles:' '    - admin_users' '    - tmux') \
        "$t/src/playbooks/tp_dev_desktop_kept.yml" >/dev/null; then echo "ok   kept playbook written"
    else echo "FAIL kept playbook:"; sed 's/^/     | /' "$t/src/playbooks/tp_dev_desktop_kept.yml"; fails=1; fi
    # the VM names of both sides pass vm.sh's guard (`_` is not in tp-[a-z0-9-]+); lowercase stamp
    local c side got stamp_t
    stamp_t=$(date -u +%Y%m%dt%H%M%Sz)
    if [[ $stamp_t == "${stamp_t,,}" ]]; then echo "ok   stamp is lowercase -> $stamp_t"; else echo "FAIL stamp has uppercase: $stamp_t"; fails=1; fi
    for c in dev_base dev_desktop_kept; do
        for side in ansible telepatch; do
            got=$(vm_name_for "$c" "$side" 20261114t051210z 2>&1)
            if [[ $got == "tp-${c//_/-}-$side-20261114t051210z" ]] && vm_name_ok "$got"; then echo "ok   vm name for $c $side -> $got"
            else echo "FAIL vm name for $c $side -> '$got'"; fails=1; fi
        done
    done
    selftest_labtwo "$t" || fails=1
    return $fails
}

if [[ ${1:-} == --self-test ]]; then self_test; exit $?; fi

# ---- arguments --------------------------------------------------------------
keep=0
if [[ ${1:-} == --keep ]]; then keep=1; shift; fi
distro=${1:-}; container=${2:-}
[[ -n $distro && -n $container ]] || die "usage: test-vm-oracle.sh [--keep] <distro> <container> | --self-test"
[[ $distro == ubuntu2404 ]] || die "only the ubuntu2404 image is supported, not '$distro'"
oracle_config "$container" || die "'$container' is not one of: dev_base, dev_desktop_kept, labtwo_{maasfix,systemd_time,root_user,hashicorp_packer,h11ssl_reboot_fix,cuda}"
# dev_base: the playbook docker-bake.hcl's CONTAINERS gives dev_base
playbook=$OC_PLAYBOOK
state_args=()
[[ -z $OC_USERS ]] || state_args=(--users "$OC_USERS")

# ---- preflight --------------------------------------------------------------
[[ -x $ROOT/build/tp-basic ]] || die "build/tp-basic not found: run 'just musl' first"
[[ -f $ROOT/$OC_VARS ]] || die "$OC_VARS not found"
[[ -x $VMTOOL_DIR/vmtool ]] || die "$VMTOOL_DIR/vmtool not found"
command -v ansible-playbook >/dev/null || die "ansible-playbook not found on this machine"

sha=${ANSIBLE_SHA:-$(sed -n 's/^commit: //p' "$ROOT/conversion/SOURCE" | head -1)}
[[ -n $sha ]] || die "no ANSIBLE_SHA and no commit in conversion/SOURCE"
git -C "$ANSIBLE_REPO" cat-file -e "$sha^{commit}" 2>/dev/null \
    || die "commit $sha not in $ANSIBLE_REPO (only read here: no fetch)"

stamp=$(date -u +%Y%m%dt%H%M%Sz)
name_ansible=$(vm_name_for "$container" ansible "$stamp")
name_telepatch=$(vm_name_for "$container" telepatch "$stamp")
for n in "$name_ansible" "$name_telepatch"; do
    vm_listed "$n" && die "a VM named $n already exists; not touching it"
done

out=$ROOT/build/test-vm-oracle/$container-$distro
mkdir -p "$out"
rm -rf "$out/ansible-src"   # a previous run's export; the rest are files
rm -f "$out"/*
mkdir "$out/ansible-src"
git -C "$ANSIBLE_REPO" archive "$sha" | tar -x -C "$out/ansible-src"
[[ $container != dev_desktop_kept ]] || write_kept_playbook "$out/ansible-src/$playbook"
# shellcheck disable=SC2086  # OC_ROLES is a word list
[[ -z $OC_ROLES ]] || write_role_playbook "$out/ansible-src/$playbook" $OC_ROLES
[[ -f $out/ansible-src/$playbook && -f $out/ansible-src/inventories/group_vars/all ]] \
    || die "the export of $sha lacks $playbook or inventories/group_vars/all"
ansible-playbook --version >"$out/ansible-version.txt" 2>&1
echo "ansible: $ANSIBLE_REPO @ $sha (exported to $out/ansible-src)"
echo "ansible-playbook: $(head -1 "$out/ansible-version.txt")"

cleanup() {
    local rc=$?
    # the VM still up (a failure before side_down): memory report, OOM check
    vm_end "$out" "${VM_PREFIX:-}" "$rc" || rc=$?
    if ! vm_cleanup "$keep"; then
        echo "test-vm-oracle: WARNING: a VM of this run is still listed by 'vmtool list'" >&2
        exit 1
    fi
    exit $rc
}
trap cleanup EXIT

# side_up <side> <name> : the environment steps, identical on both sides, then
# <side>-pre.state.
side_up() {
    vm_record "$2"
    VM_PREFIX=$1-
    vm_up "$2" "$out" "$1-"
    # the case's pre-seed: the same script on both VMs, before the pre-state
    if [[ -n $OC_PRESEED ]]; then
        [[ -f $ROOT/$OC_PRESEED ]] || die "pre-seed $OC_PRESEED not found"
        VM_STEP="pre-seed $OC_PRESEED"
        sshv "sudo -n sh -s" <"$ROOT/$OC_PRESEED" >"$out/$1-preseed.log" 2>&1 \
            || die "pre-seed $OC_PRESEED failed on $2 (log: $out/$1-preseed.log)"
        echo "pre-seeded $2 with $OC_PRESEED"
    fi
    vm_state "$ROOT/scripts/image-state.sh" "${state_args[@]}" >"$out/$1-pre.state"
    echo "captured $out/$1-pre.state ($(wc -l <"$out/$1-pre.state") lines)"
}

# side_down <side> <name> : <side>.state and <side>.versions, then delete the
# VM (unless --keep) before the next one is created.
side_down() {
    vm_state "$ROOT/scripts/image-state.sh" "${state_args[@]}" >"$out/$1.state"
    vm_state "$ROOT/scripts/image-state.sh" --versions >"$out/$1.versions"
    echo "captured $out/$1.state ($(wc -l <"$out/$1.state") lines)"
    vm_mem_report "$out" "$1-"
    VM_DEST= VM_PREFIX=
    if [[ $keep -eq 0 ]]; then
        vm_delete "$2" || exit 1
    fi
}

# run_ansible <log> : one ansible-playbook pass on the current VM, timed.
# Sets RUN_SECS. Exits 1 on failure.
run_ansible() {
    local log=$1 rc=0 t0
    echo "=== ansible-playbook $playbook on $VM_DEST (become; ansible-src/inventories/vm.yml) -> $(basename "$log") ==="
    VM_STEP="ansible-playbook $playbook -> $(basename "$log")"
    t0=$(now_s)
    (cd "$out/ansible-src" && ANSIBLE_ROLES_PATH="$out/ansible-src/roles" ansible-playbook \
        --inventory inventories/vm.yml "$playbook" \
        --extra-vars "$OC_EXTRA") \
        >"$log" 2>&1 || rc=$?
    RUN_SECS=$(awk -v a="$t0" -v b="$(now_s)" 'BEGIN { print b - a }')
    sed -n '/^PLAY RECAP/,$p' "$log"
    echo "took $(fmt_secs "$RUN_SECS")"
    if [[ $rc -ne 0 ]]; then
        grep -E '^fatal|FAILED' "$log" | tail -10 || true
        echo "FAIL: ansible-playbook exited $rc (log: $log)"
        exit 1
    fi
}

# run_telepatch <jsonl> <out> : one tp-basic run on the current VM, timed.
# Sets RUN_SECS. Exits 1 on failure.
run_telepatch() {
    local jsonl=$1 txt=$2 rc=0 t0
    echo "=== tp-basic run $OC_TP --host $VM_DEST --vars $OC_VARS -> $(basename "$txt") ==="
    VM_STEP="tp-basic run $OC_TP -> $(basename "$txt")"
    t0=$(now_s)
    tpb_ssh_args "$VM_KEY" "$VM_KNOWN_HOSTS"
    "$ROOT/build/tp-basic" run "$OC_TP" --host "$VM_DEST" "${TPB_SSH_ARGS[@]}" \
        --vars "$ROOT/$OC_VARS" --log "$jsonl" \
        >"$txt" 2>&1 || rc=$?
    RUN_SECS=$(awk -v a="$t0" -v b="$(now_s)" 'BEGIN { print b - a }')
    sed -n '/^HOST  *STATUS/,$p' "$txt"
    echo "took $(fmt_secs "$RUN_SECS")"
    if [[ $rc -ne 0 ]]; then
        tail -40 "$txt"
        echo "FAIL: tp-basic run exited $rc (log: $txt)"
        exit 1
    fi
}

# ---- ansible VM ---------------------------------------------------------------
side_up ansible "$name_ansible"
inv=$out/ansible-src/inventories/vm.yml
write_inventory "$inv" "$name_ansible" "$VM_KEY" "$VM_KNOWN_HOSTS"
run_ansible "$out/ansible.log"; a1=$RUN_SECS
run_ansible "$out/ansible2.log"; a2=$RUN_SECS
ac=$(ansible_changed "$out/ansible2.log")
side_down ansible "$name_ansible"

# ---- telepatch VM -------------------------------------------------------------
side_up telepatch "$name_telepatch"
run_telepatch "$out/telepatch.jsonl" "$out/telepatch.out"; t1=$RUN_SECS
run_telepatch "$out/telepatch2.jsonl" "$out/telepatch2.out"; t2=$RUN_SECS
tc=$(telepatch_changed "$out/telepatch2.out")
side_down telepatch "$name_telepatch"

# ---- timings and the diff -------------------------------------------------------
echo "=== timings ==="
timings_table "$out/timings.txt" "$a1" "$a2" "$ac" "$t1" "$t2" "$tc"
echo "=== ansible.state against telepatch.state ==="
if oracle_compare "$out" "$(intended_for "$container")" "$distro"; then
    echo "PASS: Ansible and telepatch agree on $container on a $distro VM"
    exit 0
fi
echo "FAIL: gating diff (see $out/gating.diff)"
exit 1
