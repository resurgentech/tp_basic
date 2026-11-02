#!/usr/bin/env bash
# VM equivalence check, on demand: Ansible against telepatch on the base that
# is actually deployed to. Two fresh VMs from the same image (ubuntu2404.qcow2
# with ~/repos/jaredeh/vmtool), one at a time: the first gets the original
# Ansible playbook (ansible-playbook from this machine, as bot with become),
# the second gets `tp-basic run --host`. Their scripts/image-state.sh captures
# are diffed the way the docker oracle (scripts/test-container.sh) diffs its
# two images. Not part of test-acceptance or any default gate.
#
#   scripts/test-vm-oracle.sh [--keep] <distro> <container>   (only: ubuntu2404 dev_base)
#   scripts/test-vm-oracle.sh --self-test
#
# Env: ANSIBLE_SHA  the ../ansible commit to run (default: conversion/SOURCE's).
#      It is exported with `git archive`; ../ansible is only read.
# Needs: build/tp-basic (`just musl`), vars/container.toml, vmtool,
#        ansible-playbook on this machine.
#
# Exit: 2 on usage or environment problems (unknown commit, no VM IP, no
# onboarding); 1 when ansible-playbook or tp-basic fails, on a gating diff of
# ansible.state against telepatch.state, or when a VM of this run is still
# listed after the cleanup. Versions are informational; whether the two
# pre-states match is printed, not gated.
#
# The VMs are tp-<container>-ansible-<UTC stamp> and
# tp-<container>-telepatch-<UTC stamp>; each is deleted after its side, and a
# trap deletes whichever still exists on every exit, unless --keep. The SSH key
# is used in place from vmtool's .machines/<vm>/; the inventory names its path.
#
# Outputs (gitignored): build/test-vm-oracle/<container>-<distro>/
#   ansible-src/ (with inventories/vm.yml), ansible-version.txt, ansible.log,
#   telepatch.jsonl, telepatch.out, {ansible,telepatch}-{create,onboard,wait,prep}.log,
#   {ansible,telepatch}-pre.state, {ansible,telepatch}.{state,versions},
#   gating.diff, versions.diff, pre.diff, comparison.txt, known_hosts
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ANSIBLE_REPO=$ROOT/../ansible
VM_TAG=test-vm-oracle

die() { echo "test-vm-oracle: $*" >&2; exit 2; }

# shellcheck source=lib/vm.sh
source "$ROOT/scripts/lib/vm.sh"

# ---- the comparison (also used by --self-test) -------------------------------

# compare_captures, copied byte for byte from scripts/test-container.sh (the
# self-test checks the copy).
# compare_captures <dir> : diffs <dir>/ansible.state vs telepatch.state (gating)
# and the .versions files (informational). Returns 1 on a gating diff.
compare_captures() {
    local dir=$1 rc=0
    if diff -u --label ansible.state --label telepatch.state "$dir/ansible.state" "$dir/telepatch.state" >"$dir/gating.diff"; then
        echo "GATING: names/arch, pip, rustup, apt sources, /usr/local/bin: identical"
    else
        echo "GATING DIFF (ansible vs telepatch):"
        cat "$dir/gating.diff"
        rc=1
    fi
    if [[ -f $dir/ansible.versions && -f $dir/telepatch.versions ]]; then
        if diff -u --label ansible.versions --label telepatch.versions "$dir/ansible.versions" "$dir/telepatch.versions" >"$dir/versions.diff"; then
            echo "VERSIONS (non-gating): identical"
        else
            echo "VERSIONS (non-gating) side diff:"
            cat "$dir/versions.diff"
        fi
    fi
    return $rc
}

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

# oracle_compare <dir> : compare_pre, then compare_captures, printed and
# written to <dir>/comparison.txt. Returns compare_captures' code.
oracle_compare() {
    local dir=$1 rc=0
    compare_pre "$dir" >"$dir/comparison.txt"
    compare_captures "$dir" >>"$dir/comparison.txt" || rc=$?
    cat "$dir/comparison.txt"
    return $rc
}

# write_inventory <file> <host> <ip> <key path> <known_hosts> : the Ansible
# inventory for one VM. It names the key's path, never its contents.
write_inventory() {
    local file=$1 host=$2 ip=$3 key=$4 kh=$5
    {
        echo "# Written by scripts/test-vm-oracle.sh for one VM of one run."
        echo "all:"
        echo "  hosts:"
        echo "    $host:"
        echo "      ansible_host: $ip"
        echo "      ansible_user: bot"
        echo "      ansible_become: true"
        echo "      ansible_ssh_private_key_file: $key"
        echo "      ansible_python_interpreter: /usr/bin/python3"
        echo "      ansible_ssh_common_args: \"-o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$kh\""
    } >"$file"
}

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

    # compare_captures is test-container.sh's, byte for byte
    local cut='/^compare_captures() {$/,/^}$/p'
    sed -n "$cut" "$ROOT/scripts/test-container.sh" >"$t/cc.container"
    sed -n "$cut" "${BASH_SOURCE[0]}" >"$t/cc.vm"
    if [[ -s $t/cc.container ]] && diff -u "$t/cc.container" "$t/cc.vm" >"$t/cc.diff"; then
        echo "ok   compare_captures identical to test-container.sh's ($(wc -l <"$t/cc.vm") lines)"
    else
        echo "FAIL compare_captures differs from test-container.sh's:"; sed 's/^/     | /' "$t/cc.diff" 2>/dev/null || true; fails=1
    fi

    # the inventory writer: host vars present, the key's path only
    local key=$t/machines/tp-x/id_ed25519
    mkdir -p "$(dirname "$key")"
    printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----' 'c2VjcmV0LWZpeHR1cmU=' '-----END OPENSSH PRIVATE KEY-----' >"$key"
    mkdir -p "$t/src/inventories"
    write_inventory "$t/src/inventories/vm.yml" tp-x 192.0.2.7 "$key" "$t/known_hosts"
    local inv=$t/src/inventories/vm.yml want ok=1
    for want in 'ansible_host: 192.0.2.7' 'ansible_user: bot' 'ansible_become: true' \
        "ansible_ssh_private_key_file: $key" 'ansible_python_interpreter: /usr/bin/python3' \
        'IdentitiesOnly=yes' 'StrictHostKeyChecking=accept-new' "UserKnownHostsFile=$t/known_hosts"; do
        grep -qF -- "$want" "$inv" || { echo "FAIL inventory lacks '$want'"; ok=0; }
    done
    if grep -qE 'PRIVATE KEY|c2VjcmV0LWZpeHR1cmU=' "$inv"; then echo "FAIL inventory holds key material"; ok=0; fi
    if [[ $ok -eq 1 ]]; then echo "ok   inventory writer (host vars, key path only)"; else fails=1; fi
    sed 's/^/     | /' "$inv"
    return $fails
}

if [[ ${1:-} == --self-test ]]; then self_test; exit $?; fi

# ---- arguments --------------------------------------------------------------
keep=0
if [[ ${1:-} == --keep ]]; then keep=1; shift; fi
distro=${1:-}; container=${2:-}
[[ -n $distro && -n $container ]] || die "usage: test-vm-oracle.sh [--keep] <distro> <container> | --self-test"
[[ $distro == ubuntu2404 && $container == dev_base ]] || die "only 'ubuntu2404 dev_base' is supported, not '$distro $container'"
# the playbook docker-bake.hcl's CONTAINERS gives dev_base
playbook=playbooks/container/dev_base.yml

# ---- preflight --------------------------------------------------------------
[[ -x $ROOT/build/tp-basic ]] || die "build/tp-basic not found: run 'just musl' first"
[[ -f $ROOT/vars/container.toml ]] || die "vars/container.toml not found"
[[ -x $VMTOOL_DIR/vmtool ]] || die "$VMTOOL_DIR/vmtool not found"
command -v ansible-playbook >/dev/null || die "ansible-playbook not found on this machine"

sha=${ANSIBLE_SHA:-$(sed -n 's/^commit: //p' "$ROOT/conversion/SOURCE")}
[[ -n $sha ]] || die "no ANSIBLE_SHA and no commit in conversion/SOURCE"
git -C "$ANSIBLE_REPO" cat-file -e "$sha^{commit}" 2>/dev/null \
    || die "commit $sha not in $ANSIBLE_REPO (only read here: no fetch)"

stamp=$(date -u +%Y%m%dt%H%M%Sz)
name_ansible=tp-$container-ansible-$stamp
name_telepatch=tp-$container-telepatch-$stamp
for n in "$name_ansible" "$name_telepatch"; do
    vm_listed "$n" && die "a VM named $n already exists; not touching it"
done

out=$ROOT/build/test-vm-oracle/$container-$distro
mkdir -p "$out"
rm -f "$out"/*
rm -rf "$out/ansible-src"
mkdir "$out/ansible-src"
git -C "$ANSIBLE_REPO" archive "$sha" | tar -x -C "$out/ansible-src"
[[ -f $out/ansible-src/$playbook && -f $out/ansible-src/inventories/group_vars/all ]] \
    || die "the export of $sha lacks $playbook or inventories/group_vars/all"
ansible-playbook --version >"$out/ansible-version.txt" 2>&1
echo "ansible: $ANSIBLE_REPO @ $sha (exported to $out/ansible-src)"
echo "ansible-playbook: $(head -1 "$out/ansible-version.txt")"

cleanup() {
    local rc=$?
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
    vm_up "$2" "$out" "$1-"
    vm_state "$ROOT/scripts/image-state.sh" >"$out/$1-pre.state"
    echo "captured $out/$1-pre.state ($(wc -l <"$out/$1-pre.state") lines)"
}

# side_down <side> <name> : <side>.state and <side>.versions, then delete the
# VM (unless --keep) before the next one is created.
side_down() {
    vm_state "$ROOT/scripts/image-state.sh" >"$out/$1.state"
    vm_state "$ROOT/scripts/image-state.sh" --versions >"$out/$1.versions"
    echo "captured $out/$1.state ($(wc -l <"$out/$1.state") lines)"
    if [[ $keep -eq 0 ]]; then
        vm_delete "$2" || exit 1
    fi
}

# ---- ansible VM ---------------------------------------------------------------
side_up ansible "$name_ansible"
inv=$out/ansible-src/inventories/vm.yml
write_inventory "$inv" "$name_ansible" "$VM_IP" "$VM_KEY" "$VM_KNOWN_HOSTS"
echo "=== ansible-playbook $playbook on $VM_DEST (become; ansible-src/inventories/vm.yml) ==="
arc=0
(cd "$out/ansible-src" && ANSIBLE_ROLES_PATH="$out/ansible-src/roles" ansible-playbook \
    --inventory inventories/vm.yml "$playbook" \
    --extra-vars '{"admin_users":["root"],"vnc_users":["root"],"full_users":["root"]}') \
    >"$out/ansible.log" 2>&1 || arc=$?
sed -n '/^PLAY RECAP/,$p' "$out/ansible.log"
if [[ $arc -ne 0 ]]; then
    grep -E '^fatal|FAILED' "$out/ansible.log" | tail -10 || true
    echo "FAIL: ansible-playbook exited $arc (log: $out/ansible.log)"
    exit 1
fi
side_down ansible "$name_ansible"

# ---- telepatch VM -------------------------------------------------------------
side_up telepatch "$name_telepatch"
echo "=== tp-basic run container/$container --host $VM_DEST ==="
trc=0
"$ROOT/build/tp-basic" run "container/$container" --host "$VM_DEST" --ssh-key "$VM_KEY" \
    --ssh-option StrictHostKeyChecking=accept-new \
    --ssh-option UserKnownHostsFile="$VM_KNOWN_HOSTS" \
    --vars "$ROOT/vars/container.toml" --log "$out/telepatch.jsonl" \
    >"$out/telepatch.out" 2>&1 || trc=$?
sed -n '/^HOST  *STATUS/,$p' "$out/telepatch.out"
if [[ $trc -ne 0 ]]; then
    tail -40 "$out/telepatch.out"
    echo "FAIL: tp-basic run exited $trc (log: $out/telepatch.out)"
    exit 1
fi
side_down telepatch "$name_telepatch"

# ---- the diff -------------------------------------------------------------------
echo "=== ansible.state against telepatch.state ==="
if oracle_compare "$out"; then
    echo "PASS: Ansible and telepatch agree on $container on a $distro VM"
    exit 0
fi
echo "FAIL: gating diff (see $out/gating.diff)"
exit 1
