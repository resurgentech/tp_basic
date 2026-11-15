#!/usr/bin/env bash
# Runs a command against the docker daemon of a fresh, disposable tp-* VM, so
# no container runs and no image is built or pulled on this machine's daemon.
# The command itself (a just recipe, a bash script, `cargo test --test live`)
# and the docker/buildx clients stay here; only the daemon is the VM's.
#
#   scripts/docker-vm.sh run [--disk N] [--keep] -- <command...>
#   scripts/docker-vm.sh --self-test        (argument checks; no VM, no docker)
#
#   0. `scripts/vm-host.sh check` (`vmtool hosts` must show veritech04
#      reachable; every VM is made there through the workstation's vmtool, see
#      scripts/lib/vm.sh): when it fails the exit is 2 and no VM is created.
#   1. vm_up a VM named tp-docker-<UTC stamp> (ubuntu2404.qcow2, 1 GiB, disk
#      N GB, default 60) with scripts/lib/vm.sh: create, check, commission,
#      check, onboard bot.
#   2. Over sshv: apt-get install docker.io docker-buildx, add bot to the
#      docker group, write /etc/docker/daemon.json with the label
#      tp-docker-vm=<name>, restart docker.
#   3. Forward the VM's /var/run/docker.sock to <scratch>/docker.sock with
#      vm.sh's VM_SSH_OPTS (the bot key in place and vmtool's tunnel as the
#      ProxyCommand) and `-N -L` (plus the port forwards below).
#   4. Run the command with DOCKER_HOST=unix://<scratch>/docker.sock,
#      TP_DOCKER_VM=<name>, BUILDX_BUILDER=default (DOCKER_CONTEXT unset), which
#      every docker recipe's guard (scripts/lib/docker-guard.sh) checks against
#      the daemon's label, and the endpoint for a container's published port:
#        TP_DOCKER_VM_PUBLISH  the address in the VM a container publishes on
#        TP_DOCKER_VM_ADDR     the address this machine connects to
#        TP_DOCKER_VM_PORTS    first-last, default 42201-42208 (override: the
#                              same variable, 1024-65535); a port has the same
#                              number at both ends
#      Both addresses are 127.0.0.1 (the guest's 192.168.122.x is not routable
#      from here) and the tunnel of step 3 also carries
#      `-L 127.0.0.1:P:127.0.0.1:P` for each port; nothing listens on veritech04.
#      TP_DOCKER_VM_IP is unset.
#   5. Whatever the command's status (and on INT/TERM): kill the tunnel,
#      delete the VM and check `vmtool list veritech04` no longer shows
#      it, unless --keep. The socket's scratch dir is removed.
#
# Exit: the command's status; 2 on a usage or setup error; 1 when the VM is
# still listed after the delete. Image pulls in the VM are anonymous (no
# registry login is copied in). No key is copied or printed.
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

# no_tp_line : the end line of a deleted run; it names the VM host.
no_tp_line() { echo "docker-vm: vmtool list $VM_HOST shows no tp-* VM"; }
# parse_ports <first-last> : sets DV_PORT_FIRST and DV_PORT_LAST; returns 2 with a
# message unless it is two decimal ports in 1024-65535 with first <= last.
parse_ports() {
    local r=${1:-}
    if ! [[ $r =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
        echo "TP_DOCKER_VM_PORTS='$r' is not first-last (for example 42201-42208)" >&2; return 2
    fi
    DV_PORT_FIRST=$((10#${BASH_REMATCH[1]})) DV_PORT_LAST=$((10#${BASH_REMATCH[2]}))
    if (( DV_PORT_FIRST < 1024 || DV_PORT_LAST > 65535 || DV_PORT_FIRST > DV_PORT_LAST )); then
        echo "TP_DOCKER_VM_PORTS=$r: ports must be in 1024-65535 and first <= last" >&2; return 2
    fi
    DV_PORT_RANGE=$DV_PORT_FIRST-$DV_PORT_LAST
}

# export_endpoint : the contract the tests that reach a container's published port
# read. Needs parse_ports. Sets DV_FWD_PORTS, the ports the tunnel forwards.
#   TP_DOCKER_VM_PUBLISH  the address in the VM a container publishes on
#   TP_DOCKER_VM_ADDR     the address this machine connects to
#   TP_DOCKER_VM_PORTS    first-last; every port has the same number at both ends
# The guest's 192.168.122.x is not routable from here (this machine's own
# virbr0 is the same network), so both are 127.0.0.1 and the tunnel forwards
# each port. TP_DOCKER_VM_IP is unset.
export_endpoint() {
    DV_FWD_PORTS=()
    export TP_DOCKER_VM_PORTS=$DV_PORT_RANGE
    unset TP_DOCKER_VM_IP
    export TP_DOCKER_VM_PUBLISH=127.0.0.1 TP_DOCKER_VM_ADDR=127.0.0.1
    local p
    for ((p = DV_PORT_FIRST; p <= DV_PORT_LAST; p++)); do DV_FWD_PORTS+=("$p"); done
}

self_test() {
    local fails=0 rc got
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

    # the end line names the VM host
    got=$(no_tp_line)
    [[ $got == "docker-vm: vmtool list veritech04 shows no tp-* VM" ]] && echo "ok   end line names the host" || { echo "FAIL end line: '$got'"; fails=1; }
    # the endpoint contract: PUBLISH (in the VM), ADDR (here), PORTS, and the forwards
    ep() { # range : prints "PUBLISH ADDR PORTS IP", then the tunnel argv
        ( export TP_DOCKER_VM_IP=9.9.9.9
          VM_DEST=bot@tp-x VM_SSH_OPTS=(-i /k -o "ProxyCommand=sh -c 'cd /v && exec ./vmtool tunnel veritech04/tp-x'")
          parse_ports "$1" || exit 2
          export_endpoint
          vm_tunnel_argv /s.sock "${DV_FWD_PORTS[@]}"
          echo "$TP_DOCKER_VM_PUBLISH $TP_DOCKER_VM_ADDR $TP_DOCKER_VM_PORTS ${TP_DOCKER_VM_IP-unset}"
          echo "${VM_TUNNEL_ARGV[*]}" )
    }
    local today="ssh -i /k -o ProxyCommand=sh -c 'cd /v && exec ./vmtool tunnel veritech04/tp-x' -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o StreamLocalBindUnlink=yes -N -L /s.sock:/var/run/docker.sock bot@tp-x"
    local fw='' p
    for p in 42201 42202 42203 42204 42205 42206 42207 42208; do fw+=" -L 127.0.0.1:$p:127.0.0.1:$p"; done
    got=$(ep 42201-42208)
    [[ $(sed -n 1p <<<"$got") == "127.0.0.1 127.0.0.1 42201-42208 unset" ]] \
        && echo "ok   PUBLISH=ADDR=127.0.0.1, PORTS=42201-42208, TP_DOCKER_VM_IP unset" || { echo "FAIL endpoint: '$got'"; fails=1; }
    want=${today/ bot@/$fw bot@}
    [[ $(sed -n 2p <<<"$got") == "$want" ]] && echo "ok   one -L 127.0.0.1:P:127.0.0.1:P per port after the socket forward, over vmtool's ProxyCommand" || { echo "FAIL tunnel argv: '$(sed -n 2p <<<"$got")'"; fails=1; }
    got=$(ep 42210-42210 | sed -n 1p)
    [[ $got == "127.0.0.1 127.0.0.1 42210-42210 unset" ]] && echo "ok   an override range is exported as given" || { echo "FAIL override: '$got'"; fails=1; }
    local r
    for r in 1023-1030 42201-65536 42208-42201 42201 a-b 42201-42208-1 ""; do
        rc=0; (parse_ports "$r") >/dev/null 2>&1 || rc=$?
        [[ $rc -eq 2 ]] && echo "ok   range '$r' is a usage error (exit 2)" || { echo "FAIL range '$r': exit $rc"; fails=1; }
    done
    rc=0; (parse_ports 1024-65535) >/dev/null 2>&1 || rc=$?
    [[ $rc -eq 0 ]] && echo "ok   range 1024-65535 is accepted" || { echo "FAIL range 1024-65535: exit $rc"; fails=1; }
    # the socket forward is built by vm.sh on VM_SSH_OPTS; no ssh of its own here
    if grep -q 'vm_tunnel_argv "\$sock"' "${BASH_SOURCE[0]}" && ! grep -qE '^ssh -i|VM_KNOWN_'"HOSTS" "${BASH_SOURCE[0]}"; then echo "ok   the tunnel uses vm_tunnel_argv (VM_SSH_OPTS)"
    else echo "FAIL the tunnel does not use vm_tunnel_argv"; fails=1; fi
    # the port forwards exist only once export_endpoint has set DV_FWD_PORTS, so the
    # run calls it before it builds the tunnel argv (T97l's first live run had no -L)
    local ln_ep ln_tun
    ln_ep=$(grep -n '^export_endpoint$' "${BASH_SOURCE[0]}" | head -1 | cut -d: -f1)
    ln_tun=$(grep -n '^vm_tunnel_argv "\$sock" "\${DV_FWD_PORTS\[@\]}"$' "${BASH_SOURCE[0]}" | head -1 | cut -d: -f1)
    if [[ -n $ln_ep && -n $ln_tun && $ln_ep -lt $ln_tun ]]; then echo "ok   export_endpoint runs before the tunnel argv is built (the -L list is in it)"
    else echo "FAIL export_endpoint (line ${ln_ep:-none}) must run before vm_tunnel_argv (line ${ln_tun:-none})"; fails=1; fi
    # vm-host.sh check runs before any VM is named, created or recorded; when it fails the exit is 2
    local d before after
    d=$(mktemp -d); mkdir -p "$d/bin" "$d/vt"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$d/bin/docker"
    chmod +x "$d/bin/docker"
    # a vmtool whose `hosts` shows veritech04 unreachable; every call is logged
    printf '#!/usr/bin/env bash\necho "$*" >>"$STUB_LOG"\nif [[ $1 == hosts ]]; then\n  printf "NAME        ADDRESS                 REACHABLE  API    CERT_DAYS  ERROR\\nveritech04  veritech04.labtwo:9473  no         -      -          dial tcp: timeout\\n"\nfi\nexit 0\n' >"$d/vt/vmtool"
    chmod +x "$d/vt/vmtool"
    before=$(ls "$ROOT/build/docker-vm" 2>/dev/null | wc -l)
    rc=0; STUB_LOG=$d/log VMTOOL_DIR=$d/vt PATH="$d/bin:$PATH" bash "${BASH_SOURCE[0]}" run -- true >"$d/o" 2>&1 || rc=$?
    after=$(ls "$ROOT/build/docker-vm" 2>/dev/null | wc -l)
    if [[ $rc -eq 2 && $before -eq $after && $(cat "$d/log") == hosts ]] && grep -q 'vm-host.sh check failed' "$d/o"; then
        echo "ok   a failing vm-host.sh check (vmtool hosts: veritech04 not reachable): exit 2, only 'vmtool hosts' ran, no VM created, no output dir"
    else echo "FAIL failing vm-host check: exit $rc, dirs $before -> $after"; cat "$d/log"; sed 's/^/     | /' "$d/o" | tail -8; fails=1; fi
    # a bad port range is refused (exit 2) before vmtool is even asked
    : >"$d/log"
    rc=0; STUB_LOG=$d/log VMTOOL_DIR=$d/vt PATH="$d/bin:$PATH" TP_DOCKER_VM_PORTS=900-950 bash "${BASH_SOURCE[0]}" run -- true >"$d/o" 2>&1 || rc=$?
    if [[ $rc -eq 2 && ! -s $d/log ]] && grep -q 'TP_DOCKER_VM_PORTS' "$d/o"; then echo "ok   a bad TP_DOCKER_VM_PORTS: exit 2 before any vmtool call"
    else echo "FAIL bad TP_DOCKER_VM_PORTS: exit $rc"; sed 's/^/     | /' "$d/o" | tail -5; fails=1; fi
    rm -rf "$d"
    return $fails
}

if [[ ${1:-} == --self-test ]]; then self_test; exit $?; fi
parse_args "$@" || exit 2
# the forwarded port range: checked before the VM host is asked, a VM is named or made
parse_ports "${TP_DOCKER_VM_PORTS:-42201-42208}" || exit 2

command -v docker >/dev/null || die "no docker client on this machine"
command -v ssh >/dev/null || die "no ssh client on this machine"
# the VM host must be ready before anything is named, created or recorded
bash "$ROOT/scripts/vm-host.sh" check || die "vm-host.sh check failed: $VM_HOST is not reachable through vmtool; no VM was created"

name=tp-docker-$(date -u +%Y%m%d-%H%M%S)
out=$ROOT/build/docker-vm/$name
mkdir -p "$out"
# a short path for the socket (sun_path holds 108 bytes)
scratch=$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/tp-docker-vm.XXXXXX")
sock=$scratch/docker.sock
tunnel_pid=

cleanup() {
    local rc=$? crc=0 rows
    trap - EXIT INT TERM
    if [[ -n $tunnel_pid ]]; then kill "$tunnel_pid" 2>/dev/null || true; wait "$tunnel_pid" 2>/dev/null || true; fi
    rm -f "$sock"; rmdir "$scratch" 2>/dev/null || true
    # the memory report always; on a failure the OOM check (3: memory failure)
    vm_end "$out" "" "$rc" || rc=$?
    vm_cleanup "$DV_KEEP" || crc=1
    if [[ $crc -ne 0 ]]; then
        echo "docker-vm: FAIL: $name is still listed by 'vmtool list $VM_HOST'" >&2
        [[ $rc -ne 0 ]] || rc=1
    elif [[ $DV_KEEP -eq 0 ]]; then
        local lrc=0
        rows=$(vm_tp_rows) || lrc=$?
        if [[ $lrc -ne 0 ]]; then
            # never claim "no tp-* VM" from a list that did not run
            echo "docker-vm: FAIL: vmtool list $VM_HOST failed (exit $lrc); check by hand that $name is gone" >&2
            [[ $rc -ne 0 ]] || rc=1
        elif [[ -n $rows ]]; then
            echo "docker-vm: note: other tp-* VMs are listed on $VM_HOST (not made by this run, not touched):" >&2
            printf '%s\n' "$rows" >&2
        else
            no_tp_line
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
# the endpoint first: it sets DV_FWD_PORTS, the ports the tunnel forwards
export_endpoint
vm_tunnel_argv "$sock" "${DV_FWD_PORTS[@]}"
"${VM_TUNNEL_ARGV[@]}" >"$out/tunnel.log" 2>&1 &
tunnel_pid=$!

export DOCKER_HOST=unix://$sock TP_DOCKER_VM=$name BUILDX_BUILDER=default
unset DOCKER_CONTEXT
deadline=$((SECONDS + 60))
until [[ -S $sock ]] && docker info --format '{{json .Labels}}' 2>/dev/null | grep -qF "\"tp-docker-vm=$name\""; do
    kill -0 "$tunnel_pid" 2>/dev/null || { cat "$out/tunnel.log"; die "the ssh tunnel to $name exited (log: $out/tunnel.log)"; }
    [[ $SECONDS -lt $deadline ]] || die "the VM's daemon did not answer on $sock within 60s"
    sleep 1
done
echo "DOCKER_HOST=$DOCKER_HOST TP_DOCKER_VM=$TP_DOCKER_VM TP_DOCKER_VM_IP=${TP_DOCKER_VM_IP:-(not set: the guest is reached through the vmtool tunnel)}"
echo "TP_DOCKER_VM_PUBLISH=$TP_DOCKER_VM_PUBLISH TP_DOCKER_VM_ADDR=$TP_DOCKER_VM_ADDR TP_DOCKER_VM_PORTS=$TP_DOCKER_VM_PORTS"
echo "tunnel: ${VM_TUNNEL_ARGV[*]}"
# where builds go: the default builder must be the VM's daemon behind the socket
docker buildx inspect default 2>&1 | grep -E '^(Name|Driver|Endpoint|Status|BuildKit version):|^ *(Endpoint|Status|BuildKit version):' | sed 's/^/buildx: /' || true
bash "$ROOT/scripts/lib/docker-guard.sh" || die "the guard refused the VM's own daemon"
echo "guard: ok"

echo "=== running: ${DV_CMD[*]} ==="
VM_STEP="the command: ${DV_CMD[*]} (its last lines are above)"
rc=0; "${DV_CMD[@]}" || rc=$?
echo "=== command exited $rc ==="
exit "$rc"
