#!/usr/bin/env bash
# Docker equivalence oracle: builds a container's chain the Ansible way and the
# telepatch way from one pinned base image, captures scripts/image-state.sh for
# the final image of each, and diffs. Exit 1 on a gating diff.
#
#   scripts/test-container.sh [--side ansible|telepatch|both] <distro> <container>
#   scripts/test-container.sh --self-test
#
# Env: ADMIN_USERS  extra users image-state.sh inspects besides root (default none)
#      ANSIBLE_SHA  override the resolved `master` commit of the ansible repo
#
# Outputs (gitignored): build/test-container/<container>-<distro>/
#   {ansible,telepatch}.{log,state,versions}, base.state (the pinned base)
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DI=$ROOT/../docker_images
HCL=$DI/docker-bake.hcl

die() { echo "test-container: $*" >&2; exit 2; }

# ---- the diff logic (also used by --self-test) ------------------------------

# compare_captures and intended_for live in scripts/lib/compare.sh, shared with
# test-vm-oracle.sh.
# shellcheck source=lib/compare.sh
source "$ROOT/scripts/lib/compare.sh"

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
    return $fails
}

if [[ ${1:-} == --self-test ]]; then self_test; exit $?; fi

# ---- arguments --------------------------------------------------------------
side=both
if [[ ${1:-} == --side ]]; then side=${2:?--side needs a value}; shift 2; fi
[[ $side =~ ^(ansible|telepatch|both)$ ]] || die "--side must be ansible, telepatch or both"
distro=${1:-}; container=${2:-}
[[ -n $distro && -n $container ]] || die "usage: test-container.sh [--side S] <distro> <container> | --self-test"

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
    [[ -x $ROOT/build/tp-basic ]] || die "build/tp-basic not found: run 'just musl' first"
    [[ -f $ROOT/vars/container.toml ]] || die "vars/container.toml not found"
    ! command -v file >/dev/null || file "$ROOT/build/tp-basic" | grep -Eq 'statically linked|static-pie' || die "build/tp-basic is not a static binary: run 'just musl'"
fi

out=$ROOT/build/test-container/$container-$distro
mkdir -p "$out"
rm -f "$out"/*

# ---- pin the base: the image id of base-<distro>:latest, once ---------------
base_ref=resurgentech/base-$distro:latest
base_id=$(docker image inspect -f '{{.Id}}' "$base_ref" 2>/dev/null) || die "$base_ref not found locally (build it with docker_images first)"
# buildx's docker-image:// context won't take a bare id, so alias the id with a
# local tag; the tag is only ever this id, and both chains start from it.
hex=${base_id#sha256:}
pin=tp-test/pin/base-$distro:${hex:0:12}
docker tag "$base_id" "$pin"
echo "base: $base_ref = $base_id (pinned as $pin)"
# the pinned base's own state, so what a chain added can be computed later
docker run --rm --entrypoint sh -e ADMIN_USERS="${ADMIN_USERS:-}" \
    -v "$ROOT/scripts/image-state.sh:/image-state.sh:ro" "$pin" /image-state.sh >"$out/base.state"
echo "captured $out/base.state ($(wc -l <"$out/base.state") lines)"

created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
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
        prev=$tag
    done
}

# ---- telepatch side ---------------------------------------------------------
build_telepatch() {
    local prev=$pin c tag pb
    for c in "${chain[@]}"; do
        tag=tp-test/telepatch/$c-$distro
        pb=$(basename "$(playbook_of "$c")" .yml)
        echo "=== telepatch: $tag (parent $prev, playbook container/$pb) ==="
        "${bb[@]}" -f "$ROOT/Dockerfiles/telepatch.$family" \
            --build-context "parent=docker-image://$prev" \
            --build-arg PLAYBOOK_NAME="$pb" -t "$tag" "$ROOT"
        prev=$tag
    done
}

capture() { # side
    local img=tp-test/$1/$container-$distro
    local run=(docker run --rm --entrypoint sh -e ADMIN_USERS="${ADMIN_USERS:-}" -v "$ROOT/scripts/image-state.sh:/image-state.sh:ro" "$img" /image-state.sh)
    "${run[@]}" >"$out/$1.state"
    "${run[@]}" --versions >"$out/$1.versions"
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
compare_captures "$out" "$(intended_for "$container")"
