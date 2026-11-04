#!/usr/bin/env bash
# VM check over SSH, a proof of the SSH transport: create a fresh VM with
# ~/repos/jaredeh/vmtool, apply a playbook to it twice with
# `tp-basic run --host`, and delete the VM. The playbooks (playbook_config):
# dev_base (container/dev_base, vars/container.toml, 4 GiB, the docker oracle
# report) and dev_desktop (vars/desktop.toml, 4 GiB, 30 GB disk, no oracle
# report; after run 2 the per-user working checks below gate). Usage errors and environment
# problems (no VM IP, no onboarding) exit 2; a failed first run, a second run
# that is not STATUS ok / CHANGED 0, or a VM still listed after the delete
# exits 1 (a Go release between the passes is the one accepted cause of a
# nonzero count on dev_desktop, and is printed as such). After run 2 it also gates on bot's login shell: `command -v just`
# must print /usr/local/share/mise/shims/just and `just --version` must work
# (dev_common's mise; exit 1 with the output otherwise).
#
#   scripts/test-vm.sh [--keep] <distro> <playbook>   (ubuntu2404; dev_base or dev_desktop)
#   scripts/test-vm.sh --self-test
#
# Needs: build/tp-basic (`just musl`). Optional:
# build/test-container/<container>-<distro>/{telepatch,base}.state
# (`just test-container <distro> <container>`) for the comparison report.
#
# The VM is named tp-<container>-<UTC stamp>; a trap deletes that one VM on
# every exit unless --keep, then checks `vmtool list` no longer shows it. The
# SSH key is used in place from vmtool's .machines/<vm>/ directory and never
# copied.
#
# The comparison with the docker oracle's record is NON-GATING, a report only:
# containers and VMs differ in structure (systemd, kernel, udev, cloud-init, a
# slimmer base), so a useful playbook cannot be expected to add the same
# packages to both (seen: binfmt-support, a Recommends the VM satisfies with
# systemd). It prints, for `packages`, `pip` and `/usr/local/bin` by name and
# architecture, what the oracle added and the VM lacks, what the run added and
# the oracle lacks, the apt-sources diff and the count of version
# differences. Equivalence of Ansible and telepatch on a VM is
# a separate check, scripts/test-vm-oracle.sh (`just test-vm-oracle`). The VM
# lifecycle (create, onboard, wait, apt-get update, delete) is scripts/lib/vm.sh.
#
# Outputs (gitignored): build/test-vm/<container>-<distro>/
#   create.log, onboard.log, wait.log, prep.log, vm-pre.state, vm-post.state, vm-post.versions,
#   run1.jsonl, run2.jsonl, run1.out, run2.out, known_hosts, comparison.txt
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VM_TAG=test-vm

die() { echo "test-vm: $*" >&2; exit 2; }

# the VM lifecycle: vmtool, vm_ip, vm_listed, vm_up, sshv, vm_state, vm_cleanup
# shellcheck source=lib/vm.sh
source "$ROOT/scripts/lib/vm.sh"

# ---- the comparison (also used by --self-test) -----------------------------

GATED='^(packages|pip|/usr/local/bin)$'

# items <state> : "<section>|<item>" for every line of a gated section.
items() {
    awk -v gated="$GATED" '
        /^== .* ==$/ { s = substr($0, 4, length($0) - 6); next }
        s ~ gated && NF { print s "|" $0 }
    ' "$1" | LC_ALL=C sort -u
}

# section <state> <name> : the lines of one section.
section_of() {
    awk -v want="$2" '
        /^== .* ==$/ { s = substr($0, 4, length($0) - 6); next }
        s == want { print }
    ' "$1"
}

# compare_vm <oracle dir> <vm dir> : reads base.state and telepatch.state from
# the oracle dir, vm-pre.state and vm-post.state from the vm dir; writes and
# prints <vm dir>/comparison.txt. A report only: it always returns 0.
compare_vm() {
    local o=$1 v=$2 t
    t=$(mktemp -d)
    items "$o/base.state" >"$t/base"
    items "$o/telepatch.state" >"$t/oracle"
    items "$v/vm-pre.state" >"$t/pre"
    items "$v/vm-post.state" >"$t/post"
    LC_ALL=C comm -23 "$t/oracle" "$t/base" >"$t/oracle-added"
    LC_ALL=C comm -23 "$t/post" "$t/pre" >"$t/vm-added"
    LC_ALL=C comm -23 "$t/oracle-added" "$t/post" >"$t/missing"
    LC_ALL=C comm -23 "$t/vm-added" "$t/oracle" >"$t/extra"
    {
        echo "NON-GATING: comparison with the docker oracle's record"
        echo "(containers and VMs differ in structure: systemd, kernel, udev, cloud-init, a slimmer base)"
        echo "oracle added $(wc -l <"$t/oracle-added") items; the run added $(wc -l <"$t/vm-added") items to the VM"
        if [[ -s $t/missing ]]; then
            echo "the oracle added these, the VM lacks them after the run ($(wc -l <"$t/missing")):"
            sed 's/^/  - /' "$t/missing"
        else
            echo "everything the oracle added is on the VM"
        fi
        if [[ -s $t/extra ]]; then
            echo "the run added these, the oracle's telepatch image lacks them ($(wc -l <"$t/extra")):"
            sed 's/^/  + /' "$t/extra"
        else
            echo "everything the run added is in the oracle"
        fi
        echo "the VM had $(wc -l <"$t/pre") gated items before the run ($(LC_ALL=C comm -23 "$t/pre" "$t/oracle" | wc -l) of them not in the oracle image)"
        if diff -u --label oracle-sources --label vm-sources \
            <(section_of "$o/telepatch.state" "apt sources") \
            <(section_of "$v/vm-post.state" "apt sources") >"$t/sources.diff"; then
            echo "apt sources identical"
        else
            echo "apt sources differ (oracle vs VM after the run):"
            sed 's/^/  /' "$t/sources.diff"
        fi
        if [[ -f $o/telepatch.versions && -f $v/vm-post.versions ]]; then
            # versions of the oracle-added packages, both sides
            local want
            want=$(sed -n 's/^packages|//p' "$t/oracle-added" | awk '{print $1 " " $2}')
            if [[ -n $want ]]; then
                section_of "$o/telepatch.versions" packages | awk 'NR==FNR{w[$1" "$2]=1; next} ($1" "$2) in w' <(echo "$want") - | LC_ALL=C sort >"$t/ov"
                section_of "$v/vm-post.versions" packages | awk 'NR==FNR{w[$1" "$2]=1; next} ($1" "$2) in w' <(echo "$want") - | LC_ALL=C sort >"$t/vv"
                local n
                n=$(diff "$t/ov" "$t/vv" | grep -c '^>' || true)
                echo "$n oracle-added packages have another version on the VM"
            fi
        fi
    } | tee "$v/comparison.txt"
    rm -f "$t"/*
    rmdir "$t"
    return 0
}

# oracle_report <oracle dir> <vm dir> : the comparison when the oracle record
# exists, else the skip line. Always returns 0.
oracle_report() {
    local o=$1 v=$2
    if [[ ! -f $o/base.state || ! -f $o/telepatch.state ]]; then
        echo "NON-GATING: no oracle record; run 'just test-container <distro> <c>' for the comparison"
        return 0
    fi
    compare_vm "$o" "$v"
}

# ---- the playbooks this script runs, and the working checks ---------------------

# playbook_config <playbook> : the allowlist. Sets PB_NAME (the registered
# playbook), PB_VARS (relative to the repo), PB_ORACLE (1 when the docker
# oracle's record of build/test-container/<playbook>-<distro> is compared),
# PB_MEMORY (GiB) and PB_DISK (GB, empty for the image's size). Returns 1 for
# any other name.
playbook_config() {
    case $1 in
        dev_base) PB_NAME=container/dev_base PB_VARS=vars/container.toml PB_ORACLE=1 PB_MEMORY=4 PB_DISK= ;;
        # docker, libvirt, Go, Node and two rustup trees do not fit the
        # image's own disk, and the libvirt and docker daemons want memory.
        dev_desktop) PB_NAME=dev_desktop PB_VARS=vars/desktop.toml PB_ORACLE=0 PB_MEMORY=4 PB_DISK=30 ;;
        *) return 1 ;;
    esac
}

# as_user_cmd <user> <command> : the remote command line that runs <command>
# in <user>'s login shell. bot is the SSH user; anyone else is reached with
# `sudo -n -iu`, so the check also proves bot's sudo needs no password.
as_user_cmd() {
    local q
    q=$(printf '%s' "$2" | sed "s/'/'\\\\''/g")
    if [[ $1 == bot ]]; then echo "bash -lc '$q'"; else echo "sudo -n -iu $1 bash -lc '$q'"; fi
}

# second_pass <run2.out> <go version after run 1> <go version after run 2> :
# "ok" for STATUS ok and CHANGED 0; "go-release" when every changed op is in
# role golang and the installed Go moved between the passes (golang wants
# Latest, resolved on the host each run: a release between the passes is the
# one accepted cause of a change); "fail" otherwise.
second_pass() {
    local out=$1 g1=$2 g2=$3 ch st roles
    ch=$(awk '/^HOST  *STATUS/{getline; print $4; exit}' "$out")
    st=$(awk '/^HOST  *STATUS/{getline; print $2; exit}' "$out")
    if [[ $st == ok && $ch == 0 ]]; then echo ok; return; fi
    roles=$(awk '/^== /{h=$0} /^-> changed/{ if (match(h, /\[[^]]*\]/)) print substr(h, RSTART + 1, RLENGTH - 2) }' "$out" | sort -u)
    if [[ $st == changed && $roles == golang && -n $g1 && $g1 != "$g2" ]]; then echo go-release; else echo fail; fi
}

# groups_have <id -nG output> <group>... : true when every group is listed.
groups_have() {
    local have=" $1 " g
    shift
    for g in "$@"; do [[ $have == *" $g "* ]] || return 1; done
}

self_test() {
    local t fails=0
    t=$(mktemp -d)
    mkdir "$t/o" "$t/v" "$t/none"
    local base=$'== packages ==\nbash amd64\n== pip ==\n== apt sources ==\n-- /etc/apt/sources.list\ndeb a\n== /usr/local/bin ==\n'
    local tp=$'== packages ==\nbash amd64\ncurl amd64\n== pip ==\n== apt sources ==\n-- /etc/apt/sources.list\ndeb a\n== /usr/local/bin ==\nuv\n'
    local pre=$'== packages ==\nbash amd64\nsnapd amd64\n== pip ==\n== apt sources ==\n-- /etc/apt/sources.list\ndeb a\n== /usr/local/bin ==\n'
    local post=$'== packages ==\nbash amd64\ncurl amd64\nsnapd amd64\n== pip ==\n== apt sources ==\n-- /etc/apt/sources.list\ndeb a\n== /usr/local/bin ==\nuv\n'
    printf '%s' "$base" >"$t/o/base.state"
    printf '%s' "$tp" >"$t/o/telepatch.state"
    printf '%s' "$pre" >"$t/v/vm-pre.state"
    # expect <name> <oracle dir> <text that must be in the output>: the report
    # returns 0, prints the text, and prints no line that says GATING (other
    # than NON-GATING) or FAIL.
    expect() {
        local name=$1 odir=$2 rc=0 ok=1
        oracle_report "$odir" "$t/v" >"$t/out" 2>&1 || rc=$?
        if [[ $rc -ne 0 ]]; then echo "FAIL $name: returned $rc, wanted 0"; ok=0; fi
        if ! grep -qF -- "$3" "$t/out"; then echo "FAIL $name: output lacks '$3'"; ok=0; fi
        if grep -E '(^|[^-])GATING|FAIL' "$t/out" >/dev/null; then echo "FAIL $name: output has a GATING or FAIL line"; ok=0; fi
        if [[ $ok -eq 1 ]]; then echo "ok   $name (returned $rc)"; else fails=1; fi
        sed 's/^/     | /' "$t/out"
    }
    # equal: the VM got what the oracle added (it also had snapd before)
    printf '%s' "$post" >"$t/v/vm-post.state"
    expect "equal" "$t/o" "NON-GATING: comparison with the docker oracle's record"
    # a package the oracle added is missing on the VM: reported, still 0
    printf '%s' "$post" | grep -v '^curl' >"$t/v/vm-post.state"
    expect "missing package" "$t/o" "- packages|curl amd64"
    # the run added a package the oracle lacks: reported, still 0
    printf '%s' "${post/snapd amd64/snapd amd64$'\n'zsh amd64}" >"$t/v/vm-post.state"
    expect "extra package" "$t/o" "+ packages|zsh amd64"
    # only apt sources differ: reported, still 0
    printf '%s' "${post/deb a/deb b}" >"$t/v/vm-post.state"
    expect "sources only" "$t/o" "apt sources differ"
    # no oracle record: the skip line is printed, still 0
    printf '%s' "$post" >"$t/v/vm-post.state"
    expect "no oracle record" "$t/none" "NON-GATING: no oracle record; run 'just test-container <distro> <c>' for the comparison"
    rm -f "$t"/o/* "$t"/v/* "$t/out"
    rmdir "$t/o" "$t/v" "$t/none" "$t"

    # the playbook allowlist: what each accepted playbook runs with
    local got
    got=$(playbook_config dev_base && echo "$PB_NAME|$PB_VARS|$PB_ORACLE|$PB_MEMORY|$PB_DISK")
    if [[ $got == "container/dev_base|vars/container.toml|1|4|" ]]; then echo "ok   playbook dev_base -> $got"
    else echo "FAIL playbook dev_base -> '$got'"; fails=1; fi
    got=$(playbook_config dev_desktop && echo "$PB_NAME|$PB_VARS|$PB_ORACLE|$PB_MEMORY|$PB_DISK")
    if [[ $got == "dev_desktop|vars/desktop.toml|0|4|30" ]]; then echo "ok   playbook dev_desktop -> $got"
    else echo "FAIL playbook dev_desktop -> '$got'"; fails=1; fi
    if (playbook_config rust_build) >/dev/null 2>&1; then echo "FAIL playbook rust_build accepted"; fails=1
    else echo "ok   playbook rust_build refused"; fi

    # a working check as each user: bot directly, any other through sudo -iu
    got=$(as_user_cmd bot 'go version')
    if [[ $got == "bash -lc 'go version'" ]]; then echo "ok   as_user_cmd bot -> $got"
    else echo "FAIL as_user_cmd bot -> '$got'"; fails=1; fi
    got=$(as_user_cmd tpdev 'id -nG')
    if [[ $got == "sudo -n -iu tpdev bash -lc 'id -nG'" ]]; then echo "ok   as_user_cmd tpdev -> $got"
    else echo "FAIL as_user_cmd tpdev -> '$got'"; fails=1; fi

    # the groups check reads `id -nG` output
    if groups_have "bot adm sudo docker libvirt" sudo docker libvirt; then echo "ok   groups_have all present"
    else echo "FAIL groups_have all present"; fails=1; fi
    if groups_have "tpdev sudo docker" sudo docker libvirt; then echo "FAIL groups_have missing libvirt passed"; fails=1
    else echo "ok   groups_have missing libvirt fails"; fi

    # the second pass: CHANGED 0, or only golang's op changed because Go released
    t=$(mktemp -d)
    local hdr='HOST                 STATUS    OK CHANGED FAILED NOT RUN  DETAIL'
    printf '%s\n' "$hdr" 'bot@192.0.2.7  ok         9       0      0       0' >"$t/r0"
    printf '%s\n' '== bot@192.0.2.7 [golang] #30 pkg[script] update go ==' '-> changed' \
        "$hdr" 'bot@192.0.2.7  changed    8       1      0       0' >"$t/rgo"
    printf '%s\n' '== bot@192.0.2.7 [docker] #12 sh systemctl enable ==' '-> changed' \
        '== bot@192.0.2.7 [golang] #30 pkg[script] update go ==' '-> changed' \
        "$hdr" 'bot@192.0.2.7  changed    7       2      0       0' >"$t/rboth"
    sp() { # name file go1 go2 want
        local g; g=$(second_pass "$2" "$3" "$4")
        if [[ $g == "$5" ]]; then echo "ok   second_pass $1 -> $g"; else echo "FAIL second_pass $1 -> '$g', wanted $5"; fails=1; fi
    }
    sp "changed 0" "$t/r0" "go1.25.3" "go1.25.3" ok
    sp "go released between passes" "$t/rgo" "go1.25.3" "go1.25.4" go-release
    sp "golang changed, no release" "$t/rgo" "go1.25.3" "go1.25.3" fail
    sp "another role changed" "$t/rboth" "go1.25.3" "go1.25.4" fail
    rm -f "$t"/r*; rmdir "$t"
    return $fails
}

if [[ ${1:-} == --self-test ]]; then self_test; exit $?; fi

# ---- arguments --------------------------------------------------------------
keep=0
if [[ ${1:-} == --keep ]]; then keep=1; shift; fi
distro=${1:-}; container=${2:-}
[[ -n $distro && -n $container ]] || die "usage: test-vm.sh [--keep] <distro> <playbook> | --self-test"
[[ $distro == ubuntu2404 ]] || die "only the ubuntu2404 image is supported, not '$distro'"
playbook_config "$container" || die "playbook '$container' is not one of: dev_base, dev_desktop"

# ---- preflight --------------------------------------------------------------
oracle=$ROOT/build/test-container/$container-$distro
[[ -x $ROOT/build/tp-basic ]] || die "build/tp-basic not found: run 'just musl' first"
[[ -f $ROOT/$PB_VARS ]] || die "$PB_VARS not found"
[[ -x $VMTOOL_DIR/vmtool ]] || die "$VMTOOL_DIR/vmtool not found"

name=tp-$container-$(date -u +%Y%m%dt%H%M%Sz)
vm_listed "$name" && die "a VM named $name already exists; not touching it"

out=$ROOT/build/test-vm/$container-$distro
mkdir -p "$out"
rm -f "$out"/*

cleanup() {
    local rc=$?
    vm_cleanup "$keep" || exit 1
    exit $rc
}
trap cleanup EXIT

# ---- create, onboard bot, wait, apt-get update (scripts/lib/vm.sh) -------------
vm_record "$name"
vm_up "$name" "$out" "" "$PB_MEMORY" "$PB_DISK"
key=$VM_KEY dest=$VM_DEST

# ---- state before -------------------------------------------------------------
vm_state "$ROOT/scripts/image-state.sh" >"$out/vm-pre.state"
echo "captured $out/vm-pre.state ($(wc -l <"$out/vm-pre.state") lines)"

# ---- the two runs -------------------------------------------------------------
changed_of() { awk '/^HOST  *STATUS/{getline; print $4; exit}' "$1"; }
status_of() { awk '/^HOST  *STATUS/{getline; print $2; exit}' "$1"; }

run() { # n
    echo "=== run $1: tp-basic run $PB_NAME --host $dest --vars $PB_VARS ==="
    local rc=0 t0=$SECONDS
    "$ROOT/build/tp-basic" run "$PB_NAME" --host "$dest" --ssh-key "$key" \
        --ssh-option StrictHostKeyChecking=accept-new \
        --ssh-option UserKnownHostsFile="$out/known_hosts" \
        --vars "$ROOT/$PB_VARS" --log "$out/run$1.jsonl" \
        >"$out/run$1.out" 2>&1 || rc=$?
    sed -n '/^HOST  *STATUS/,$p' "$out/run$1.out"
    echo "run $1 took $((SECONDS - t0))s"
    return $rc
}

# the installed Go, for second_pass (empty when the playbook has no golang)
go_now() { sshv '[ -x /usr/local/go/bin/go ] && /usr/local/go/bin/go version || true' 2>/dev/null | awk '{print $3}'; }

rc1=0; run 1 || rc1=$?
if [[ $rc1 -ne 0 ]]; then
    tail -40 "$out/run1.out"
    echo "FAIL: first run exited $rc1 (log: $out/run1.out)"
    exit 1
fi
grep '^== .* \[prepare\]' "$out/run1.out" || true
go1=$(go_now)

rc2=0; run 2 || rc2=$?
grep '^== .* \[prepare\]' "$out/run2.out" || true
go2=$(go_now)
ch=$(changed_of "$out/run2.out"); st=$(status_of "$out/run2.out")
verdict=fail
[[ $rc2 -ne 0 ]] || verdict=$(second_pass "$out/run2.out" "$go1" "$go2")
case $verdict in
    ok) echo "second run: STATUS ok, CHANGED 0" ;;
    go-release)
        echo "second run: STATUS ${st}, CHANGED ${ch}: only golang changed, and Go moved from $go1 to $go2 between the passes"
        echo "(a Go release between the passes is the one accepted cause of a nonzero count; reported, not hidden)" ;;
    *)
        echo "FAIL: second run exited $rc2, STATUS ${st:-?}, CHANGED ${ch:-?} (log: $out/run2.out)"
        echo "changed ops in the second run:"
        awk '/^== /{h=$0} /^-> changed/{print "  " h}' "$out/run2.out"
        exit 1 ;;
esac

# ---- just through mise's system shims, as bot in a login shell (gating) ----------
# dev_common puts /usr/local/share/mise/shims on login shells' PATH
# (/etc/profile.d/mise.sh) and installs just there through mise.
jrc=0; jpath=$(sshv 'bash -lc "command -v just"' 2>&1) || jrc=$?
if [[ $jrc -ne 0 || $jpath != /usr/local/share/mise/shims/just ]]; then
    echo "FAIL: bot's login shell finds just at '${jpath}' (exit $jrc), wanted /usr/local/share/mise/shims/just"
    exit 1
fi
jrc=0; jver=$(sshv 'bash -lc "just --version"' 2>&1) || jrc=$?
if [[ $jrc -ne 0 ]]; then
    echo "FAIL: bot's 'bash -lc \"just --version\"' exited $jrc:"
    printf '%s\n' "$jver"
    exit 1
fi
echo "bot: command -v just -> $jpath; just --version -> $jver"

# ---- dev_desktop: the working checks, per admin user (gating) ---------------------
# Each admin user of vars/desktop.toml, in a login shell: bot directly, tpdev
# through `sudo -n -iu` (which also proves bot's sudo needs no password).
# Every check must pass; all are run and printed before the verdict.
if [[ $container == dev_desktop ]]; then
    users=$(sed -n 's/^admin_users *= *\[\(.*\)\]/\1/p' "$ROOT/$PB_VARS" | tr -d '" ' | tr ',' ' ')
    [[ -n $users ]] || die "no admin_users in $PB_VARS"
    wrc=0
    check() { # user label command
        local r=0 o
        o=$(sshv "$(as_user_cmd "$1" "$3")" 2>&1) || r=$?
        if [[ $r -eq 0 ]]; then echo "ok   [$1] $2: $(printf '%s' "$o" | tail -1)"
        else echo "FAIL [$1] $2 (exit $r):"; printf '%s\n' "$o" | tail -5 | sed 's/^/     | /'; wrc=1; fi
    }
    echo "=== working checks (users: $users) ==="
    for u in $users; do
        check "$u" "sudo -n true" 'sudo -n true && echo yes'
        g=$(sshv "$(as_user_cmd "$u" 'id -nG')" 2>&1) || g=""
        if groups_have "$g" sudo docker libvirt; then echo "ok   [$u] id -nG has sudo docker libvirt: $g"
        else echo "FAIL [$u] id -nG lacks one of sudo docker libvirt: '$g'"; wrc=1; fi
        check "$u" "docker run --rm hello-world" 'docker run --rm hello-world | grep -m1 "Hello from Docker"'
        check "$u" "go version" 'go version'
        check "$u" "node --version" 'node --version'
        check "$u" "just --version" 'just --version'
        # mise must not warn: a root shell without `-H` kept HOME=/home/bot
        # under the drop-in's `!env_reset`, and root's mise wrote bot's
        # ~/.cache/mise (seen on 2026-11-04; the engine now runs `sudo -n -H`).
        check "$u" "just --version has no mise warning" '! (just --version 2>&1 | grep -q WARN) && echo clean'
        # Nothing under the user's home may belong to anyone else, for the
        # same reason: root's ops must write to /root, as_user ops to ~u.
        f=$(sshv "sudo -n find /home/$u -xdev ! -user $u -print 2>/dev/null | head -5") || f="(find failed)"
        if [[ -z $f ]]; then echo "ok   [$u] home has no files owned by others"
        else echo "FAIL [$u] home has files owned by others:"; printf '%s\n' "$f" | sed 's/^/     | /'; wrc=1; fi
        check "$u" "tmux -V" 'tmux -V'
        check "$u" "virsh --version" 'virsh --version'
        # non-gating: the VM may not offer nested KVM (A-5b-13)
        v=$(sshv "$(as_user_cmd "$u" 'virsh -c qemu:///system version')" 2>&1) || true
        echo "info [$u] virsh -c qemu:///system version (non-gating):"
        printf '%s\n' "$v" | sed 's/^/     | /'
    done
    if [[ $wrc -ne 0 ]]; then echo "FAIL: a working check failed"; exit 1; fi
    echo "working checks: all passed"
fi

# ---- state after and the non-gating comparison -----------------------------------
# Neither the capture nor the report decides the exit code. Only dev_base has
# a docker oracle record to compare with.
crc=0
{ vm_state "$ROOT/scripts/image-state.sh" >"$out/vm-post.state" \
    && vm_state "$ROOT/scripts/image-state.sh" --versions >"$out/vm-post.versions"; } || crc=$?
if [[ $crc -ne 0 ]]; then
    echo "test-vm: WARNING: the post capture exited $crc; no comparison report" >&2
else
    echo "captured $out/vm-post.state ($(wc -l <"$out/vm-post.state") lines)"
    if [[ $PB_ORACLE -eq 1 ]]; then
        echo "=== comparison with the oracle ($oracle), non-gating ==="
        rrc=0; oracle_report "$oracle" "$out" || rrc=$?
        [[ $rrc -eq 0 ]] || echo "test-vm: WARNING: the comparison report returned $rrc" >&2
    fi
fi
echo "PASS: $PB_NAME on a $distro VM over SSH (run 1 ok; run 2 $verdict)"
exit 0
