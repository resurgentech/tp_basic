#!/usr/bin/env bash
# Idempotency check: in one container of the pinned resurgentech/base-<distro>
# image, apply container/<container> twice with the static tp-basic
# (bind-mounted, as Dockerfiles/telepatch.* do, with vars/container.toml).
# Passes when the second run exits 0 and its table shows CHANGED 0; otherwise
# prints the second run's changed ops and exits 1. Usage errors exit 2.
#
#   scripts/test-idempotent.sh <distro> <dev_base|rust>
#
# Outputs (gitignored): build/test-idempotent/<container>-<distro>/{run1,run2}.log
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HCL=$ROOT/../docker_images/docker-bake.hcl

die() { echo "test-idempotent: $*" >&2; exit 2; }

distro=${1:-}; container=${2:-}
[[ -n $distro && -n $container ]] || die "usage: test-idempotent.sh <distro> <dev_base|rust>"
case $container in
    dev_base|rust) ;;
    *) die "container must be dev_base or rust, not '$container'" ;;
esac

family=$(sed -nE "s/^ *$distro += \{ root = .*ansible = \"([^\"]+)\".*/\1/p" "$HCL")
[[ -n $family ]] || die "distro '$distro' not in $HCL DISTROS"

# The same preamble the Dockerfiles run before tp-basic.
case $family in
    debian) preamble='apt-get update --fix-missing && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y' ;;
    redhat) preamble='dnf clean all && dnf update -y' ;;
    arch) preamble='pacman -Syu --noconfirm' ;;
    *) die "unknown family '$family'" ;;
esac

[[ -x $ROOT/build/tp-basic ]] || die "build/tp-basic not found: run 'just musl' first"
[[ -f $ROOT/vars/container.toml ]] || die "vars/container.toml not found"
! command -v file >/dev/null || file "$ROOT/build/tp-basic" | grep -Eq 'statically linked|static-pie' || die "build/tp-basic is not a static binary: run 'just musl'"

base_ref=resurgentech/base-$distro:latest
base_id=$(docker image inspect -f '{{.Id}}' "$base_ref" 2>/dev/null) || die "$base_ref not found locally"
echo "base: $base_ref = $base_id"

out=$ROOT/build/test-idempotent/$container-$distro
mkdir -p "$out"
rm -f "$out"/*

name=tp-idem-$container-$distro-$$
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker run -d --name "$name" --entrypoint sleep \
    -v "$ROOT/build/tp-basic:/tmp/tp-basic:ro" -v "$ROOT/vars:/tmp/tp-vars:ro" \
    "$base_id" infinity >/dev/null

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
