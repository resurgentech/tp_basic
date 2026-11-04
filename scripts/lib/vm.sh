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
# The SSH key is used in place from vmtool's .machines/<name>/ directory and
# never copied or printed.

VMTOOL_DIR=${VMTOOL_DIR:-$HOME/repos/jaredeh/vmtool}
VM_RECORDED=()

vm_warn() { echo "${VM_TAG:-vm}: $*" >&2; }

# vmtool <args>... : vmtool's CLI, run from its own directory.
vmtool() { (cd "$VMTOOL_DIR" && ./vmtool "$@"); }
# vm_ip <name> : the IP column of the list row whose NAME is exactly <name>.
vm_ip() { vmtool list | awk -v n="$1" 'NR > 1 && $1 == n { print $NF }'; }
# vm_listed <name> : true when `vmtool list` has a row whose NAME is exactly <name>.
vm_listed() { vmtool list | awk -v n="$1" 'NR > 1 && $1 == n { f = 1 } END { exit !f }'; }
# vm_key <name> : the path of the key vmtool's setup_bot.yml wrote for bot.
vm_key() { echo "$VMTOOL_DIR/.machines/$1/id_ed25519"; }

# vm_record <name> : remember <name> as created by this run, before creating it.
vm_record() { VM_RECORDED+=("$1"); }

# vm_up <name> <out dir> <log prefix> [<memory GiB>] [<disk GB>] : create the VM
# (ubuntu2404.qcow2; memory default 4 GiB, disk default the image's own size),
# wait for tcp/22, onboard bot with setup_bot.yml, wait for cloud-init and a free
# dpkg lock, and run `apt-get update --fix-missing`. Logs go to
# <out>/<prefix>{create,onboard,wait,prep}.log. Sets VM_IP, VM_KEY, VM_DEST and
# VM_KNOWN_HOSTS (<out>/known_hosts) for sshv. The name must be recorded first.
vm_up() {
    local name=$1 out=$2 p=$3 mem=${4:-4} disk=${5:-} crc=0 deadline ready
    local size=(--memory "$mem")
    [[ -z $disk ]] || size+=(--disk-size "$disk")
    echo "=== creating VM $name (ubuntu2404.qcow2, $mem GiB${disk:+, $disk GB disk}) ==="
    vmtool create "$name" ubuntu2404.qcow2 "${size[@]}" >"$out/${p}create.log" 2>&1 || crc=$?
    if grep -q 'timed out waiting for IP' "$out/${p}create.log"; then
        tail -5 "$out/${p}create.log"
        vm_warn "the VM got no IP. This is a host environment problem, not a telepatch failure:"
        vm_warn "see $VMTOOL_DIR/README.md, \"Troubleshooting\" > \"A new VM never gets an IP\"."
        exit 2
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
    until timeout 5 bash -c "exec 3<>/dev/tcp/$VM_IP/22" 2>/dev/null; do
        [[ $SECONDS -lt $deadline ]] || die "sshd on $name ($VM_IP) did not answer within 5 min"
        sleep 3
    done
    vmtool playbook "$name" setup_bot.yml >"$out/${p}onboard.log" 2>&1 \
        || { grep -E 'fatal|ERROR|RECAP' "$out/${p}onboard.log" | tail -5; die "vmtool playbook $name setup_bot.yml failed (log: $out/${p}onboard.log)"; }
    VM_KEY=$(vm_key "$name")
    [[ -f $VM_KEY ]] || die "no key at $VM_KEY"
    VM_DEST=bot@$VM_IP
    VM_KNOWN_HOSTS=$out/known_hosts
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

    # The cloud image ships package lists from its build date, whose archive
    # files are gone (observed: 404 on the first install). The oracle's
    # Dockerfile runs `apt-get update --fix-missing` before tp-basic; this is the
    # same environment step, done before the "before" capture so it is not
    # counted as something the run added.
    echo "=== apt-get update on the VM (as the oracle's Dockerfile does) ==="
    sshv 'sudo -n apt-get -q update --fix-missing' >"$out/${p}prep.log" 2>&1 \
        || { tail -10 "$out/${p}prep.log"; die "apt-get update on the VM failed (log: $out/${p}prep.log)"; }
}

# sshv <remote command> : ssh to the current VM as bot, key in place, accept-new
# into the run's known_hosts.
sshv() {
    ssh -T -i "$VM_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$VM_KNOWN_HOSTS" "$VM_DEST" "$@"
}

# vm_state <image-state.sh> [--versions] : scripts/image-state.sh on the current
# VM as root; the capture on stdout.
vm_state() {
    local script=$1; shift
    sshv "sudo -n sh -s -- $*" <"$script"
}

# vm_delete <name> : delete <name> if listed, then check it is gone. Returns 1
# (with a warning) when `vmtool list` still shows it.
vm_delete() {
    local name=$1
    if vm_listed "$name"; then
        echo "=== deleting VM $name ==="
        vmtool delete "$name" || vm_warn "WARNING: vmtool delete $name failed"
    fi
    if vm_listed "$name"; then
        vm_warn "WARNING: VM $name is still listed by 'vmtool list' after the delete"
        return 1
    fi
    echo "VM $name deleted (not in 'vmtool list')"
}

# vm_cleanup <keep> : for every recorded name, print the delete command when
# <keep> is 1; else delete it (if still listed) and check it is gone. Returns 1
# when one remains.
vm_cleanup() {
    local keep=$1 n rc=0
    for n in "${VM_RECORDED[@]}"; do
        if [[ $keep -eq 1 ]]; then
            echo "--keep: VM $n left running (delete with: cd $VMTOOL_DIR && ./vmtool delete $n)"
        else
            vm_delete "$n" || rc=1
        fi
    done
    return $rc
}
