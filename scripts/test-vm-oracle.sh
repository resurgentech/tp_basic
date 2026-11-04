#!/usr/bin/env bash
# VM equivalence check, on demand: Ansible against telepatch on the base that
# is actually deployed to. Two fresh VMs from the same image (ubuntu2404.qcow2
# with ~/repos/jaredeh/vmtool), one at a time: the first gets the original
# Ansible playbook (ansible-playbook from this machine, as bot with become),
# the second gets `tp-basic run --host`. Their scripts/image-state.sh captures
# are diffed the way the docker oracle (scripts/test-container.sh) diffs its
# two images. Not part of test-acceptance or any default gate.
#
#   scripts/test-vm-oracle.sh [--keep] <distro> <container>   (ubuntu2404; dev_base or dev_desktop_kept)
#   scripts/test-vm-oracle.sh --self-test
#
# Env: ANSIBLE_SHA  the ../ansible commit to run (default: conversion/SOURCE's).
#      It is exported with `git archive`; ../ansible is only read.
# Needs: build/tp-basic (`just musl`), vars/container.toml, vmtool,
#        ansible-playbook on this machine.
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
# tp-<container>-telepatch-<UTC stamp>; each is deleted after its side, and a
# trap deletes whichever still exists on every exit, unless --keep. The SSH key
# is used in place from vmtool's .machines/<vm>/; the inventory names its path.
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
# compare_captures and intended_for, shared with test-container.sh
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

# oracle_compare <dir> [<intended file>] : compare_pre, then compare_captures,
# printed and written to <dir>/comparison.txt. Returns compare_captures' code.
oracle_compare() {
    local dir=$1 rc=0
    compare_pre "$dir" >"$dir/comparison.txt"
    compare_captures "$dir" "${2:-}" >>"$dir/comparison.txt" || rc=$?
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

# oracle_config <container> : the allowlist. Sets OC_PLAYBOOK (the Ansible
# playbook, relative to the export), OC_TP (the tp-basic playbook), OC_VARS,
# OC_EXTRA (ansible --extra-vars JSON) and OC_USERS (image-state.sh --users,
# empty for none). Returns 1 for any other name.
#
# dev_desktop_kept: the roles of playbooks/dev_desktop.yml that were kept as
# ports, admin_users and tmux (the others were rewritten and have no Ansible
# side to diff, and the real playbook needs unpinned Galaxy roles). The
# playbook is written into this run's export only; ../ansible is not touched.
oracle_config() {
    case $1 in
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
    selftest_no_local_copy "$ROOT/scripts/test-container.sh" "${BASH_SOURCE[0]}" || fails=1

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
    return $fails
}

if [[ ${1:-} == --self-test ]]; then self_test; exit $?; fi

# ---- arguments --------------------------------------------------------------
keep=0
if [[ ${1:-} == --keep ]]; then keep=1; shift; fi
distro=${1:-}; container=${2:-}
[[ -n $distro && -n $container ]] || die "usage: test-vm-oracle.sh [--keep] <distro> <container> | --self-test"
[[ $distro == ubuntu2404 ]] || die "only the ubuntu2404 image is supported, not '$distro'"
oracle_config "$container" || die "'$container' is not one of: dev_base, dev_desktop_kept"
# dev_base: the playbook docker-bake.hcl's CONTAINERS gives dev_base
playbook=$OC_PLAYBOOK
state_args=()
[[ -z $OC_USERS ]] || state_args=(--users "$OC_USERS")

# ---- preflight --------------------------------------------------------------
[[ -x $ROOT/build/tp-basic ]] || die "build/tp-basic not found: run 'just musl' first"
[[ -f $ROOT/$OC_VARS ]] || die "$OC_VARS not found"
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
rm -rf "$out/ansible-src"   # a previous run's export; the rest are files
rm -f "$out"/*
mkdir "$out/ansible-src"
git -C "$ANSIBLE_REPO" archive "$sha" | tar -x -C "$out/ansible-src"
[[ $container != dev_desktop_kept ]] || write_kept_playbook "$out/ansible-src/$playbook"
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
    vm_state "$ROOT/scripts/image-state.sh" "${state_args[@]}" >"$out/$1-pre.state"
    echo "captured $out/$1-pre.state ($(wc -l <"$out/$1-pre.state") lines)"
}

# side_down <side> <name> : <side>.state and <side>.versions, then delete the
# VM (unless --keep) before the next one is created.
side_down() {
    vm_state "$ROOT/scripts/image-state.sh" "${state_args[@]}" >"$out/$1.state"
    vm_state "$ROOT/scripts/image-state.sh" --versions >"$out/$1.versions"
    echo "captured $out/$1.state ($(wc -l <"$out/$1.state") lines)"
    if [[ $keep -eq 0 ]]; then
        vm_delete "$2" || exit 1
    fi
}

# run_ansible <log> : one ansible-playbook pass on the current VM, timed.
# Sets RUN_SECS. Exits 1 on failure.
run_ansible() {
    local log=$1 rc=0 t0
    echo "=== ansible-playbook $playbook on $VM_DEST (become; ansible-src/inventories/vm.yml) -> $(basename "$log") ==="
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
    t0=$(now_s)
    "$ROOT/build/tp-basic" run "$OC_TP" --host "$VM_DEST" --ssh-key "$VM_KEY" \
        --ssh-option StrictHostKeyChecking=accept-new \
        --ssh-option UserKnownHostsFile="$VM_KNOWN_HOSTS" \
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
write_inventory "$inv" "$name_ansible" "$VM_IP" "$VM_KEY" "$VM_KNOWN_HOSTS"
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
if oracle_compare "$out" "$(intended_for "$container")"; then
    echo "PASS: Ansible and telepatch agree on $container on a $distro VM"
    exit 0
fi
echo "FAIL: gating diff (see $out/gating.diff)"
exit 1
