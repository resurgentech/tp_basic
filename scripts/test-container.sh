#!/usr/bin/env bash
# Docker equivalence oracle: builds a container's chain the Ansible way and the
# telepatch way from one pinned base image, captures scripts/image-state.sh for
# the final image of each, and diffs. Exit 1 on a gating diff.
#
#   scripts/test-container.sh [--prune] [--side ansible|telepatch|both] <distro> <container>
#   scripts/test-container.sh --self-test
#
#      --prune (test-acceptance passes it; needs both sides): after the compare,
#      the guard is checked again and exactly the images this cell built are
#      removed, then `docker builder prune -f`; the bases are kept. The VM's
#      disk use is printed before and after.
#
#      The telepatch side is built from what ships: the working tree of
#      ../docker_images (Dockerfiles/telepatch.<family> and its context) with
#      build/dist as the named context `tp` (`just dist` first; a _dirty
#      PROVENANCE is printed, not gated). The Ansible side stays on the pinned export.
#
# Env: ADMIN_USERS  extra users image-state.sh inspects besides root (default none)
#      ANSIBLE_SHA  override the resolved `master` commit of the ansible repo
#      DI_SHA       docker_images commit the Ansible side is built from (required;
#                   `just` passes ported_docker_images); exported to build/docker_images/<sha>/
#
# Outputs (gitignored): build/test-container/<container>-<distro>/
#   {ansible,telepatch}.{log,state,versions}, base.state (the pinned base)
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

die() { echo "test-container: $*" >&2; exit 2; }

# ---- the diff logic (also used by --self-test) ------------------------------

# compare_captures and intended_for live in scripts/lib/compare.sh, shared with
# test-vm-oracle.sh.
# shellcheck source=lib/compare.sh
source "$ROOT/scripts/lib/compare.sh"
# shellcheck source=lib/docker-images.sh
source "$ROOT/scripts/lib/docker-images.sh"
# shellcheck source=lib/dist-input.sh
source "$ROOT/scripts/lib/dist-input.sh"
# shellcheck source=lib/docker-guard.sh
source "$ROOT/scripts/lib/docker-guard.sh"
# shellcheck source=lib/vm.sh
source "$ROOT/scripts/lib/vm.sh"

# ---- the per-cell prune (--prune; test-acceptance passes it) -----------------

# cell_disk <before|after> : the docker VM's disk use for /var/lib/docker, over
# ssh with vmtool's key in place (docker-vm.sh's known_hosts). Never fails the run.
cell_disk() {
    local VM_KEY VM_DEST VM_KNOWN_HOSTS line
    VM_KEY=$(vm_key "$TP_DOCKER_VM") VM_DEST=bot@${TP_DOCKER_VM_IP:-} \
        VM_KNOWN_HOSTS=$ROOT/build/docker-vm/$TP_DOCKER_VM/known_hosts
    if line=$(sshv 'df -h /var/lib/docker | tail -1' 2>/dev/null); then
        echo "disk ($1 prune): $line"
    else
        echo "disk ($1 prune): unavailable (ssh to ${TP_DOCKER_VM_IP:-?} failed)"
    fi
}

# cell_prune <ids file> : remove exactly the images this cell built (one
# "<id> <tag>" line per build, both sides, every chain stage), newest first, then
# `docker builder prune -f`. The guard is checked again first, so this only ever
# acts on a tp-docker-* VM's daemon (exit 2 otherwise, nothing removed). The
# pinned bases resurgentech/base-*:latest are kept for the next cell; nothing
# here prunes by pattern.
cell_prune() {
    local ids=$1 bases id tag fails=0
    (docker_guard) || return 2
    cell_disk before
    bases=$(docker image ls --no-trunc -q --filter 'reference=resurgentech/base-*')
    while read -r id tag; do
        [[ -n $id ]] || continue
        if grep -qxF "$id" <<<"$bases"; then echo "prune: kept base $id ($tag)"; continue; fi
        if docker image rm "$id" >/dev/null; then echo "prune: removed $id ($tag)"; else echo "prune: FAILED to remove $id ($tag)" >&2; fails=1; fi
    done < <(tac "$ids" | awk '!seen[$1]++')
    docker builder prune -f >/dev/null || { echo "prune: docker builder prune failed" >&2; fails=1; }
    cell_disk after
    return $fails
}

self_test() {
    local t fails=0
    t=$(mktemp -d)
    trap 'rm -rf "$t"' RETURN
    local state=$'== packages ==\nbash amd64\ncurl amd64\n== /usr/local/bin ==\nuv\n'
    local vers=$'== packages ==\nbash amd64 5.2\ncurl amd64 8.5\n'
    expect() { # name expected-rc
        local name=$1 want=$2 rc=0
        compare_captures "$t" >"$t/out" 2>&1 || rc=$?
        if [[ $rc -eq $want ]]; then echo "ok   $name (exit $rc)"; else echo "FAIL $name: exit $rc, wanted $want"; fails=1; fi
        sed 's/^/     | /' "$t/out"
    }
    # equal -> 0
    printf '%s' "$state" >"$t/ansible.state"; cp "$t/ansible.state" "$t/telepatch.state"
    printf '%s' "$vers" >"$t/ansible.versions"; cp "$t/ansible.versions" "$t/telepatch.versions"
    expect "equal" 0
    # a package missing on the telepatch side -> 1, diff printed
    printf '%s' "$state" | grep -v '^curl' >"$t/telepatch.state"
    expect "package missing" 1
    grep -q '^-curl amd64' "$t/out" || { echo "FAIL package missing: diff not printed"; fails=1; }
    # version-only change -> 0, side diff printed
    cp "$t/ansible.state" "$t/telepatch.state"
    printf '%s' "${vers/8.5/8.6}" >"$t/telepatch.versions"
    expect "version only" 0
    grep -q '^+curl amd64 8.6' "$t/out" || { echo "FAIL version only: side diff not printed"; fails=1; }
    selftest_intended compare_captures "$t" || fails=1
    selftest_no_local_copy "${BASH_SOURCE[0]}" "$ROOT/scripts/test-vm-oracle.sh" || fails=1
    selftest_export || fails=1
    selftest_dist || fails=1
    selftest_prune || fails=1
    return $fails
}

# cell_prune against a stub docker (first on PATH; it logs every call): refused
# without the VM's label, and with it removes exactly the recorded ids, never a base
selftest_prune() {
    local t rc fails=0 calls
    t=$(mktemp -d)
    mkdir -p "$t/bin"
    cat >"$t/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >>"${DOCKER_STUB_LOG:?}"
case "$1 ${2:-}" in
    "info "*) [[ -n ${DOCKER_STUB_LABELS:-} ]] && { echo "$DOCKER_STUB_LABELS"; exit 0; }; exit 1 ;;
    "image ls") echo sha256:base0; exit 0 ;;
    "image rm") exit 0 ;;
    "builder prune") exit 0 ;;
esac
exit 99
STUB
    chmod +x "$t/bin/docker"
    printf '%s\n' 'sha256:aaa1 tp-test/ansible/dev_base-x' 'sha256:aaa2 tp-test/ansible/kernel_build-x' \
        'sha256:base0 tp-test/pin/base-x:0' 'sha256:bbb1 tp-test/telepatch/dev_base-x' >"$t/built.ids"
    pr() { # labels tp_docker_vm : runs cell_prune in a subshell with the stub
        : >"$t/calls"; rc=0
        (
            export PATH="$t/bin:$PATH" DOCKER_STUB_LOG=$t/calls DOCKER_STUB_LABELS=$1
            unset DOCKER_HOST DOCKER_CONTEXT BUILDX_BUILDER TP_DOCKER_VM
            [[ -n $2 ]] && export TP_DOCKER_VM=$2
            cell_disk() { echo "disk ($1 prune): stub"; }
            cell_prune "$t/built.ids"
        ) >"$t/out" 2>&1 || rc=$?
        calls=$(grep -cE 'docker (image rm|builder|system|image prune)' "$t/calls" || true)
    }
    pr '' ''
    if [[ $rc -eq 2 && $calls -eq 0 && ! -s $t/calls ]] && grep -qF "$DOCKER_GUARD_MSG" "$t/out"; then
        echo "ok   prune: TP_DOCKER_VM unset (exit 2, no docker call)"
    else echo "FAIL prune: TP_DOCKER_VM unset: exit $rc"; sed 's/^/     | /' "$t/calls" "$t/out"; fails=1; fi
    pr '[]' tp-docker-x
    if [[ $rc -eq 2 && $calls -eq 0 ]] && grep -qF "$DOCKER_GUARD_MSG" "$t/out"; then
        echo "ok   prune: daemon without the label (exit 2, nothing removed)"
    else echo "FAIL prune: no label: exit $rc"; sed 's/^/     | /' "$t/calls" "$t/out"; fails=1; fi
    pr '["tp-docker-vm=tp-docker-x"]' tp-docker-x
    local got want=$'docker image rm sha256:bbb1\ndocker image rm sha256:aaa2\ndocker image rm sha256:aaa1\ndocker builder prune -f'
    got=$(grep -E 'docker (image rm|builder|system|image prune)' "$t/calls" || true)
    if [[ $rc -eq 0 && $got == "$want" ]] && grep -q 'kept base sha256:base0' "$t/out" \
        && grep -q 'disk (before prune)' "$t/out" && grep -q 'disk (after prune)' "$t/out"; then
        echo "ok   prune: the VM's label (the 3 recorded ids, newest first; base kept; builder prune; disk lines)"
    else echo "FAIL prune: the VM's label: exit $rc"; sed 's/^/     | /' "$t/calls" "$t/out"; fails=1; fi
    # nothing in the script may prune by pattern: that would take the bases
    if grep -vE '^[[:space:]]*#' "${BASH_SOURCE[0]}" | grep -vF 'grep' | grep -qE 'docker (system|image) prune|prune -a'; then
        echo "FAIL prune: the script has a pattern prune"; fails=1
    else echo "ok   prune: no system or image prune in the script"; fi
    rm -rf "$t"
    return $fails
}

# the dist input and the preamble check (no docker; a scratch dist, never build/dist)
selftest_dist() {
    local t rc fails=0 d
    t=$(mktemp -d); d=$t/dist
    mkdir -p "$d/vars"
    : >"$d/vars/container.toml"; echo 'tp_basic_hash: abc_dirty' >"$d/PROVENANCE"
    cp /bin/true "$d/tp-basic"
    # a missing PROVENANCE: exit 2 naming 'just dist'
    rm "$d/PROVENANCE"
    rc=0; (dist_require "$d") >"$t/out" 2>&1 || rc=$?
    if [[ $rc -eq 2 ]] && grep -q "PROVENANCE not found: run 'just dist' first" "$t/out"; then echo "ok   dist: missing PROVENANCE (exit 2)"; else echo "FAIL dist: missing PROVENANCE: exit $rc"; fails=1; fi
    # an empty PROVENANCE
    : >"$d/PROVENANCE"
    rc=0; (dist_require "$d") >"$t/out" 2>&1 || rc=$?
    if [[ $rc -eq 2 ]] && grep -q 'PROVENANCE is empty' "$t/out"; then echo "ok   dist: empty PROVENANCE (exit 2)"; else echo "FAIL dist: empty PROVENANCE: exit $rc"; fails=1; fi
    # a missing binary
    echo 'tp_basic_hash: abc_dirty' >"$d/PROVENANCE"; rm "$d/tp-basic"
    rc=0; (dist_require "$d") >"$t/out" 2>&1 || rc=$?
    if [[ $rc -eq 2 ]] && grep -q 'tp-basic not found' "$t/out"; then echo "ok   dist: missing tp-basic (exit 2)"; else echo "FAIL dist: missing tp-basic: exit $rc"; fails=1; fi
    # a non-static binary (skipped where /bin/true is static or `file` is absent)
    cp /bin/true "$d/tp-basic"
    if command -v file >/dev/null && ! file "$d/tp-basic" | grep -Eq 'statically linked|static-pie'; then
        rc=0; (dist_require "$d") >"$t/out" 2>&1 || rc=$?
        if [[ $rc -eq 2 ]] && grep -q 'not a static binary' "$t/out"; then echo "ok   dist: dynamic tp-basic (exit 2)"; else echo "FAIL dist: dynamic tp-basic: exit $rc"; fails=1; fi
    fi
    # the preamble: a matching one passes, a drifted one fails with both texts
    printf '%s\n' 'FROM parent' 'ARG PLAYBOOK' 'RUN --mount=type=bind,from=tp,source=tp-basic,target=/tmp/tp-basic \' \
        '    --mount=type=bind,from=tp,source=vars,target=/tmp/tp-vars \' '    dnf clean all && \' '    dnf update -y && \' \
        '    /tmp/tp-basic run "${PLAYBOOK}" --local' '' 'RUN rm -rf /tmp/*' >"$t/Dockerfile.redhat"
    rc=0; preamble_check redhat "$t/Dockerfile.redhat" 'dnf clean all && dnf update -y' >"$t/out" 2>&1 || rc=$?
    if [[ $rc -eq 0 ]]; then echo "ok   preamble: matching"; else echo "FAIL preamble: matching: exit $rc"; sed 's/^/     | /' "$t/out"; fails=1; fi
    rc=0; preamble_check redhat "$t/Dockerfile.redhat" 'dnf update -y' >"$t/out" 2>&1 || rc=$?
    if [[ $rc -eq 2 ]] && grep -q 'preamble drifted' "$t/out" && grep -q 'file:   dnf clean all && dnf update -y' "$t/out"; then echo "ok   preamble: drifted (exit 2)"; else echo "FAIL preamble: drifted: exit $rc"; fails=1; fi
    rm -rf "$t"
    return $fails
}

# docker_images export (needs git and the sibling repo, no docker)
selftest_export() {
    local t rc fails=0 pinned=5df316b67429370105efec0e5c5ac29a6ccbd71a
    t=$(mktemp -d)
    # a bogus sha: exit 2, message names the sha and the repo
    rc=0; (DI_SHA=0000000000000000000000000000000000000bad di_export "$ROOT" "$t") >"$t/out" 2>&1 || rc=$?
    if [[ $rc -eq 2 ]] && grep -q 'not a commit in .*docker_images: fetch it or set DI_SHA' "$t/out" && grep -q 0000000000000000000000000000000000000bad "$t/out"; then
        echo "ok   export: bogus sha (exit 2)"; else echo "FAIL export: bogus sha: exit $rc"; sed 's/^/     | /' "$t/out"; fails=1; fi
    # unset DI_SHA: exit 2, usage message
    rc=0; (unset DI_SHA; di_export "$ROOT" "$t") >"$t/out" 2>&1 || rc=$?
    if [[ $rc -eq 2 ]] && grep -q 'DI_SHA is not set' "$t/out"; then echo "ok   export: DI_SHA unset (exit 2)"; else echo "FAIL export: DI_SHA unset: exit $rc"; fails=1; fi
    # the pinned commit (short form too): full-sha dir, hcl and ansible Dockerfile, marker, reuse
    if git -C "$ROOT/../docker_images" cat-file -e "$pinned^{commit}" 2>/dev/null; then
        local d=$t/build/docker_images/$pinned
        rc=0; (DI_SHA=${pinned:0:10} di_export "$ROOT" "$t") >"$t/out" 2>&1 || rc=$?
        if [[ $rc -eq 0 && -f $d/docker-bake.hcl && -f $d/Dockerfiles/ansible.debian && -f $d/.export-complete \
              && -f $d/.dockerignore && -f $d/scripts/image-history.sh ]]; then
            echo "ok   export: pinned commit (short sha, full-sha dir)"; else echo "FAIL export: pinned commit: exit $rc"; sed 's/^/     | /' "$t/out"; fails=1; fi
        rc=0; (DI_SHA=$pinned di_export "$ROOT" "$t") >"$t/out" 2>&1 || rc=$?
        if [[ $rc -eq 0 ]] && ! grep -q exported "$t/out"; then echo "ok   export: complete export reused"; else echo "FAIL export: reuse"; fails=1; fi
    else
        echo "FAIL export: pinned commit $pinned not in ../docker_images"; fails=1
    fi
    rm -rf "$t"
    return $fails
}

if [[ ${1:-} == --self-test ]]; then self_test; exit $?; fi

# docker only in a tp-* VM (scripts/docker-vm.sh): refused before anything else
docker_guard

# ---- arguments --------------------------------------------------------------
side=both prune=0
while [[ ${1:-} == --* ]]; do
    case $1 in
        --side) side=${2:?--side needs a value}; shift 2 ;;
        --prune) prune=1; shift ;;
        *) die "unknown option $1" ;;
    esac
done
[[ $side =~ ^(ansible|telepatch|both)$ ]] || die "--side must be ansible, telepatch or both"
[[ $prune -eq 0 || $side == both ]] || die "--prune needs both sides"
distro=${1:-}; container=${2:-}
[[ -n $distro && -n $container ]] || die "usage: test-container.sh [--prune] [--side S] <distro> <container> | --self-test"

# ---- the pinned docker_images commit, exported once (never the working tree) --
di_export "$ROOT" || exit 2
DI=$DI_DIR
HCL=$DI/docker-bake.hcl

# ---- docker-bake.hcl, parsed line-oriented (same idea as telepatch's os-fixtures) --
# DISTROS line:     name = { root = "...", base = "...", ansible = "<family>", ...
# CONTAINERS line:  name = { parent = "<p>", playbook = "playbooks/container/<f>.yml" }
family=$(sed -nE "s/^ *$distro += \{ root = .*ansible = \"([^\"]+)\".*/\1/p" "$HCL")
[[ -n $family ]] || die "distro '$distro' not in $HCL DISTROS"
container_line() { sed -nE "s/^ *$1 += \{ parent = \"([^\"]+)\", playbook = \"([^\"]+)\" \}.*/\1 \2/p" "$HCL"; }
[[ -n $(container_line "$container") ]] || die "container '$container' not in $HCL CONTAINERS"
# chain: container and its parents, up to (not including) "base", root-first
chain=(); c=$container
while [[ $c != base ]]; do
    chain=("$c" "${chain[@]}")
    read -r c _ < <(container_line "$c")
    [[ -n $c ]] || die "broken parent chain for $container"
done
playbook_of() { local _ pb; read -r _ pb < <(container_line "$1"); echo "$pb"; }
ansible_url=$(sed -nE 's/^variable "ANSIBLE_URL" \{ default = "([^"]+)".*/\1/p' "$HCL")
[[ -n $ansible_url ]] || die "can't read ANSIBLE_URL from $HCL"

# ---- preflight, before any build -------------------------------------------
if [[ $side != ansible ]]; then
    # what ships: the dist (`just dist`) and the working tree's telepatch Dockerfile
    dist_require "$ROOT/build/dist" || exit 2
    tp_dockerfile=$ROOT/../docker_images/Dockerfiles/telepatch.$family
    [[ -f $tp_dockerfile ]] || die "$tp_dockerfile not found"
fi

out=$ROOT/build/test-container/$container-$distro
mkdir -p "$out"
rm -f "$out"/*

# ---- pin the base: the image id of base-<distro>:latest, once ---------------
base_ref=resurgentech/base-$distro:latest
di_base "$distro" || exit 2
base_id=$(docker image inspect -f '{{.Id}}' "$base_ref" 2>/dev/null) || die "$base_ref not found in the VM's daemon"
# buildx's docker-image:// context won't take a bare id, so alias the id with a
# local tag; the tag is only ever this id, and both chains start from it.
hex=${base_id#sha256:}
pin=tp-test/pin/base-$distro:${hex:0:12}
docker tag "$base_id" "$pin"
echo "base: $base_ref = $base_id (pinned as $pin)"
# the pinned base's own state, so what a chain added can be computed later;
# image-state.sh goes in on stdin (no bind mount: the daemon is the VM's)
docker run --rm -i --entrypoint sh -e ADMIN_USERS="${ADMIN_USERS:-}" \
    "$pin" -s <"$ROOT/scripts/image-state.sh" >"$out/base.state"
echo "captured $out/base.state ($(wc -l <"$out/base.state") lines)"

created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# every image this cell builds, "<id> <tag>", for cell_prune
built_ids=$out/built.ids
: >"$built_ids"
record_built() {
    local id
    id=$(docker image inspect -f '{{.Id}}' "$1") && [[ -n $id ]] || die "built $1 but cannot read its image id"
    echo "$id $1" >>"$built_ids"
}
bb=(docker buildx build --no-cache --provenance=false --sbom=false --load --progress=plain)

# ---- ansible side -----------------------------------------------------------
build_ansible() {
    local sha=${ANSIBLE_SHA:-}
    if [[ -z $sha ]]; then
        sha=$(git ls-remote "$ansible_url" refs/heads/master | cut -f1)
        [[ -n $sha ]] || die "can't resolve master of $ansible_url"
    fi
    local pinned
    pinned=$(sed -n 's/^commit: //p' "$ROOT/conversion/SOURCE")
    [[ $sha == "$pinned" ]] || echo "WARNING: ansible master is $sha but conversion/SOURCE records $pinned" >&2
    echo "ansible: $ansible_url @ $sha"
    local prev=$pin c tag
    for c in "${chain[@]}"; do
        tag=tp-test/ansible/$c-$distro
        echo "=== ansible: $tag (parent $prev) ==="
        "${bb[@]}" -f "$DI/Dockerfiles/ansible.$family" \
            --build-context "parent=docker-image://$prev" \
            --build-arg ORG=tp-test --build-arg IMAGE="$tag" --build-arg BASE_IMAGE="$prev" \
            --build-arg CREATED="$created" --build-arg GIT_URL=https://example.invalid/tp-test \
            --build-arg GIT_SHA=tp-test --build-arg ANSIBLE_URL="$ansible_url" \
            --build-arg ANSIBLE_SHA="$sha" --build-arg PLAYBOOK="$(playbook_of "$c")" \
            -t "$tag" "$DI"
        record_built "$tag"
        prev=$tag
    done
}

# ---- telepatch side ---------------------------------------------------------
build_telepatch() {
    local prev=$pin c tag pb
    echo "telepatch: $tp_dockerfile, dist $(sed -n 's/^tp_basic_hash: //p' "$ROOT/build/dist/PROVENANCE")"
    for c in "${chain[@]}"; do
        tag=tp-test/telepatch/$c-$distro
        pb=$(basename "$(playbook_of "$c")" .yml)
        echo "=== telepatch: $tag (parent $prev, playbook container/$pb) ==="
        "${bb[@]}" -f "$tp_dockerfile" \
            --build-context "parent=docker-image://$prev" \
            --build-context "tp=$ROOT/build/dist" \
            --build-arg ORG=tp-test --build-arg IMAGE="$tag" --build-arg BASE_IMAGE="$prev" \
            --build-arg CREATED="$created" --build-arg GIT_URL=https://example.invalid/tp-test \
            --build-arg GIT_SHA=tp-test --build-arg PLAYBOOK="container/$pb" \
            -t "$tag" "$ROOT/../docker_images"
        record_built "$tag"
        prev=$tag
    done
}

capture() { # side
    local img=tp-test/$1/$container-$distro
    # image-state.sh on stdin (no bind mount: the daemon is the VM's)
    local run=(docker run --rm -i --entrypoint sh -e ADMIN_USERS="${ADMIN_USERS:-}" "$img" -s --)
    "${run[@]}" <"$ROOT/scripts/image-state.sh" >"$out/$1.state"
    "${run[@]}" --versions <"$ROOT/scripts/image-state.sh" >"$out/$1.versions"
}

for s in ansible telepatch; do
    [[ $side == both || $side == "$s" ]] || continue
    # the build output is the stream log; keep it and show it
    "build_$s" 2>&1 | tee "$out/$s.log"
    [[ ${PIPESTATUS[0]} -eq 0 ]] || die "$s build failed (log: $out/$s.log)"
    capture "$s"
    echo "captured $out/$s.state ($(wc -l <"$out/$s.state") lines)"
done

if [[ $side != both ]]; then
    echo "side=$side: built and captured one side only; no comparison"
    exit 0
fi
rc=0
compare_captures "$out" "$(intended_for "$container")" "$distro" || rc=$?
if [[ $prune -eq 1 ]]; then
    echo "=== prune: $container-$distro ($(wc -l <"$built_ids") images built) ==="
    prc=0; cell_prune "$built_ids" || prc=$?
    [[ $prc -eq 2 ]] && exit 2
    if [[ $prc -ne 0 ]]; then echo "test-container: the prune failed" >&2; [[ $rc -ne 0 ]] || rc=1; fi
fi
exit "$rc"
