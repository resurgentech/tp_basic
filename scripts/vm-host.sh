#!/usr/bin/env bash
# Checks that the VM host is ready for the tp-* VMs: the workstation's vmtool
# (VMTOOL_DIR, scripts/lib/vm.sh) lists veritech04 as reachable. Read only.
# Nothing here creates, touches or names a VM, and nothing is installed or
# kept on veritech04: the VMs are made through vmtool's daemon there.
#
#   scripts/vm-host.sh check        `./vmtool hosts` must show veritech04 with
#                                   REACHABLE yes; one ok / FAIL line
#   scripts/vm-host.sh --self-test  a stub vmtool; no daemon, no host
#
# Exit: 0 ok; 2 on a FAIL or a usage error.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
die() { echo "vm-host: $*" >&2; exit 2; }
VM_TAG=vm-host
# shellcheck source=lib/vm.sh
source "$HERE/lib/vm.sh"

# cmd_check : the row of `vmtool hosts` named $VM_HOST, its REACHABLE column
# (found by its header, so a column added before it does not matter) must be yes.
cmd_check() {
    [[ -x $VMTOOL_DIR/vmtool ]] || die "FAIL  $VMTOOL_DIR/vmtool not found"
    local rows rc=0 got
    rows=$(vmtool hosts 2>&1) || rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "FAIL  vmtool hosts exited $rc"; sed 's/^/      | /' <<<"$rows" | head -5; return 2
    fi
    got=$(awk -v h="$VM_HOST" '
        NR == 1 { for (i = 1; i <= NF; i++) if ($i == "REACHABLE") c = i; next }
        $1 == h && c { print $c; exit }' <<<"$rows")
    if [[ $got == yes ]]; then echo "ok    $VM_HOST reachable (vmtool hosts)"; return 0; fi
    echo "FAIL  $VM_HOST is not reachable through vmtool (REACHABLE: ${got:-no such row})"
    sed 's/^/      | /' <<<"$rows" | head -6
    return 2
}

self_test() {
    local d fails=0 rc out
    d=$(mktemp -d); mkdir -p "$d/vt"
    # a stub vmtool: `hosts` prints $STUB_HOSTS, every call is logged
    printf '#!/usr/bin/env bash\necho "$*" >>"$STUB_LOG"\n[[ $1 == hosts ]] && { cat "$STUB_HOSTS"; exit "${STUB_RC:-0}"; }\nexit 0\n' >"$d/vt/vmtool"
    chmod +x "$d/vt/vmtool"
    t() { # name rc-wanted grep-pattern
        local name=$1 want=$2 pat=$3
        : >"$d/log"; rc=0
        out=$(STUB_LOG=$d/log STUB_HOSTS=$d/hosts VMTOOL_DIR=$d/vt bash "${BASH_SOURCE[0]}" check 2>&1) || rc=$?
        if [[ $rc -eq $want && $(cat "$d/log") == hosts ]] && grep -q "$pat" <<<"$out"; then echo "ok   $name"
        else echo "FAIL $name: exit $rc, vmtool calls '$(tr '\n' ';' <"$d/log")'"; sed 's/^/     | /' <<<"$out"; fails=1; fi
    }
    local H='NAME        ADDRESS                 REACHABLE  API    CERT_DAYS  ERROR'
    printf '%s\n' "$H" 'jetfire     local                   yes        1.0.0  824        -' 'veritech04  veritech04.labtwo:9473  yes        1.0.0  824        -' >"$d/hosts"
    t "veritech04 reachable: ok, only 'vmtool hosts' ran" 0 '^ok .*veritech04 reachable'
    printf '%s\n' "$H" 'jetfire     local                   yes        1.0.0  824        -' 'veritech04  veritech04.labtwo:9473  no         -      -          dial tcp: i/o timeout' >"$d/hosts"
    t "veritech04 not reachable: FAIL, exit 2" 2 '^FAIL .*not reachable'
    printf '%s\n' "$H" 'jetfire     local                   yes        1.0.0  824        -' >"$d/hosts"
    t "no veritech04 row (another host reachable): FAIL, exit 2" 2 'no such row'
    printf '%s\n' "$H" 'veritech04x  h:1  yes  1.0.0  824  -' >"$d/hosts"
    t "a similar name does not count: FAIL, exit 2" 2 'no such row'
    printf '%s\n' "$H" 'veritech04  veritech04.labtwo:9473  yes        1.0.0  824        -' >"$d/hosts"
    rc=0; out=$(STUB_RC=1 STUB_LOG=$d/log STUB_HOSTS=$d/hosts VMTOOL_DIR=$d/vt bash "${BASH_SOURCE[0]}" check 2>&1) || rc=$?
    if [[ $rc -eq 2 ]] && grep -q '^FAIL  vmtool hosts exited 1' <<<"$out"; then echo "ok   vmtool hosts failing: FAIL, exit 2"; else echo "FAIL vmtool hosts failing: exit $rc"; echo "$out"; fails=1; fi
    rc=0; out=$(STUB_LOG=$d/log STUB_HOSTS=$d/hosts VMTOOL_DIR=$d/none bash "${BASH_SOURCE[0]}" check 2>&1) || rc=$?
    if [[ $rc -eq 2 ]] && grep -q 'not found' <<<"$out"; then echo "ok   no vmtool at VMTOOL_DIR: exit 2"; else echo "FAIL missing vmtool: exit $rc"; echo "$out"; fails=1; fi
    rc=0; out=$(bash "${BASH_SOURCE[0]}" setup 2>&1) || rc=$?
    if [[ $rc -eq 2 ]] && grep -q 'usage' <<<"$out"; then echo "ok   setup is gone (usage error, exit 2)"; else echo "FAIL setup: exit $rc"; fails=1; fi
    rm -rf "$d"
    return $fails
}

if [[ ${1:-} == --self-test ]]; then self_test; exit $?; fi
case ${1:-} in
    check) cmd_check ;;
    *) die "usage: vm-host.sh check | --self-test" ;;
esac
