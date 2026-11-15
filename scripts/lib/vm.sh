# VM lifecycle helpers for the scripts that run against a fresh VM made with
# the workstation's ~/repos/jaredeh/vmtool (scripts/test-vm.sh,
# scripts/test-vm-oracle.sh, scripts/docker-vm.sh). Sourced, not run. No
# comparison logic lives here.
#
# The caller defines die() (message, exit 2) and may set VM_TAG (the prefix of
# the lib's own warnings, default "vm"). Every function takes the VM name, the
# output directory and the log prefix (the start of its log file names, "" for
# create.log, "ansible-" for ansible-create.log) as arguments; nothing is
# matched by pattern, and only names passed to vm_record are ever deleted.
#
# One driver: every VM operation is `./vmtool <cmd> veritech04/tp-<name>`, run
# from VMTOOL_DIR so vmtool's config.yml and token are used in place. Nothing is
# installed, built or kept on veritech04 by us, and there is no ssh to it and no
# virsh. vmtool's .env, token, tls/ and .machines/ content is never read,
# printed or copied; the bot key under .machines/veritech04/<vm>/ is used in
# place, by path, and never opened here.
#
# The guest is reached through vmtool's tunnel, not ProxyJump: the ssh option
# ProxyCommand is `sh -c 'cd <vmtool dir> && exec ./vmtool tunnel veritech04/<vm>'`
# (the form `./vmtool ssh-config` prints), the destination is bot@<vm> (an
# alias: with a ProxyCommand the name is never resolved) and known_hosts is
# keyed by it. The tunnel follows the daemon across a reboot.
#
# vm_up makes one VM in this order, and a failed check deletes the VM and stops:
#   1. create (ubuntu2404.qcow2, 1 GiB, no --playbook)
#   2. pre-commission check as packer: the guest's hostname is not vt-*, its
#      uptime is less than the seconds since step 1 began, and the IP
#      `vmtool list` shows for it is on no other row
#   3. `vmtool playbook ... commission.yml` (own hostname, machine-id, host
#      keys; reboots)
#   4. post-commission check: the hostname is the VM's name and the IP is on no
#      other row
#   5. `vmtool playbook ... setup_bot.yml`
# Worst case without the checks: commission.yml (new hostname, machine-id, host
# keys, a reboot) runs on another session's VM through a shared DHCP address.

VMTOOL_DIR=${VMTOOL_DIR:-$HOME/repos/jaredeh/vmtool}
# The hypervisor the tp-* VMs live on, as vmtool's config.yml names it.
VM_HOST=veritech04
VM_RECORDED=()
# The ssh options for the guest: the ONE definition, used by sshv and by the
# docker socket forward (vm_tunnel_argv). Set by vm_set_ssh_opts.
VM_SSH_OPTS=()
# The ProxyCommand's value (also put into the oracle's Ansible inventory and
# tp-basic's --ssh-option). Set by vm_set_ssh_opts.
VM_PROXY_COMMAND=
# Every tp-* VM gets 1 GiB ("no reason to have them use more than 1GB of RAM
# each"); vm_up refuses any other size. Swap is a file enabled with swapon only.
VM_MEMORY_GIB=1
VM_SWAP_GIB=4
# The image's own disk (GB): a default-size VM gets this plus the swap file,
# so the swap does not eat the free space a playbook had before.
VM_IMAGE_DISK_GB=10
# What the current script is doing, for the memory-failure report.
VM_STEP=
# The wait for the guest's sshd (steps 2 and 4): retry the check call every
# VM_RETRY_SLEEP seconds for VM_RETRY_SECS seconds (environment overrides, for
# the self-test).
VM_RETRY_SLEEP=${VM_RETRY_SLEEP:-3}
VM_RETRY_SECS=${VM_RETRY_SECS:-300}

vm_warn() { echo "${VM_TAG:-vm}: $*" >&2; }

# vmtool <args>... : vmtool's CLI, from VMTOOL_DIR, stdin /dev/null.
vmtool() { (cd "$VMTOOL_DIR" && ./vmtool "$@") </dev/null; }
# vm_epoch : the clock of the uptime check (whole seconds; the self-test replaces it).
vm_epoch() { date +%s; }
# vm_ref <name> : vmtool's host/vm form.
vm_ref() { echo "$VM_HOST/$1"; }
# vm_list : `vmtool list veritech04` (header, then one row per VM; NAME is host/vm,
# MEMORY holds a space, so the IP is the last field and may be `-`).
vm_list() { vmtool list "$VM_HOST"; }
# vm_listed <name> : true when the list has a row whose NAME is exactly host/<name>;
# a list that cannot be read dies (the caller's die()).
vm_listed() {
    local rows
    rows=$(vm_list) || die "vmtool list $VM_HOST failed; cannot tell whether $1 exists"
    awk -v n="$(vm_ref "$1")" 'NR > 1 && $1 == n { f = 1 } END { exit !f }' <<<"$rows"
}
# vm_tp_rows : the list rows of every tp-* VM on the host (for the end-of-gate
# report; reading only).
vm_tp_rows() {
    local rows
    rows=$(vm_list) || return 1
    awk -v p="$VM_HOST/tp-" 'NR > 1 && index($1, p) == 1' <<<"$rows"
}
# vm_ip_check <name> : one `vmtool list`; sets VM_CHK_IP (the IP of <name>'s row,
# empty when none) and VM_CHK_OTHERS (the NAMEs of the other rows with that IP,
# space-separated). Returns 1 when the list cannot be read.
vm_ip_check() {
    local rows ref
    ref=$(vm_ref "$1")
    rows=$(vm_list) || return 1
    VM_CHK_IP=$(awk -v n="$ref" 'NR > 1 && $1 == n { print $NF; exit }' <<<"$rows")
    VM_CHK_OTHERS=
    [[ $VM_CHK_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0
    VM_CHK_OTHERS=$(awk -v n="$ref" -v ip="$VM_CHK_IP" 'NR > 1 && $1 != n && $NF == ip { printf "%s%s", s, $1; s = " " }' <<<"$rows")
}
# vm_key <name> : the path of the key vmtool's setup_bot.yml wrote for bot (used
# in place; the file is never opened here).
vm_key() { echo "$VMTOOL_DIR/.machines/$VM_HOST/$1/id_ed25519"; }
# vm_name_ok <name> : true for tp- followed by lowercase letters, digits and -.
vm_name_ok() { [[ $1 =~ ^tp-[a-z0-9-]+$ ]]; }
# vm_require_name <name> : any other name dies (the caller's die(): message,
# exit 2) before any vmtool call. No vt-* or default VM is ever named.
vm_require_name() { vm_name_ok "$1" || die "refusing VM name '$1': only tp-[a-z0-9-]+ names are used (vt-* and every other VM are not ours)"; }
# vm_delete_cmd <name> : the command that deletes <name> by hand.
vm_delete_cmd() { echo "cd $VMTOOL_DIR && ./vmtool delete $(vm_ref "$1")"; }
# vm_proxy_command <name> : the ProxyCommand value for <name>. The directory is
# written without quotes, so it may hold only letters, digits and . _ / - (the
# text is then one safe word to ssh's shell, to the YAML of the Ansible
# inventory and to shlex alike).
vm_proxy_command() {
    [[ $VMTOOL_DIR =~ ^/[A-Za-z0-9._/-]*$ ]] || die "VMTOOL_DIR '$VMTOOL_DIR': an absolute path of letters, digits and . _ / - only (it is written unquoted into the ProxyCommand)"
    vm_require_name "$1"
    echo "sh -c 'cd $VMTOOL_DIR && exec ./vmtool tunnel $(vm_ref "$1")'"
}
# vm_set_ssh_opts <name> : (re)build VM_PROXY_COMMAND and VM_SSH_OPTS from VM_KEY
# and VM_KNOWN_HOSTS.
vm_set_ssh_opts() {
    VM_PROXY_COMMAND=$(vm_proxy_command "$1") || exit 2
    VM_SSH_OPTS=(-i "$VM_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10
        -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$VM_KNOWN_HOSTS"
        -o "ProxyCommand=$VM_PROXY_COMMAND")
}

# vm_record <name> : remember <name> as created by this run, before creating it.
# A name that is not tp-[a-z0-9-]+ dies (exit 2), so nothing else is ever deleted.
vm_record() { vm_require_name "$1"; VM_RECORDED+=("$1"); }

# vm_probe <name> <file> : ONE ssh call as packer through vmtool's tunnel
# (`vmtool cmd` falls back to packer until setup_bot.yml has run): the guest's
# /proc/uptime and kernel hostname, with no shell on the guest. Writes
# "<uptime seconds> <hostname>" to <file> and returns 0 when the output has that
# shape; 1 on any failure to connect or answer.
vm_probe() {
    local out
    out=$(vmtool cmd "$(vm_ref "$1")" cat /proc/uptime /proc/sys/kernel/hostname 2>"$2.err") || return 1
    awk 'NR == 1 && NF == 2 && $1 ~ /^[0-9]+(\.[0-9]+)?$/ { u = $1; next }
         u != "" && NF == 1 && !h { print u, $1; h = 1 }' <<<"$out" >"$2"
    [[ -s $2 ]]
}
# vm_probe_wait <name> <file> : vm_probe until it answers (only a connection
# failure is retried; what it answers is final), for VM_RETRY_SECS.
vm_probe_wait() {
    local deadline=$((SECONDS + VM_RETRY_SECS))
    until vm_probe "$1" "$2"; do
        [[ $SECONDS -lt $deadline ]] || return 1
        sleep "$VM_RETRY_SLEEP"
    done
}
# vm_check_fail <name> <which> <out dir> <log prefix> <reason>... : the FAIL
# line, the evidence, our VM deleted (even under --keep: a VM that failed its
# check is not for inspection through an address that may be someone else's),
# and exit 2.
vm_check_fail() {
    local name=$1 which=$2 out=$3 p=$4 r
    shift 4
    r=$(IFS=';'; echo "$*")
    echo "$which-commission check: FAIL (${r# })"
    { echo "# $which-commission check of $name"; echo "# reasons: $r"; echo "# list:"; vm_list 2>&1 || true; } >"$out/${p}$which-check.log"
    echo "evidence: $out/${p}$which-check.log; deleting $name, commission is not run on it"
    vm_delete "$name" || true
    die "$which-commission check failed for $name: ${r# }"
}

# vm_up <name> <out dir> <log prefix> [<memory GiB>] [<disk GB>] : create the VM
# (ubuntu2404.qcow2; memory 1 GiB, the only size allowed: any other value is a
# usage error; disk default the image's own size plus the swap file), check it,
# commission it, check it again, onboard bot with setup_bot.yml (the order and
# its why are in the header), wait for cloud-init and a free dpkg lock, run
# `apt-get update --fix-missing`, add a VM_SWAP_GIB swap file (/tp-swap,
# `swapon` only: no /etc/fstab line, so nothing a playbook or the state capture
# sees changes, and a reboot drops it) and start a vmstat sampler for
# vm_mem_report. Logs go to <out>/<prefix>{create,precheck,commission,postcheck,
# onboard,wait,prep,swap}.log. Sets VM_IP, VM_KEY, VM_DEST (bot@<name>),
# VM_KNOWN_HOSTS (<out>/known_hosts), VM_PROXY_COMMAND and VM_SSH_OPTS for
# sshv. The name must be recorded first.
vm_up() {
    local name=$1 out=$2 p=$3 mem=${4:-$VM_MEMORY_GIB} disk=${5:-} crc=0 deadline ready grow_late=0 t0 up host now elapsed
    [[ $mem == "$VM_MEMORY_GIB" ]] || die "vm_up: $mem GiB asked for $name; every tp-* VM gets $VM_MEMORY_GIB GiB (swap is allowed, more memory is not)"
    [[ -n $disk ]] || disk=$((VM_IMAGE_DISK_GB + VM_SWAP_GIB))
    vm_require_name "$name"
    local size=(--memory "$mem" --disk-size "$disk") ref
    ref=$(vm_ref "$name")
    VM_STEP="creating $name"
    echo "=== creating VM $ref (ubuntu2404.qcow2, $mem GiB${disk:+, $disk GB disk}) ==="
    t0=$(vm_epoch)
    vmtool create "$ref" ubuntu2404.qcow2 "${size[@]}" >"$out/${p}create.log" 2>&1 || crc=$?
    if grep -q 'timed out waiting for IP' "$out/${p}create.log"; then
        tail -5 "$out/${p}create.log"
        vm_warn "the VM got no IP. This is a host environment problem, not a telepatch failure:"
        vm_warn "see $VMTOOL_DIR/README.md, \"Troubleshooting\" > \"A new VM never gets an IP\"."
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

    # ---- step 2: pre-commission check, as packer, before anything runs on the guest ----
    echo "=== pre-commission check on $name (packer, through vmtool's tunnel) ==="
    VM_STEP="pre-commission check of $name"
    vm_probe_wait "$name" "$out/${p}precheck.probe" \
        || { tail -3 "$out/${p}precheck.probe.err" 2>/dev/null || true; vm_check_fail "$name" pre "$out" "$p" "no answer from $name through the tunnel within ${VM_RETRY_SECS}s"; }
    read -r up host <"$out/${p}precheck.probe"
    now=$(vm_epoch); elapsed=$((now - t0))
    vm_ip_check "$name" || vm_check_fail "$name" pre "$out" "$p" "vmtool list $VM_HOST failed"
    local why=()
    [[ $host != vt-* ]] || why+=("hostname $host is a vt-* name")
    awk -v u="$up" -v e="$elapsed" 'BEGIN { exit !(u < e) }' || why+=("uptime ${up}s is not less than the ${elapsed}s since create began")
    [[ -n $VM_CHK_IP && $VM_CHK_IP != - ]] || why+=("no IP in vmtool list for $ref")
    [[ -z $VM_CHK_OTHERS ]] || why+=("IP $VM_CHK_IP is also listed for: $VM_CHK_OTHERS")
    [[ ${#why[@]} -eq 0 ]] || vm_check_fail "$name" pre "$out" "$p" "${why[@]}"
    echo "pre-commission check: ok (hostname $host, uptime ${up}s < ${elapsed}s since create, IP $VM_CHK_IP on no other row)"

    # ---- step 3: commission: own hostname, machine-id and host keys, then a reboot ----
    echo "=== commissioning $name (commission.yml; it reboots the VM) ==="
    VM_STEP="commissioning $name"
    vmtool playbook "$ref" commission.yml >"$out/${p}commission.log" 2>&1 \
        || { grep -E 'fatal|ERROR|RECAP' "$out/${p}commission.log" | tail -5; die "vmtool playbook $ref commission.yml failed (log: $out/${p}commission.log)"; }

    # ---- step 4: post-commission check ----
    vm_probe_wait "$name" "$out/${p}postcheck.probe" \
        || { tail -3 "$out/${p}postcheck.probe.err" 2>/dev/null || true; vm_check_fail "$name" post "$out" "$p" "no answer from $name through the tunnel within ${VM_RETRY_SECS}s after commission"; }
    read -r up host <"$out/${p}postcheck.probe"
    vm_ip_check "$name" || vm_check_fail "$name" post "$out" "$p" "vmtool list $VM_HOST failed"
    why=()
    [[ $host == "$name" ]] || why+=("hostname $host, wanted $name")
    [[ -n $VM_CHK_IP && $VM_CHK_IP != - ]] || why+=("no IP in vmtool list for $ref")
    [[ -z $VM_CHK_OTHERS ]] || why+=("IP $VM_CHK_IP is also listed for: $VM_CHK_OTHERS")
    [[ ${#why[@]} -eq 0 ]] || vm_check_fail "$name" post "$out" "$p" "${why[@]}"
    VM_IP=$VM_CHK_IP
    echo "post-commission check: ok (hostname $host, IP $VM_IP on no other row)"

    # ---- step 5: onboard bot: setup_bot.yml (user bot, key auth, passwordless sudo) ----
    echo "=== onboarding bot (setup_bot.yml) ==="
    VM_STEP="onboarding bot on $name"
    # setup_bot.yml's "Switch remaining tasks to bot key auth" set_fact replaces
    # ansible_ssh_common_args, dropping the ProxyCommand vmtool's inventory puts
    # there for a VM on another host; the next task then resolves
    # "veritech04/<vm>" as a hostname and fails (observed, T164 smoke run 1).
    # The ProxyCommand is passed again as ansible_ssh_extra_args, an extra var
    # (beats set_fact), which ssh reads after the common args: before the
    # switch the inventory's identical value wins, after it this is the only
    # one. vmtool's own form: its binary, with the token in the environment
    # vmtool gives ansible.
    vmtool playbook "$ref" setup_bot.yml --extra-var "ansible_ssh_extra_args='-o ProxyCommand=\"$VMTOOL_DIR/vmtool tunnel $ref\"'" \
        >"$out/${p}onboard.log" 2>&1 \
        || { grep -E 'fatal|ERROR|RECAP' "$out/${p}onboard.log" | tail -5; die "vmtool playbook $ref setup_bot.yml failed (log: $out/${p}onboard.log)"; }
    VM_DEST=bot@$name
    VM_KNOWN_HOSTS=$out/known_hosts
    VM_KEY=$(vm_key "$name")
    [[ -f $VM_KEY ]] || die "no key at $VM_KEY"
    vm_set_ssh_opts "$name"
    deadline=$((SECONDS + 60))
    until sshv true >>"$out/${p}onboard.log" 2>&1; do
        [[ $SECONDS -lt $deadline ]] || { tail -5 "$out/${p}onboard.log"; die "the bot key was not accepted by $VM_DEST through vmtool's tunnel (log: $out/${p}onboard.log)"; }
        sleep "$VM_RETRY_SLEEP"
    done
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

# sshv <remote command> : ssh to the current VM as bot with VM_SSH_OPTS (the key
# in place, accept-new into the run's known_hosts, and vmtool's tunnel as the
# ProxyCommand).
sshv() { ssh -T "${VM_SSH_OPTS[@]}" "$VM_DEST" "$@"; }

# vm_tunnel_argv <sock> [port...] : sets VM_TUNNEL_ARGV, the ssh that forwards the
# current VM's docker socket to <sock>. Built on VM_SSH_OPTS, so its key and
# ProxyCommand are sshv's. Each <port> adds `-L 127.0.0.1:P:127.0.0.1:P` (after the
# socket forward): a TCP port a container publishes on the guest's loopback is
# reachable here on 127.0.0.1 with the same number. With only <sock> the argv is
# the socket forward alone.
vm_tunnel_argv() {
    local sock=$1 p fwd=()
    shift
    for p in "$@"; do fwd+=(-L "127.0.0.1:$p:127.0.0.1:$p"); done
    VM_TUNNEL_ARGV=(ssh "${VM_SSH_OPTS[@]}" -o ExitOnForwardFailure=yes -o ServerAliveInterval=30
        -o StreamLocalBindUnlink=yes -N -L "$sock:/var/run/docker.sock" "${fwd[@]}" "$VM_DEST")
}

# vm_state <image-state.sh> [--versions] : scripts/image-state.sh on the current
# VM as root; the capture on stdout.
vm_state() {
    local script=$1; shift
    sshv "sudo -n sh -s -- $*" <"$script"
}

# vm_delete <name> : delete <name> if listed (`vmtool delete veritech04/<name>`),
# then check it is gone: `vmtool list veritech04` no longer has it. Returns 1
# (with a warning, and the exact command to delete by hand) when the list cannot
# be read or the VM is still listed. A name that is not tp-[a-z0-9-]+ dies
# (exit 2) before any vmtool call.
vm_delete() {
    local name=$1 rows rc=0 ref
    vm_require_name "$name"
    ref=$(vm_ref "$name")
    unreadable() { vm_warn "WARNING: 'vmtool list $VM_HOST' failed; delete $name by hand: $(vm_delete_cmd "$name")"; }
    rows=$(vm_list) || rc=$?
    if [[ $rc -ne 0 ]]; then unreadable; return 1; fi
    if awk -v n="$ref" 'NR > 1 && $1 == n { f = 1 } END { exit !f }' <<<"$rows"; then
        echo "=== deleting VM $ref ==="
        rc=0; vmtool delete "$ref" || rc=$?
        [[ $rc -eq 0 ]] || vm_warn "WARNING: vmtool delete $ref failed (exit $rc)"
    fi
    rc=0; rows=$(vm_list) || rc=$?
    if [[ $rc -ne 0 ]]; then unreadable; return 1; fi
    if awk -v n="$ref" 'NR > 1 && $1 == n { f = 1 } END { exit !f }' <<<"$rows"; then
        vm_warn "WARNING: VM $ref is still listed by 'vmtool list $VM_HOST' after the delete; delete it by hand: $(vm_delete_cmd "$name")"
        return 1
    fi
    echo "VM $name deleted (not in 'vmtool list $VM_HOST')"
}

# vm_cleanup <keep> : for every recorded name, print the delete command when
# <keep> is 1; else delete it (if still listed) and check it is gone. Returns 1
# when a VM remains.
vm_cleanup() {
    local keep=$1 n rc=0
    for n in "${VM_RECORDED[@]}"; do
        if [[ $keep -eq 1 ]]; then
            echo "--keep: VM $n left running (delete with: $(vm_delete_cmd "$n"))"
        else
            vm_delete "$n" || rc=1
        fi
    done
    return $rc
}
