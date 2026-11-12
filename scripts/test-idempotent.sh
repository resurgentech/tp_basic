#!/usr/bin/env bash
# Idempotency check: in one container of the pinned resurgentech/base-<distro>
# image, apply container/<container> twice with the static tp-basic
# from build/dist (`just dist`; copied in with `docker cp` to the paths docker_images' Dockerfiles/telepatch.* mount it at, with vars/container.toml).
# Runs only in a tp-* VM's daemon (`just docker-vm test-idempotent ...`); the base is built there.
# Passes when the second run exits 0 and its table shows CHANGED 0; otherwise
# prints the second run's changed ops and exits 1. Usage errors exit 2.
#
#   scripts/test-idempotent.sh <distro> <dev_base|rust|latest_kernel_build>
#
# latest_kernel_build is built on ubuntu2604 only (justfile test-acceptance).
#
# Env: DI_SHA  docker_images commit the hcl is read from (required; just passes ported_docker_images)
#
# Outputs (gitignored): build/test-idempotent/<container>-<distro>/{run1,run2}.log
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/docker-images.sh
source "$ROOT/scripts/lib/docker-images.sh"
# shellcheck source=lib/dist-input.sh
source "$ROOT/scripts/lib/dist-input.sh"

die() { echo "test-idempotent: $*" >&2; exit 2; }

# docker only in a tp-* VM (scripts/docker-vm.sh): refused before anything else
# shellcheck source=lib/docker-guard.sh
source "$ROOT/scripts/lib/docker-guard.sh"
docker_guard

distro=${1:-}; container=${2:-}
[[ -n $distro && -n $container ]] || die "usage: test-idempotent.sh <distro> <dev_base|rust|latest_kernel_build>"
case $container in
    dev_base|rust|latest_kernel_build) ;;
    *) die "container must be dev_base, rust or latest_kernel_build, not '$container'" ;;
esac

# the pinned docker_images commit, exported once (never the working tree)
di_export "$ROOT" || exit 2
HCL=$DI_DIR/docker-bake.hcl

family=$(sed -nE "s/^ *$distro += \{ root = .*ansible = \"([^\"]+)\".*/\1/p" "$HCL")
[[ -n $family ]] || die "distro '$distro' not in $HCL DISTROS"

# The preamble ../docker_images/Dockerfiles/telepatch.<family> runs before
# tp-basic; checked against the file below, so a drift fails here.
case $family in
    debian) preamble='apt-get update --fix-missing && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y' ;;
    redhat) preamble='dnf clean all && dnf update -y' ;;
    arch) preamble='pacman -Syu --noconfirm' ;;
    *) die "unknown family '$family'" ;;
esac

dist_require "$ROOT/build/dist" || exit 2
# the copy above must be what the working tree's Dockerfile runs (fails on drift)
preamble_check "$family" "$ROOT/../docker_images/Dockerfiles/telepatch.$family" "$preamble" || exit 2

base_ref=resurgentech/base-$distro:latest
di_base "$distro" || exit 2
base_id=$(docker image inspect -f '{{.Id}}' "$base_ref" 2>/dev/null) || die "$base_ref not found in the VM's daemon"
echo "base: $base_ref = $base_id"

out=$ROOT/build/test-idempotent/$container-$distro
mkdir -p "$out"
rm -f "$out"/*

name=tp-idem-$container-$distro-$$
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
# the dist goes in with docker cp (no bind mount: the daemon is the VM's)
docker create --name "$name" --entrypoint sleep "$base_id" infinity >/dev/null
docker cp -q "$ROOT/build/dist/tp-basic" "$name:/tmp/tp-basic"
docker cp -q "$ROOT/build/dist/vars" "$name:/tmp/tp-vars"
docker start "$name" >/dev/null

echo "=== preamble ($family) ==="
docker exec "$name" sh -c "$preamble" >"$out/preamble.log" 2>&1 || { tail -20 "$out/preamble.log"; die "preamble failed (log: $out/preamble.log)"; }

run() { # n
    echo "=== run $1: tp-basic run container/$container --local ==="
    local rc=0
    docker exec "$name" /tmp/tp-basic run "container/$container" --local --vars /tmp/tp-vars/container.toml \
        >"$out/run$1.log" 2>&1 || rc=$?
    # the table and what follows it
    sed -n '/^HOST  *STATUS/,$p' "$out/run$1.log"
    return $rc
}

# changed <log> : the CHANGED cell of the table's single host row
changed_of() { awk '/^HOST  *STATUS/{getline; print $4; exit}' "$1"; }

rc1=0; run 1 || rc1=$?
if [[ $rc1 -ne 0 ]]; then
    tail -40 "$out/run1.log"
    echo "FAIL: first run exited $rc1 (log: $out/run1.log)"
    exit 1
fi
grep '^== .* \[prepare\]' "$out/run1.log" || true

rc2=0; run 2 || rc2=$?
grep '^== .* \[prepare\]' "$out/run2.log" || true
ch=$(changed_of "$out/run2.log")
if [[ $rc2 -eq 0 && $ch == 0 ]]; then
    echo "PASS: second run CHANGED 0 ($container on $distro)"
    exit 0
fi
echo "FAIL: second run exited $rc2, CHANGED ${ch:-?} (log: $out/run2.log)"
echo "changed ops in the second run:"
awk '/^== /{h=$0} /^-> changed/{print "  " h}' "$out/run2.log"
exit 1
