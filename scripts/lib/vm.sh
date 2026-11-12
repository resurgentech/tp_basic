# VM lifecycle helpers for the scripts that run against a fresh VM made with
# ~/repos/jaredeh/vmtool (scripts/test-vm.sh, scripts/test-vm-oracle.sh).
# Sourced, not run. No comparison logic lives here.
#
# The caller defines die() (message, exit 2) and may set VM_TAG (the prefix of
# the lib's own warnings, default "vm"). Every function takes the VM name, the
# output directory and the log prefix (the start of its log file names, "" for
# create.log, "ansible-" for ansible-create.log) as arguments; nothing is
# matched by pattern, and only names passed to vm_record are ever deleted.
#
# Local (TP_VM_HOST=local): the SSH key is used in place from vmtool's
# .machines/<name>/ directory and never copied or printed.
# Remote: vmtool runs on TP_VM_HOST, its key never leaves that host, and the
# guest is reached from here with `-o ProxyJump=$TP_VM_HOST` and a per-run key
# (see vm_up). Every remote command is ONE ssh argument, `bash -c <script>` with
# the script quoted by printf %q: the host's login shell may be zsh, which
# splits and expands the string before bash sees it (the scheme of
# scripts/vm-host.sh).

VMTOOL_DIR=${VMTOOL_DIR:-$HOME/repos/jaredeh/vmtool}
# Where the tp-* VMs are created (environment overrides; no .env file). The one
# place the VM host is named. scripts/vm-host.sh reads the same settings.
#   TP_VM_HOST      ssh destination of the VM host; `local` is this workstation
#                   (VMTOOL_DIR/vmtool, as before)
#   TP_VM_HOST_DIR  vmtool's directory on the VM host, relative to its home
#   TP_VM_POOL      libvirt pool for the clones and the image: `tp` on a remote
#                   host, empty on `local` (vmtool's own `default`)
TP_VM_HOST=${TP_VM_HOST:-veritech04.labtwo}
TP_VM_HOST_DIR=${TP_VM_HOST_DIR:-tp-vmtool}
if [[ $TP_VM_HOST == local ]]; then TP_VM_POOL=${TP_VM_POOL:-}; else TP_VM_POOL=${TP_VM_POOL:-tp}; fi
VM_RECORDED=()
# The run's scratch dir (the per-run key lives there): made by vm_up on a remote
# host, removed by vm_cleanup, which every caller's exit trap runs.
VM_SCRATCH=
# The ssh options for the guest: the ONE definition, used by sshv and by the
# docker socket forward (vm_tunnel_argv). Set by vm_set_ssh_opts.
VM_SSH_OPTS=()
# Every tp-* VM gets 1 GiB ("no reason to have them use more than 1GB of RAM
# each"); vm_up refuses any other size. Swap is a file enabled with swapon only.
VM_MEMORY_GIB=1
VM_SWAP_GIB=4
# The image's own disk (GB): a default-size VM gets this plus the swap file,
# so the swap does not eat the free space a playbook had before.
VM_IMAGE_DISK_GB=10
# What the current script is doing, for the memory-failure report.
VM_STEP=

vm_warn() { echo "${VM_TAG:-vm}: $*" >&2; }

# vm_is_local : true when the VM host is this workstation.
vm_is_local() { [[ $TP_VM_HOST == local ]]; }
# vm_rcmd_string <script> : the one string ssh sends: `bash -c <script>`, the
# script quoted by printf %q (means the same to zsh and bash).
vm_rcmd_string() { printf 'bash -c %q' "$1"; }
# vm_rs <script> : run the script on the VM host; stdin is the caller's.
vm_rs() { ssh -o BatchMode=yes "$TP_VM_HOST" "$(vm_rcmd_string "$1")"; }
# vmtool <args>... : vmtool's CLI. Local: from VMTOOL_DIR. Remote: ./vmtool in
# ~/$TP_VM_HOST_DIR on the VM host, every argument quoted, stdin /dev/null.
vmtool() {
    if vm_is_local; then (cd "$VMTOOL_DIR" && ./vmtool "$@"); return; fi
    local s='cd "$HOME/'$TP_VM_HOST_DIR'" && ./vmtool' a
    for a in "$@"; do s+=$(printf ' %q' "$a"); done
    vm_rs "$s" </dev/null
}
# vm_ip <name> : the IP column of the list row whose NAME is exactly <name>.
vm_ip() { vmtool list | awk -v n="$1" 'NR > 1 && $1 == n { print $NF }'; }
# vm_listed <name> : true when `vmtool list` has a row whose NAME is exactly <name>.
vm_listed() { vmtool list | awk -v n="$1" 'NR > 1 && $1 == n { f = 1 } END { exit !f }'; }
# vm_key <name> : (local) the path of the key vmtool's setup_bot.yml wrote for bot.
vm_key() { echo "$VMTOOL_DIR/.machines/$1/id_ed25519"; }
# vm_name_ok <name> : true for tp- followed by lowercase letters, digits and -.
vm_name_ok() { [[ $1 =~ ^tp-[a-z0-9-]+$ ]]; }
# vm_require_name <name> : any other name dies (the caller's die(): message,
# exit 2) before any vmtool call. No vt-* or default VM is ever named.
vm_require_name() { vm_name_ok "$1" || die "refusing VM name '$1': only tp-[a-z0-9-]+ names are used (vt-* and every other VM are not ours)"; }
# vm_where : " on <host>" for a remote host, nothing for local.
vm_where() { vm_is_local || printf ' on %s' "$TP_VM_HOST"; }
# vm_delete_cmd <name> : the command that deletes <name> by hand.
vm_delete_cmd() {
    if vm_is_local; then echo "cd $VMTOOL_DIR && ./vmtool delete $1"
    else echo "ssh $TP_VM_HOST 'cd ~/$TP_VM_HOST_DIR && ./vmtool delete $1'"; fi
}
# vm_set_ssh_opts : (re)build VM_SSH_OPTS from VM_KEY and VM_KNOWN_HOSTS. A remote
# host adds ProxyJump: the guest's 192.168.122.x is reached only through it.
vm_set_ssh_opts() {
    VM_SSH_OPTS=(-i "$VM_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10
        -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$VM_KNOWN_HOSTS")
    vm_is_local || VM_SSH_OPTS+=(-o "ProxyJump=$TP_VM_HOST")
}
# vm_scratch_rm : remove the run's scratch dir, and the run key in it.
vm_scratch_rm() {
    if [[ -n $VM_SCRATCH && -d $VM_SCRATCH ]]; then rm -rf -- "$VM_SCRATCH"; fi
    VM_SCRATCH=
}

# vm_record <name> : remember <name> as created by this run, before creating it.
# A name that is not tp-[a-z0-9-]+ dies (exit 2), so nothing else is ever deleted.
vm_record() { vm_require_name "$1"; VM_RECORDED+=("$1"); }

# vm_probe_ssh <ip> : true when tcp/22 of <ip> answers within 5 s. Remote: probed
# from the VM host, the guest's address is not routable from here.
vm_probe_ssh() {
    if vm_is_local; then timeout 5 bash -c "exec 3<>/dev/tcp/$1/22" 2>/dev/null
    else vm_rs "timeout 5 bash -c 'exec 3<>/dev/tcp/$1/22'" </dev/null >/dev/null 2>&1; fi
}

# vm_run_key <name> <ip> : (remote) make the per-run key and install its public
# half for bot. This lib owns the scratch dir (VM_SCRATCH: mktemp -d under
# XDG_RUNTIME_DIR, mode 0700; the key 0600) and vm_cleanup removes it. The install
# is an ssh ON the VM host: bot@<ip> with vmtool's key in place, the .pub on
# stdin, appended to bot's authorized_keys. No known_hosts file is written
# there (UserKnownHostsFile=/dev/null), so nothing lands in .machines or
# anywhere else on the host. Sets VM_KEY.
vm_run_key() {
    local name=$1 ip=$2 s
    [[ -n $VM_SCRATCH && -d $VM_SCRATCH ]] || VM_SCRATCH=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/tp-vm.XXXXXX") || die "mktemp -d failed"
    VM_KEY=$VM_SCRATCH/id_$name
    rm -f "$VM_KEY" "$VM_KEY.pub"
    ssh-keygen -q -t ed25519 -N '' -C "tp-run-$name" -f "$VM_KEY" || die "ssh-keygen failed"
    chmod 600 "$VM_KEY"
    s='ssh -i "$HOME/'$TP_VM_HOST_DIR'/.machines/'$name'/id_ed25519" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10'
    s+=' -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR bot@'$ip
    s+=" 'umask 077; mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys'"
    vm_rs "$s" <"$VM_KEY.pub" || die "installing the run key for bot@$ip through $TP_VM_HOST failed"
}

# vm_up <name> <out dir> <log prefix> [<memory GiB>] [<disk GB>] : create the VM
# (ubuntu2404.qcow2; memory 1 GiB, the only size allowed: any other value is a
# usage error; disk default the image's own size plus the swap file), wait for
# tcp/22, onboard bot with setup_bot.yml, wait for cloud-init and a free dpkg
# lock, run `apt-get update --fix-missing`, add a VM_SWAP_GIB swap file
# (/tp-swap, `swapon` only: no /etc/fstab line, so nothing a playbook or the
# state capture sees changes, and a reboot drops it) and start a vmstat
# sampler for vm_mem_report. Logs go to <out>/<prefix>{create,onboard,wait,
# prep,swap}.log. Sets VM_IP, VM_KEY, VM_DEST, VM_KNOWN_HOSTS (<out>/known_hosts)
# and VM_SSH_OPTS for sshv. The name must be recorded first.
#
# On a remote host: create has `--pool $TP_VM_POOL` and create.log starts with a
# line naming the host; the tcp/22 wait is probed from the VM host; vmtool
# onboards bot there (its key stays in ~/$TP_VM_HOST_DIR/.machines/<name>/);
# then vm_run_key makes the per-run key (VM_KEY) and installs its public half.
# Nothing is read back from .machines.
vm_up() {
    local name=$1 out=$2 p=$3 mem=${4:-$VM_MEMORY_GIB} disk=${5:-} crc=0 deadline ready grow_late=0
    [[ $mem == "$VM_MEMORY_GIB" ]] || die "vm_up: $mem GiB asked for $name; every tp-* VM gets $VM_MEMORY_GIB GiB (swap is allowed, more memory is not)"
    [[ -n $disk ]] || disk=$((VM_IMAGE_DISK_GB + VM_SWAP_GIB))
    vm_require_name "$name"
    local size=(--memory "$mem" --disk-size "$disk")
    [[ -z $TP_VM_POOL ]] || size+=(--pool "$TP_VM_POOL")
    VM_STEP="creating $name"
    echo "=== creating VM $name$(vm_where) (ubuntu2404.qcow2, $mem GiB${disk:+, $disk GB disk}) ==="
    {
        vm_is_local || echo "# vmtool create $name on $TP_VM_HOST (~/$TP_VM_HOST_DIR, pool ${TP_VM_POOL:-default})"
        vmtool create "$name" ubuntu2404.qcow2 "${size[@]}"
    } >"$out/${p}create.log" 2>&1 || crc=$?
    if grep -q 'timed out waiting for IP' "$out/${p}create.log"; then
        tail -5 "$out/${p}create.log"
        vm_warn "the VM got no IP. This is a host environment problem, not a telepatch failure:"
        vm_warn "see $VMTOOL_DIR/README.md$(vm_where), \"Troubleshooting\" > \"A new VM never gets an IP\"."
        exit 2
    fi
    # With --disk-size, vmtool resizes the image, boots, and then grows the root
    # partition with an ansible ad-hoc command right after the IP, racing sshd's
    # start like `create --playbook` (observed: "growing disk: running command:
    # exit status 4", ansible's unreachable). The VM is up with the larger disk;
    # the grow is redone below once sshd answers.
    if [[ $crc -ne 0 && -n $disk ]] && grep -q 'growing disk: running command' "$out/${p}create.log" \
        && grep -q 'created and started' "$out/${p}create.log"; then
        vm_warn "vmtool's in-guest disk grow ran before sshd answered; growing the root filesystem after onboarding"
        crc=0 grow_late=1
    fi
    [[ $crc -eq 0 ]] || { tail -20 "$out/${p}create.log"; die "vmtool create exited $crc (log: $out/${p}create.log)"; }

    VM_IP=$(vm_ip "$name")
    [[ $VM_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "no IP for $name in 'vmtool list' (got '${VM_IP:-}')"

    # Onboarding: vmtool's setup_bot.yml makes user bot (key auth, passwordless
    # sudo) and writes the key to its .machines/<name>/id_ed25519. It is run once
    # the guest's sshd answers: `create --playbook` runs it right after the IP and
    # races sshd's start (observed: "Connection refused").
    echo "=== waiting for sshd on $VM_IP, then onboarding bot (setup_bot.yml) ==="
    deadline=$((SECONDS + 300))
    until vm_probe_ssh "$VM_IP"; do
        [[ $SECONDS -lt $deadline ]] || die "sshd on $name ($VM_IP) did not answer within 5 min"
        sleep 3
    done
    vmtool playbook "$name" setup_bot.yml >"$out/${p}onboard.log" 2>&1 \
        || { grep -E 'fatal|ERROR|RECAP' "$out/${p}onboard.log" | tail -5; die "vmtool playbook $name setup_bot.yml failed (log: $out/${p}onboard.log)"; }
    VM_DEST=bot@$VM_IP
    VM_KNOWN_HOSTS=$out/known_hosts
    if vm_is_local; then
        VM_KEY=$(vm_key "$name")
        [[ -f $VM_KEY ]] || die "no key at $VM_KEY"
        vm_set_ssh_opts
    else
        vm_run_key "$name" "$VM_IP"
        vm_set_ssh_opts
        sshv true >>"$out/${p}onboard.log" 2>&1 \
            || { tail -5 "$out/${p}onboard.log"; die "the run key was not accepted by $VM_DEST through $TP_VM_HOST (log: $out/${p}onboard.log)"; }
    fi
    # A later VM of the same run may get an earlier one's IP from DHCP; forget
    # that host key so accept-new takes the new VM's.
    if [[ -f $VM_KNOWN_HOSTS ]]; then ssh-keygen -q -R "$VM_IP" -f "$VM_KNOWN_HOSTS" >/dev/null 2>&1 || true; fi
    echo "VM $name at $VM_IP"

    # ---- wait for cloud-init and the dpkg lock (bounded, 10 min) ----------------
    echo "=== waiting for cloud-init and a free dpkg lock ==="
    ready='cloud-init status --wait >/dev/null 2>&1; s=$?; [ $s -eq 0 ] || [ $s -eq 2 ] || exit 1
if command -v fuser >/dev/null 2>&1; then
  ! sudo -n fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1
else
  ! pgrep -x "apt|apt-get|dpkg|unattended-upgr" >/dev/null
fi'
    deadline=$((SECONDS + 600))
    until sshv "$ready" >>"$out/${p}wait.log" 2>&1; do
        [[ $SECONDS -lt $deadline ]] || { tail -5 "$out/${p}wait.log"; echo "FAIL: VM not ready after 10 min (log: $out/${p}wait.log)"; exit 1; }
        sleep 5
    done
    echo "ready after $((SECONDS - deadline + 600))s"

    if [[ $grow_late -eq 1 ]]; then
        # growpart exits 1 with NOCHANGE when cloud-init already grew it
        echo "=== growing the root filesystem to the ${disk} GB disk (vmtool's grow raced sshd) ==="
        sshv 'sudo -n growpart /dev/vda 2; sudo -n resize2fs /dev/vda2; df -BG --output=size / | tail -1' >"$out/${p}grow.log" 2>&1 || true
        local got
        got=$(tail -1 "$out/${p}grow.log" | tr -dc 0-9)
        [[ -n $got && $got -ge $((disk * 9 / 10)) ]] || { tail -10 "$out/${p}grow.log"; die "the root filesystem of $name is ${got:-?} GB, wanted about $disk (log: $out/${p}grow.log)"; }
        echo "root filesystem: ${got} GB"
    fi

    # The cloud image ships package lists from its build date, whose archive
    # files are gone (observed: 404 on the first install). The oracle's
    # Dockerfile runs `apt-get update --fix-missing` before tp-basic; this is the
    # same environment step, done before the "before" capture so it is not
    # counted as something the run added.
    echo "=== apt-get update on the VM (as the oracle's Dockerfile does) ==="
    sshv 'sudo -n apt-get -q update --fix-missing' >"$out/${p}prep.log" 2>&1 \
        || { tail -10 "$out/${p}prep.log"; die "apt-get update on the VM failed (log: $out/${p}prep.log)"; }

    echo "=== swap: a $VM_SWAP_GIB GiB file, swapon only (no /etc/fstab line) ==="
    sshv "sudo -n sh -c 'fallocate -l ${VM_SWAP_GIB}G /tp-swap && chmod 600 /tp-swap && mkswap /tp-swap >/dev/null && swapon /tp-swap' && swapon --show && free -m" \
        >"$out/${p}swap.log" 2>&1 || { cat "$out/${p}swap.log"; die "adding swap on $name failed (log: $out/${p}swap.log)"; }
    grep -q '/tp-swap' "$out/${p}swap.log" || { cat "$out/${p}swap.log"; die "swapon --show lacks /tp-swap on $name"; }
    # memory and swap every 5 s until the VM is deleted, for vm_mem_report
    sshv 'nohup vmstat -n -S M 5 >/var/tmp/tp-vmstat.log 2>&1 </dev/null &' >/dev/null 2>&1 \
        || vm_warn "WARNING: could not start the vmstat sampler on $name"
    VM_STEP=
}

# vm_mem_report <out dir> <log prefix> : on the current VM, `free -m`, `vmstat
# -s` and the sampler's log into <out>/<prefix>memory.log, and a summary line:
# total memory, peak used (total - free - buffers - cache over the samples) and
# peak swap used. Never fails the caller.
vm_mem_report() {
    local out=$1 p=$2 f
    f=$out/${p}memory.log
    sshv 'echo "== free -m"; free -m; echo "== swapon --show"; swapon --show; echo "== vmstat -S M -s"; vmstat -S M -s; echo "== vmstat -n -S M 5 (sampler)"; cat /var/tmp/tp-vmstat.log 2>/dev/null' >"$f" 2>&1 || {
        vm_warn "WARNING: no memory report from $VM_DEST"; return 0; }
    echo "=== memory on the VM ($VM_MEMORY_GIB GiB, $VM_SWAP_GIB GiB swap file) ==="
    sed -n '/^== free -m/,/^== swapon/p' "$f" | sed '1d;$d'
    awk '/^== free -m/ { s = "free" } /^== vmstat -n/ { s = "vm"; next }
         s == "free" && $1 == "Mem:" { total = $2 }
         s == "vm" && $1 ~ /^[0-9]+$/ && NF >= 6 {
             n++; used = total - $4 - $5 - $6; if (used > pu) pu = used; if ($3 > ps) ps = $3 }
         END { printf "memory: total %d MiB; peak used %d MiB, peak swap used %d MiB (%d vmstat samples, 5 s apart)\n", total, pu, ps, n }' "$f"
    return 0
}

# vm_oom_check <out dir> <log prefix> : the kernel log of the current VM into
# <out>/<prefix>kernel.log; when it has an `Out of memory` or `oom-kill` line,
# print those lines, the process the kernel killed and VM_STEP, and return 1.
# The caller then stops the gate, keeps the evidence and deletes the VM; the
# memory is never raised.
vm_oom_check() {
    local out=$1 p=$2 f
    f=$out/${p}kernel.log
    sshv 'sudo -n journalctl -k --no-pager -o short-monotonic 2>/dev/null || sudo -n dmesg' >"$f" 2>&1 || return 0
    grep -Eq 'Out of memory|oom-kill|oom_reaper' "$f" || return 0
    echo "=== MEMORY FAILURE on $VM_DEST at $VM_MEMORY_GIB GiB: the gate stops (memory is not raised) ==="
    echo "step running: ${VM_STEP:-unknown}"
    echo "kernel:"
    grep -E 'Out of memory|oom-kill|oom_reaper' "$f" | sed 's/^/  /'
    echo "killed: $(grep -oE 'Killed process [0-9]+ \([^)]*\)' "$f" | sort -u | tr '\n' ' ')"
    echo "evidence: $f (and the memory report beside it)"
    return 1
}

# vm_end <out dir> <log prefix> <rc> : at the end of a run on the current VM,
# before it is deleted: the memory report, and on a failure (rc != 0) the
# memory-failure check. Returns 3 when the failure was a memory failure,
# else <rc>.
vm_end() {
    local out=$1 p=$2 rc=$3
    [[ -n ${VM_DEST:-} ]] || return "$rc"
    vm_mem_report "$out" "$p"
    if [[ $rc -ne 0 ]] && ! vm_oom_check "$out" "$p"; then return 3; fi
    return "$rc"
}

# sshv <remote command> : ssh to the current VM as bot with VM_SSH_OPTS (the key,
# accept-new into the run's known_hosts, and on a remote host ProxyJump).
sshv() { ssh -T "${VM_SSH_OPTS[@]}" "$VM_DEST" "$@"; }

# vm_tunnel_argv <sock> : sets VM_TUNNEL_ARGV, the ssh that forwards the current
# VM's docker socket to <sock>. Built on VM_SSH_OPTS, so its key and ProxyJump
# are sshv's.
vm_tunnel_argv() {
    VM_TUNNEL_ARGV=(ssh "${VM_SSH_OPTS[@]}" -o ExitOnForwardFailure=yes -o ServerAliveInterval=30
        -o StreamLocalBindUnlink=yes -N -L "$1:/var/run/docker.sock" "$VM_DEST")
}

# vm_state <image-state.sh> [--versions] : scripts/image-state.sh on the current
# VM as root; the capture on stdout.
vm_state() {
    local script=$1; shift
    sshv "sudo -n sh -s -- $*" <"$script"
}

# vm_delete <name> : delete <name> if listed, then check it is gone: `vmtool list`
# on the host no longer has it and, on a remote host, ~/$TP_VM_HOST_DIR/.machines/
# <name> is gone (a `test -e`; nothing is read). Returns 1 (with a warning) when it
# is not. When the VM host cannot be reached (ssh exit 255) it returns 1 and
# prints the exact command to delete by hand. A name that is not tp-[a-z0-9-]+
# dies (exit 2) before any vmtool call.
vm_delete() {
    local name=$1 rows rc=0 n
    vm_require_name "$name"
    unreachable() { vm_warn "WARNING: $TP_VM_HOST cannot be reached; delete $name by hand: $(vm_delete_cmd "$name")"; }
    rows=$(vmtool list) || rc=$?
    if [[ $rc -eq 255 ]] && ! vm_is_local; then unreachable; return 1; fi
    n=$(awk -v n="$name" 'NR > 1 && $1 == n { c++ } END { print c + 0 }' <<<"$rows")
    if [[ $n -gt 0 ]]; then
        echo "=== deleting VM $name$(vm_where) ==="
        rc=0; vmtool delete "$name" || rc=$?
        if [[ $rc -eq 255 ]] && ! vm_is_local; then unreachable; return 1; fi
        [[ $rc -eq 0 ]] || vm_warn "WARNING: vmtool delete $name failed"
    fi
    rc=0; rows=$(vmtool list) || rc=$?
    if [[ $rc -eq 255 ]] && ! vm_is_local; then unreachable; return 1; fi
    n=$(awk -v n="$name" 'NR > 1 && $1 == n { c++ } END { print c + 0 }' <<<"$rows")
    if [[ $n -gt 0 ]]; then
        vm_warn "WARNING: VM $name is still listed by 'vmtool list'$(vm_where) after the delete"
        return 1
    fi
    if vm_is_local; then echo "VM $name deleted (not in 'vmtool list')"; return 0; fi
    rc=0; vm_rs "test -e \"\$HOME/$TP_VM_HOST_DIR/.machines/$name\"" </dev/null || rc=$?
    case $rc in
        1) ;;
        255) unreachable; return 1 ;;
        *) vm_warn "WARNING: ~/$TP_VM_HOST_DIR/.machines/$name still exists on $TP_VM_HOST after the delete"; return 1 ;;
    esac
    echo "VM $name deleted (not in 'vmtool list' on $TP_VM_HOST, no .machines/$name)"
}

# vm_cleanup <keep> : for every recorded name, print the delete command when
# <keep> is 1; else delete it (if still listed) and check it is gone. Always
# removes the run's scratch dir (the run key) last. Returns 1 when a VM remains.
vm_cleanup() {
    local keep=$1 n rc=0
    for n in "${VM_RECORDED[@]}"; do
        if [[ $keep -eq 1 ]]; then
            if vm_is_local; then echo "--keep: VM $n left running (delete with: $(vm_delete_cmd "$n"))"
            else echo "--keep: VM $n left running on $TP_VM_HOST (delete with: $(vm_delete_cmd "$n"))"; fi
        else
            vm_delete "$n" || rc=1
        fi
    done
    vm_scratch_rm
    return $rc
}
