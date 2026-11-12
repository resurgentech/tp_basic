#!/usr/bin/env bash
# The manual edge matrix (T97f): the edge cell (scripts/test-edge.sh cell) on
# every tests/plans.rs distro, one after another, in ONE tp-* VM. Not a goal
# gate: Jared starts it (`just test-edge-matrix`). The goal gate stays `just
# test-edge`, ubuntu2404 only.
#
#   scripts/test-edge-matrix.sh run        on this machine: refuses when a tp-*
#       VM is already listed by `vmtool list` on the VM host (TP_VM_HOST, through
#       scripts/lib/vm.sh's wrapper; vt-* and other rows are ignored and never
#       printed) or when run inside a docker-vm VM (TP_DOCKER_VM set). Then
#       `just musl` (build/tp-basic) and one `scripts/docker-vm.sh run` whose
#       command is this script's `cells`.
#   scripts/test-edge-matrix.sh cells      inside that VM only (the docker guard
#       first): for each distro in tests/plans.rs order, `test-edge.sh cell
#       <distro>` with its own 10/30 minute clock. omarchy has no stock image:
#       it prints `SKIP omarchy`, is not baked from ../docker_images and fails
#       nothing. A failed cell does not stop the next one. Summary: one PASS,
#       FAIL or SKIP line per distro; exit 1 when any cell failed.
#   scripts/test-edge-matrix.sh distros    the matrix's distros, one per line.
#   scripts/test-edge-matrix.sh --self-test  stubs only: no daemon, no VM.
#
# Outputs (gitignored): build/test-edge/<distro>/ per cell (test-edge.sh),
# build/test-edge-matrix/<distro>.log.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
die() { echo "test-edge-matrix: $*" >&2; exit 2; }
VM_TAG=test-edge-matrix
# shellcheck source=lib/vm.sh
source "$ROOT/scripts/lib/vm.sh"
# shellcheck source=lib/docker-guard.sh
source "$ROOT/scripts/lib/docker-guard.sh"

# matrix_distros : tests/plans.rs DISTROS, in order (the plan snapshots' list).
matrix_distros() {
    local d
    d=$(sed -n '/^const DISTROS/,/^];/p' "$ROOT/tests/plans.rs" | grep -oE '"[a-z0-9]+"' | tr -d '"')
    [[ -n $d ]] || die "no DISTROS in tests/plans.rs"
    printf '%s\n' "$d"
}

# matrix_no_tp_vm : status 0 when the VM host lists no tp-* VM. Only tp-* names
# are printed; a list that did not run is a refusal, never "none".
matrix_no_tp_vm() {
    local rows rc=0 tp
    rows=$(vmtool list) || rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "test-edge-matrix: vmtool list$(vm_where) failed (exit $rc); not booting a VM" >&2
        return 1
    fi
    tp=$(awk 'NR > 1 && $1 ~ /^tp-/ { print $1 }' <<<"$rows")
    if [[ -n $tp ]]; then
        echo "test-edge-matrix: refusing: a tp-* VM is already listed$(vm_where) (one VM at a time):" >&2
        printf '  %s\n' $tp >&2
        return 1
    fi
}

matrix_build() { (cd "$ROOT" && just musl); }
matrix_boot() {
    bash "$ROOT/scripts/docker-vm.sh" run -- bash "$ROOT/scripts/test-edge-matrix.sh" cells
}

matrix_run() {
    [[ -z ${TP_DOCKER_VM:-} ]] || die "refusing: TP_DOCKER_VM=$TP_DOCKER_VM is set, so this is already inside a docker-vm VM; the matrix boots its own, one VM at a time"
    matrix_no_tp_vm || exit 2
    echo "=== no tp-* VM$(vm_where); building build/tp-basic ==="
    matrix_build
    matrix_boot
}

# matrix_cell <distro> : one edge cell, its output kept per distro.
matrix_cell() {
    local logs=$ROOT/build/test-edge-matrix
    mkdir -p "$logs"
    bash "$ROOT/scripts/test-edge.sh" cell "$1" 2>&1 | tee "$logs/$1.log"
    return "${PIPESTATUS[0]}"
}

matrix_cells() {
    docker_guard
    local d rc failed=0 lines=() t0
    for d in $(matrix_distros); do
        if ! bash "$ROOT/scripts/test-edge.sh" image "$d" >/dev/null 2>&1; then
            echo "SKIP $d"
            lines+=("SKIP $d (no stock image)")
            continue
        fi
        echo "=== edge cell: $d ==="
        t0=$SECONDS rc=0
        matrix_cell "$d" || rc=$?
        if [[ $rc -eq 0 ]]; then lines+=("PASS $d ($((SECONDS - t0))s)")
        else lines+=("FAIL $d (exit $rc, $((SECONDS - t0))s)"); failed=1; fi
    done
    echo "=== edge matrix ==="
    printf '%s\n' "${lines[@]}"
    return $failed
}

# ---- self-test ------------------------------------------------------------------

matrix_self_test() {
    set +e +o pipefail   # every check counts its own failure
    local self=$ROOT/scripts/test-edge-matrix.sh t fails=0 rc d want got
    t=$(mktemp -d)
    ok() { echo "ok   $*"; }
    bad() { echo "FAIL $*"; fails=1; }

    # the map: tests/plans.rs DISTROS, in order, to the stock images
    local -A images=([debian12]=debian:12 [debian13]=debian:13 [ubuntu2404]=ubuntu:24.04
        [ubuntu2604]=ubuntu:26.04 [fedora43]=fedora:43 [fedora44]=fedora:44 [rockylinux9]=rockylinux:9
        [rockylinux10]=rockylinux/rockylinux:10 [almalinux9]=almalinux:9 [almalinux10]=almalinux:10
        [amazonlinux2023]=amazonlinux:2023 [arch]=archlinux:latest)
    local plans
    plans=$(sed -n '/^const DISTROS/,/^];/p' "$ROOT/tests/plans.rs" | grep -oE '"[a-z0-9]+"' | tr -d '"' | tr '\n' ' ')
    got=$(bash "$self" distros 2>&1 | tr '\n' ' ') || got=
    [[ -n $plans && $got == "$plans" ]] && ok "map: the matrix is tests/plans.rs DISTROS in order ($(wc -w <<<"$plans"))" \
        || bad "map: matrix '$got', plans.rs '$plans'"
    for d in $plans; do
        if [[ $d == omarchy ]]; then
            rc=0; got=$(bash "$ROOT/scripts/test-edge.sh" image omarchy 2>/dev/null) || rc=$?
            [[ $rc -ne 0 && -z $got ]] && ok "map: omarchy has no stock image" || bad "map: omarchy -> '$got'"
            continue
        fi
        want=${images[$d]:-}
        got=$(bash "$ROOT/scripts/test-edge.sh" image "$d" 2>/dev/null) || got=
        [[ -n $want && $got == "$want" ]] && ok "map: $d -> $got" || bad "map: $d -> '$got', wanted '${want:-unlisted}'"
    done

    # cells: guard first; omarchy prints SKIP and fails nothing; a failing cell
    # does not stop the others; the summary names it and the exit is 1
    local log=$t/cells.log
    rc=0
    (
        source "$self"
        docker_guard() { echo guard >>"$log"; }
        matrix_cell() { echo "cell $1" >>"$log"; [[ $1 != fedora43 ]]; }
        matrix_cells
    ) >"$t/cells.out" 2>&1 || rc=$?
    [[ $(head -1 "$log") == guard ]] && ok "cells: the docker guard runs first" || bad "cells: guard not first"
    grep -qx 'SKIP omarchy' "$t/cells.out" && ok "cells: prints 'SKIP omarchy'" || bad "cells: no 'SKIP omarchy'"
    grep -q 'cell omarchy' "$log" && bad "cells: omarchy was run" || ok "cells: omarchy is not run (nothing baked)"
    got=$(grep '^cell ' "$log" | cut -d' ' -f2 | tr '\n' ' ')
    want=$(tr ' ' '\n' <<<"$plans" | grep -vx omarchy | grep . | tr '\n' ' ')
    [[ $got == "$want" ]] && ok "cells: one after another, in order, a failure does not stop the rest" || bad "cells: ran '$got', wanted '$want'"
    [[ $rc -eq 1 ]] && grep -qE '^FAIL +fedora43' "$t/cells.out" && grep -qE '^PASS +arch' "$t/cells.out" \
        && ok "cells: summary FAIL fedora43, PASS arch, exit 1" || { bad "cells: exit $rc / summary"; sed 's/^/     | /' "$t/cells.out" | tail -8; }
    rc=0
    ( source "$self"; docker_guard() { :; }; matrix_cell() { :; }; matrix_cells ) >"$t/cells.out" 2>&1 || rc=$?
    [[ $rc -eq 0 ]] && grep -q 'SKIP omarchy' "$t/cells.out" && ok "cells: all pass, omarchy skipped: exit 0" || bad "cells: all pass gave exit $rc"
    rc=0
    env -u TP_DOCKER_VM -u DOCKER_HOST PATH="$t/nodocker:$PATH" bash "$self" cells >"$t/o" 2>&1 || rc=$?
    [[ $rc -eq 2 ]] && grep -q 'docker workloads run only in a tp-\* VM' "$t/o" && ok "cells: outside docker-vm, the guard refuses (exit 2)" || bad "cells: outside docker-vm exit $rc"

    # run: one VM. A tp-* row in `vmtool list` on the VM host (vm.sh's wrapper,
    # stubbed) refuses before anything boots; vt-* rows never refuse and are
    # never named; running inside a docker-vm VM refuses too.
    mrun() { # name want-rc list-rows [env...]
        local name=$1 want=$2 r=0; STUB_ROWS=$3; shift 3
        : >"$t/boot.log"
        (
            for e in "$@"; do export "${e?}"; done
            source "$self"
            vmtool() { echo "vmtool $* [host $TP_VM_HOST]" >>"$t/boot.log"; [[ $STUB_ROWS == FAIL ]] && return 255
                printf 'NAME STATE IP\n%b' "$STUB_ROWS"; }
            matrix_build() { echo build >>"$t/boot.log"; }
            matrix_boot() { echo boot >>"$t/boot.log"; }
            matrix_run
        ) >"$t/run.out" 2>&1 || r=$?
        if [[ $r -eq $want ]]; then ok "$name (exit $r)"; else bad "$name: exit $r, wanted $want"; sed 's/^/     | /' "$t/run.out" | tail -6; fi
    }
    local vt='vt-r1 running 192.168.122.11\nvt-a1 running 192.168.122.17\n'
    mrun "run: no tp-* VM on the host: builds, boots one" 0 "$vt" TP_VM_HOST=h.test
    grep -qx 'vmtool list \[host h.test\]' "$t/boot.log" && ok "run: asked 'vmtool list' through the wrapper, on TP_VM_HOST" || bad "run: no wrapper list on h.test"
    [[ $(grep -cx boot "$t/boot.log") -eq 1 ]] && ok "run: exactly one boot" || bad "run: boots $(grep -cx boot "$t/boot.log")"
    grep -q 'vt-' "$t/run.out" && bad "run: a vt-* name was printed" || ok "run: vt-* rows neither refuse nor are named"
    mrun "run: a tp-* VM listed on the host refuses (one VM at a time)" 2 "${vt}tp-docker-20261112-000000 running 192.168.122.40\n" TP_VM_HOST=h.test
    grep -q 'tp-docker-20261112-000000' "$t/run.out" && ! grep -q 'vt-' "$t/run.out" && ok "run: the refusal names the tp-* VM only" || bad "run: refusal text"
    grep -qx boot "$t/boot.log" || grep -qx build "$t/boot.log" && bad "run: built or booted after the refusal" || ok "run: nothing built or booted after the refusal"
    mrun "run: a failing vmtool list refuses (never 'no tp-* VM' from a list that did not run)" 2 FAIL TP_VM_HOST=h.test
    grep -qx boot "$t/boot.log" && bad "run: booted after a failed list" || ok "run: no boot after a failed list"
    mrun "run: inside a docker-vm VM refuses (that would be a second VM)" 2 "" TP_VM_HOST=h.test TP_DOCKER_VM=tp-docker-x
    grep -q '^vmtool' "$t/boot.log" && bad "run: listed after the TP_DOCKER_VM refusal" || ok "run: refused before any vmtool call"
    # the boot is docker-vm.sh once, running this script's cells
    if grep -qE '^ *bash "\$ROOT/scripts/docker-vm.sh" run -- bash "\$ROOT/scripts/test-edge-matrix.sh" cells$' "$self" \
        && [[ $(grep -cE '^ *bash "\$ROOT/scripts/docker-vm.sh" run' "$self") -eq 1 ]]; then ok "run: one docker-vm.sh run, the cells inside it"
    else bad "run: matrix_boot is not one docker-vm.sh run of the cells"; fi
    rm -rf "$t"
    return $fails
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    case ${1:-} in
        --self-test) matrix_self_test; exit $? ;;
        run) matrix_run ;;
        cells) matrix_cells ;;
        distros) matrix_distros ;;
        *) die "usage: test-edge-matrix.sh run | cells | distros | --self-test" ;;
    esac
fi
