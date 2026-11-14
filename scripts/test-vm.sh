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
# reboot_vm (test-only, vars/reboot_vm.toml, 1 GiB, the image's disk, five runs,
# every check prints ok or FAIL and all gate): a file op marked
# `.needs_reboot()`, the barrier `h.reboot().if_pending()`, a file op after it.
# The boot id is read before run 1. Run 1 exits 0, STATUS changed, the boot id
# differs, run1.out says `boot id changed, shells reopened`, run1.jsonl has one
# `reboot` event, /etc/tp-reboot-after holds its default and
# /run/telepatch/reboot-pending is gone. Run 2 (same vars) is CHANGED 0 with no
# reboot and the same boot id. Run 3 gets a vars copy (vars-run3.toml) that
# changes `marked` (a fresh mark) and `after`, with `--reboot never`: exit 1,
# STATUS `reboot pending`, `reboot pending at barrier`, the marked file new, the
# after file old, the mark file present and naming the marked file, no reboot,
# same boot id. Run 4 (run 3's vars, default policy) exits 0 with one reboot, a
# new boot id, the after file new and the marked op `-> ok`: the mark an earlier
# run left drove the reboot. Run 5 is CHANGED 0 with no reboot.
#
# undo_fs (test-only, vars/undo_fs.toml, 1 GiB, the image's disk, one run, every
# check prints ok or FAIL and all gate): the proof, with no TP_FS_ROOTS seam, of
# T106's backup on the target's own filesystem. Setup, as root INSIDE the VM over
# the script's SSH path: a 64 MiB ext4 image (/var/lib/tp-undo.img) loop-mounted
# at /srv/tpfs, with the file /srv/tpfs/tp-undo-file, the directory
# /srv/tpfs/tp-undo-gone and /var/tmp/tp-undo-fs/gone made before the run. The
# playbook writes new bytes over the file and runs `.absent()` on both
# directories; its last op writes a listing of what exists mid-run to
# /root/tp-undo-fs-mid.txt (the run log carries no sh output). Checks: the
# listing shows two backups under /srv/tpfs/.telepatch/tmp/<run>/undo/root/<id>/,
# a stage symlink to each, one plain stage directory for the /var/tmp target and
# no /.telepatch on the root filesystem; after the run neither
# /srv/tpfs/.telepatch/tmp nor /var/tmp/telepatch/<run> exists, the file holds the
# new bytes, both directories are gone, and run 1 was STATUS changed.
# T119's fetch case (written, run in T104): the setup serves /var/lib/tp-fetch/blob.txt
# and pkg.tgz on the root filesystem; the playbook fetches them as file:// URLs
# into /srv/tpfs/tp-fetch-blob.txt (.from) and /srv/tpfs/tp-fetch-tree (.unpack).
# The mid-run listing shows the downloads on /srv/tpfs/.telepatch/ (the cache
# entries there) and only links in the stage; after the run the cache entries
# stay on /srv/tpfs/.telepatch/cache/sha256 (the main cache is unused), its tmp is
# gone, and run 2 is STATUS ok, CHANGED 0, with both fetches `cached` (a hit on
# /srv/tpfs, no download).
# T123's cache case (written, run in T104), after run 2: `tp-basic cache usage
# --host <vm>` lists /srv/tpfs/.telepatch/cache/sha256 with its two items and a
# size (the main cache /var/cache/telepatch/sha256 is listed only if it exists;
# this case fetches onto /srv/tpfs, so it may not, and the check says which);
# `cache purge --host <vm>` without --yes changes nothing; `cache purge --yes`
# empties both (/srv/tpfs/.telepatch is gone, the main cache holds no file) and
# usage then shows 0 items.
# local_user (T120, test-only, written and run in T104, one VM): as_user over
# --local, run INSIDE the VM. The script copies the musl build/tp-basic to
# /usr/local/bin/tp-basic-local-user and makes `tpuser` (a login shell) and
# `tpnologin` (/usr/sbin/nologin). Run A is `sudo tp-basic run local_user
# --local` (the caller is root, so `sudo -n -iu tpuser bash`); run B is the
# same as the VM's passwordless-sudo login user. After each, ~tpuser/marker
# holds `tpuser` (id -un in the user's shell) and ~tpuser/file-marker (a file
# op) is there, both owned by tpuser. Run C is `local_user_nologin` as the
# login user: exit non-zero, STATUS blocked, and `sudo -n -iu tpnologin bash
# refused on this machine (no sudo rights for tpnologin, or a login shell
# that refuses, such as nologin)`. The VM is deleted at the end.
#
#   scripts/test-vm.sh [--keep] <distro> <playbook>   (ubuntu2404; dev_base, dev_desktop, services_vm, reboot_vm, undo_fs or local_user)
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
        # test-only (src/playbooks/reboot.rs): two files and the reboot
        # barrier between them, nothing installed.
        reboot_vm) PB_NAME=reboot_vm PB_VARS=vars/reboot_vm.toml PB_ORACLE=0 PB_MEMORY=1 PB_DISK= ;;
        # test-only (src/playbooks/undo.rs): a file and two directories, one
        # target on a 64 MiB loop-mounted image the setup makes in the VM.
        undo_fs) PB_NAME=undo_fs PB_VARS=vars/undo_fs.toml PB_ORACLE=0 PB_MEMORY=1 PB_DISK= ;;
        # test-only (src/playbooks/local_user.rs): as_user over --local, run
        # inside the VM by the copied musl tp-basic (T120).
        local_user) PB_NAME=local_user PB_VARS=vars/local_user.toml PB_ORACLE=0 PB_MEMORY=1 PB_DISK= ;;
        *) return 1 ;;
    esac
}

# vm_name_for <playbook> <stamp> : the VM's name, tp-<playbook>-<stamp>, with
# every `_` of the playbook as `-` (vm.sh accepts only tp-[a-z0-9-]+).
vm_name_for() { echo "tp-${1//_/-}-$2"; }

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

# reboot_events <run.jsonl> : how many `reboot` events the run streamed
# (one per reboot the executor did, telepatch's reboot.rs).
reboot_events() { grep -c '"ev":"reboot"' "$1" || true; }

# table_row <run.out> <status|changed> : the STATUS or CHANGED cell of the
# host row under the `HOST STATUS OK CHANGED ..` header. STATUS can be two
# words (`reboot pending`), so the row is read from the right of the status:
# the first field from the third on that starts four numbers (OK CHANGED
# FAILED NOT RUN) ends it.
table_row() {
    awk -v want="$2" '/^HOST  *STATUS/ {
        getline
        for (i = 3; i + 3 <= NF; i++)
            if ($i ~ /^[0-9]+$/ && $(i+1) ~ /^[0-9]+$/ && $(i+2) ~ /^[0-9]+$/ && $(i+3) ~ /^[0-9]+$/) break
        if (want == "changed") { print $(i+1); exit }
        s = $2; for (k = 3; k < i; k++) s = s " " $k
        print s; exit
    }' "$1"
}

# undo_fs_mid_run <listing> : the run id the playbook's last op printed
# (`run <id>`), empty when there is none.
undo_fs_mid_run() { sed -n 's/^run //p' "$1" | head -1; }

# undo_fs_mid_problems <listing> : one line per way the mid-run listing
# (src/playbooks/undo.rs) is not what T106 promises, nothing when it is. Two
# `backup` lines under /srv/tpfs/.telepatch/tmp/<run>/undo/root/<id>/, each with
# a `link` from /var/tmp/telepatch/<run>/undo/root/<id> to it, one `stagedir`
# (the /var/tmp target: a plain directory in the stage, no link), and
# `root-telepatch absent`.
undo_fs_mid_problems() {
    local f=$1 run nb nl ns b l t
    run=$(undo_fs_mid_run "$f")
    [[ -n $run ]] || { echo "no 'run <id>' line"; return 0; }
    nb=$(grep -c '^backup ' "$f" || true)
    nl=$(grep -c '^link ' "$f" || true)
    ns=$(grep -c '^stagedir ' "$f" || true)
    [[ $nb -eq 2 ]] || echo "$nb backup lines, wanted 2"
    [[ $nl -eq 2 ]] || echo "$nl link lines, wanted 2"
    [[ $ns -eq 1 ]] || echo "$ns stagedir lines, wanted 1"
    while read -r _ b; do
        [[ $b == "/srv/tpfs/.telepatch/tmp/$run/undo/root/"*/ ]] || echo "backup '$b' is not under /srv/tpfs/.telepatch/tmp/$run/undo/root/<id>/"
        grep -qxF "link /var/tmp/telepatch/$run/undo/root/$(basename "$b") -> ${b%/}" "$f" || echo "backup $b has no stage link to it"
    done < <(grep '^backup ' "$f")
    while read -r _ l _ t; do
        [[ $l == "/var/tmp/telepatch/$run/undo/root/"* ]] || echo "link '$l' is not under the stage's undo/root"
        grep -qxF "backup $t/" "$f" || echo "link $l points at '$t', which is not a listed backup"
    done < <(grep '^link ' "$f")
    grep -q "^stagedir /var/tmp/telepatch/$run/undo/root/" "$f" || echo "no plain stage directory for the /var/tmp target"
    grep -qx 'root-telepatch absent' "$f" || echo "the root filesystem has a /.telepatch (or the line is missing)"
    return 0
}

# The fixed sums of the fetch case's two served files (src/playbooks/undo.rs).
UNDO_FETCH_SUMS=(9c2355ab6d8d2a8020c65547e567e31f80eb41eede1ce611e591d82779be5cc0 2d44dca14b5af2c8e4f1c784d246deacf22fb8c613641a9422696514249c0789)

# undo_fs_fetch_problems <listing> <download|hit> : one line per way the fetch
# part of the mid-run listing is not what T119 promises, nothing when it is.
# Each served file has a `fetchcache` entry under /srv/tpfs/.telepatch/cache/sha256/
# and a `fetchlink` from /var/tmp/telepatch/<run>/f-<sum> to it; the stage holds no
# regular file (`stagefile`, the `fsroots` index aside); no `.part` is left in
# the run's fetch directory (`fetchtmp`); and that directory exists after a
# download (`fetchdir present`) but not after a cache hit (nothing was made).
undo_fs_fetch_problems() {
    local f=$1 want=$2 run s n
    run=$(undo_fs_mid_run "$f")
    [[ -n $run ]] || { echo "no 'run <id>' line"; return 0; }
    n=$(grep -c '^fetchlink ' "$f" || true)
    [[ $n -eq 2 ]] || echo "$n fetchlink lines, wanted 2"
    for s in "${UNDO_FETCH_SUMS[@]}"; do
        grep -qxF "fetchcache /srv/tpfs/.telepatch/cache/sha256/$s" "$f" || echo "no cache entry $s on /srv/tpfs/.telepatch/cache/sha256"
        grep -qxF "fetchlink /var/tmp/telepatch/$run/f-$s -> /srv/tpfs/.telepatch/cache/sha256/$s" "$f" || echo "no stage link f-$s to the cache entry on /srv/tpfs"
    done
    n=$(grep -c '^stagefile ' "$f" || true)
    [[ $n -eq 0 ]] || echo "$n regular file(s) in the stage, wanted only links"
    n=$(grep -c '^fetchtmp ' "$f" || true)
    [[ $n -eq 0 ]] || echo "$n file(s) left in the run's fetch directory on /srv/tpfs"
    if [[ $want == download ]]; then
        grep -qx 'fetchdir present' "$f" || echo "no fetch directory under /srv/tpfs/.telepatch/tmp/$run (the download was not staged there)"
    else
        grep -qx 'fetchdir absent' "$f" || echo "a cache hit made /srv/tpfs/.telepatch/tmp/$run/fetch"
    fi
    return 0
}

# cache_usage_problems <usage output> <host> <items on /srv/tpfs> : one line per
# way `tp-basic cache usage` output (the table) fails the undo_fs cache check:
# the host is named, /srv/tpfs/.telepatch/cache/sha256 is listed with that many
# items and a size in MB or GB, and the run total says as many items.
cache_usage_problems() {
    local f=$1 host=$2 n=$3 line
    local re='^  /srv/tpfs/.telepatch/cache/sha256: ([0-9]+) items?, [0-9]+\.[0-9] (MB|GB)'
    grep -qxF "host $host" "$f" || echo "no 'host $host' line"
    line=$(grep -F '  /srv/tpfs/.telepatch/cache/sha256: ' "$f" | head -1)
    if [[ -z $line ]]; then
        [[ $n -eq 0 ]] || echo "/srv/tpfs/.telepatch/cache/sha256 is not listed"
    elif [[ $line =~ $re ]]; then
        [[ ${BASH_REMATCH[1]} == "$n" ]] || echo "/srv/tpfs/.telepatch/cache/sha256 lists '${BASH_REMATCH[1]}' items, wanted $n"
    else
        echo "no item count and size on '$line'"
    fi
    grep -qE "^run total: 1 host, $n items?, [0-9]+\.[0-9] (MB|GB)\$" "$f" || echo "the run total is not $n item(s)"
    return 0
}

# cache_main_listed <usage output> : prints listed or unlisted for the main
# cache /var/cache/telepatch/sha256 (listed only when the directory exists).
cache_main_listed() {
    if grep -qF '  /var/cache/telepatch/sha256: ' "$1"; then echo listed; else echo unlisted; fi
}

# undo_fs_self_test : the listing readers of the undo_fs checks.
undo_fs_self_test() {
    local fails=0 t got r=RUNX
    t=$(mktemp -d)
    local c=/srv/tpfs/.telepatch/cache/sha256 s0=${UNDO_FETCH_SUMS[0]} s1=${UNDO_FETCH_SUMS[1]}
    printf '%s\n' "fetchlink /var/tmp/telepatch/$r/f-$s0 -> $c/$s0" "fetchlink /var/tmp/telepatch/$r/f-$s1 -> $c/$s1" \
        "fetchcache $c/$s0" "fetchcache $c/$s1" 'fetchdir present' "run $r" >"$t/fgood"
    got=$(undo_fs_fetch_problems "$t/fgood" download)
    if [[ -z $got ]]; then echo "ok   undo_fs_fetch_problems: a good download listing has none"; else echo "FAIL good fetch listing: $got"; fails=1; fi
    got=$(undo_fs_fetch_problems "$t/fgood" hit)
    if [[ $got == *'a cache hit made'* ]]; then echo "ok   undo_fs_fetch_problems: a fetch directory after a hit is named"; else echo "FAIL hit with a fetch dir: '$got'"; fails=1; fi
    sed 's/^fetchdir present/fetchdir absent/' "$t/fgood" >"$t/fhit"
    got=$(undo_fs_fetch_problems "$t/fhit" hit)
    if [[ -z $got ]]; then echo "ok   undo_fs_fetch_problems: a good hit listing has none"; else echo "FAIL good hit listing: $got"; fails=1; fi
    got=$(undo_fs_fetch_problems "$t/fhit" download)
    if [[ $got == *'was not staged there'* ]]; then echo "ok   undo_fs_fetch_problems: a download with no fetch directory is named"; else echo "FAIL download with no fetch dir: '$got'"; fails=1; fi
    { cat "$t/fgood"; echo "stagefile /var/tmp/telepatch/$r/0.part"; echo "fetchtmp $c/../tmp/$r/fetch/1.part"; } >"$t/fbad"
    got=$(undo_fs_fetch_problems "$t/fbad" download)
    if [[ $got == *'regular file(s) in the stage'* && $got == *"left in the run's fetch directory"* ]]; then echo "ok   undo_fs_fetch_problems: a file in the stage and a left .part are named"
    else echo "FAIL stage file and left part: '$got'"; fails=1; fi
    grep -v "^fetchlink .*f-$s1" "$t/fgood" >"$t/fnolink"
    got=$(undo_fs_fetch_problems "$t/fnolink" download)
    if [[ $got == *'1 fetchlink lines, wanted 2'* && $got == *"no stage link f-$s1"* ]]; then echo "ok   undo_fs_fetch_problems: a missing stage link is named"
    else echo "FAIL missing fetch link: '$got'"; fails=1; fi
    sed "s#-> $c/$s0#-> /var/cache/telepatch/sha256/$s0#" "$t/fgood" >"$t/fmain"
    got=$(undo_fs_fetch_problems "$t/fmain" download)
    if [[ $got == *"no stage link f-$s0 to the cache entry on /srv/tpfs"* ]]; then echo "ok   undo_fs_fetch_problems: a link into the main cache is named"
    else echo "FAIL link into the main cache: '$got'"; fails=1; fi
    printf '%s\n' "backup /srv/tpfs/.telepatch/tmp/$r/undo/root/0/" "backup /srv/tpfs/.telepatch/tmp/$r/undo/root/1/" \
        "link /var/tmp/telepatch/$r/undo/root/0 -> /srv/tpfs/.telepatch/tmp/$r/undo/root/0" \
        "link /var/tmp/telepatch/$r/undo/root/1 -> /srv/tpfs/.telepatch/tmp/$r/undo/root/1" \
        "stagedir /var/tmp/telepatch/$r/undo/root/2" 'root-telepatch absent' "run $r" >"$t/good"
    got=$(undo_fs_mid_run "$t/good")
    if [[ $got == "$r" ]]; then echo "ok   undo_fs_mid_run -> $got"; else echo "FAIL undo_fs_mid_run -> '$got'"; fails=1; fi
    got=$(undo_fs_mid_problems "$t/good")
    if [[ -z $got ]]; then echo "ok   undo_fs_mid_problems: a good listing has none"; else echo "FAIL good listing: $got"; fails=1; fi
    grep -v '^link .*root/1 ' "$t/good" >"$t/nolink"
    got=$(undo_fs_mid_problems "$t/nolink")
    if [[ $got == *'1 link lines, wanted 2'* && $got == *'has no stage link'* ]]; then echo "ok   undo_fs_mid_problems: a missing link is named"
    else echo "FAIL missing link: '$got'"; fails=1; fi
    sed 's/^root-telepatch absent/root-telepatch PRESENT/' "$t/good" >"$t/rootfs"
    got=$(undo_fs_mid_problems "$t/rootfs")
    if [[ $got == *'/.telepatch'* ]]; then echo "ok   undo_fs_mid_problems: a /.telepatch on the root filesystem is named"
    else echo "FAIL root .telepatch: '$got'"; fails=1; fi
    sed "s#^stagedir .*#link /var/tmp/telepatch/$r/undo/root/2 -> /elsewhere#" "$t/good" >"$t/wrong"
    got=$(undo_fs_mid_problems "$t/wrong")
    if [[ $got == *'not a listed backup'* && $got == *'0 stagedir lines'* ]]; then echo "ok   undo_fs_mid_problems: a link to elsewhere is named"
    else echo "FAIL link to elsewhere: '$got'"; fails=1; fi
    : >"$t/empty"
    got=$(undo_fs_mid_problems "$t/empty")
    if [[ $got == "no 'run <id>' line" ]]; then echo "ok   undo_fs_mid_problems: an empty listing says so"; else echo "FAIL empty listing: '$got'"; fails=1; fi
    printf '%s\n' 'host bot@192.0.2.7' '  /srv/tpfs/.telepatch/cache/sha256: 2 items, 0.0 MB' '    unowned: 2 items, 0.0 MB' '  host total: 2 items, 0.0 MB' '' 'run total: 1 host, 2 items, 0.0 MB' >"$t/cu2"
    printf '%s\n' 'host bot@192.0.2.7' '  host total: 0 items, 0.0 MB' '' 'run total: 1 host, 0 items, 0.0 MB' >"$t/cu0"
    printf '%s\n' 'host bot@192.0.2.7' '  /srv/tpfs/.telepatch/cache/sha256: 1 item, 1.5 GB' '  /var/cache/telepatch/sha256: 0 items, 0.0 MB' 'run total: 1 host, 1 item, 1.5 GB' >"$t/cu1"
    got=$(cache_usage_problems "$t/cu2" bot@192.0.2.7 2)
    if [[ -z $got ]]; then echo "ok   cache_usage_problems: a good listing has none"; else echo "FAIL good usage: $got"; fails=1; fi
    got=$(cache_usage_problems "$t/cu0" bot@192.0.2.7 0)
    if [[ -z $got ]]; then echo "ok   cache_usage_problems: an emptied cache lists nothing and totals 0"; else echo "FAIL empty usage: $got"; fails=1; fi
    got=$(cache_usage_problems "$t/cu0" bot@192.0.2.7 2)
    if [[ $got == *'is not listed'* && $got == *'run total is not 2'* ]]; then echo "ok   cache_usage_problems: a missing directory and total are named"; else echo "FAIL missing dir: '$got'"; fails=1; fi
    got=$(cache_usage_problems "$t/cu1" bot@192.0.2.7 2)
    if [[ $got == *"lists '1' items, wanted 2"* ]]; then echo "ok   cache_usage_problems: a wrong count is named"; else echo "FAIL wrong count: '$got'"; fails=1; fi
    got=$(cache_usage_problems "$t/cu2" bot@other 2)
    if [[ $got == *"no 'host bot@other' line"* ]]; then echo "ok   cache_usage_problems: a wrong host is named"; else echo "FAIL wrong host: '$got'"; fails=1; fi
    if [[ $(cache_main_listed "$t/cu1") == listed && $(cache_main_listed "$t/cu2") == unlisted ]]; then echo "ok   cache_main_listed"; else echo "FAIL cache_main_listed"; fails=1; fi
    rm -rf "$t"
    return $fails
}

# ---- local_user (T120): as_user over --local, in the VM -------------------------
# The accounts the setup makes (src/playbooks/local_user.rs).
LU_USER=tpuser LU_NOLOGIN=tpnologin

# local_user_problems <listing> <user> : one line per way what the playbook
# left in ~<user> is not what T120 promises, nothing when it is. The listing
# has `marker=<content>` (what `id -un` printed in the user's shell),
# `markerowner=<owner>`, `file=<content>` and `fileowner=<owner>`.
local_user_problems() {
    local f=$1 u=$2
    grep -qxF "marker=$u" "$f" || echo "~$u/marker holds '$(sed -n 's/^marker=//p' "$f" | head -1)', wanted '$u' (id -un in the user's shell)"
    grep -qxF "markerowner=$u" "$f" || echo "~$u/marker is owned by '$(sed -n 's/^markerowner=//p' "$f" | head -1)', wanted $u"
    grep -qxF 'file=written by the file op' "$f" || echo "~$u/file-marker does not hold what the file op wrote"
    grep -qxF "fileowner=$u" "$f" || echo "~$u/file-marker is owned by '$(sed -n 's/^fileowner=//p' "$f" | head -1)', wanted $u"
    return 0
}

# local_user_refusal_problems <run output> <rc> <user> : one line per way a run
# against a user whose login shell is nologin is not the transport's refusal:
# the run must exit non-zero, the table must say `blocked`, and the output must
# carry `sudo -n -iu <user> bash refused on this machine (no sudo rights for
# <user>, or a login shell that refuses, such as nologin)`.
local_user_refusal_problems() {
    local f=$1 rc=$2 u=$3
    [[ $rc -ne 0 ]] || echo "the run exited 0, wanted non-zero"
    [[ $(table_row "$f" status) == blocked ]] || echo "STATUS is '$(table_row "$f" status)', wanted blocked"
    grep -qF "sudo -n -iu $u bash refused on this machine (no sudo rights for $u, or a login shell that refuses, such as nologin)" "$f" \
        || echo "no 'sudo -n -iu $u bash refused on this machine (no sudo rights for $u, or a login shell that refuses, such as nologin)' in the output"
    return 0
}

# local_user_self_test : the readers of the local_user checks, on synthetic
# output.
local_user_self_test() {
    local fails=0 t got hdr='HOST                 STATUS            OK CHANGED FAILED NOT RUN  DETAIL'
    t=$(mktemp -d)
    printf '%s\n' 'marker=tpuser' 'markerowner=tpuser' 'file=written by the file op' 'fileowner=tpuser' >"$t/good"
    printf '%s\n' 'marker=root' 'markerowner=root' 'file=written by the file op' 'fileowner=root' >"$t/root"
    printf '%s\n' 'marker=tpuser' 'markerowner=tpuser' 'file=' 'fileowner=' >"$t/nofile"
    : >"$t/empty"
    got=$(local_user_problems "$t/good" tpuser)
    if [[ -z $got ]]; then echo "ok   local_user_problems: a good listing has none"; else echo "FAIL good listing: $got"; fails=1; fi
    got=$(local_user_problems "$t/root" tpuser)
    if [[ $got == *"~tpuser/marker holds 'root'"* && $got == *'~tpuser/marker is owned by '"'root'"* && $got == *'file-marker is owned by '"'root'"* ]]; then echo "ok   local_user_problems: a shell that was root is named"
    else echo "FAIL root listing: '$got'"; fails=1; fi
    got=$(local_user_problems "$t/nofile" tpuser)
    if [[ $got == *'does not hold what the file op wrote'* && $got == *'file-marker is owned by'* ]]; then echo "ok   local_user_problems: a missing file op is named"; else echo "FAIL nofile listing: '$got'"; fails=1; fi
    got=$(local_user_problems "$t/empty" tpuser)
    if [[ $(printf '%s\n' "$got" | wc -l) -eq 4 ]]; then echo "ok   local_user_problems: an empty listing fails all four checks"; else echo "FAIL empty listing: '$got'"; fails=1; fi
    printf '%s\n' "$hdr" 'local               blocked            0       0      0       0  sudo -n -iu tpnologin bash refused on this machine (no sudo rights for tpnologin, or a login shell that refuses, such as nologin): it printed nothing on stderr and closed' >"$t/blocked"
    printf '%s\n' "$hdr" 'local               ok                 1       2      0       0' >"$t/ok"
    printf '%s\n' "$hdr" 'local               blocked            0       0      0       0  could not open a root shell: sudo refused' >"$t/other"
    got=$(local_user_refusal_problems "$t/blocked" 1 tpnologin)
    if [[ -z $got ]]; then echo "ok   local_user_refusal_problems: the refusal has none"; else echo "FAIL good refusal: $got"; fails=1; fi
    got=$(local_user_refusal_problems "$t/ok" 0 tpnologin)
    if [[ $got == *'exited 0'* && $got == *"STATUS is 'ok'"* && $got == *'no '"'sudo -n -iu tpnologin bash refused"* ]]; then echo "ok   local_user_refusal_problems: a run that worked is named"; else echo "FAIL ok run: '$got'"; fails=1; fi
    got=$(local_user_refusal_problems "$t/other" 1 tpnologin)
    if [[ $got != *'exited 0'* && $got != *'STATUS is'* && $got == *'no '"'sudo -n -iu tpnologin bash refused"* ]]; then echo "ok   local_user_refusal_problems: another blocked reason is named"; else echo "FAIL other reason: '$got'"; fails=1; fi
    got=$(local_user_refusal_problems "$t/blocked" 1 tpuser)
    if [[ $got == *"no 'sudo -n -iu tpuser bash refused"* ]]; then echo "ok   local_user_refusal_problems: the wrong user is named"; else echo "FAIL wrong user: '$got'"; fails=1; fi
    rm -rf "$t"
    return $fails
}

# reboot_vm_vars3 <file> : run 3's vars, a fresh mark (`marked` changed) and
# a changed `after`, both different from vars/reboot_vm.toml's. Runs 4 and 5
# use the same file.
reboot_vm_vars3() {
    printf '%s\n' '# reboot_vm run 3: a fresh mark, and a changed file after the barrier' '[reboot_vm]' \
        'marked = "marked=2\n"' 'after = "after=2\n"' >"$1"
}

# reboot_vm_self_test : the log readers of the reboot_vm checks, on
# synthetic output (the table is telepatch's report.rs, the event is
# reboot.rs's `{"ev":"reboot",..}`).
reboot_vm_self_test() {
    local t fails=0 got hdr='HOST                 STATUS            OK CHANGED FAILED NOT RUN  DETAIL'
    t=$(mktemp -d)
    printf '%s\n' "$hdr" 'bot@h                changed            1       2      0       0' >"$t/changed"
    printf '%s\n' "$hdr" 'bot@h                ok                 3       0      0       0' >"$t/ok"
    printf '%s\n' "$hdr" 'bot@h                reboot pending     1       1      0       1  reboot pending at barrier' >"$t/pend"
    printf '%s\n' "$hdr" 'bot@h                failed             1       0      1       2  role (none): file /etc/x (rc 1)' >"$t/failed"
    got="$(table_row "$t/changed" status)|$(table_row "$t/changed" changed)"
    if [[ $got == 'changed|2' ]]; then echo "ok   table_row changed -> $got"; else echo "FAIL table_row changed -> '$got'"; fails=1; fi
    got="$(table_row "$t/ok" status)|$(table_row "$t/ok" changed)"
    if [[ $got == 'ok|0' ]]; then echo "ok   table_row ok -> $got"; else echo "FAIL table_row ok -> '$got'"; fails=1; fi
    got="$(table_row "$t/pend" status)|$(table_row "$t/pend" changed)"
    if [[ $got == 'reboot pending|1' ]]; then echo "ok   table_row reboot pending (two words) -> $got"; else echo "FAIL table_row reboot pending -> '$got'"; fails=1; fi
    got="$(table_row "$t/failed" status)|$(table_row "$t/failed" changed)"
    if [[ $got == 'failed|0' ]]; then echo "ok   table_row failed with a detail -> $got"; else echo "FAIL table_row failed -> '$got'"; fails=1; fi
    printf '%s\n' '{"ev":"op_start","host":"h"}' \
        '{"ev":"reboot","host":"h","down_s":31,"old_boot_id":"a","new_boot_id":"b","items":["file /etc/tp-reboot-marked"]}' \
        '{"ev":"op_result","host":"h"}' >"$t/r.jsonl"
    got=$(reboot_events "$t/r.jsonl")
    if [[ $got -eq 1 ]]; then echo "ok   reboot_events -> 1"; else echo "FAIL reboot_events -> $got"; fails=1; fi
    : >"$t/empty.jsonl"
    got=$(reboot_events "$t/empty.jsonl")
    if [[ $got -eq 0 ]]; then echo "ok   reboot_events of nothing -> 0"; else echo "FAIL reboot_events of nothing -> $got"; fails=1; fi
    printf '%s\n' '== h [reboot] down 31s, boot id changed, shells reopened ==' >"$t/r.out"
    if grep -qF 'boot id changed, shells reopened' "$t/r.out"; then echo "ok   the reboot stream line is the one the checks grep for"
    else echo "FAIL reboot stream line"; fails=1; fi
    reboot_vm_vars3 "$t/v3"
    if grep -q '^\[reboot_vm\]' "$t/v3" && grep -Fq 'marked = "marked=2\n"' "$t/v3" && grep -Fq 'after = "after=2\n"' "$t/v3" \
        && ! cmp -s "$t/v3" "$ROOT/vars/reboot_vm.toml" \
        && grep -Fq 'marked = "marked=1\n"' "$ROOT/vars/reboot_vm.toml" \
        && grep -Fq 'after = "after=1\n"' "$ROOT/vars/reboot_vm.toml"; then echo "ok   reboot_vm_vars3 changes marked and after, differs from vars/reboot_vm.toml"
    else echo "FAIL reboot_vm_vars3"; fails=1; fi
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
    got=$(playbook_config reboot_vm && echo "$PB_NAME|$PB_VARS|$PB_ORACLE|$PB_MEMORY|$PB_DISK")
    if [[ $got == "reboot_vm|vars/reboot_vm.toml|0|1|" ]]; then echo "ok   playbook reboot_vm -> $got"
    else echo "FAIL playbook reboot_vm -> '$got'"; fails=1; fi
    reboot_vm_self_test || fails=1
    got=$(playbook_config undo_fs && echo "$PB_NAME|$PB_VARS|$PB_ORACLE|$PB_MEMORY|$PB_DISK")
    if [[ $got == "undo_fs|vars/undo_fs.toml|0|1|" ]]; then echo "ok   playbook undo_fs -> $got"
    else echo "FAIL playbook undo_fs -> '$got'"; fails=1; fi
    undo_fs_self_test || fails=1
    got=$(playbook_config local_user && echo "$PB_NAME|$PB_VARS|$PB_ORACLE|$PB_MEMORY|$PB_DISK")
    if [[ $got == "local_user|vars/local_user.toml|0|1|" ]]; then echo "ok   playbook local_user -> $got"
    else echo "FAIL playbook local_user -> '$got'"; fails=1; fi
    local_user_self_test || fails=1
    # every accepted playbook gives a VM name vm.sh's guard accepts (`_` is not in tp-[a-z0-9-]+)
    local pbn
    for pbn in dev_base dev_desktop services_vm reboot_vm undo_fs local_user; do
        got=$(vm_name_for "$pbn" 20261112t000000z)
        if vm_name_ok "$got"; then echo "ok   vm name for $pbn -> $got"
        else echo "FAIL vm name for $pbn -> '$got' is refused by vm_name_ok"; fails=1; fi
    done
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
playbook_config "$container" || die "playbook '$container' is not one of: dev_base, dev_desktop, services_vm, reboot_vm, undo_fs, local_user"

# ---- preflight --------------------------------------------------------------
[[ -x $ROOT/build/tp-basic ]] || die "build/tp-basic not found: run 'just musl' first"
[[ -f $ROOT/$PB_VARS ]] || die "$PB_VARS not found"
# vmtool lives on the VM host when it is remote; there the first vmtool call
# (vm_listed, below) is the check
if vm_is_local; then [[ -x $VMTOOL_DIR/vmtool ]] || die "$VMTOOL_DIR/vmtool not found"; fi

name=$(vm_name_for "$container" "$(date -u +%Y%m%dt%H%M%Sz)")
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
changed_of() { table_row "$1" changed; }
status_of() { table_row "$1" status; }

# extra tp-basic arguments for run(), empty unless a playbook's checks set
# them (reboot_vm's run 3: --reboot never)
RUN_EXTRA=()

run() { # n
    echo "=== run $1: tp-basic run $PB_NAME --host $dest --vars ${RUN_VARS:+(changed copy) }$PB_VARS ==="
    VM_STEP="run $1: tp-basic run $PB_NAME --host $dest"
    local rc=0 t0=$SECONDS
    tpb_ssh_args "$key" "$out/known_hosts"
    "$ROOT/build/tp-basic" run "$PB_NAME" --host "$dest" "${TPB_SSH_ARGS[@]}" \
        --vars "${RUN_VARS:-$ROOT/$PB_VARS}" --log "$out/run$1.jsonl" "${RUN_EXTRA[@]}" \
        >"$out/run$1.out" 2>&1 || rc=$?
    sed -n '/^HOST  *STATUS/,$p' "$out/run$1.out"
    echo "run $1 took $((SECONDS - t0))s"
    return $rc
}

# the installed Go, for second_pass (empty when the playbook has no golang)
go_now() { sshv '[ -x /usr/local/go/bin/go ] && /usr/local/go/bin/go version || true' 2>/dev/null | awk '{print $3}'; }

# reboot_vm: the boot id before anything runs, to tell a reboot from none
boot_cmd='cat /proc/sys/kernel/random/boot_id'
b0=
if [[ $container == reboot_vm ]]; then
    b0=$(sshv "$boot_cmd" 2>&1) || b0="(failed: $b0)"
    echo "boot id before run 1: $b0"
fi

# undo_fs: the setup, as root INSIDE the VM over the script's SSH path (never on
# the machine running this script). A 64 MiB ext4 image loop-mounted at
# /srv/tpfs, and the three targets, all existing before the run: the file the
# content op backs up, the directory on the image and the one under /var/tmp.
undo_fs_setup() {
    sshv 'sudo -n sh -s' <<'SETUP'
set -e
truncate -s 64M /var/lib/tp-undo.img
mkfs.ext4 -q -F /var/lib/tp-undo.img
mkdir -p /srv/tpfs
mount -o loop /var/lib/tp-undo.img /srv/tpfs
printf 'old bytes\n' > /srv/tpfs/tp-undo-file
mkdir -p /srv/tpfs/tp-undo-gone/sub /var/tmp/tp-undo-fs/gone/sub
printf 'x\n' > /srv/tpfs/tp-undo-gone/sub/f
printf 'y\n' > /var/tmp/tp-undo-fs/gone/sub/f
# T119: two files served from the root filesystem (file:// URLs, no network)
mkdir -p /var/lib/tp-fetch
printf 'tp fetch bytes\n' > /var/lib/tp-fetch/blob.txt
printf '%s' 'H4sIAAAAAAAAA+3VSwrCMBSFYceuIhtQ00eSsWCHTtxB1frAR0uN+7cVC7Yo4iBR8f8myexeOOSk2K0HwVCOeg7JilHqela654O7NjrsCeVyqcb5ZNNSCB+jvlFxy3+WjCfTxM2MOlQdx8/zD7v5Gx1V+Us367T9ef62EKvMLjaizNLlIet/eh/41bz/+fbo7A94v/+Niuh/L+7zt3m+dzHjZf9L1c4/kHGo6H8f6swpfQAAAAAAAAAAAAD4fRfw7WVeACgAAA==' | base64 -d > /var/lib/tp-fetch/pkg.tgz
echo "undo_fs fetch files: $(sha256sum /var/lib/tp-fetch/blob.txt /var/lib/tp-fetch/pkg.tgz | cut -c1-16 | tr '\n' ' ')"
echo "undo_fs setup: device $(stat -c %d /srv/tpfs) on /srv/tpfs, $(stat -c %d /var/tmp) on /var/tmp"
SETUP
}
if [[ $container == undo_fs ]]; then
    echo "=== undo_fs setup in the VM: 64 MiB ext4 loop-mounted at /srv/tpfs ==="
    if ! undo_fs_setup; then echo "FAIL: the undo_fs setup failed"; exit 1; fi
fi

# ---- local_user: as_user over --local, run INSIDE the VM (gating) ---------------
# T120 (written, run in T104). The musl tp-basic is copied into the VM and run
# there with `--local`, the only place a real second user exists. No run goes
# over SSH to a host: sshv only sets up, runs tp-basic and reads the files.
# Setup, as root in the VM: `tpuser` (a login shell) and `tpnologin`
# (/usr/sbin/nologin). Run A is `sudo tp-basic run local_user --local` (the
# caller is root: `sudo -n -iu tpuser bash`); run B is the same as the VM's
# passwordless-sudo login user (root shell by `sudo -n -H bash`, user shell by
# `sudo -n -iu tpuser bash`). After each, ~tpuser/marker holds `tpuser` (id -un
# in the user's shell) and ~tpuser/file-marker is the file op's, both owned by
# tpuser. Run C targets tpnologin and must be refused: exit non-zero, STATUS
# blocked, the refusal text of the transport.
if [[ $container == local_user ]]; then
    wrc=0
    ok() { echo "ok   $1"; }
    bad() { echo "FAIL $1"; wrc=1; }
    TPB=/usr/local/bin/tp-basic-local-user
    echo "=== local_user setup in the VM: tpuser, tpnologin and the musl tp-basic ==="
    if ! sshv 'sudo -n sh -s' <<'SETUP'
set -e
id tpuser >/dev/null 2>&1 || useradd -m -s /bin/bash tpuser
id tpnologin >/dev/null 2>&1 || useradd -m -s /usr/sbin/nologin tpnologin
echo "local_user setup: $(getent passwd tpuser tpnologin | cut -d: -f1,6,7 | tr '\n' ' ')"
SETUP
    then echo "FAIL: the local_user setup failed"; exit 1; fi
    if ! sshv "sudo -n tee $TPB >/dev/null && sudo -n chmod 755 $TPB" <"$ROOT/build/tp-basic"; then
        echo "FAIL: copying build/tp-basic into the VM failed"; exit 1
    fi
    echo "tp-basic in the VM: $(sshv "$TPB list | head -1" 2>&1 || true)"
    # lu_run <name> <sudo|plain> <playbook> : tp-basic run <playbook> --local in the VM, output in $out/<name>.out
    lu_run() {
        local name=$1 how=$2 pb=$3 rc=0 pre=
        [[ $how == sudo ]] && pre='sudo -n '
        echo "=== $name: ${pre}tp-basic run $pb --local (in the VM, as $([[ $how == sudo ]] && echo root || echo 'the login user')) ==="
        sshv "${pre}$TPB run $pb --local" >"$out/$name.out" 2>&1 || rc=$?
        sed -n '/^HOST  *STATUS/,$p' "$out/$name.out"
        return $rc
    }
    # lu_read <file> : what the playbook left in ~tpuser, read as root
    lu_read() {
        sshv 'sudo -n sh -s' >"$1" 2>&1 <<'READ' || true
printf "marker=%s\n" "$(cat /home/tpuser/marker 2>/dev/null)"
printf "markerowner=%s\n" "$(stat -c %U /home/tpuser/marker 2>/dev/null)"
printf "file=%s\n" "$(cat /home/tpuser/file-marker 2>/dev/null)"
printf "fileowner=%s\n" "$(stat -c %U /home/tpuser/file-marker 2>/dev/null)"
READ
    }
    for step in "runA sudo root" "runB plain the-login-user"; do
        read -r name how who <<<"$step"
        sshv 'sudo -n rm -f /home/tpuser/marker /home/tpuser/file-marker' || true
        rc=0; lu_run "$name" "$how" local_user || rc=$?
        lu_read "$out/$name.listing"
        sed 's/^/     | /' "$out/$name.listing"
        if [[ $rc -eq 0 && $(status_of "$out/$name.out") == changed ]]; then ok "$name ($who): exit 0, STATUS changed"
        else bad "$name ($who): exit $rc, STATUS '$(status_of "$out/$name.out")', wanted exit 0 and changed (log: $out/$name.out)"; fi
        probs=$(local_user_problems "$out/$name.listing" "$LU_USER")
        if [[ -z $probs ]]; then ok "$name ($who): ~$LU_USER/marker says $LU_USER and both files are owned by $LU_USER"
        else while IFS= read -r l; do bad "$name ($who): $l"; done <<<"$probs"; fi
    done
    rc=0; lu_run runC plain local_user_nologin || rc=$?
    probs=$(local_user_refusal_problems "$out/runC.out" "$rc" "$LU_NOLOGIN")
    if [[ -z $probs ]]; then ok "runC (nologin): refused with the transport's text, STATUS blocked"
    else while IFS= read -r l; do bad "runC (nologin): $l"; done <<<"$probs"; fi
    r=$(sshv 'sudo -n test -e /home/tpnologin/marker && echo present || echo absent' 2>&1) || true
    if [[ $r == absent ]]; then ok "runC (nologin): nothing was written to ~$LU_NOLOGIN"; else bad "runC (nologin): ~$LU_NOLOGIN/marker is '$r'"; fi
    if [[ $wrc -ne 0 ]]; then echo "FAIL: a local_user check failed"; exit 1; fi
    echo "local_user checks: all passed"
    echo "PASS: local_user on a $distro VM (as_user over --local: as root and as the sudo login user the op ran as $LU_USER and wrote its files owned by $LU_USER; a nologin user was refused with the transport's text)"
    exit 0
fi

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

# ---- reboot_vm: marks, the barrier and --reboot never on a booted VM (gating) ------
# Run 1 is done (exit 0). Every check prints ok or FAIL; the verdict comes
# after the checks of each run.
if [[ $container == reboot_vm ]]; then
    wrc=0
    ok() { echo "ok   $1"; }
    bad() { echo "FAIL $1"; wrc=1; }
    # vexpect <label> <want> <command>: the command's stdout, run over SSH, is <want>
    vexpect() {
        local o r=0
        o=$(sshv "$3" 2>&1) || r=$?
        if [[ $o == "$2" ]]; then ok "$1: $o"; else bad "$1 printed '$o' (exit $r), wanted '$2'"; fi
    }
    # boot_is <label> <same|changed> <boot id to compare with>: sets bnow
    bnow=
    boot_is() {
        bnow=$(sshv "$boot_cmd" 2>&1) || bnow="(failed: $bnow)"
        if [[ $bnow == '(failed'* || -z $bnow ]]; then bad "$1: boot id unreadable ('$bnow')"
        elif [[ $2 == changed && $bnow != "$3" ]]; then ok "$1: boot id changed ($3 -> $bnow)"
        elif [[ $2 == same && $bnow == "$3" ]]; then ok "$1: boot id unchanged ($bnow)"
        else bad "$1: boot id $3 -> $bnow, wanted it $2"; fi
    }
    pend_cmd='test -e /run/telepatch/reboot-pending && echo present || echo absent'
    # n_reboots <label> <run n> <want>
    n_reboots() {
        local n
        n=$(reboot_events "$out/run$2.jsonl")
        if [[ $n -eq $3 ]]; then ok "$1: $n reboot event(s)"; else bad "$1: $n reboot events, wanted $3"; fi
    }
    [[ $b0 != '(failed'* && -n $b0 ]] || { echo "FAIL: the boot id before run 1 is unreadable ('$b0')"; exit 1; }

    echo "=== reboot_vm after run 1: the marked file op, the barrier, the file after it ==="
    grep '^== .* \[reboot\]' "$out/run1.out" || true
    if [[ $(status_of "$out/run1.out") == changed ]]; then ok "run 1: exit 0, STATUS changed"
    else bad "run 1: STATUS $(status_of "$out/run1.out"), wanted changed (log: $out/run1.out)"; fi
    boot_is "after run 1" changed "$b0"
    b1=$bnow
    if grep -qF 'boot id changed, shells reopened' "$out/run1.out"; then ok "run 1: the stream says 'boot id changed, shells reopened'"
    else bad "run 1: run1.out lacks 'boot id changed, shells reopened'"; fi
    n_reboots "run 1" 1 1
    vexpect "after run 1 /etc/tp-reboot-after (the op after the barrier ran)" 'after=1' 'cat /etc/tp-reboot-after'
    vexpect "after run 1 /etc/tp-reboot-marked" 'marked=1' 'cat /etc/tp-reboot-marked'
    vexpect "after run 1 /run/telepatch/reboot-pending" absent "$pend_cmd"
    [[ $wrc -eq 0 ]] || { echo "FAIL: a reboot_vm check after run 1 failed"; exit 1; }

    echo "=== reboot_vm run 2: same vars, nothing changes, no reboot ==="
    rc2=0; run 2 || rc2=$?
    if [[ $rc2 -eq 0 && $(status_of "$out/run2.out") == ok && $(changed_of "$out/run2.out") == 0 ]]; then ok "run 2: STATUS ok, CHANGED 0"
    else
        bad "run 2 exited $rc2, STATUS $(status_of "$out/run2.out"), CHANGED $(changed_of "$out/run2.out") (log: $out/run2.out)"
        changed_ops "$out/run2.out" | sed 's/^/     changed: /'
    fi
    n_reboots "run 2" 2 0
    boot_is "after run 2" same "$b1"
    [[ $wrc -eq 0 ]] || { echo "FAIL: a reboot_vm check after run 2 failed"; exit 1; }

    echo "=== reboot_vm run 3: a fresh mark, --reboot never stops at the barrier ==="
    RUN_VARS=$out/vars-run3.toml
    reboot_vm_vars3 "$RUN_VARS"
    echo "run 3's vars (runs 4 and 5 too): $RUN_VARS"; sed 's/^/     | /' "$RUN_VARS"
    RUN_EXTRA=(--reboot never)
    rc3=0; run 3 || rc3=$?
    RUN_EXTRA=()
    if [[ $rc3 -eq 1 ]]; then ok "run 3: exit 1"; else bad "run 3 exited $rc3, wanted 1 (log: $out/run3.out)"; fi
    if [[ $(status_of "$out/run3.out") == 'reboot pending' ]]; then ok "run 3: STATUS reboot pending"
    else bad "run 3: STATUS '$(status_of "$out/run3.out")', wanted 'reboot pending' (log: $out/run3.out)"; fi
    if grep -qF 'reboot pending at barrier' "$out/run3.out"; then ok "run 3: run3.out says 'reboot pending at barrier'"
    else bad "run 3: run3.out lacks 'reboot pending at barrier'"; fi
    vexpect "after run 3 /etc/tp-reboot-marked (the marked op ran)" 'marked=2' 'cat /etc/tp-reboot-marked'
    vexpect "after run 3 /etc/tp-reboot-after (the op after the barrier did not run)" 'after=1' 'cat /etc/tp-reboot-after'
    vexpect "after run 3 /run/telepatch/reboot-pending" present "$pend_cmd"
    mk=$(sshv 'sudo -n cat /run/telepatch/reboot-pending' 2>&1) || mk="(failed: $mk)"
    if [[ $mk == *'/etc/tp-reboot-marked'* ]]; then ok "run 3: the mark lists the marked file: $mk"
    else bad "run 3: the mark file says '$mk', wanted a line naming /etc/tp-reboot-marked"; fi
    n_reboots "run 3" 3 0
    boot_is "after run 3" same "$b1"
    [[ $wrc -eq 0 ]] || { echo "FAIL: a reboot_vm check after run 3 failed"; exit 1; }

    echo "=== reboot_vm run 4: same vars, default policy: the mark run 3 left reboots ==="
    rc4=0; run 4 || rc4=$?
    grep '^== .* \[reboot\]' "$out/run4.out" || true
    if [[ $rc4 -eq 0 ]]; then ok "run 4: exit 0"; else bad "run 4 exited $rc4, wanted 0 (log: $out/run4.out)"; fi
    n_reboots "run 4" 4 1
    boot_is "after run 4" changed "$b1"
    b4=$bnow
    vexpect "after run 4 /etc/tp-reboot-after" 'after=2' 'cat /etc/tp-reboot-after'
    vexpect "after run 4 /run/telepatch/reboot-pending" absent "$pend_cmd"
    r4=$(op_result "$out/run4.out" 'file /etc/tp-reboot-marked content')
    if [[ $r4 == '-> ok' ]]; then ok "run 4: the marked file op ended -> ok (the reboot came from run 3's mark)"
    else bad "run 4: the marked file op ended '$r4', wanted '-> ok'"; fi
    [[ $wrc -eq 0 ]] || { echo "FAIL: a reboot_vm check after run 4 failed"; exit 1; }

    echo "=== reboot_vm run 5: same vars, nothing changes, no reboot ==="
    rc5=0; run 5 || rc5=$?
    if [[ $rc5 -eq 0 && $(status_of "$out/run5.out") == ok && $(changed_of "$out/run5.out") == 0 ]]; then ok "run 5: STATUS ok, CHANGED 0"
    else
        bad "run 5 exited $rc5, STATUS $(status_of "$out/run5.out"), CHANGED $(changed_of "$out/run5.out") (log: $out/run5.out)"
        changed_ops "$out/run5.out" | sed 's/^/     changed: /'
    fi
    n_reboots "run 5" 5 0
    boot_is "after run 5" same "$b4"
    if [[ $wrc -ne 0 ]]; then echo "FAIL: a reboot_vm check failed"; exit 1; fi
    echo "reboot_vm checks: all passed"
    echo "PASS: reboot_vm on a $distro VM over SSH (run 1 crossed the barrier; run 2 CHANGED 0, no reboot; run 3 --reboot never stopped at the barrier; run 4 rebooted from the mark; run 5 CHANGED 0)"
    exit 0
fi

# ---- undo_fs: the real device walk on a second filesystem (gating) -----------------
# Run 1 is done (exit 0; the setup above ran before it). Every check prints ok
# or FAIL; the verdict comes after all of them.
if [[ $container == undo_fs ]]; then
    wrc=0
    ok() { echo "ok   $1"; }
    bad() { echo "FAIL $1"; wrc=1; }
    # vexpect <label> <want> <command>: the command's stdout, run over SSH, is <want>
    vexpect() {
        local o r=0
        o=$(sshv "$3" 2>&1) || r=$?
        if [[ $o == "$2" ]]; then ok "$1: $o"; else bad "$1 printed '$o' (exit $r), wanted '$2'"; fi
    }
    echo "=== undo_fs after run 1: the mid-run listing and what is left ==="
    mid=$out/undo-fs-mid.txt
    sshv 'sudo -n cat /root/tp-undo-fs-mid.txt' >"$mid" 2>&1 || true
    echo "mid-run listing (/root/tp-undo-fs-mid.txt):"; sed 's/^/     | /' "$mid"
    if [[ $(status_of "$out/run1.out") == changed ]]; then ok "run 1: STATUS changed"
    else bad "run 1: STATUS '$(status_of "$out/run1.out")', wanted changed (log: $out/run1.out)"; fi
    probs=$(undo_fs_mid_problems "$mid")
    if [[ -z $probs ]]; then ok "mid-run: two backups under /srv/tpfs/.telepatch/tmp/<run>/undo/root/<id>/, a stage link to each, one plain stage directory, no /.telepatch on the root filesystem"
    else while IFS= read -r l; do bad "mid-run listing: $l"; done <<<"$probs"; fi
    run=$(undo_fs_mid_run "$mid")
    vexpect "the second filesystem has a device of its own" different '[ "$(stat -c %d /srv/tpfs)" != "$(stat -c %d /var/tmp)" ] && echo different || echo same'
    # T119: the fetch case. The downloads were on /srv/tpfs mid-run, with only links in the stage.
    fprobs=$(undo_fs_fetch_problems "$mid" download)
    if [[ -z $fprobs ]]; then ok "mid-run: both downloads are cache entries under /srv/tpfs/.telepatch/cache/sha256/, the stage holds only a link to each, no .part left"
    else while IFS= read -r l; do bad "mid-run fetch listing: $l"; done <<<"$fprobs"; fi
    # what is left: /srv/tpfs/.telepatch holds the cache only (its tmp went with the run); the main cache was not used
    vexpect "after the run /srv/tpfs/.telepatch/tmp" absent '[ -e /srv/tpfs/.telepatch/tmp ] && echo present || echo absent'
    vexpect "after the run /srv/tpfs/.telepatch holds" cache 'ls /srv/tpfs/.telepatch'
    vexpect "after the run the cache on /srv/tpfs" "$(printf '%s\n' "${UNDO_FETCH_SUMS[@]}" | sort | tr '\n' ' ' | sed 's/ $//')" 'ls /srv/tpfs/.telepatch/cache/sha256 | sort | tr "\n" " " | sed "s/ $//"'
    vexpect "the cache entries are root-owned 0644" '644 root' 'for f in /srv/tpfs/.telepatch/cache/sha256/*; do stat -c "%a %U" "$f"; done | sort -u'
    vexpect "the main cache holds neither file" absent '[ -e /var/cache/telepatch/sha256/'"${UNDO_FETCH_SUMS[0]}"' ] || [ -e /var/cache/telepatch/sha256/'"${UNDO_FETCH_SUMS[1]}"' ] && echo present || echo absent'
    vexpect "after the run /srv/tpfs/tp-fetch-blob.txt" 'tp fetch bytes' 'cat /srv/tpfs/tp-fetch-blob.txt'
    vexpect "after the run /srv/tpfs/tp-fetch-tree/README" 'tp fetch readme' 'cat /srv/tpfs/tp-fetch-tree/README'
    if [[ -n $run ]]; then
        vexpect "after the run /var/tmp/telepatch/$run" absent "if [ -e /var/tmp/telepatch/$run ] || [ -L /var/tmp/telepatch/$run ]; then echo present; else echo absent; fi"
    else bad "after the run: no run id in the listing, /var/tmp/telepatch/<run> not checked"; fi
    vexpect "after the run /.telepatch" absent '[ -e /.telepatch ] && echo present || echo absent'
    vexpect "after the run /srv/tpfs/tp-undo-file" 'new bytes' 'cat /srv/tpfs/tp-undo-file'
    vexpect "after the run /srv/tpfs/tp-undo-gone" absent '[ -e /srv/tpfs/tp-undo-gone ] && echo present || echo absent'
    vexpect "after the run /var/tmp/tp-undo-fs/gone" absent '[ -e /var/tmp/tp-undo-fs/gone ] && echo present || echo absent'
    # T119, run 2: nothing changes, and both fetches are a hit on /srv/tpfs (no download, no fetch directory)
    echo "=== undo_fs run 2: the cache on /srv/tpfs answers ==="
    rc2=0; run 2 || rc2=$?
    mid2=$out/undo-fs-mid2.txt
    sshv 'sudo -n cat /root/tp-undo-fs-mid.txt' >"$mid2" 2>&1 || true
    echo "mid-run listing of run 2:"; sed 's/^/     | /' "$mid2"
    if [[ $rc2 -eq 0 && $(status_of "$out/run2.out") == ok && $(changed_of "$out/run2.out") == 0 ]]; then ok "run 2: STATUS ok, CHANGED 0"
    else
        bad "run 2 exited $rc2, STATUS $(status_of "$out/run2.out"), CHANGED $(changed_of "$out/run2.out") (log: $out/run2.out)"
        changed_ops "$out/run2.out" | sed 's/^/     changed: /'
    fi
    nhit=$(grep -c '\[prepare\] fetch file:///var/lib/tp-fetch/.*: cached' "$out/run2.out" || true)
    if [[ $nhit -eq 2 ]]; then ok "run 2: both fetches say cached (the cache on /srv/tpfs, no download)"
    else bad "run 2: $nhit fetch line(s) say cached, wanted 2 (log: $out/run2.out)"; fi
    fprobs2=$(undo_fs_fetch_problems "$mid2" hit)
    if [[ -z $fprobs2 ]]; then ok "run 2 mid-run: a stage link to each cache entry on /srv/tpfs, no fetch directory made"
    else while IFS= read -r l; do bad "run 2 mid-run fetch listing: $l"; done <<<"$fprobs2"; fi
    vexpect "after run 2 /srv/tpfs/.telepatch holds" cache 'ls /srv/tpfs/.telepatch'
    # T123: tp-basic cache usage and cache purge over the same SSH path (a single --host)
    echo "=== undo_fs: tp-basic cache usage / purge --host $dest ==="
    cache_cmd() { # <name> <tp-basic cache args>: output in $out/<name>.out, the exit code returned
        local name=$1 rc=0; shift
        tpb_ssh_args "$key" "$out/known_hosts"
        "$ROOT/build/tp-basic" cache "$@" --host "$dest" "${TPB_SSH_ARGS[@]}" >"$out/$name.out" 2>&1 || rc=$?
        echo "tp-basic cache $* --host $dest (exit $rc):"; sed 's/^/     | /' "$out/$name.out"
        return $rc
    }
    crc=0; cache_cmd cache-usage1 usage || crc=$?
    if [[ $crc -eq 0 ]]; then ok "cache usage exited 0"; else bad "cache usage exited $crc (log: $out/cache-usage1.out)"; fi
    cprobs=$(cache_usage_problems "$out/cache-usage1.out" "$dest" 2)
    if [[ -z $cprobs ]]; then ok "cache usage lists /srv/tpfs/.telepatch/cache/sha256 with 2 items and a size"
    else while IFS= read -r l; do bad "cache usage: $l"; done <<<"$cprobs"; fi
    echo "note: the main cache /var/cache/telepatch/sha256 is $(cache_main_listed "$out/cache-usage1.out") in the usage (this case fetches onto /srv/tpfs; the main cache is listed only if it exists)"
    # without --yes nothing is removed
    crc=0; cache_cmd cache-purge-dry purge || crc=$?
    if [[ $crc -eq 0 ]] && grep -q 'would remove' "$out/cache-purge-dry.out"; then ok "cache purge without --yes exited 0 and said what it would remove"
    else bad "cache purge without --yes: exit $crc, no 'would remove' (log: $out/cache-purge-dry.out)"; fi
    vexpect "after a purge without --yes the cache on /srv/tpfs still holds" 2 'ls /srv/tpfs/.telepatch/cache/sha256 | wc -l'
    crc=0; cache_cmd cache-purge purge --yes || crc=$?
    if [[ $crc -eq 0 ]]; then ok "cache purge --yes exited 0"; else bad "cache purge --yes exited $crc (log: $out/cache-purge.out)"; fi
    vexpect "after cache purge --yes /srv/tpfs/.telepatch" absent '[ -e /srv/tpfs/.telepatch ] && echo present || echo absent'
    vexpect "after cache purge --yes the main cache holds no file" 0 'ls /var/cache/telepatch/sha256 2>/dev/null | wc -l'
    vexpect "after cache purge --yes the fetched file itself is untouched" 'tp fetch bytes' 'cat /srv/tpfs/tp-fetch-blob.txt'
    crc=0; cache_cmd cache-usage2 usage || crc=$?
    cprobs=$(cache_usage_problems "$out/cache-usage2.out" "$dest" 0)
    if [[ $crc -eq 0 && -z $cprobs ]]; then ok "cache usage after the purge shows 0 items"
    else bad "cache usage after the purge: exit $crc ${cprobs//$'\n'/; } (log: $out/cache-usage2.out)"; fi
    if [[ $wrc -ne 0 ]]; then echo "FAIL: an undo_fs check failed"; exit 1; fi
    echo "undo_fs checks: all passed"
    echo "PASS: undo_fs on a $distro VM over SSH (backups on the target's own filesystem, a stage link each, no /.telepatch on the root filesystem, all gone after the run; fetches cached on the target's filesystem, run 2 CHANGED 0)"
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
