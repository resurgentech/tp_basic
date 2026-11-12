#!/usr/bin/env bash
# Runs a command against the docker daemon of a fresh, disposable tp-* VM, so
# no container runs and no image is built or pulled on this machine's daemon.
# The command itself (a just recipe, a bash script, `cargo test --test live`)
# and the docker/buildx clients stay here; only the daemon is the VM's.
#
#   scripts/docker-vm.sh run [--disk N] [--keep] -- <command...>
#   scripts/docker-vm.sh --self-test        (argument checks; no VM, no docker)
#
#   1. vm_up a VM named tp-docker-<UTC stamp> (ubuntu2404.qcow2, 1 GiB, disk
#      N GB, default 60) with scripts/lib/vm.sh.
#   2. Over sshv: apt-get install docker.io docker-buildx, add bot to the
#      docker group, write /etc/docker/daemon.json with the label
#      tp-docker-vm=<name>, restart docker.
#   3. Forward the VM's /var/run/docker.sock to <scratch>/docker.sock with
#      `ssh -i <vmtool's key, in place> -o IdentitiesOnly=yes -N -L`.
#   4. Run the command with DOCKER_HOST=unix://<scratch>/docker.sock,
#      TP_DOCKER_VM=<name>, TP_DOCKER_VM_IP=<ip> and BUILDX_BUILDER=default
#      (DOCKER_CONTEXT unset), which every docker recipe's guard
#      (scripts/lib/docker-guard.sh) checks against the daemon's label.
#   5. Whatever the command's status (and on INT/TERM): kill the tunnel,
#      delete the VM and check `vmtool list` no longer shows it, unless --keep.
#
# Exit: the command's status; 2 on a usage or setup error; 1 when the VM is
# still listed after the delete. Image pulls in the VM are anonymous (no
# registry login is copied in). The key is never copied or printed.
#
# Outputs (gitignored): build/docker-vm/<name>/{create,onboard,wait,prep,
# docker-install,docker-config,tunnel}.log, known_hosts
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
die() { echo "docker-vm: $*" >&2; exit 2; }
VM_TAG=docker-vm
# shellcheck source=lib/vm.sh
source "$ROOT/scripts/lib/vm.sh"

usage="usage: docker-vm.sh run [--disk N] [--keep] -- <command...> | --self-test"

# parse_args <args...> : sets DV_DISK, DV_KEEP and DV_CMD; returns 2 with a
# message on a usage error. No side effects (the self-test calls it).
parse_args() {
    DV_DISK=60 DV_KEEP=0 DV_CMD=()
    [[ ${1:-} == run ]] || { echo "$usage" >&2; return 2; }
    shift
    while [[ $# -gt 0 ]]; do
        case $1 in
            --disk)
                [[ ${2:-} =~ ^[1-9][0-9]*$ ]] || { echo "--disk needs a size in GB, not '${2:-}'" >&2; return 2; }
                DV_DISK=$2; shift 2 ;;
            --keep) DV_KEEP=1; shift ;;
            --) shift; break ;;
            *) echo "unknown argument '$1' ($usage)" >&2; return 2 ;;
        esac
    done
    [[ $# -gt 0 ]] || { echo "no command after -- ($usage)" >&2; return 2; }
    DV_CMD=("$@")
}

self_test() {
    local fails=0 rc
    t() { # name want-rc args...
        local name=$1 want=$2; shift 2
        rc=0; (parse_args "$@") >/dev/null 2>&1 || rc=$?
        if [[ $rc -eq $want ]]; then echo "ok   $name (exit $rc)"; else echo "FAIL $name: exit $rc, wanted $want"; fails=1; fi
    }
    t "no arguments" 2
    t "not run" 2 start -- true
    t "no --" 2 run true
    t "nothing after --" 2 run --keep --
    t "bad --disk" 2 run --disk x -- true
    t "zero --disk" 2 run --disk 0 -- true
    t "unknown flag" 2 run --memory 4 -- true
    t "plain" 0 run -- just test-live-os
    t "--disk and --keep" 0 run --disk 80 --keep -- just test-services ubuntu2404
    parse_args run --disk 80 --keep -- just test-services ubuntu2404
    if [[ $DV_DISK == 80 && $DV_KEEP == 1 && ${DV_CMD[*]} == "just test-services ubuntu2404" ]]; then
        echo "ok   parsed values"; else echo "FAIL parsed values: disk=$DV_DISK keep=$DV_KEEP cmd=${DV_CMD[*]}"; fails=1; fi
    parse_args run -- true
    [[ $DV_DISK == 60 && $DV_KEEP == 0 ]] && echo "ok   defaults (60 GB, delete)" || { echo "FAIL defaults: disk=$DV_DISK keep=$DV_KEEP"; fails=1; }
    # nothing in this script may ask for more than 1 GiB
    local calls ones
    calls=$(grep -c '^ *vm_up ' "${BASH_SOURCE[0]}")
    ones=$(grep -c '^vm_up "$name" "$out" "" 1 "$DV_DISK"$' "${BASH_SOURCE[0]}")
    if [[ $calls -eq 1 && $ones -eq 1 ]]; then echo "ok   the one vm_up asks for 1 GiB"; else echo "FAIL vm_up calls: $calls, at 1 GiB: $ones"; fails=1; fi
    return $fails
}

if [[ ${1:-} == --self-test ]]; then self_test; exit $?; fi
parse_args "$@" || exit 2

command -v docker >/dev/null || die "no docker client on this machine"
command -v ssh >/dev/null || die "no ssh client on this machine"

name=tp-docker-$(date -u +%Y%m%d-%H%M%S)
out=$ROOT/build/docker-vm/$name
mkdir -p "$out"
# a short path for the socket (sun_path holds 108 bytes)
scratch=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/tp-docker-vm.XXXXXX")
sock=$scratch/docker.sock
tunnel_pid=

cleanup() {
    local rc=$? crc=0
    trap - EXIT INT TERM
    if [[ -n $tunnel_pid ]]; then kill "$tunnel_pid" 2>/dev/null || true; wait "$tunnel_pid" 2>/dev/null || true; fi
    rm -f "$sock"; rmdir "$scratch" 2>/dev/null || true
    # the memory report always; on a failure the OOM check (3: memory failure)
    vm_end "$out" "" "$rc" || rc=$?
    vm_cleanup "$DV_KEEP" || crc=1
    if [[ $crc -ne 0 ]]; then
        echo "docker-vm: FAIL: $name is still listed by 'vmtool list'" >&2
        [[ $rc -ne 0 ]] || rc=1
    elif [[ $DV_KEEP -eq 0 ]]; then
        if vmtool list | awk 'NR > 1 && $1 ~ /^tp-/ { f = 1 } END { exit !f }'; then
            echo "docker-vm: note: other tp-* VMs are listed (not made by this run, not touched):" >&2
            vmtool list | awk 'NR > 1 && $1 ~ /^tp-/' >&2
        else
            echo "docker-vm: vmtool list shows no tp-* VM"
        fi
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

vm_record "$name"
vm_up "$name" "$out" "" 1 "$DV_DISK"

echo "=== docker in the VM: docker.io and docker-buildx from apt ==="
VM_STEP="installing docker.io and docker-buildx"
sshv 'sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y -q docker.io docker-buildx' >"$out/docker-install.log" 2>&1 \
    || { tail -20 "$out/docker-install.log"; die "installing docker in $name failed (log: $out/docker-install.log)"; }
# the label is what docker-guard.sh looks for; bot reaches the socket through
# the docker group (the tunnel logs in after this, so it has the group)
sshv "sudo -n usermod -aG docker bot && printf '{\"labels\": [\"tp-docker-vm=%s\"]}\n' '$name' | sudo -n tee /etc/docker/daemon.json >/dev/null && sudo -n systemctl restart docker && sudo -n docker info --format '{{json .Labels}} {{.ServerVersion}}'" \
    >"$out/docker-config.log" 2>&1 || { cat "$out/docker-config.log"; die "configuring docker in $name failed (log: $out/docker-config.log)"; }
echo "VM daemon: $(tail -1 "$out/docker-config.log")"

echo "=== forwarding $name:/var/run/docker.sock to $sock ==="
ssh -i "$VM_KEY" -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 \
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$VM_KNOWN_HOSTS" \
    -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o StreamLocalBindUnlink=yes \
    -N -L "$sock:/var/run/docker.sock" "$VM_DEST" >"$out/tunnel.log" 2>&1 &
tunnel_pid=$!

export DOCKER_HOST=unix://$sock TP_DOCKER_VM=$name TP_DOCKER_VM_IP=$VM_IP BUILDX_BUILDER=default
unset DOCKER_CONTEXT
deadline=$((SECONDS + 60))
until [[ -S $sock ]] && docker info --format '{{json .Labels}}' 2>/dev/null | grep -qF "\"tp-docker-vm=$name\""; do
    kill -0 "$tunnel_pid" 2>/dev/null || { cat "$out/tunnel.log"; die "the ssh tunnel to $name exited (log: $out/tunnel.log)"; }
    [[ $SECONDS -lt $deadline ]] || die "the VM's daemon did not answer on $sock within 60s"
    sleep 1
done
echo "DOCKER_HOST=$DOCKER_HOST TP_DOCKER_VM=$TP_DOCKER_VM TP_DOCKER_VM_IP=$TP_DOCKER_VM_IP"
# where builds go: the default builder must be the VM's daemon behind the socket
docker buildx inspect default 2>&1 | grep -E '^(Name|Driver|Endpoint|Status|BuildKit version):|^ *(Endpoint|Status|BuildKit version):' | sed 's/^/buildx: /' || true
bash "$ROOT/scripts/lib/docker-guard.sh" || die "the guard refused the VM's own daemon"
echo "guard: ok"

echo "=== running: ${DV_CMD[*]} ==="
VM_STEP="the command: ${DV_CMD[*]} (its last lines are above)"
rc=0; "${DV_CMD[@]}" || rc=$?
echo "=== command exited $rc ==="
exit "$rc"
