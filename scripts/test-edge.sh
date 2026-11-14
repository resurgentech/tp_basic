#!/usr/bin/env bash
# The edge gate (T97e): playbooks/edge (Ansible) against playbook `edge`
# (telepatch) in one cell. `just test-edge` (ubuntu2404 only) is the goal's
# live proof; the other distros' cells are the manual matrix (T97f,
# scripts/test-edge-matrix.sh).
#
#   scripts/test-edge.sh local <distro>   the local half, on this machine:
#       refuses any distro but ubuntu2404, then telepatch `cargo test
#       --workspace`, tp_basic `cargo test --test plans`, this script's
#       --self-test and `just musl` (build/tp-basic). No docker, no VM.
#   scripts/test-edge.sh cell <distro>    one cell, against the daemon of a
#       tp-* VM only (`just docker-vm test-edge-cell ubuntu2404`; the guard
#       runs before any docker command). <distro> is any tests/plans.rs
#       distro with a stock image (edge_image; omarchy has none):
#       1. The distro's stock image (`ubuntu:24.04` for ubuntu2404) pulled
#          inside the VM; two containers from that one image id, `sleep
#          infinity` as PID 1 (no systemd, nothing privileged).
#       2. The same bootstrap on both (edge_boot): python3 and the package
#          manager's python bindings, which Ansible needs on the target
#          (ubuntu: python3, python3-apt and python3-venv).
#       3. Ansible side: a throwaway venv under /opt/edge-ansible (ansible-core
#          2.22 needs python >= 3.13 and ubuntu 24.04 ships 3.12, so uv builds
#          the venv on a uv-managed 3.13 kept inside that directory), the pin
#          in playbooks/edge/requirements.txt plus the community.general
#          collection (EDGE_CG, below), `ansible-playbook --connection
#          local` once with the target's /usr/bin/python3, then /opt/edge-ansible
#          is removed before the capture.
#       4. Telepatch side: build/tp-basic copied in, `tp-basic run edge --local`
#          twice; the second run must exit 0 with CHANGED 0.
#       5. scripts/image-state.sh on both, `compare_captures` (lib/compare.sh)
#          with no intended-differences file; the marker's sha256 must equal
#          `printf 'edge\n' | sha256sum` and /usr/local/bin/edge-jq must be the
#          jq 1.7.1 binary, on both sides.
#       Budget 10 minutes (over it prints `budget: exceeded` and continues);
#       hard stop 30 minutes (the containers are killed, exit 1). The env
#       overrides TP_EDGE_BUDGET_SECS / TP_EDGE_STOP_SECS may only lower them.
#       On exit both containers are removed; docker-vm.sh deletes the VM.
#   scripts/test-edge.sh image <distro>   prints the distro's stock image (exit 2
#       for omarchy or an unknown name). No docker.
#   scripts/test-edge.sh --self-test      stub docker, no daemon, no VM.
#
# Exit: 0 pass, 1 fail (a diff, a changed second run, the hard stop), 2 a
# usage error or a refusal.
# Outputs (gitignored): build/test-edge/<distro>/{bootstrap-*,venv,ansible,
# run1,run2}.log, {ansible,telepatch}.{state,versions}, gating.diff
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/compare.sh
source "$ROOT/scripts/lib/compare.sh"
# shellcheck source=lib/docker-guard.sh
source "$ROOT/scripts/lib/docker-guard.sh"

EDGE_BUDGET=600
EDGE_STOP=1800
EDGE_MARKER=/usr/local/share/telepatch-edge.txt
EDGE_JQ=/usr/local/bin/edge-jq
# the jq-linux-amd64 line of jq 1.7.1's sha256sum.txt (src/roles/edge.rs)
EDGE_JQ_SHA256=5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5
EDGE_UV=0.13.7
EDGE_PY=3.13
# ansible.builtin.pacman (the playbook's Arch task) is a routing redirect to
# community.general.pacman, which ansible-core alone does not ship; modules are
# resolved when the play loads, so every cell needs it. Galaxy's newest on
# 2026-11-12 (requires_ansible >=2.19.0). Installed under /opt/edge-ansible,
# removed with it.
EDGE_CG=14.0.1
die() { echo "test-edge: $*" >&2; exit 2; }

# edge_image <distro> : the stock image of a tests/plans.rs DISTROS entry (T97f).
# omarchy has no stock image (it is not baked here either): no line, status 1.
# Rocky is the Rocky project's own repository: Docker's library `rockylinux`
# stops at 9 (no `rockylinux:10` tag), and its `rockylinux:9` is the 2024 build
# (T117: Rocky 9 moved to `rockylinux/rockylinux:9`, as ../docker_images builds).
edge_image() {
    case ${1:-} in
        debian12) echo debian:12 ;;
        debian13) echo debian:13 ;;
        ubuntu2404) echo ubuntu:24.04 ;;
        ubuntu2604) echo ubuntu:26.04 ;;
        fedora43) echo fedora:43 ;;
        fedora44) echo fedora:44 ;;
        rockylinux9) echo rockylinux/rockylinux:9 ;;
        rockylinux10) echo rockylinux/rockylinux:10 ;;
        almalinux9) echo almalinux:9 ;;
        almalinux10) echo almalinux:10 ;;
        amazonlinux2023) echo amazonlinux:2023 ;;
        arch) echo archlinux:latest ;;
        *) return 1 ;;
    esac
}

# edge_boot <distro> : what both containers get before either tool runs: the
# python3 Ansible needs on the target, its package manager's bindings (apt:
# python3-apt; dnf 4: python3-dnf; dnf 5 on Fedora: python3-libdnf5; pacman
# needs none) and venv support. The same command on both sides, so it is never
# a difference. Status 1 for a distro with no stock image.
edge_boot() {
    case ${1:-} in
        debian*|ubuntu*) echo 'apt-get -q update && DEBIAN_FRONTEND=noninteractive apt-get install -y -q python3 python3-apt python3-venv' ;;
        fedora*) echo 'dnf -y -q install python3 python3-libdnf5' ;;
        rockylinux*|almalinux*|amazonlinux*) echo 'dnf -y -q install python3 python3-dnf' ;;
        arch) echo 'pacman -Sy --noconfirm --needed python' ;;
        *) return 1 ;;
    esac
}
refuse_distro() { die "no stock image for '${1:-}' (the cell takes a tests/plans.rs distro but omarchy)"; }
refuse_local() { die "the edge gate is ubuntu2404 only, not '${1:-}' (the other distros: just test-edge-matrix)"; }

# edge_limits : sets budget and stop (seconds); the env may only lower them.
edge_limits() {
    budget=${TP_EDGE_BUDGET_SECS:-$EDGE_BUDGET}
    stop=${TP_EDGE_STOP_SECS:-$EDGE_STOP}
    [[ $budget =~ ^[1-9][0-9]*$ && $budget -le $EDGE_BUDGET ]] \
        || die "TP_EDGE_BUDGET_SECS='$budget': at most $EDGE_BUDGET (the budget is not widened)"
    [[ $stop =~ ^[1-9][0-9]*$ && $stop -le $EDGE_STOP ]] \
        || die "TP_EDGE_STOP_SECS='$stop': at most $EDGE_STOP (the hard stop is not widened)"
}

# check_marker <container> <side> : the marker's bytes are exactly `edge\n`.
check_marker() {
    local want got
    want=$(printf 'edge\n' | sha256sum | cut -d' ' -f1)
    got=$(docker exec "$1" sha256sum "$EDGE_MARKER" 2>/dev/null | cut -d' ' -f1) || got=
    if [[ $got == "$want" ]]; then
        echo "ok   $2: $EDGE_MARKER sha256 $got = printf 'edge\\n' | sha256sum"
        return 0
    fi
    echo "FAIL $2: $EDGE_MARKER sha256 '${got:-no file}', wanted $want (printf 'edge\\n' | sha256sum)"
    return 1
}

# check_jq <container> <side> : /usr/local/bin/edge-jq is executable and is
# the checksummed release.
check_jq() {
    local got
    got=$(docker exec "$1" sh -c "test -x '$EDGE_JQ' && sha256sum '$EDGE_JQ'" 2>/dev/null | cut -d' ' -f1) || got=
    if [[ $got == "$EDGE_JQ_SHA256" ]]; then
        echo "ok   $2: $EDGE_JQ executable, sha256 $got"
        return 0
    fi
    echo "FAIL $2: $EDGE_JQ '${got:-missing or not executable}', wanted sha256 $EDGE_JQ_SHA256"
    return 1
}

# edge_compare <dir> [<intended dir>] : compare_captures with no
# intended-differences file. The edge gate declares no difference, so an
# edge.txt in the intended dir is itself a failure.
edge_compare() {
    local idir=${2:-$ROOT/tests/oracle/intended}
    if [[ -e $idir/edge.txt ]]; then
        echo "GATING DIFF: the edge gate takes no intended-differences file, and $idir/edge.txt exists"
        return 1
    fi
    compare_captures "$1"
}

# changed_of <log> : the CHANGED cell of the run table's single host row.
changed_of() { awk '/^HOST  *STATUS/{getline; print $4; exit}' "$1"; }

local_half() {
    local distro=${1:-}
    [[ $distro == ubuntu2404 ]] || refuse_local "$distro"
    echo "=== local: telepatch cargo test --workspace ==="
    (cd "$ROOT/../telepatch" && cargo test --workspace)
    echo "=== local: tp_basic cargo test --test plans ==="
    (cd "$ROOT" && cargo test --test plans)
    echo "=== local: test-edge.sh --self-test ==="
    bash "$ROOT/scripts/test-edge.sh" --self-test
    echo "=== local: just musl ==="
    (cd "$ROOT" && just musl)
}

# watchdog <seconds> <command...> : runs the command after the delay unless
# killed first (TERM also kills its sleep, so no orphan holds stdout).
watchdog() {
    local secs=$1; shift
    (
        s=
        trap '[[ -n $s ]] && kill "$s" 2>/dev/null; exit 0' TERM
        sleep "$secs" & s=$!
        wait "$s"
        "$@"
    ) &
}

cell() {
    local distro=${1:-} image boot bin id rc fails=0 c side
    docker_guard
    image=$(edge_image "$distro") || refuse_distro "$distro"
    boot=$(edge_boot "$distro") || refuse_distro "$distro"
    edge_limits
    bin=${TP_EDGE_BIN:-$ROOT/build/tp-basic}
    [[ -x $bin ]] || die "no $bin: the local half builds it (just musl)"
    out=${TP_EDGE_OUT:-$ROOT/build/test-edge/$distro}
    mkdir -p "$out"
    rm -f "$out"/*
    CA=tp-edge-ansible-$$ CT=tp-edge-telepatch-$$
    # globals, not locals: cell_cleanup (the EXIT trap) reads them
    main=$BASHPID start=$SECONDS wd_budget= wd_stop=

    cell_cleanup() {
        local rc=$?
        trap - EXIT TERM INT
        [[ -z $wd_budget ]] || kill "$wd_budget" 2>/dev/null || true
        [[ -z $wd_stop ]] || kill "$wd_stop" 2>/dev/null || true
        wait 2>/dev/null || true
        docker rm -f "$CA" "$CT" >/dev/null 2>&1 || true
        echo "containers removed: $CA $CT"
        if [[ -e $out/stopped ]]; then
            echo "FAIL: the cell hit the ${stop}s hard stop"
            rc=1
        fi
        echo "cell: $((SECONDS - start))s, exit $rc"
        exit "$rc"
    }
    trap cell_cleanup EXIT
    trap 'exit 1' TERM
    trap 'exit 130' INT
    watchdog "$budget" echo "budget: exceeded (${budget}s); the cell continues to the ${stop}s stop"
    wd_budget=$!
    watchdog "$stop" sh -c 'echo "FAIL: hard stop at $1s: killing the cell containers" >&2; : >"$2/stopped"; docker rm -f "$3" "$4" >/dev/null 2>&1; kill -TERM "$5"' \
        _ "$stop" "$out" "$CA" "$CT" "$main"
    wd_stop=$!

    echo "=== $image, pulled in the VM ==="
    docker pull -q "$image" >"$out/pull.log" 2>&1 || { cat "$out/pull.log"; die "pull $image failed"; }
    id=$(docker image inspect -f '{{.Id}}' "$image")
    echo "image: $image = $id"
    for c in "$CA" "$CT"; do
        docker create --name "$c" "$id" sleep infinity >/dev/null
        docker start "$c" >/dev/null
        [[ $(docker exec "$c" cat /proc/1/comm) == sleep ]] || { echo "FAIL: PID 1 of $c is not sleep"; exit 1; }
    done
    echo "containers: $CA, $CT (PID 1: sleep)"

    echo "=== bootstrap, the same on both: $boot ==="
    for side in ansible telepatch; do
        c=$CA; [[ $side == telepatch ]] && c=$CT
        docker exec "$c" sh -c "$boot" >"$out/bootstrap-$side.log" 2>&1 \
            || { tail -20 "$out/bootstrap-$side.log"; echo "FAIL: bootstrap on the $side side"; exit 1; }
    done

    echo "=== ansible: throwaway venv /opt/edge-ansible (uv $EDGE_UV, python $EDGE_PY) ==="
    docker cp -q "$ROOT/playbooks/edge" "$CA:/tmp/edge-playbook"
    local venv_env=(-e LC_ALL=C.UTF-8 -e PIP_NO_CACHE_DIR=1 -e UV_CACHE_DIR=/opt/edge-ansible/cache
        -e UV_PYTHON_INSTALL_DIR=/opt/edge-ansible/python -e UV_PYTHON_BIN_DIR=/opt/edge-ansible/bin
        -e ANSIBLE_HOME=/opt/edge-ansible/home)
    docker exec "${venv_env[@]}" "$CA" sh -c "set -e
        python3 -m venv /opt/edge-ansible/boot
        /opt/edge-ansible/boot/bin/pip install -q uv==$EDGE_UV
        /opt/edge-ansible/boot/bin/uv venv -q --managed-python --python $EDGE_PY /opt/edge-ansible/venv
        /opt/edge-ansible/boot/bin/uv pip install -q --python /opt/edge-ansible/venv/bin/python -r /tmp/edge-playbook/requirements.txt
        /opt/edge-ansible/venv/bin/ansible-galaxy collection install -p /opt/edge-ansible/collections community.general==$EDGE_CG
        /opt/edge-ansible/venv/bin/ansible-playbook --version | head -2" >"$out/venv.log" 2>&1 \
        || { tail -20 "$out/venv.log"; echo "FAIL: the ansible venv"; exit 1; }
    sed 's/^/  /' "$out/venv.log"

    echo "=== ansible: ansible-playbook --connection local playbooks/edge/edge.yml ==="
    local t0=$SECONDS
    rc=0
    docker exec -e LC_ALL=C.UTF-8 -e ANSIBLE_NOCOLOR=1 -e ANSIBLE_HOME=/opt/edge-ansible/home \
        -e ANSIBLE_COLLECTIONS_PATH=/opt/edge-ansible/collections \
        -e ANSIBLE_LOCAL_TEMP=/opt/edge-ansible/tmp -e ANSIBLE_REMOTE_TEMP=/opt/edge-ansible/remote \
        "$CA" /opt/edge-ansible/venv/bin/ansible-playbook -i localhost, --connection local \
        -e ansible_python_interpreter=/usr/bin/python3 /tmp/edge-playbook/edge.yml >"$out/ansible.log" 2>&1 || rc=$?
    sed -n '/^PLAY RECAP/,$p' "$out/ansible.log"
    if [[ $rc -ne 0 ]]; then tail -40 "$out/ansible.log"; echo "FAIL: ansible-playbook exited $rc"; exit 1; fi
    echo "ansible: $((SECONDS - t0))s"
    docker exec "$CA" rm -rf /opt/edge-ansible /tmp/edge-playbook /root/.ansible
    docker exec "$CA" test ! -e /opt/edge-ansible || { echo "FAIL: /opt/edge-ansible is still there"; exit 1; }
    echo "ansible: venv removed"

    echo "=== telepatch: tp-basic run edge --local, twice ==="
    docker cp -q "$bin" "$CT:/tmp/tp-basic"
    local n rcn
    for n in 1 2; do
        t0=$SECONDS rcn=0
        docker exec "$CT" /tmp/tp-basic run edge --local >"$out/run$n.log" 2>&1 || rcn=$?
        sed -n '/^HOST  *STATUS/,$p' "$out/run$n.log"
        echo "telepatch run $n: $((SECONDS - t0))s, exit $rcn"
        if [[ $rcn -ne 0 ]]; then tail -40 "$out/run$n.log"; echo "FAIL: run $n exited $rcn"; exit 1; fi
    done
    local ch
    ch=$(changed_of "$out/run2.log")
    if [[ $ch == 0 ]]; then echo "ok   second run CHANGED 0"
    else
        echo "FAIL second run CHANGED ${ch:-?}; changed ops:"
        awk '/^== /{h=$0} /^-> changed/{print "  " h}' "$out/run2.log"
        fails=1
    fi
    docker exec "$CT" rm -f /tmp/tp-basic

    echo "=== capture: scripts/image-state.sh on both ==="
    for side in ansible telepatch; do
        c=$CA; [[ $side == telepatch ]] && c=$CT
        docker cp -q "$ROOT/scripts/image-state.sh" "$c:/tmp/image-state.sh"
        docker exec "$c" sh /tmp/image-state.sh >"$out/$side.state"
        docker exec "$c" sh /tmp/image-state.sh --versions >"$out/$side.versions"
        docker exec "$c" rm -f /tmp/image-state.sh
    done
    edge_compare "$out" || fails=1
    check_marker "$CA" ansible || fails=1
    check_marker "$CT" telepatch || fails=1
    check_jq "$CA" ansible || fails=1
    check_jq "$CT" telepatch || fails=1
    if [[ $fails -eq 0 ]]; then echo "PASS: edge on $distro"; exit 0; fi
    echo "FAIL: edge on $distro (outputs: $out)"
    exit 1
}

# ---- self-test ------------------------------------------------------------------

# A stub `docker`: logs every call; answers `info` with $DOCKER_STUB_LABELS,
# `image inspect` with a fake id, the marker's sha256sum with the hash of
# $DOCKER_STUB_MARKER (printf %b; MISSING: no file); with DOCKER_STUB_HANG=1
# every other exec hangs until `rm` kills it, as a removed container does.
edge_stub() {
    local dir=$1
    mkdir -p "$dir"
    cat >"$dir/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >>"${DOCKER_STUB_LOG:?}"
case ${1:-} in
    info) [[ -n ${DOCKER_STUB_LABELS:-} ]] && { echo "$DOCKER_STUB_LABELS"; exit 0; }; exit 1 ;;
    image) echo sha256:stub; exit 0 ;;
    pull|create|start|cp) exit 0 ;;
    rm) [[ -f ${DOCKER_STUB_DIR:?}/exec.pid ]] && kill "$(cat "$DOCKER_STUB_DIR/exec.pid")" 2>/dev/null; exit 0 ;;
    exec)
        if [[ $* == *"sha256sum /usr/local/share/telepatch-edge.txt"* ]]; then
            [[ ${DOCKER_STUB_MARKER-} == MISSING ]] && { echo "sha256sum: no such file" >&2; exit 1; }
            printf '%b' "${DOCKER_STUB_MARKER-edge\n}" | sha256sum; exit 0
        fi
        if [[ ${DOCKER_STUB_HANG:-} == 1 ]]; then
            sleep 60 & echo $! >"$DOCKER_STUB_DIR/exec.pid"; wait; exit 137
        fi
        exit 0 ;;
esac
exit 99
EOF
    chmod +x "$dir/docker"
}

edge_self_test() {
    local t fails=0 rc n self=$ROOT/scripts/test-edge.sh
    t=$(mktemp -d)
    edge_stub "$t/bin"
    export DOCKER_STUB_LOG=$t/calls DOCKER_STUB_DIR=$t
    : >"$t/tp-basic"; chmod +x "$t/tp-basic"
    # run <name> <want rc> <pattern in the output, or -> env... -- args...
    run() {
        local name=$1 want=$2 pat=$3 e=() rc=0
        shift 3
        while [[ $1 != -- ]]; do e+=("$1"); shift; done
        shift
        : >"$DOCKER_STUB_LOG"; rm -f "$t/exec.pid"
        env -u TP_DOCKER_VM -u DOCKER_HOST -u DOCKER_CONTEXT -u BUILDX_BUILDER -u TP_EDGE_STOP_SECS -u TP_EDGE_BUDGET_SECS \
            PATH="$t/bin:$PATH" TP_EDGE_BIN="$t/tp-basic" TP_EDGE_OUT="$t/out" "${e[@]}" bash "$self" "$@" >"$t/run.out" 2>&1 || rc=$?
        if [[ $rc -ne $want ]]; then echo "FAIL $name: exit $rc, wanted $want"; sed 's/^/     | /' "$t/run.out" | tail -8; fails=1; return 1; fi
        if [[ $pat != - ]] && ! grep -qE -- "$pat" "$t/run.out"; then echo "FAIL $name: output lacks /$pat/"; sed 's/^/     | /' "$t/run.out" | tail -8; fails=1; return 1; fi
        echo "ok   $name (exit $rc, docker calls: $(wc -l <"$DOCKER_STUB_LOG"))"
    }
    local vm=(TP_DOCKER_VM=tp-docker-x DOCKER_STUB_LABELS='["tp-docker-vm=tp-docker-x"]')

    # guard refusal: outside docker-vm, exit 2 before any docker command
    if run "guard: cell outside a tp-* VM" 2 'docker workloads run only in a tp-\* VM' -- cell ubuntu2404; then
        n=$(wc -l <"$DOCKER_STUB_LOG")
        [[ $n -eq 0 ]] && echo "ok   guard: no docker call before the refusal" || { echo "FAIL guard: $n docker calls"; fails=1; }
    fi
    run "guard: this machine's daemon (no label)" 2 'has no label' TP_DOCKER_VM=tp-docker-x DOCKER_STUB_LABELS='[]' -- cell ubuntu2404 || true
    local d
    for d in omarchy nosuch; do
        if run "distro: cell $d refused after the guard" 2 "no stock image for '$d'" "${vm[@]}" -- cell "$d"; then
            grep -qv '^docker info' "$DOCKER_STUB_LOG" && { echo "FAIL distro: docker beyond info:"; sed 's/^/     | /' "$DOCKER_STUB_LOG"; fails=1; }
        fi
    done
    # every mapped distro is accepted by the cell: it gets as far as its own
    # image's pull (the stub's PID 1 is not sleep, so it stops there, exit 1)
    local img
    for d in ubuntu2404 rockylinux10 archlinux; do
        [[ $d == archlinux ]] && d=arch
        img=$(bash "$self" image "$d" 2>/dev/null) || img=
        if run "distro: cell $d accepted (pulls ${img:-?})" 1 'PID 1 of' "${vm[@]}" -- cell "$d"; then
            grep -qx "docker pull -q $img" "$DOCKER_STUB_LOG" && [[ -n $img ]] \
                || { echo "FAIL distro: $d did not pull '${img:-?}'"; sed 's/^/     | /' "$DOCKER_STUB_LOG"; fails=1; }
        fi
    done
    run "distro: local debian12 refused before cargo" 2 'ubuntu2404 only' -- local debian12 || true
    grep -q 'cargo test' "$t/run.out" && { echo "FAIL distro: local half ran"; fails=1; }
    # the bootstrap is the family's package manager, the same on both sides
    local b
    b=$(edge_boot ubuntu2404); [[ $b == *'apt-get install'*python3-apt* ]] && echo "ok   boot: ubuntu2404 uses apt (python3-apt)" || { echo "FAIL boot ubuntu2404: '$b'"; fails=1; }
    b=$(edge_boot rockylinux10); [[ $b == *'dnf -y'*install*python3-dnf* && $b != *apt-get* ]] && echo "ok   boot: rockylinux10 uses dnf (python3-dnf)" || { echo "FAIL boot rockylinux10: '$b'"; fails=1; }
    b=$(edge_boot fedora43); [[ $b == *'dnf -y'*install*python3-libdnf5* ]] && echo "ok   boot: fedora43 uses dnf5 (python3-libdnf5)" || { echo "FAIL boot fedora43: '$b'"; fails=1; }
    b=$(edge_boot arch); [[ $b == *pacman*python* ]] && echo "ok   boot: arch uses pacman" || { echo "FAIL boot arch: '$b'"; fails=1; }
    edge_boot omarchy >/dev/null 2>&1 && { echo "FAIL boot: omarchy has a bootstrap"; fails=1; } || echo "ok   boot: omarchy has none (no stock image)"
    run "limits: a stop over 30 minutes is refused" 2 'at most 1800' "${vm[@]}" TP_EDGE_STOP_SECS=1801 -- cell ubuntu2404 || true
    run "limits: a budget over 10 minutes is refused" 2 'at most 600' "${vm[@]}" TP_EDGE_BUDGET_SECS=601 -- cell ubuntu2404 || true
    if grep -qx 'EDGE_BUDGET=600' "$self" && grep -qx 'EDGE_STOP=1800' "$self"; then echo "ok   limits: budget 600s, stop 1800s"
    else echo "FAIL limits: EDGE_BUDGET=600 / EDGE_STOP=1800 not in the script"; fails=1; fi

    # the 30 minute kill path, at 3 seconds: the first exec hangs, the stop
    # removes both containers, the cell exits 1
    local s0=$SECONDS
    if run "stop: hard stop kills the containers and exits 1" 1 'hard stop at 3s' "${vm[@]}" DOCKER_STUB_HANG=1 TP_EDGE_BUDGET_SECS=1 TP_EDGE_STOP_SECS=3 -- cell ubuntu2404; then
        grep -q 'budget: exceeded' "$t/run.out" && echo "ok   stop: budget line printed first" || { echo "FAIL stop: no budget line"; fails=1; }
        grep -qE '^docker rm -f tp-edge-ansible-[0-9]+ tp-edge-telepatch-[0-9]+$' "$DOCKER_STUB_LOG" \
            && echo "ok   stop: docker rm -f of both containers" || { echo "FAIL stop: no rm -f of both"; sed 's/^/     | /' "$DOCKER_STUB_LOG"; fails=1; }
        [[ -e $t/out/stopped ]] && echo "ok   stop: the stop marker" || { echo "FAIL stop: no marker"; fails=1; }
        [[ $((SECONDS - s0)) -lt 20 ]] && echo "ok   stop: returned in $((SECONDS - s0))s" || { echo "FAIL stop: took $((SECONDS - s0))s"; fails=1; }
    fi

    # the file-bytes check, through docker exec
    mk() { # name want marker
        local rc=0
        DOCKER_STUB_MARKER=$3 PATH="$t/bin:$PATH" check_marker c side >"$t/m.out" 2>&1 || rc=$?
        [[ $rc -eq $2 ]] && echo "ok   marker: $1 (exit $rc)" || { echo "FAIL marker: $1: exit $rc, wanted $2"; sed 's/^/     | /' "$t/m.out"; fails=1; }
    }
    mk "edge\\n is the five bytes" 0 'edge\n'
    mk "edge with no newline" 1 'edge'
    mk "edge with a second newline" 1 'edge\n\n'
    mk "Edge, wrong bytes" 1 'Edge\n'
    mk "no file" 1 MISSING

    # no intended-differences file: compare as is; one present is a failure
    local cap=$t/cap state=$'== packages ==\nbash amd64\ncurl amd64\n== /usr/local/bin ==\nedge-jq\n'
    mkdir -p "$cap" "$t/intended-none" "$t/intended-some"
    [[ ! -e $ROOT/tests/oracle/intended/edge.txt ]] && echo "ok   intended: tests/oracle/intended/edge.txt does not exist" \
        || { echo "FAIL intended: tests/oracle/intended/edge.txt exists"; fails=1; }
    printf '%s' "$state" >"$cap/ansible.state"; cp "$cap/ansible.state" "$cap/telepatch.state"
    rc=0; edge_compare "$cap" "$t/intended-none" >"$t/c.out" 2>&1 || rc=$?
    if [[ $rc -eq 0 ]] && grep -qx 'GATING: names/arch, pip, rustup, apt sources, /usr/local/bin: identical' "$t/c.out"; then
        echo "ok   intended: missing file, identical captures gate as identical"
    else echo "FAIL intended: missing file, identical: exit $rc"; sed 's/^/     | /' "$t/c.out"; fails=1; fi
    printf '%s' "${state/edge-jq/}" >"$cap/telepatch.state"
    rc=0; edge_compare "$cap" "$t/intended-none" >"$t/c.out" 2>&1 || rc=$?
    if [[ $rc -eq 1 ]] && grep -q '^-edge-jq' "$t/c.out"; then echo "ok   intended: missing file, a difference fails (exit 1)"
    else echo "FAIL intended: missing file, a difference: exit $rc"; sed 's/^/     | /' "$t/c.out"; fails=1; fi
    : >"$t/intended-some/edge.txt"; cp "$cap/ansible.state" "$cap/telepatch.state"
    rc=0; edge_compare "$cap" "$t/intended-some" >"$t/c.out" 2>&1 || rc=$?
    if [[ $rc -eq 1 ]] && grep -q 'takes no intended-differences file' "$t/c.out"; then echo "ok   intended: an edge.txt is refused (exit 1)"
    else echo "FAIL intended: an edge.txt present: exit $rc"; sed 's/^/     | /' "$t/c.out"; fails=1; fi
    selftest_no_local_copy "$self" || fails=1

    # scope: the cell runs only playbook edge, and starts no init
    local body
    body=$(sed -n '/^cell() {/,/^}/p' "$self" | grep -v '^ *#')
    if grep -q '/tmp/tp-basic run edge --local' <<<"$body" && ! grep 'tp-basic run' <<<"$body" | grep -qv 'tp-basic run edge --local' \
        && ! grep -qE 'dev_base|kernel_build|container/|/sbin/init|systemd|--privileged|--cgroupns|--pid=host' <<<"$body"; then
        echo "ok   scope: the cell applies playbook edge only, starts no init, nothing privileged"
    else echo "FAIL scope: the cell runs something besides playbook edge"; fails=1; fi
    rm -rf "$t"
    return $fails
}

case ${1:-} in
    --self-test) edge_self_test; exit $? ;;
    local) shift; local_half "$@" ;;
    cell) shift; cell "$@" ;;
    image) shift; edge_image "${1:-}" || refuse_distro "${1:-}" ;;
    *) die "usage: test-edge.sh local <distro> | cell <distro> | image <distro> | --self-test" ;;
esac
