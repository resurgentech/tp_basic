#!/usr/bin/env bash
# VM check over SSH, a proof of the SSH transport: create a fresh VM with
# ~/repos/jaredeh/vmtool, apply a playbook to it twice with
# `tp-basic run --host`, and delete the VM. The playbooks (playbook_config):
# dev_base (container/dev_base, vars/container.toml, 1 GiB; the production
# acceptance runner was retired, so this script does not compare it to a
# container record) and dev_desktop (vars/desktop.toml, 1 GiB, 30 GB disk;
# after run 2 the per-user working checks below gate). Usage errors and environment
# problems (no VM IP, no onboarding) exit 2; a failed first run, a second run
# that is not STATUS ok / CHANGED 0, or a VM still listed after the delete
# exits 1 (a Go release between the passes is the one accepted cause of a
# nonzero count on dev_desktop, and is printed as such). After run 2 it also gates on bot's login shell: `command -v just`
# must print /usr/local/share/mise/shims/just and `just --version` must work
# (dev_common's mise; exit 1 with the output otherwise).
#
# dev_desktop makes three runs, the only booted-systemd proof of the svc
# primitive (nothing privileged runs on this machine: no systemd-as-init
# container): run 1 (ok); then `sudo systemctl disable --now docker` over SSH,
# gated on `is-enabled docker` = disabled and `is-active docker` = inactive;
# run 2 must be STATUS changed with CHANGED 1, the one changed op the svc op of
# docker, and its prepare line `svc docker.service: will enable, will start`
# (the enable-then-start path, not only the no-op); run 3 must be CHANGED 0
# (the Go-release tolerance applies to run 3). After the per-user checks,
# `systemctl is-enabled` of docker and libvirtd.socket must print enabled and
# `is-active` active. dev_base stays two runs (run 2 CHANGED 0).
# The daemon-reload of a changed unit is proved by services_vm (below).
#
# services_vm (test-only, vars/services_vm.toml, 1 GiB, the image's disk, five
# runs, every check prints ok or FAIL and all gate): run 1 exits 0 and
# tp-probe.service is enabled and active with its drop-in, tp-probe-off.service
# is disabled and inactive, tp-probe-masked.service is masked, and the guarded
# restart and reload are suppressed by the start; run 2 is CHANGED 0 and its
# guarded restart and reload end `-> skipped (when ..)`; then run 3 is given a
# vars copy (build/test-vm/<c>-<distro>/vars-run3.toml) that changes
# `services_vm.probe_description`, i.e. the unit file's Description= line:
# the changed ops are exactly the unit's content and the probe's restart,
# `systemctl show -p ExecMainStartTimestamp` moves, and the journal gains
# exactly one `Reloading requested from client` line, matching exactly one
# `daemon_reload` event in run3.jsonl. Run 4 changes only `probe_conf`
# (vars-run4.toml, keeping run 3's Description=): the changed ops are the conf
# file and the guarded reload (`-> changed`), no restart, MainPID unchanged,
# zero `daemon_reload` events and journal delta 0. Run 5, the same vars, is
# CHANGED 0.
#
#   scripts/test-vm.sh [--keep] <distro> <playbook>   (ubuntu2404; dev_base, dev_desktop or services_vm)
#   scripts/test-vm.sh --self-test
#
# Needs: build/tp-basic (`just musl`). This script does not read a container
# record. dev_base is a different playbook from the edge cell.
#
# The VM is named tp-<container>-<UTC stamp>; a trap deletes that one VM on
# every exit unless --keep, then checks `vmtool list` no longer shows it. The
# SSH key is vmtool's, used in place from .machines/<vm>/ and never copied,
# when the VM host is local; when TP_VM_HOST names a remote host it is a
# per-run key made here (scripts/lib/vm.sh), and tp-basic and every guest
# command reach the guest through ProxyJump=$TP_VM_HOST.
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
        echo "NON-GATING: no oracle record (the production acceptance runner was retired)"
        return 0
    fi
    compare_vm "$o" "$v"
}

# ---- the playbooks this script runs, and the working checks ---------------------

# playbook_config <playbook> : the allowlist. Sets PB_NAME (the registered
# playbook), PB_VARS (relative to the repo), PB_ORACLE (0: the production
# acceptance runner was retired, and this script does not compare against a
# container record), PB_MEMORY (GiB) and PB_DISK (GB, empty for the image's
# size). Returns 1 for any other name.
playbook_config() {
    case $1 in
        dev_base) PB_NAME=container/dev_base PB_VARS=vars/container.toml PB_ORACLE=0 PB_MEMORY=1 PB_DISK= ;;
        # docker, libvirt, Go, Node and two rustup trees do not fit the
        # image's own disk, and the libvirt and docker daemons want memory.
        dev_desktop) PB_NAME=dev_desktop PB_VARS=vars/desktop.toml PB_ORACLE=0 PB_MEMORY=1 PB_DISK=30 ;;
        # test-only (src/playbooks/desktop.rs): a few units, nothing is
        # installed, so the image's own disk is plenty.
        services_vm) PB_NAME=services_vm PB_VARS=vars/services_vm.toml PB_ORACLE=0 PB_MEMORY=1 PB_DISK= ;;
        *) return 1 ;;
    esac
}

# desktop_secret_vars <dest> : a copy of vars/desktop.toml whose password is
# an env reference. The hash stays in TP_TEST_PW_HASH and is not written.
desktop_secret_vars() {
    grep -v '^default_password[[:space:]]*=' "$ROOT/vars/desktop.toml" >"$1"
    printf '\ndefault_password = { env = "TP_TEST_PW_HASH" }\n' >>"$1"
}

# tpb_ssh_args <key> <known_hosts> : fills TPB_SSH_ARGS, the ssh arguments of
# `tp-basic run --host`. A remote VM host adds the jump (the telepatch ssh
# master takes it as an ordinary option; only mux channels override
# ProxyCommand).
tpb_ssh_args() {
    TPB_SSH_ARGS=(--ssh-key "$1" --ssh-option StrictHostKeyChecking=accept-new
        --ssh-option UserKnownHostsFile="$2")
    vm_is_local || TPB_SSH_ARGS+=(--ssh-option "ProxyJump=$TP_VM_HOST")
}

# su_tpdev : ssh as bot and `su` to tpdev. The password is stdin of the
# remote python, never an argument and never printed. Returns 0 when su
# prints tp-su-ok.
su_tpdev() {
    local py b64
    py=$(cat <<'PY'
import os, pty, select, sys, time
pw = sys.stdin.buffer.readline()
if pw.endswith(b"\n"):
    pw = pw[:-1]
if pw.endswith(b"\r"):
    pw = pw[:-1]
pid, fd = pty.fork()
if pid == 0:
    os.execvp("su", ["su", "-c", "printf tp-su-ok", "tpdev"])
buf = b""
sent = False
deadline = time.time() + 10
status = 1
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            chunk = b""
        if chunk:
            buf += chunk
            if (not sent) and (b"assword" in buf):
                os.write(fd, pw + b"\n")
                sent = True
        else:
            break
    try:
        wpid, st = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        break
    if wpid == pid:
        status = st
        break
else:
    try:
        os.kill(pid, 15)
    except OSError:
        pass
    try:
        _, status = os.waitpid(pid, 0)
    except ChildProcessError:
        pass
# An empty read means the slave closed, which happens as su exits and
# often before waitpid has run. Reap here, and keep any last bytes.
while True:
    r, _, _ = select.select([fd], [], [], 0)
    if not r:
        break
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    buf += chunk
try:
    _, status = os.waitpid(pid, 0)
except ChildProcessError:
    pass
ok = sent and (b"tp-su-ok" in buf) and os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0
sys.exit(0 if ok else 1)
PY
)
    b64=$(printf '%s' "$py" | base64 -w0)
    printf '%s\n' "$TP_TEST_PW" | sshv "python3 -c \"import base64; exec(base64.b64decode('$b64'))\""
}

# logs_have_secret <files...> : 0 when a file contains the throwaway
# password or its hash. Does not print the match.
logs_have_secret() {
    local f
    [[ -n ${TP_TEST_PW:-} && -n ${TP_TEST_PW_HASH:-} ]] || return 1
    for f in "$@"; do
        [[ -f $f ]] || continue
        if grep -q -F -- "$TP_TEST_PW" "$f" || grep -q -F -- "$TP_TEST_PW_HASH" "$f"; then
            return 0
        fi
    done
    return 1
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

# one_svc_change <run.out> <label> : true when the run is STATUS changed with
# CHANGED 1 and the one changed op is the svc op whose header label is <label>
# (the unit as the role wrote it: `svc docker`, while prepare names the key
# `svc docker.service`).
one_svc_change() {
    local out=$1 unit=$2 ch st n
    ch=$(awk '/^HOST  *STATUS/{getline; print $4; exit}' "$out")
    st=$(awk '/^HOST  *STATUS/{getline; print $2; exit}' "$out")
    [[ $st == changed && $ch == 1 ]] || return 1
    n=$(awk '/^== /{h=$0} /^-> changed/{print h}' "$out")
    [[ $(printf "%s\n" "$n" | wc -l) -eq 1 && $n == *" svc $unit =="* ]]
}

# op_result <run.out> <op description> : the `-> ...` line that ends the first
# op whose header names the description exactly (`svc tp-probe.service
# restart`; the header is `== <host> [<roles>] #<id> <desc> ==`).
op_result() {
    awk -v d=" $2 ==" '/^== /{h = (substr($0, length($0) - length(d) + 1) == d); next} h && /^-> /{print; exit}' "$1"
}

# changed_ops <run.out> : the description of every op that ended `-> changed`.
changed_ops() {
    awk '/^== /{h = $0; sub(/^== [^]]*\] #[0-9]+ /, "", h); sub(/ ==$/, "", h); next} /^-> changed/{print h}' "$1"
}

# restarts_of <run.out> : how many times the probe's restart op changed.
restarts_of() { changed_ops "$1" | grep -cxF 'svc tp-probe.service restart' || true; }

# reloads_in <journal text file> : how many daemon-reloads systemd logged
# (`Reloading requested from client PID <n> ('systemctl') ...`, one per
# reload; `Reloading finished in <t>` follows it).
reloads_in() { grep -c 'Reloading requested from client' "$1" || true; }

# daemon_reload_events <jsonl> : how many `daemon_reload` events telepatch
# wrote (one per daemon-reload it ran; a skipped one writes nothing).
daemon_reload_events() { grep -c '"ev":"daemon_reload"' "$1" || true; }

# services_vm_vars3 <file> : run 3's vars file, the description changed and
# probe_conf left at its default (omitted, so the conf op does not move).
services_vm_vars3() {
    printf '%s\n' '# services_vm run 3: the probe unit'"'"'s Description= changed' '[services_vm]' 'probe_description = "telepatch services_vm probe, changed"' >"$1"
}

# services_vm_vars4 <file> : run 4's vars file. Keeps run 3's Description=
# (already on the host, so the unit does not change back) and changes only
# probe_conf.
services_vm_vars4() {
    printf '%s\n' '# services_vm run 4: only /etc/tp-probe.conf changes' '[services_vm]' \
        'probe_description = "telepatch services_vm probe, changed"' 'probe_conf = "probe=2\n"' >"$1"
}

# groups_have <id -nG output> <group>... : true when every group is listed.
groups_have() {
    local have=" $1 " g
    shift
    for g in "$@"; do [[ $have == *" $g "* ]] || return 1; done
}

# vm_lib_self_test : scripts/lib/vm.sh's memory rule, OOM check and memory
# report, with sshv replaced by a stub (no VM, no ssh, no vmtool).
vm_lib_self_test() {
    local t fails=0 rc
    t=$(mktemp -d)
    # every tp-* VM at 1 GiB: vm_up refuses any other size before vmtool runs
    rc=0; (vmtool() { echo "vmtool ran" >"$t/vmtool"; }; vm_up tp-x "$t" "" 4) >"$t/out" 2>&1 || rc=$?
    if [[ $rc -eq 2 && ! -e $t/vmtool ]] && grep -q 'every tp-\* VM gets 1 GiB' "$t/out"; then echo "ok   vm_up refuses 4 GiB before vmtool"
    else echo "FAIL vm_up 4 GiB: exit $rc"; sed 's/^/     | /' "$t/out"; fails=1; fi
    [[ $VM_MEMORY_GIB == 1 && $VM_SWAP_GIB == 4 ]] && echo "ok   VM_MEMORY_GIB=1 VM_SWAP_GIB=4" || { echo "FAIL VM_MEMORY_GIB=$VM_MEMORY_GIB VM_SWAP_GIB=$VM_SWAP_GIB"; fails=1; }
    # no script passes any other memory to vm_up or vmtool
    if grep -nE -- '--memory [^"$]|PB_MEMORY=[^1]' "$ROOT"/scripts/*.sh "$ROOT"/scripts/lib/*.sh | grep -v 'vm_lib_self_test\|grep -nE\|t "unknown flag"'; then
        echo "FAIL a script asks for another memory size"; fails=1; else echo "ok   no script asks for more than 1 GiB"; fi
    # the OOM check: a kernel log with an oom-kill
    local kern=$'[ 812.1] cc1plus invoked oom-killer: gfp_mask=0x140cca\n[ 812.3] Out of memory: Killed process 4242 (cc1plus) total-vm:900000kB\n[ 812.4] oom_reaper: reaped process 4242 (cc1plus)'
    rc=0; (sshv() { printf '%s\n' "$kern"; }; VM_DEST=bot@192.0.2.7 VM_STEP="run 1: tp-basic run dev_desktop"; vm_oom_check "$t" "") >"$t/out" 2>&1 || rc=$?
    if [[ $rc -eq 1 ]] && grep -q 'MEMORY FAILURE' "$t/out" && grep -q 'step running: run 1: tp-basic run dev_desktop' "$t/out" \
        && grep -q 'killed: Killed process 4242 (cc1plus)' "$t/out" && grep -q 'Out of memory: Killed process 4242' "$t/kernel.log"; then
        echo "ok   oom: line, killed process and step printed, kernel.log kept"
    else echo "FAIL oom check: exit $rc"; sed 's/^/     | /' "$t/out"; fails=1; fi
    rc=0; (sshv() { echo '[ 1.0] Linux version 6.8'; }; VM_DEST=bot@192.0.2.7; vm_oom_check "$t" "") >"$t/out" 2>&1 || rc=$?
    [[ $rc -eq 0 && ! -s $t/out ]] && echo "ok   no oom: silent, 0" || { echo "FAIL no-oom check: exit $rc"; fails=1; }
    # vm_end: a failure with an OOM returns 3, without one keeps the status
    rc=0; (sshv() { printf '%s\n' "$kern"; }; VM_DEST=bot@192.0.2.7; vm_end "$t" "" 1) >"$t/out" 2>&1 || rc=$?
    [[ $rc -eq 3 ]] && echo "ok   vm_end: failure with oom -> 3" || { echo "FAIL vm_end oom: $rc"; fails=1; }
    rc=0; (sshv() { echo quiet; }; VM_DEST=bot@192.0.2.7; vm_end "$t" "" 0) >"$t/out" 2>&1 || rc=$?
    [[ $rc -eq 0 ]] && echo "ok   vm_end: success -> 0" || { echo "FAIL vm_end ok: $rc"; fails=1; }
    # the memory report: peak used = total - free - buff - cache, peak swap
    local rep=$'== free -m\n               total        used        free      shared  buff/cache   available\nMem:             957         300         400           1         257         657\nSwap:           4095          12        4083\n== swapon --show\nNAME     TYPE SIZE USED PRIO\n/tp-swap file   4G  12M   -2\n== vmstat -S M -s\n 957 M total memory\n== vmstat -n -S M 5 (sampler)\nprocs -----------memory---------- ---swap-- -----io---- -system-- ------cpu-----\n r  b   swpd   free   buff  cache   si   so    bi    bo   in   cs us sy id wa st\n 1  0      0    600     20    200    0    0     1     1   10   10  1  1 98  0  0\n 2  0    700     50     10    100    0    0     1     1   10   10  1  1 98  0  0\n 1  0     12    400     17    240    0    0     1     1   10   10  1  1 98  0  0'
    (sshv() { printf '%s\n' "$rep"; }; VM_DEST=bot@192.0.2.7; vm_mem_report "$t" "") >"$t/out" 2>&1
    if grep -q 'memory: total 957 MiB; peak used 797 MiB, peak swap used 700 MiB (3 vmstat samples' "$t/out" && grep -q '^Mem: ' "$t/out"; then
        echo "ok   memory report: free -m and peak used 797, swap 700"
    else echo "FAIL memory report"; sed 's/^/     | /' "$t/out"; fails=1; fi
    rm -rf "$t"
    return $fails
}
# vm_host_self_test : scripts/lib/vm.sh on a remote VM host and on `local`, with
# stub ssh, timeout and vmtool on PATH that record argv (no network, no VM). Each
# call is written as its arguments joined by US (0x1f) and ended by RS (0x1e).
vm_host_self_test() {
    local d fails=0 rc n got want key mem1=1
    d=$(mktemp -d)
    mkdir -p "$d/bin" "$d/vt/.machines/tp-x" "$d/out" "$d/run"
    : >"$d/vt/.machines/tp-x/id_ed25519"
    cat >"$d/bin/ssh" <<'EOF'
#!/usr/bin/env bash
{ printf '%s\x1f' "$@"; printf '\x1e'; } >>"$STUB_LOG"
last=${!#} script=$last
if [[ $last == 'bash -c '* ]]; then eval "set -- $last"; script=$3; fi
case $script in
    *'./vmtool list'*) cat "$STUB_LIST"; exit "${STUB_LIST_RC:-0}" ;;
    *'./vmtool delete'*) sed -i "/^${script##* } /d" "$STUB_LIST"; exit 0 ;;
    'test -e'*) exit "${STUB_TEST_RC:-1}" ;;
    *authorized_keys*) cat >"$STUB_LOG.stdin"; exit 0 ;;
    *swapon*) echo '/tp-swap file 4G'; exit 0 ;;
esac
exit 0
EOF
    printf '#!/usr/bin/env bash\necho "timeout $*" >>"$STUB_LOG.local"\nexit 0\n' >"$d/bin/timeout"
    cat >"$d/vt/vmtool" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG.vmtool"
case $1 in
    list) cat "$STUB_LIST" ;;
    delete) sed -i "/^$2 /d" "$STUB_LIST" ;;
esac
exit 0
EOF
    chmod +x "$d/bin/ssh" "$d/bin/timeout" "$d/vt/vmtool"
    local list=$'NAME STATE IP\ntp-x running 192.168.122.50'
    reset() { : >"$d/log"; rm -f "$d/log.stdin" "$d/log.local" "$d/log.vmtool"; printf '%s\n' "$list" >"$d/list"; rm -rf "$d/out"; mkdir -p "$d/out"; }
    # decode <log> : one line per call. A remote call is `REMOTE <ssh options> | <script>`, the script as bash
    # gets it after the login shell's word splitting (eval of the one argument); anything else is `RAW <args>`.
    decode() {
        local rec f last
        while IFS= read -r -d $'\x1e' rec; do
            mapfile -d $'\x1f' -t f < <(printf '%s' "$rec")
            last=${f[-1]}
            if [[ $last == 'bash -c '* ]]; then
                (eval "set -- $last"; if [[ $# -eq 3 && $1 == bash && $2 == -c ]]; then printf 'REMOTE %s | %s\n' "${f[*]:0:${#f[@]}-1}" "$3"; else printf 'BADQUOTE %s\n' "$last"; fi)
            else printf 'RAW %s\n' "${f[*]}"; fi
        done <"$1"
    }
    chk() { # name rc detail...
        local name=$1 ok=$2; shift 2
        if [[ $ok -eq 0 ]]; then echo "ok   $name"; else echo "FAIL $name"; printf '     | %s\n' "$@"; fails=1; fi
    }
    # run <host> <pool> <keep> : record, vm_up, tunnel, cleanup, in a subshell; facts into $d/facts
    run() {
        reset
        : >"$d/facts"
        (
            export PATH="$d/bin:$PATH" STUB_LOG=$d/log STUB_LIST=$d/list XDG_RUNTIME_DIR=$d/run VMTOOL_DIR=$d/vt
            TP_VM_HOST=$1 TP_VM_POOL=$2 TP_VM_HOST_DIR=tp-vmtool
            vm_record tp-x
            vm_up tp-x "$d/out" "" >"$d/up.out" 2>&1
            { echo "key=$VM_KEY"; echo "mode=$(stat -c %a "$VM_KEY" 2>/dev/null)"; echo "scratch=$VM_SCRATCH"
              if [[ -n $VM_SCRATCH ]]; then if cmp -s "$VM_KEY.pub" "$d/log.stdin"; then echo stdin=pub; else echo stdin=other; fi; fi
              printf 'opts=%s\n' "${VM_SSH_OPTS[*]}"; } >>"$d/facts"
            sshv 'echo hi' >/dev/null
            vm_tunnel_argv "$d/s.sock"; echo "tunnel=${VM_TUNNEL_ARGV[*]}" >>"$d/facts"
            vm_cleanup "$3" >"$d/cleanup.out" 2>&1 || echo "cleanup-rc=$?" >>"$d/facts"
        ) 2>"$d/up.err" || echo "run-rc=$?" >>"$d/facts"
        decode "$d/log" >"$d/dec"
    }

    # ---- remote ----
    run veritech04.labtwo tp 0
    key=$(sed -n 's/^key=//p' "$d/facts")
    local O='-o BatchMode=yes veritech04.labtwo | '
    local H='cd "$HOME/tp-vmtool" && ./vmtool'
    want="REMOTE ${O}$H create tp-x ubuntu2404.qcow2 --memory $mem1 --disk-size 14 --pool tp"
    grep -qxF "$want" "$d/dec"; chk "remote create: 1 GiB, --disk-size 14, --pool tp, one bash -c argument" $? "$(cat "$d/dec" "$d/up.err" "$d/up.out" 2>&1 | head -20)"
    ! grep -q '^BADQUOTE' "$d/dec"; chk "remote: every command decodes (eval of the word list) to bash -c <script>" $?
    grep -qxF "REMOTE ${O}timeout 5 bash -c 'exec 3<>/dev/tcp/192.168.122.50/22'" "$d/dec"; chk "remote: tcp/22 probed from the VM host" $? "$(cat "$d/dec")"
    [[ ! -e $d/log.local ]]; chk "remote: no probe from this machine" $?
    grep -qxF "REMOTE ${O}$H playbook tp-x setup_bot.yml" "$d/dec"; chk "remote: vmtool playbook tp-x setup_bot.yml on the host" $?
    want="REMOTE ${O}ssh -i \"\$HOME/tp-vmtool/.machines/tp-x/id_ed25519\" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR bot@192.168.122.50 'umask 077; mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys'"
    grep -qxF "$want" "$d/dec"; chk "remote: key install runs on the host with vmtool's key in place" $? "$(cat "$d/dec")"
    grep -q '^stdin=pub$' "$d/facts"; chk "remote: the install's stdin is the run key's .pub" $? "$(cat "$d/facts")"
    grep -qxF "REMOTE ${O}$H list" "$d/dec"; chk "remote: vmtool list on the host" $?
    grep -qxF "REMOTE ${O}$H delete tp-x" "$d/dec"; chk "remote: vmtool delete tp-x on the host" $?
    grep -qxF "REMOTE ${O}test -e \"\$HOME/tp-vmtool/.machines/tp-x\"" "$d/dec"; chk "remote: .machines/tp-x checked gone with test -e" $?
    ! grep -q '^cleanup-rc' "$d/facts"; chk "remote: cleanup ok after the delete is verified" $? "$(cat "$d/facts" "$d/cleanup.out")"
    [[ $key == "$d"/run/tp-vm.*/id_tp-x ]]; chk "remote: run key under XDG_RUNTIME_DIR scratch ($key)" $?
    grep -q '^mode=600$' "$d/facts"; chk "remote: run key mode 0600" $?
    [[ -n $key && ! -e $key && ! -e $(sed -n 's/^scratch=//p' "$d/facts") ]]; chk "remote: scratch dir and run key removed by vm_cleanup" $?
    local pre="RAW -T -i $key -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$d/out/known_hosts -o ProxyJump=veritech04.labtwo bot@192.168.122.50 "
    got=$(grep -c '^RAW ' "$d/dec")
    [[ $got -ge 4 && $(grep '^RAW ' "$d/dec" | grep -cF "$pre") -eq $got ]]; chk "remote sshv: -T, the run key, ProxyJump=veritech04.labtwo, bot@IP ($got calls)" $? "$(grep '^RAW ' "$d/dec" | cut -c1-200)"
    want="tunnel=ssh -i $key -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$d/out/known_hosts -o ProxyJump=veritech04.labtwo -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o StreamLocalBindUnlink=yes -N -L $d/s.sock:/var/run/docker.sock bot@192.168.122.50"
    grep -qxF "$want" "$d/facts"; chk "remote tunnel argv: same options as sshv plus the forward" $? "$(grep '^tunnel' "$d/facts")"
    ! grep -F '.machines' "$d/facts" | grep -q .; chk "remote: no .machines path in VM_SSH_OPTS or the tunnel" $?
    ! grep '^RAW ' "$d/dec" | grep -q '\.machines'; chk "remote: no .machines path in any sshv argv" $?
    head -1 "$d/out/create.log" | grep -q 'veritech04.labtwo'; chk "remote: create.log's first line names the host" $? "$(head -2 "$d/out/create.log")"
    ! grep -qE 'PRIVATE KEY|ssh-ed25519' "$d/log" "$d/dec" "$d/up.out" "$d/cleanup.out"; chk "remote: no key material in any argv or output" $?
    run veritech04.labtwo tp 1
    grep -qxF -- "--keep: VM tp-x left running on veritech04.labtwo (delete with: ssh veritech04.labtwo 'cd ~/tp-vmtool && ./vmtool delete tp-x')" "$d/cleanup.out"
    chk "remote --keep hint names the host and the delete command" $? "$(cat "$d/cleanup.out")"
    ! grep -q 'delete tp-x' "$d/dec"; chk "remote --keep: nothing deleted" $?

    # ---- delete: unreachable host, leftover .machines ----
    reset
    rc=0; got=$( (export PATH="$d/bin:$PATH" STUB_LOG=$d/log STUB_LIST=$d/list STUB_LIST_RC=255 TP_VM_HOST=veritech04.labtwo TP_VM_HOST_DIR=tp-vmtool; vm_delete tp-x) 2>&1 ) || rc=$?
    [[ $rc -eq 1 && $got == *"delete tp-x by hand: ssh veritech04.labtwo 'cd ~/tp-vmtool && ./vmtool delete tp-x'"* ]] && ! decode "$d/log" | grep -q 'vmtool delete'
    chk "vm_delete: host unreachable (255) -> exit 1 and the exact command to run by hand" $? "rc=$rc $got"
    reset
    rc=0; got=$( (export PATH="$d/bin:$PATH" STUB_LOG=$d/log STUB_LIST=$d/list STUB_TEST_RC=0 TP_VM_HOST=veritech04.labtwo TP_VM_HOST_DIR=tp-vmtool; vm_delete tp-x) 2>&1 ) || rc=$?
    [[ $rc -eq 1 && $got == *".machines/tp-x still exists on veritech04.labtwo"* ]]; chk "vm_delete: .machines/tp-x left behind -> exit 1" $? "rc=$rc $got"

    # ---- names: vm_record and vm_delete refuse, both modes, before any vmtool call ----
    for h in veritech04.labtwo local; do
        for n in vt-r1 default 'tp-x;rm' tp- TP-x 'tp-x y' ''; do
            reset
            rc=0; (export PATH="$d/bin:$PATH" STUB_LOG=$d/log STUB_LIST=$d/list VMTOOL_DIR=$d/vt TP_VM_HOST=$h; vm_record "$n") >/dev/null 2>&1 || rc=$?
            [[ $rc -eq 2 && ! -s $d/log && ! -e $d/log.vmtool ]]; chk "vm_record '$n' ($h): exit 2, no call" $? "rc=$rc"
            rc=0; (export PATH="$d/bin:$PATH" STUB_LOG=$d/log STUB_LIST=$d/list VMTOOL_DIR=$d/vt TP_VM_HOST=$h; vm_delete "$n") >/dev/null 2>&1 || rc=$?
            [[ $rc -eq 2 && ! -s $d/log && ! -e $d/log.vmtool ]]; chk "vm_delete '$n' ($h): exit 2, no call" $? "rc=$rc"
        done
    done
    rc=0; (export TP_VM_HOST=local; VM_RECORDED=(); vm_record tp-ok-1; [[ ${VM_RECORDED[*]} == tp-ok-1 ]]) || rc=$?
    chk "vm_record tp-ok-1 is recorded" $rc

    # ---- local: argv identical to the code before T97i ----
    run local "" 0
    got=$(cat "$d/log.vmtool")
    want="create tp-x ubuntu2404.qcow2 --memory $mem1 --disk-size 14"$'\nlist\nplaybook tp-x setup_bot.yml\nlist\ndelete tp-x\nlist'
    [[ $got == "$want" ]]; chk "local vmtool argv (create without --pool, playbook, delete)" $? "$got"
    [[ $(cat "$d/log.local") == "timeout 5 bash -c exec 3<>/dev/tcp/192.168.122.50/22" ]]; chk "local tcp/22 probe from this machine, as before" $? "$(cat "$d/log.local")"
    pre="RAW -T -i $d/vt/.machines/tp-x/id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$d/out/known_hosts bot@192.168.122.50 "
    got=$(grep -c '^RAW ' "$d/dec")
    [[ $got -ge 4 && $(grep -cF "$pre" "$d/dec") -eq $got && $(grep -c '^REMOTE' "$d/dec") -eq 0 ]]; chk "local sshv argv: vmtool's key in place, no ProxyJump, no host ($got calls)" $? "$(cut -c1-200 "$d/dec")"
    want="tunnel=ssh -i $d/vt/.machines/tp-x/id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$d/out/known_hosts -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o StreamLocalBindUnlink=yes -N -L $d/s.sock:/var/run/docker.sock bot@192.168.122.50"
    grep -qxF "$want" "$d/facts"; chk "local tunnel argv unchanged" $? "$(grep '^tunnel' "$d/facts")"
    [[ -z $(sed -n 's/^scratch=//p' "$d/facts") ]]; chk "local: no run key, no scratch dir" $?
    [[ $(head -c1 "$d/out/create.log") != '#' ]]; chk "local: create.log has no host header" $?
    rc=0; (export TP_VM_HOST=local VMTOOL_DIR=/v; VM_RECORDED=(tp-x); vm_cleanup 1) >"$d/o" 2>&1 || rc=$?
    [[ $(cat "$d/o") == "--keep: VM tp-x left running (delete with: cd /v && ./vmtool delete tp-x)" ]]; chk "local --keep hint unchanged" $? "$(cat "$d/o")"

    # ---- the 1 GiB refusal stays: before any call, on the remote host too ----
    reset
    rc=0; (export PATH="$d/bin:$PATH" STUB_LOG=$d/log STUB_LIST=$d/list TP_VM_HOST=veritech04.labtwo; vm_up tp-x "$d/out" "" 4) >"$d/o" 2>&1 || rc=$?
    [[ $rc -eq 2 && ! -s $d/log ]] && grep -q 'every tp-\* VM gets 1 GiB' "$d/o"; chk "remote vm_up 4 GiB refused before any ssh" $? "rc=$rc"

    # ---- test-vm.sh and test-vm-oracle.sh accept a remote host: bad args reach their own check ----
    local s h
    for s in test-vm test-vm-oracle; do
        for h in veritech04.labtwo unset local; do
            reset
            rc=0
            if [[ $h == unset ]]; then
                env -u TP_VM_HOST PATH="$d/bin:$PATH" STUB_LOG="$d/log" STUB_LIST="$d/list" VMTOOL_DIR="$d/vt" bash "$ROOT/scripts/$s.sh" nosuchdistro x >"$d/o" 2>&1 || rc=$?
            else
                TP_VM_HOST=$h PATH="$d/bin:$PATH" STUB_LOG="$d/log" STUB_LIST="$d/list" VMTOOL_DIR="$d/vt" bash "$ROOT/scripts/$s.sh" nosuchdistro x >"$d/o" 2>&1 || rc=$?
            fi
            [[ $rc -eq 2 && ! -s $d/log && ! -e $d/log.vmtool ]] && ! grep -qF 'T97j' "$d/o" && grep -q 'only the ubuntu2404 image' "$d/o"
            chk "$s.sh with TP_VM_HOST=$h is not refused (reaches its own argument check, no ssh or vmtool call)" $? "rc=$rc $(cat "$d/o")"
        done
    done

    # ---- the tp-basic ssh argv: local unchanged, remote adds the jump ----
    local -a loc=(--ssh-key /k/id --ssh-option StrictHostKeyChecking=accept-new --ssh-option UserKnownHostsFile=/o/known_hosts)
    local -a rem=("${loc[@]}" --ssh-option ProxyJump=veritech04.labtwo)
    (export TP_VM_HOST=local; tpb_ssh_args /k/id /o/known_hosts; [[ $(printf '%s\x1f' "${TPB_SSH_ARGS[@]}") == "$(printf '%s\x1f' "${loc[@]}")" ]])
    chk "local tp-basic ssh argv unchanged" $?
    (export TP_VM_HOST=veritech04.labtwo; tpb_ssh_args /k/id /o/known_hosts; [[ $(printf '%s\x1f' "${TPB_SSH_ARGS[@]}") == "$(printf '%s\x1f' "${rem[@]}")" ]])
    chk "remote tp-basic ssh argv adds --ssh-option ProxyJump=<host>" $?
    rm -rf "$d"
    return $fails
}
# services_vm_self_test : the log readers of the services_vm checks, on
# synthetic run output (the wording is telepatch's executor: a header
# `== <host> [<roles>] #<id> <desc> ==`, then the op's result line).
services_vm_self_test() {
    local t fails=0 got hdr='HOST                 STATUS    OK CHANGED FAILED NOT RUN  DETAIL'
    t=$(mktemp -d)
    # run 2: nothing changed, the guarded ops skipped
    printf '%s\n' \
        '== bot@h [(none)] #4 svc tp-probe.service ==' '-> ok' \
        '== bot@h [(none)] #5 svc tp-probe.service restart ==' '-> skipped (when changed(#0) & !started(#4))' \
        '== bot@h [(none)] #6 svc tp-probe.service reload ==' '-> skipped (when changed(#2))' \
        "$hdr" 'bot@h  ok  9  0  0  0' >"$t/r2"
    # run 3: the unit changed, restarted once
    printf '%s\n' \
        '== bot@h [(none)] #0 unit tp-probe.service content ==' '-> changed' \
        '== bot@h [(none)] #4 svc tp-probe.service ==' '-> ok' \
        '== bot@h [(none)] #5 svc tp-probe.service restart ==' '-> changed' \
        '== bot@h [(none)] #6 svc tp-probe.service reload ==' '-> skipped (when changed(#2))' \
        "$hdr" 'bot@h  changed  7  2  0  0' >"$t/r3"
    got=$(op_result "$t/r2" 'svc tp-probe.service restart')
    if [[ $got == '-> skipped (when changed(#0) & !started(#4))' ]]; then echo "ok   op_result restart in run 2 -> $got"
    else echo "FAIL op_result restart in run 2 -> '$got'"; fails=1; fi
    got=$(op_result "$t/r2" 'svc tp-probe.service')
    if [[ $got == '-> ok' ]]; then echo "ok   op_result state op is not the restart op -> $got"
    else echo "FAIL op_result state op -> '$got'"; fails=1; fi
    got=$(op_result "$t/r2" 'svc nothing')
    if [[ -z $got ]]; then echo "ok   op_result of an absent op is empty"
    else echo "FAIL op_result of an absent op -> '$got'"; fails=1; fi
    got=$(changed_ops "$t/r3" | tr '\n' ';')
    if [[ $got == 'unit tp-probe.service content;svc tp-probe.service restart;' ]]; then echo "ok   changed_ops run 3 -> $got"
    else echo "FAIL changed_ops run 3 -> '$got'"; fails=1; fi
    got=$(changed_ops "$t/r2" | wc -l)
    if [[ $got -eq 0 ]]; then echo "ok   changed_ops run 2 -> none"
    else echo "FAIL changed_ops run 2 -> $got"; fails=1; fi
    got=$(restarts_of "$t/r3"); if [[ $got -eq 1 ]]; then echo "ok   restarts_of run 3 -> 1"; else echo "FAIL restarts_of run 3 -> $got"; fails=1; fi
    got=$(restarts_of "$t/r2"); if [[ $got -eq 0 ]]; then echo "ok   restarts_of run 2 -> 0"; else echo "FAIL restarts_of run 2 -> $got"; fails=1; fi
    # the manager's journal lines for daemon-reloads
    printf '%s\n' 'Started tp-probe.service.' \
        "Reloading requested from client PID 811 ('systemctl') (unit session-1.scope)..." 'Reloading finished in 40 ms.' \
        "Reloading requested from client PID 905 ('systemctl') (unit session-2.scope)..." 'Reloading finished in 38 ms.' >"$t/j"
    got=$(reloads_in "$t/j"); if [[ $got -eq 2 ]]; then echo "ok   reloads_in -> 2"; else echo "FAIL reloads_in -> $got"; fails=1; fi
    : >"$t/j0"
    got=$(reloads_in "$t/j0"); if [[ $got -eq 0 ]]; then echo "ok   reloads_in of nothing -> 0"; else echo "FAIL reloads_in of nothing -> $got"; fails=1; fi
    # run 3's vars file: the one var, a value other than the default's
    services_vm_vars3 "$t/v3"
    if grep -q '^\[services_vm\]' "$t/v3" && grep -q '^probe_description = ' "$t/v3" \
        && ! grep -q '^probe_conf = ' "$t/v3" \
        && ! cmp -s "$t/v3" "$ROOT/vars/services_vm.toml" \
        && grep -q '^probe_description = ' "$ROOT/vars/services_vm.toml"; then echo "ok   services_vm_vars3 sets probe_description, differs from vars/services_vm.toml"
    else echo "FAIL services_vm_vars3"; fails=1; fi
    services_vm_vars4 "$t/v4"
    if grep -Fq 'probe_conf = "probe=2\n"' "$t/v4" \
        && grep -q 'probe, changed' "$t/v4" \
        && ! cmp -s "$t/v4" "$t/v3" \
        && ! cmp -s "$t/v4" "$ROOT/vars/services_vm.toml"; then echo "ok   services_vm_vars4 changes probe_conf and keeps run 3's Description="
    else echo "FAIL services_vm_vars4"; fails=1; fi
    printf '%s\n' '{"ev":"op_start","host":"h"}' \
        '{"ev":"daemon_reload","host":"h","reason":"before #4 svc tp-probe.service (unit tp-probe.service changed)","op":4}' \
        '{"ev":"op_result","host":"h"}' >"$t/r3.jsonl"
    got=$(daemon_reload_events "$t/r3.jsonl")
    if [[ $got -eq 1 ]]; then echo "ok   daemon_reload_events -> 1"
    else echo "FAIL daemon_reload_events -> $got"; fails=1; fi
    : >"$t/empty.jsonl"
    got=$(daemon_reload_events "$t/empty.jsonl")
    if [[ $got -eq 0 ]]; then echo "ok   daemon_reload_events of nothing -> 0"
    else echo "FAIL daemon_reload_events of nothing -> $got"; fails=1; fi
    rm -f "$t"/*; rmdir "$t"
    return $fails
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
    expect "no oracle record" "$t/none" "NON-GATING: no oracle record (the production acceptance runner was retired)"
    rm -f "$t"/o/* "$t"/v/* "$t/out"
    rmdir "$t/o" "$t/v" "$t/none" "$t"

    # the playbook allowlist: what each accepted playbook runs with
    local got
    got=$(playbook_config dev_base && echo "$PB_NAME|$PB_VARS|$PB_ORACLE|$PB_MEMORY|$PB_DISK")
    if [[ $got == "container/dev_base|vars/container.toml|0|1|" ]]; then echo "ok   playbook dev_base -> $got"
    else echo "FAIL playbook dev_base -> '$got'"; fails=1; fi
    got=$(playbook_config dev_desktop && echo "$PB_NAME|$PB_VARS|$PB_ORACLE|$PB_MEMORY|$PB_DISK")
    if [[ $got == "dev_desktop|vars/desktop.toml|0|1|30" ]]; then echo "ok   playbook dev_desktop -> $got"
    else echo "FAIL playbook dev_desktop -> '$got'"; fails=1; fi
    if (playbook_config rust_build) >/dev/null 2>&1; then echo "FAIL playbook rust_build accepted"; fails=1
    else echo "ok   playbook rust_build refused"; fi
    got=$(playbook_config services_vm && echo "$PB_NAME|$PB_VARS|$PB_ORACLE|$PB_MEMORY|$PB_DISK")
    if [[ $got == "services_vm|vars/services_vm.toml|0|1|" ]]; then echo "ok   playbook services_vm -> $got"
    else echo "FAIL playbook services_vm -> '$got'"; fails=1; fi
    services_vm_self_test || fails=1
    vm_lib_self_test || fails=1
    vm_host_self_test || fails=1

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
    # the svc pass after `disable --now docker`: one changed op, the svc op
    printf '%s\n' '== bot@192.0.2.7 [docker] #4 svc docker ==' '-> changed' \
        "$hdr" 'bot@192.0.2.7  changed    8       1      0       0' >"$t/rsvc"
    printf '%s\n' '== bot@192.0.2.7 [docker] #4 svc docker ==' '-> changed' \
        '== bot@192.0.2.7 [golang] #30 pkg[script] update go ==' '-> changed' \
        "$hdr" 'bot@192.0.2.7  changed    7       2      0       0' >"$t/rsvc2"
    printf '%s\n' '== bot@192.0.2.7 [docker] #12 sh systemctl enable ==' '-> changed' \
        "$hdr" 'bot@192.0.2.7  changed    8       1      0       0' >"$t/rsh"
    osc() { # name file want(0|1)
        local g=0; one_svc_change "$2" docker || g=1
        if [[ $g -eq $3 ]]; then echo "ok   one_svc_change $1 -> $g"; else echo "FAIL one_svc_change $1 -> $g, wanted $3"; fails=1; fi
    }
    osc "svc op only" "$t/rsvc" 0
    osc "svc and golang" "$t/rsvc2" 1
    osc "another op" "$t/rsh" 1
    osc "changed 0" "$t/r0" 1
    rm -f "$t"/r*; rmdir "$t"

    # the dev_desktop vars copy names an env var and does not contain the value
    t=$(mktemp -d)
    TP_TEST_PW=sentinel-pw TP_TEST_PW_HASH=sentinel-hash desktop_secret_vars "$t/desk.toml"
    if grep -q '{ env = "TP_TEST_PW_HASH" }' "$t/desk.toml" \
        && ! grep -q -F 'sentinel-hash' "$t/desk.toml" \
        && ! grep -q -F 'sentinel-pw' "$t/desk.toml"; then
        echo "ok   desktop_secret_vars writes an env reference and not the value"
    else
        echo "FAIL desktop_secret_vars"
        fails=1
    fi
    unset TP_TEST_PW TP_TEST_PW_HASH
    rm -rf "$t"

    # su_tpdev: a fake su that accepts the password and exits 0. The pty
    # closes as su exits, which used to be reported as failure before the
    # child was reaped. The sentinel is not printed.
    t=$(mktemp -d)
    cat >"$t/su" << 'EOF'
#!/usr/bin/env python3
import os, sys
os.write(1, b"Password: ")
pw = b""
while True:
    c = os.read(0, 1)
    if not c or c == b"\n":
        break
    pw += c
if pw == os.environ["EXPECT_PW"].encode():
    os.write(1, b"tp-su-ok")
    sys.exit(0)
sys.exit(1)
EOF
    chmod +x "$t/su"
    local rc=0
    (
        sshv() { bash -c "$1"; }
        export TP_TEST_PW=sentinel-pw EXPECT_PW=sentinel-pw PATH="$t:$PATH"
        su_tpdev
    ) >/dev/null || rc=$?
    if [[ $rc -eq 0 ]]; then echo "ok   su_tpdev accepts the password when su exits 0"
    else echo "FAIL su_tpdev returned $rc"; fails=1; fi
    rm -rf "$t"
    return $fails
}

if [[ ${1:-} == --self-test ]]; then self_test; exit $?; fi

# ---- arguments --------------------------------------------------------------
keep=0
if [[ ${1:-} == --keep ]]; then keep=1; shift; fi
distro=${1:-}; container=${2:-}
[[ -n $distro && -n $container ]] || die "usage: test-vm.sh [--keep] <distro> <playbook> | --self-test"
[[ $distro == ubuntu2404 ]] || die "only the ubuntu2404 image is supported, not '$distro'"
playbook_config "$container" || die "playbook '$container' is not one of: dev_base, dev_desktop, services_vm"

# ---- preflight --------------------------------------------------------------
[[ -x $ROOT/build/tp-basic ]] || die "build/tp-basic not found: run 'just musl' first"
[[ -f $ROOT/$PB_VARS ]] || die "$PB_VARS not found"
# vmtool lives on the VM host when it is remote; there the first vmtool call
# (vm_listed, below) is the check
if vm_is_local; then [[ -x $VMTOOL_DIR/vmtool ]] || die "$VMTOOL_DIR/vmtool not found"; fi

name=tp-$container-$(date -u +%Y%m%dt%H%M%Sz)
vm_listed "$name" && die "a VM named $name already exists; not touching it"

out=$ROOT/build/test-vm/$container-$distro
mkdir -p "$out"
rm -f "$out"/*

# dev_desktop: the throwaway hash is an env reference. It is never written
# into the vars file and never printed.
SU_FAIL=0
if [[ $container == dev_desktop ]]; then
    TP_TEST_PW=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    TP_TEST_PW_HASH=$(printf '%s' "$TP_TEST_PW" | openssl passwd -6 -stdin) || die "openssl passwd -6 failed"
    export TP_TEST_PW TP_TEST_PW_HASH
    RUN_VARS=$out/desktop-secret.toml
    desktop_secret_vars "$RUN_VARS"
fi

# the memory report always; on a failure the OOM check (exit 3 when the
# kernel killed for memory: the gate stops, the memory is not raised)
cleanup() {
    local rc=$?
    vm_end "$out" "" "$rc" || rc=$?
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
    echo "=== run $1: tp-basic run $PB_NAME --host $dest --vars ${RUN_VARS:+(changed copy) }$PB_VARS ==="
    VM_STEP="run $1: tp-basic run $PB_NAME --host $dest"
    local rc=0 t0=$SECONDS
    tpb_ssh_args "$key" "$out/known_hosts"
    "$ROOT/build/tp-basic" run "$PB_NAME" --host "$dest" "${TPB_SSH_ARGS[@]}" \
        --vars "${RUN_VARS:-$ROOT/$PB_VARS}" --log "$out/run$1.jsonl" \
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

# dev_desktop: an account this run created accepts the throwaway password.
# A failure is remembered so the idempotent pass still runs.
if [[ $container == dev_desktop ]]; then
    echo "=== su as tpdev with the throwaway password ==="
    if su_tpdev; then echo "ok   su tpdev"
    else echo "FAIL: su as tpdev did not accept the throwaway password"; SU_FAIL=1; fi
fi

# ---- services_vm: states, units and guarded restarts on a booted VM (gating) -------
# Run 1 is done (exit 0). Every check prints ok or FAIL; the verdict comes after
# all of them.
if [[ $container == services_vm ]]; then
    wrc=0
    ok() { echo "ok   $1"; }
    bad() { echo "FAIL $1"; wrc=1; }
    # vexpect <label> <want> <command>: the command's stdout, run over SSH, is <want>
    vexpect() {
        local o r=0
        o=$(sshv "$3" 2>&1) || r=$?
        if [[ $o == "$2" ]]; then ok "$1: $o"; else bad "$1 printed '$o' (exit $r), wanted '$2'"; fi
    }
    echo "=== services_vm after run 1 ==="
    grep '^== .* \[prepare\] \(unit\|svc\)' "$out/run1.out" || true
    vexpect "tp-probe.service is-enabled" enabled 'systemctl is-enabled tp-probe.service'
    vexpect "tp-probe.service is-active" active 'systemctl is-active tp-probe.service'
    vexpect "tp-probe.service drop-in applied (Environment)" 'Environment=TP_PROBE=1' 'systemctl show -p Environment tp-probe.service'
    vexpect "tp-probe-off.service is-enabled" disabled 'systemctl is-enabled tp-probe-off.service || true'
    vexpect "tp-probe-off.service is-active" inactive 'systemctl is-active tp-probe-off.service || true'
    vexpect "tp-probe-masked.service is-enabled" masked 'systemctl is-enabled tp-probe-masked.service || true'
    # Run 1's state op starts the unit, so the restart and the reload guarded
    # on run 1's unit and file writes are both suppressed by `!started(#4)`
    # (T77a): a fresh start already has the new unit and config.
    for a in restart reload; do
        r=$(op_result "$out/run1.out" "svc tp-probe.service $a")
        if [[ $r == '-> skipped (when '*'!started('* ]]; then ok "run 1: svc tp-probe.service $a suppressed by the start: $r"
        else bad "run 1: svc tp-probe.service $a ended '$r', wanted '-> skipped (when .. & !started(..))'"; fi
    done
    [[ $wrc -eq 0 ]] || { echo "FAIL: a services_vm check after run 1 failed"; exit 1; }

    echo "=== services_vm run 2: nothing changes ==="
    rc2=0; run 2 || rc2=$?
    grep '^== .* \[prepare\]' "$out/run2.out" || true
    if [[ $rc2 -eq 0 && $(status_of "$out/run2.out") == ok && $(changed_of "$out/run2.out") == 0 ]]; then ok "run 2: STATUS ok, CHANGED 0"
    else
        bad "run 2 exited $rc2, STATUS $(status_of "$out/run2.out"), CHANGED $(changed_of "$out/run2.out") (log: $out/run2.out)"
        changed_ops "$out/run2.out" | sed 's/^/     changed: /'
    fi
    for a in restart reload; do
        r=$(op_result "$out/run2.out" "svc tp-probe.service $a")
        if [[ $r == '-> skipped (when '* ]]; then ok "run 2: svc tp-probe.service $a shown as skipped: $r"
        else bad "run 2: svc tp-probe.service $a ended '$r', wanted '-> skipped (when ..)'"; fi
    done
    [[ $wrc -eq 0 ]] || { echo "FAIL: a services_vm check after run 2 failed"; exit 1; }

    echo "=== services_vm run 3: the unit's content var changes ==="
    ts_cmd='systemctl show -p ExecMainStartTimestamp --value tp-probe.service'
    rel_cmd='sudo -n journalctl -b -o cat _PID=1 --no-pager'
    ts0=$(sshv "$ts_cmd" 2>&1) || ts0="(failed: $ts0)"
    sshv "$rel_cmd" >"$out/journal-before.txt" 2>&1 || true
    n0=$(reloads_in "$out/journal-before.txt")
    RUN_VARS=$out/vars-run3.toml
    services_vm_vars3 "$RUN_VARS"
    echo "run 3's vars: $RUN_VARS"; sed 's/^/     | /' "$RUN_VARS"
    echo "before run 3: ExecMainStartTimestamp=$ts0; daemon-reloads logged: $n0"
    rc3=0; run 3 || rc3=$?
    grep '^== .* \[prepare\]' "$out/run3.out" || true
    sleep 1   # the start timestamp has a one-second resolution
    ts1=$(sshv "$ts_cmd" 2>&1) || ts1="(failed: $ts1)"
    sshv "$rel_cmd" >"$out/journal-after.txt" 2>&1 || true
    n1=$(reloads_in "$out/journal-after.txt")
    echo "after run 3: ExecMainStartTimestamp=$ts1; daemon-reloads logged: $n1"
    if [[ $rc3 -eq 0 && $(status_of "$out/run3.out") == changed ]]; then ok "run 3: exit 0, STATUS changed"
    else bad "run 3 exited $rc3, STATUS $(status_of "$out/run3.out") (log: $out/run3.out)"; fi
    ch3=$(changed_ops "$out/run3.out" | sort | tr '\n' ';')
    if [[ $ch3 == 'svc tp-probe.service restart;unit tp-probe.service content;' ]]; then ok "run 3: the changed ops are the unit's content and the restart"
    else bad "run 3 changed '$ch3', wanted the unit's content and the restart only"; fi
    nr=$(restarts_of "$out/run3.out")
    if [[ $nr -eq 1 ]]; then ok "run 3: exactly one restart of tp-probe.service"; else bad "run 3: $nr restarts of tp-probe.service, wanted 1"; fi
    if [[ -n $ts0 && -n $ts1 && $ts0 != "$ts1" && $ts1 != '(failed'* && $ts0 != '(failed'* ]]; then ok "run 3: ExecMainStartTimestamp moved ($ts0 -> $ts1)"
    else bad "run 3: ExecMainStartTimestamp did not move ('$ts0' -> '$ts1')"; fi
    ev3=$(daemon_reload_events "$out/run3.jsonl")
    d3=$((n1 - n0))
    if [[ $ev3 -eq 1 && $d3 -eq 1 ]]; then ok "run 3: exactly one daemon_reload event, journal delta 1 ($n0 -> $n1)"
    else bad "run 3: $ev3 daemon_reload events, journal delta $d3 ($n0 -> $n1), wanted 1 and 1"; fi
    vexpect "after run 3 tp-probe.service is-active" active 'systemctl is-active tp-probe.service'
    vexpect "after run 3 the unit file carries the new Description" 'Description=telepatch services_vm probe, changed' 'systemctl show -p Description tp-probe.service'
    [[ $wrc -eq 0 ]] || { echo "FAIL: a services_vm check after run 3 failed"; exit 1; }

    echo "=== services_vm run 4: only the probe conf changes ==="
    pid_cmd='systemctl show -p MainPID --value tp-probe.service'
    pid0=$(sshv "$pid_cmd" 2>&1) || pid0="(failed: $pid0)"
    sshv "$rel_cmd" >"$out/journal-before4.txt" 2>&1 || true
    n4a=$(reloads_in "$out/journal-before4.txt")
    RUN_VARS=$out/vars-run4.toml
    services_vm_vars4 "$RUN_VARS"
    echo "run 4's vars: $RUN_VARS"; sed 's/^/     | /' "$RUN_VARS"
    echo "before run 4: MainPID=$pid0; daemon-reloads logged: $n4a"
    rc4=0; run 4 || rc4=$?
    grep '^== .* \[prepare\]' "$out/run4.out" || true
    pid1=$(sshv "$pid_cmd" 2>&1) || pid1="(failed: $pid1)"
    sshv "$rel_cmd" >"$out/journal-after4.txt" 2>&1 || true
    n4b=$(reloads_in "$out/journal-after4.txt")
    ev4=$(daemon_reload_events "$out/run4.jsonl")
    d4=$((n4b - n4a))
    echo "after run 4: MainPID=$pid1; daemon-reloads logged: $n4b; events: $ev4"
    if [[ $rc4 -eq 0 && $(status_of "$out/run4.out") == changed ]]; then ok "run 4: exit 0, STATUS changed"
    else bad "run 4 exited $rc4, STATUS $(status_of "$out/run4.out") (log: $out/run4.out)"; fi
    ch4=$(changed_ops "$out/run4.out" | sort | tr '\n' ';')
    if [[ $ch4 == 'file /etc/tp-probe.conf content;svc tp-probe.service reload;' ]]; then ok "run 4: the changed ops are the conf file and the guarded reload"
    else bad "run 4 changed '$ch4', wanted the conf file and the guarded reload only"; fi
    r4=$(op_result "$out/run4.out" 'svc tp-probe.service reload')
    if [[ $r4 == '-> changed' ]]; then ok "run 4: the guarded reload ended -> changed"
    else bad "run 4: the guarded reload ended '$r4', wanted '-> changed'"; fi
    nr4=$(restarts_of "$out/run4.out")
    if [[ $nr4 -eq 0 ]]; then ok "run 4: no restart"; else bad "run 4: $nr4 restarts, wanted 0"; fi
    if [[ -n $pid0 && $pid0 == "$pid1" && $pid0 != '(failed'* && $pid0 != 0 ]]; then ok "run 4: MainPID unchanged ($pid0)"
    else bad "run 4: MainPID changed or empty ('$pid0' -> '$pid1')"; fi
    if [[ $ev4 -eq 0 && $d4 -eq 0 ]]; then ok "run 4: zero daemon_reload events, journal delta 0"
    else bad "run 4: $ev4 daemon_reload events, journal delta $d4 ($n4a -> $n4b), wanted 0 and 0"; fi
    [[ $wrc -eq 0 ]] || { echo "FAIL: a services_vm check after run 4 failed"; exit 1; }

    echo "=== services_vm run 5: same vars, nothing changes ==="
    rc5=0; run 5 || rc5=$?
    grep '^== .* \[prepare\]' "$out/run5.out" || true
    if [[ $rc5 -eq 0 && $(status_of "$out/run5.out") == ok && $(changed_of "$out/run5.out") == 0 ]]; then ok "run 5: STATUS ok, CHANGED 0"
    else
        bad "run 5 exited $rc5, STATUS $(status_of "$out/run5.out"), CHANGED $(changed_of "$out/run5.out") (log: $out/run5.out)"
        changed_ops "$out/run5.out" | sed 's/^/     changed: /'
    fi
    if [[ $wrc -ne 0 ]]; then echo "FAIL: a services_vm check failed"; exit 1; fi
    echo "services_vm checks: all passed"
    echo "PASS: services_vm on a $distro VM over SSH (run 1 ok; run 2 CHANGED 0; run 3 one restart, one daemon-reload; run 4 guarded reload, no daemon-reload; run 5 CHANGED 0)"
    exit 0
fi

# ---- dev_desktop: the enable-then-start path of svc (gating) ----------------------
# Between run 1 and the idempotent pass, take docker down on the booted VM:
# `systemctl disable --now docker`, check it is `disabled` and `inactive`, then
# run 2 must change exactly one op, the svc op of docker, and its prepare line
# must say `svc docker.service: will enable, will start`. The pass after it
# (run 3) is the CHANGED 0 pass. Nothing between the disable and run 2 touches
# the docker socket (on Ubuntu docker.socket stays enabled and active, so
# docker.service stays inactive until something connects to it).
last=2
if [[ $container == dev_desktop ]]; then
    last=3
    echo "=== svc enable-then-start: systemctl disable --now docker ==="
    drc=0; dout=$(sshv 'sudo -n systemctl disable --now docker' 2>&1) || drc=$?
    printf '%s\n' "$dout" | sed 's/^/     | /'
    if [[ $drc -ne 0 ]]; then echo "FAIL: 'sudo systemctl disable --now docker' exited $drc"; exit 1; fi
    en=$(sshv 'systemctl is-enabled docker' 2>&1) || true
    ac=$(sshv 'systemctl is-active docker' 2>&1) || true
    echo "after the disable: is-enabled docker -> $en; is-active docker -> $ac"
    if [[ $en != disabled || $ac != inactive ]]; then
        echo "FAIL: after the disable docker is '$en' and '$ac', wanted 'disabled' and 'inactive'"
        exit 1
    fi
    rc2=0; run 2 || rc2=$?
    grep '^== .* \[prepare\]' "$out/run2.out" || true
    if [[ $rc2 -ne 0 ]] || ! one_svc_change "$out/run2.out" docker; then
        echo "FAIL: run 2 (after the disable) exited $rc2, STATUS $(status_of "$out/run2.out"), CHANGED $(changed_of "$out/run2.out"); wanted STATUS changed, CHANGED 1, the svc docker op (log: $out/run2.out)"
        echo "changed ops in run 2:"
        awk '/^== /{h=$0} /^-> changed/{print "  " h}' "$out/run2.out"
        exit 1
    fi
    if ! grep -F '[prepare] svc docker.service: will enable, will start' "$out/run2.out"; then
        echo "FAIL: run 2's prepare block lacks 'svc docker.service: will enable, will start' (log: $out/run2.out)"
        exit 1
    fi
    echo "run 2: STATUS changed, CHANGED 1, the svc docker op; prepare said 'will enable, will start'"
fi

rc2=0; run "$last" || rc2=$?
grep '^== .* \[prepare\]' "$out/run$last.out" || true
go2=$(go_now)
ch=$(changed_of "$out/run$last.out"); st=$(status_of "$out/run$last.out")
verdict=fail
[[ $rc2 -ne 0 ]] || verdict=$(second_pass "$out/run$last.out" "$go1" "$go2")
case $verdict in
    ok) echo "run $last: STATUS ok, CHANGED 0" ;;
    go-release)
        echo "run $last: STATUS ${st}, CHANGED ${ch}: only golang changed, and Go moved from $go1 to $go2 between the passes"
        echo "(a Go release between the passes is the one accepted cause of a nonzero count; reported, not hidden)" ;;
    *)
        echo "FAIL: run $last exited $rc2, STATUS ${st:-?}, CHANGED ${ch:-?} (log: $out/run$last.out)"
        echo "changed ops in run $last:"
        awk '/^== /{h=$0} /^-> changed/{print "  " h}' "$out/run$last.out"
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
    # the services, after run 3 (gating): the units the svc ops keep up
    for verb in is-enabled is-active; do
        want=enabled; [[ $verb == is-active ]] && want=active
        for unit in docker libvirtd.socket; do
            r=0; o=$(sshv "systemctl $verb $unit" 2>&1) || r=$?
            if [[ $o == "$want" ]]; then echo "ok   systemctl $verb $unit: $o"
            else echo "FAIL systemctl $verb $unit printed '$o' (exit $r), wanted $want"; wrc=1; fi
        done
    done
    if [[ $wrc -ne 0 ]]; then echo "FAIL: a working check failed"; exit 1; fi
    echo "working checks: all passed"
fi

# ---- state after -----------------------------------------------------------------
# The capture does not decide the exit code. PB_ORACLE stays 0: the production
# acceptance runner was retired, and this script does not read a container record.
crc=0
{ vm_state "$ROOT/scripts/image-state.sh" >"$out/vm-post.state" \
    && vm_state "$ROOT/scripts/image-state.sh" --versions >"$out/vm-post.versions"; } || crc=$?
if [[ $crc -ne 0 ]]; then
    echo "test-vm: WARNING: the post capture exited $crc" >&2
else
    echo "captured $out/vm-post.state ($(wc -l <"$out/vm-post.state") lines)"
    if [[ $PB_ORACLE -eq 1 ]]; then
        echo "test-vm: WARNING: PB_ORACLE is set, but this script does not read a container record" >&2
    fi
fi
if [[ $container == dev_desktop ]]; then
    if logs_have_secret "$out"/run*.out "$out"/run*.jsonl "$out"/desktop-secret.toml; then
        echo "FAIL: a run log contains the throwaway password or its hash"
        exit 1
    fi
    if [[ $SU_FAIL -ne 0 ]]; then
        echo "FAIL: su as tpdev failed"
        exit 1
    fi
fi
echo "PASS: $PB_NAME on a $distro VM over SSH (run 1 ok; run $last $verdict)"
exit 0
