#!/usr/bin/env bash
# The fail-closed guard of every docker workload (containers, image builds,
# pulls) in tp_basic and telepatch: they run only against the
# daemon of a disposable tp-* VM that scripts/docker-vm.sh made, never against
# this machine's daemon.
#
#   source scripts/lib/docker-guard.sh; docker_guard    (exits 2 when refused)
#   bash scripts/lib/docker-guard.sh                    (the same, as a command:
#                                                        the first line of every
#                                                        docker recipe)
#   bash scripts/lib/docker-guard.sh --self-test        (no daemon is touched:
#                                                        a stub `docker` first on PATH)
#
# Passes only when TP_DOCKER_VM is set to a tp-* name, BUILDX_BUILDER is unset
# or `default` (a named builder may sit on another daemon), and the labels of
# the daemon DOCKER_HOST reaches (`docker info --format '{{json .Labels}}'`)
# contain `tp-docker-vm=$TP_DOCKER_VM`, which docker-vm.sh writes into the VM's
# /etc/docker/daemon.json. This machine's daemon has no such label. With
# TP_DOCKER_VM unset, nothing docker is run at all.

DOCKER_GUARD_MSG='docker workloads run only in a tp-* VM: use `just docker-vm <recipe>`'

docker_guard() {
    local labels
    if [[ -z ${TP_DOCKER_VM:-} ]]; then
        echo "$DOCKER_GUARD_MSG (TP_DOCKER_VM is not set)" >&2
        exit 2
    fi
    if [[ $TP_DOCKER_VM != tp-* ]]; then
        echo "$DOCKER_GUARD_MSG (TP_DOCKER_VM=$TP_DOCKER_VM is not a tp-* name)" >&2
        exit 2
    fi
    if [[ ${BUILDX_BUILDER:-default} != default ]]; then
        echo "$DOCKER_GUARD_MSG (BUILDX_BUILDER=$BUILDX_BUILDER; only the default builder of the VM's daemon is allowed)" >&2
        exit 2
    fi
    if ! labels=$(docker info --format '{{json .Labels}}' 2>/dev/null); then
        echo "$DOCKER_GUARD_MSG (docker info failed for DOCKER_HOST=${DOCKER_HOST:-unset})" >&2
        exit 2
    fi
    if [[ $labels != *"\"tp-docker-vm=$TP_DOCKER_VM\""* ]]; then
        echo "$DOCKER_GUARD_MSG (the daemon at DOCKER_HOST=${DOCKER_HOST:-unset} has no label tp-docker-vm=$TP_DOCKER_VM; labels: $labels)" >&2
        exit 2
    fi
}

# ---- self-test ------------------------------------------------------------------

# A stub `docker` that logs every call to $DOCKER_STUB_LOG and answers
# `docker info --format ...` with $DOCKER_STUB_LABELS (exit 1 when unset); any
# other call exits 99. It shadows the real client, so no check here can reach
# a daemon even when a guard is missing.
guard_stub() {
    local dir=$1
    mkdir -p "$dir"
    cat >"$dir/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >>"${DOCKER_STUB_LOG:?}"
if [[ ${1:-} == info && -n ${DOCKER_STUB_LABELS:-} ]]; then echo "$DOCKER_STUB_LABELS"; exit 0; fi
exit 99
EOF
    chmod +x "$dir/docker"
}

guard_self_test() {
    local here root t fails=0 rc
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    root=$(cd "$here/../.." && pwd)
    t=$(mktemp -d)
    guard_stub "$t/bin"
    export DOCKER_STUB_LOG=$t/calls
    # every check runs with the stub first on PATH and no inherited docker env
    gt() { # name want-rc want-calls(0|1) env... -- command...
        local name=$1 want=$2 calls=$3 rc=0 e=()
        shift 3
        while [[ $1 != -- ]]; do e+=("$1"); shift; done
        shift
        : >"$DOCKER_STUB_LOG"
        env -u TP_DOCKER_VM -u TP_DOCKER_VM_IP -u DOCKER_HOST -u DOCKER_CONTEXT -u BUILDX_BUILDER \
            PATH="$t/bin:$PATH" "${e[@]}" "$@" >"$t/out" 2>&1 || rc=$?
        local n
        n=$(wc -l <"$DOCKER_STUB_LOG")
        if [[ $rc -ne $want ]]; then
            echo "FAIL $name: exit $rc, wanted $want"; sed 's/^/     | /' "$t/out" | tail -5; fails=1
        elif [[ $want -eq 2 ]] && ! grep -qF "$DOCKER_GUARD_MSG" "$t/out"; then
            echo "FAIL $name: exit 2 without the guard's message"; sed 's/^/     | /' "$t/out" | tail -5; fails=1
        elif [[ $calls -eq 0 && $n -ne 0 ]]; then
            echo "FAIL $name: docker was called before the refusal:"; sed 's/^/     | /' "$DOCKER_STUB_LOG"; fails=1
        elif [[ $calls -eq 1 && $n -eq 0 ]]; then
            echo "FAIL $name: docker info was never asked"; fails=1
        else
            echo "ok   $name (exit $rc, docker calls: $n)"
        fi
    }
    local g=(bash "$here/docker-guard.sh")
    local lab='["tp-docker-vm=tp-docker-x"]'
    # the function
    gt "guard: TP_DOCKER_VM unset" 2 0 -- "${g[@]}"
    gt "guard: not a tp-* name" 2 0 TP_DOCKER_VM=docker-x -- "${g[@]}"
    gt "guard: a named buildx builder" 2 0 TP_DOCKER_VM=tp-docker-x BUILDX_BUILDER=other -- "${g[@]}"
    gt "guard: docker info fails" 2 1 TP_DOCKER_VM=tp-docker-x -- "${g[@]}"
    gt "guard: daemon without the label (this machine's: [])" 2 1 TP_DOCKER_VM=tp-docker-x DOCKER_STUB_LABELS='[]' -- "${g[@]}"
    gt "guard: another VM's label" 2 1 TP_DOCKER_VM=tp-docker-x DOCKER_STUB_LABELS='["tp-docker-vm=tp-docker-xy"]' -- "${g[@]}"
    gt "guard: the VM's label" 0 1 TP_DOCKER_VM=tp-docker-x DOCKER_STUB_LABELS="$lab" -- "${g[@]}"
    gt "guard: the VM's label, BUILDX_BUILDER=default" 0 1 TP_DOCKER_VM=tp-docker-x BUILDX_BUILDER=default DOCKER_STUB_LABELS="$lab" -- "${g[@]}"

    # every docker recipe and script in tp_basic and telepatch, run outside
    # docker-vm: exit 2 with the message and no docker call at all.
    # ../docker_images is not guarded and not run here: its recipes are the
    # user's release tooling, not tests (T70a's guard there was reverted).
    local tpb=$root tel=$root/../telepatch r
    for r in "test-idempotent ubuntu2404 dev_base" "test-services ubuntu2404"; do
        # shellcheck disable=SC2086
        gt "tp_basic: just $r" 2 0 -- just --justfile "$tpb/justfile" --working-directory "$tpb" $r
    done
    for r in "test-idempotent.sh ubuntu2404 dev_base" "test-services.sh ubuntu2404"; do
        # shellcheck disable=SC2086
        gt "tp_basic: scripts/$r" 2 0 DI_SHA=HEAD -- bash $tpb/scripts/$r
    done
    for r in os-fixtures test-live-os test-live-pkg test-live-mise test-live-ssh test-live-user test-live-repo test-live-svc test-live-unit test-live-fetch; do
        gt "telepatch: just $r" 2 0 -- just --justfile "$tel/justfile" --working-directory "$tel" "$r"
    done
    rm -rf "$t"
    return $fails
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    if [[ ${1:-} == --self-test ]]; then guard_self_test; exit $?; fi
    docker_guard
fi
