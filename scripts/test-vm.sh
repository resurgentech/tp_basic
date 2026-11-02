#!/usr/bin/env bash
# VM check over SSH, a proof of the SSH transport: create a fresh VM with
# ~/repos/jaredeh/vmtool, apply container/<container> to it twice with
# `tp-basic run --host`, and delete the VM. Usage errors and environment
# problems (no VM IP, no onboarding) exit 2; a failed first run, a second run
# that is not STATUS ok / CHANGED 0, or a VM still listed after the delete
# exits 1.
#
#   scripts/test-vm.sh [--keep] <distro> <container>   (only: ubuntu2404 dev_base)
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
# a separate check (scripts/test-vm-oracle.sh, to come).
#
# Outputs (gitignored): build/test-vm/<container>-<distro>/
#   create.log, onboard.log, wait.log, prep.log, vm-pre.state, vm-post.state, vm-post.versions,
#   run1.jsonl, run2.jsonl, run1.out, run2.out, known_hosts, comparison.txt
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VMTOOL_DIR=$HOME/repos/jaredeh/vmtool

die() { echo "test-vm: $*" >&2; exit 2; }

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
    return $fails
}

if [[ ${1:-} == --self-test ]]; then self_test; exit $?; fi

# ---- arguments --------------------------------------------------------------
keep=0
if [[ ${1:-} == --keep ]]; then keep=1; shift; fi
distro=${1:-}; container=${2:-}
[[ -n $distro && -n $container ]] || die "usage: test-vm.sh [--keep] <distro> <container> | --self-test"
[[ $distro == ubuntu2404 && $container == dev_base ]] || die "only 'ubuntu2404 dev_base' is supported, not '$distro $container'"

# ---- preflight --------------------------------------------------------------
oracle=$ROOT/build/test-container/$container-$distro
[[ -x $ROOT/build/tp-basic ]] || die "build/tp-basic not found: run 'just musl' first"
[[ -f $ROOT/vars/container.toml ]] || die "vars/container.toml not found"
[[ -x $VMTOOL_DIR/vmtool ]] || die "$VMTOOL_DIR/vmtool not found"

vmtool() { (cd "$VMTOOL_DIR" && ./vmtool "$@"); }
# vm_ip <name> : the IP column of the list row whose NAME is exactly <name>.
vm_ip() { vmtool list | awk -v n="$1" 'NR > 1 && $1 == n { print $NF }'; }
vm_listed() { vmtool list | awk -v n="$1" 'NR > 1 && $1 == n { f = 1 } END { exit !f }'; }

name=tp-$container-$(date -u +%Y%m%dt%H%M%Sz)
vm_listed "$name" && die "a VM named $name already exists; not touching it"

out=$ROOT/build/test-vm/$container-$distro
mkdir -p "$out"
rm -f "$out"/*

cleanup() {
    local rc=$?
    if [[ $keep -eq 1 ]]; then
        echo "--keep: VM $name left running (delete with: cd $VMTOOL_DIR && ./vmtool delete $name)"
    else
        if vm_listed "$name"; then
            echo "=== deleting VM $name ==="
            vmtool delete "$name" || echo "test-vm: WARNING: vmtool delete $name failed" >&2
        fi
        if vm_listed "$name"; then
            echo "test-vm: WARNING: VM $name is still listed by 'vmtool list' after the delete" >&2
            exit 1
        fi
        echo "VM $name deleted (not in 'vmtool list')"
    fi
    exit $rc
}
trap cleanup EXIT

# ---- create -----------------------------------------------------------------
echo "=== creating VM $name (ubuntu2404.qcow2, 4 GiB) ==="
crc=0
vmtool create "$name" ubuntu2404.qcow2 --memory 4 >"$out/create.log" 2>&1 || crc=$?
if grep -q 'timed out waiting for IP' "$out/create.log"; then
    tail -5 "$out/create.log"
    echo "test-vm: the VM got no IP. This is a host environment problem, not a telepatch failure:" >&2
    echo "test-vm: see $VMTOOL_DIR/README.md, \"Troubleshooting\" > \"A new VM never gets an IP\"." >&2
    exit 2
fi
[[ $crc -eq 0 ]] || { tail -20 "$out/create.log"; die "vmtool create exited $crc (log: $out/create.log)"; }

ip=$(vm_ip "$name")
[[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "no IP for $name in 'vmtool list' (got '${ip:-}')"

# Onboarding: vmtool's setup_bot.yml makes user bot (key auth, passwordless
# sudo) and writes the key to its .machines/<name>/id_ed25519. It is run once
# the guest's sshd answers: `create --playbook` runs it right after the IP and
# races sshd's start (observed: "Connection refused").
echo "=== waiting for sshd on $ip, then onboarding bot (setup_bot.yml) ==="
deadline=$((SECONDS + 300))
until timeout 5 bash -c "exec 3<>/dev/tcp/$ip/22" 2>/dev/null; do
    [[ $SECONDS -lt $deadline ]] || die "sshd on $name ($ip) did not answer within 5 min"
    sleep 3
done
vmtool playbook "$name" setup_bot.yml >"$out/onboard.log" 2>&1 \
    || { grep -E 'fatal|ERROR|RECAP' "$out/onboard.log" | tail -5; die "vmtool playbook $name setup_bot.yml failed (log: $out/onboard.log)"; }
key=$VMTOOL_DIR/.machines/$name/id_ed25519
[[ -f $key ]] || die "no key at $key"
dest=bot@$ip
echo "VM $name at $ip"

sshv() {
    ssh -T -i "$key" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$out/known_hosts" "$dest" "$@"
}

# ---- wait for cloud-init and the dpkg lock (bounded, 10 min) ----------------
echo "=== waiting for cloud-init and a free dpkg lock ==="
ready='cloud-init status --wait >/dev/null 2>&1; s=$?; [ $s -eq 0 ] || [ $s -eq 2 ] || exit 1
if command -v fuser >/dev/null 2>&1; then
  ! sudo -n fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1
else
  ! pgrep -x "apt|apt-get|dpkg|unattended-upgr" >/dev/null
fi'
deadline=$((SECONDS + 600))
until sshv "$ready" >>"$out/wait.log" 2>&1; do
    [[ $SECONDS -lt $deadline ]] || { tail -5 "$out/wait.log"; echo "FAIL: VM not ready after 10 min (log: $out/wait.log)"; exit 1; }
    sleep 5
done
echo "ready after $((SECONDS - deadline + 600))s"

# The cloud image ships package lists from its build date, whose archive
# files are gone (observed: 404 on the first install). The oracle's
# Dockerfile runs `apt-get update --fix-missing` before tp-basic; this is the
# same environment step, done before the "before" capture so it is not
# counted as something the run added.
echo "=== apt-get update on the VM (as the oracle's Dockerfile does) ==="
sshv 'sudo -n apt-get -q update --fix-missing' >"$out/prep.log" 2>&1 \
    || { tail -10 "$out/prep.log"; die "apt-get update on the VM failed (log: $out/prep.log)"; }

# ---- state before -------------------------------------------------------------
sshv 'sudo -n sh -s' <"$ROOT/scripts/image-state.sh" >"$out/vm-pre.state"
echo "captured $out/vm-pre.state ($(wc -l <"$out/vm-pre.state") lines)"

# ---- the two runs -------------------------------------------------------------
changed_of() { awk '/^HOST  *STATUS/{getline; print $4; exit}' "$1"; }
status_of() { awk '/^HOST  *STATUS/{getline; print $2; exit}' "$1"; }

run() { # n
    echo "=== run $1: tp-basic run container/$container --host $dest ==="
    local rc=0
    "$ROOT/build/tp-basic" run "container/$container" --host "$dest" --ssh-key "$key" \
        --ssh-option StrictHostKeyChecking=accept-new \
        --ssh-option UserKnownHostsFile="$out/known_hosts" \
        --vars "$ROOT/vars/container.toml" --log "$out/run$1.jsonl" \
        >"$out/run$1.out" 2>&1 || rc=$?
    sed -n '/^HOST  *STATUS/,$p' "$out/run$1.out"
    return $rc
}

rc1=0; run 1 || rc1=$?
if [[ $rc1 -ne 0 ]]; then
    tail -40 "$out/run1.out"
    echo "FAIL: first run exited $rc1 (log: $out/run1.out)"
    exit 1
fi
grep '^== .* \[prepare\]' "$out/run1.out" || true

rc2=0; run 2 || rc2=$?
grep '^== .* \[prepare\]' "$out/run2.out" || true
ch=$(changed_of "$out/run2.out"); st=$(status_of "$out/run2.out")
if [[ $rc2 -ne 0 || $ch != 0 || $st != ok ]]; then
    echo "FAIL: second run exited $rc2, STATUS ${st:-?}, CHANGED ${ch:-?} (log: $out/run2.out)"
    echo "changed ops in the second run:"
    awk '/^== /{h=$0} /^-> changed/{print "  " h}' "$out/run2.out"
    exit 1
fi
echo "second run: STATUS ok, CHANGED 0"

# ---- state after and the non-gating comparison -----------------------------------
# Neither the capture nor the report decides the exit code.
crc=0
{ sshv 'sudo -n sh -s' <"$ROOT/scripts/image-state.sh" >"$out/vm-post.state" \
    && sshv 'sudo -n sh -s -- --versions' <"$ROOT/scripts/image-state.sh" >"$out/vm-post.versions"; } || crc=$?
if [[ $crc -ne 0 ]]; then
    echo "test-vm: WARNING: the post capture exited $crc; no comparison report" >&2
else
    echo "captured $out/vm-post.state ($(wc -l <"$out/vm-post.state") lines)"
    echo "=== comparison with the oracle ($oracle), non-gating ==="
    rrc=0; oracle_report "$oracle" "$out" || rrc=$?
    [[ $rrc -eq 0 ]] || echo "test-vm: WARNING: the comparison report returned $rrc" >&2
fi
echo "PASS: $container on a $distro VM over SSH (run 1 ok; run 2 STATUS ok, CHANGED 0)"
exit 0
