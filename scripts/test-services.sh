#!/usr/bin/env bash
# svc check in an init-less container: in one container of the pinned
# resurgentech/base-<distro> image (`sleep infinity`, `docker exec` only: no
# privileges, no extra mounts, no systemd as init, never), apply the
# `desktop_services` playbook (docker and vm_server after curl and
# ca-certificates) twice with the static tp-basic (bind-mounted read-only, with
# vars/container.toml, as test-idempotent.sh does).
#
# Gates: run 1 exits 0 and its prepare block has at least one `svc ` line;
# run 2 exits 0 with CHANGED 0. Then, when the image has systemctl,
# `systemctl is-enabled docker` and the kit's libvirt socket (libvirtd.socket,
# virtqemud.socket on the redhat family) must print `enabled` and run 1's
# prepare must not have promised `no systemctl: skipped`; when it has none,
# run 1's prepare must have said `no systemctl` (skipped, or yet).
#
# The prepare probe runs before the window, so on these bases (no systemctl
# until the packages bring it) it says `no systemctl yet: decided at run
# time, after this window's earlier ops`; a prepare line that promises
# `no systemctl: skipped` while systemctl exists afterwards fails (the engine
# printed that before 2026-11-04, telepatch 9ad103c). Every svc prepare line
# and every svc op result of run 1 (changed, or ok (skipped) when the package
# had already enabled the unit) is printed verbatim, so the wording can be
# recorded per distro. Usage errors exit 2.
#
#   scripts/test-services.sh <distro>
#
# Outputs (gitignored): build/test-services/<distro>/{preamble,run1,run2}.log
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HCL=$ROOT/../docker_images/docker-bake.hcl

die() { echo "test-services: $*" >&2; exit 2; }

[[ $# -eq 1 && -n ${1:-} ]] || die "usage: test-services.sh <distro>"
distro=$1

family=$(sed -nE "s/^ *$distro += \{ root = .*ansible = \"([^\"]+)\".*/\1/p" "$HCL")
[[ -n $family ]] || die "distro '$distro' not in $HCL DISTROS"

# The same preamble the Dockerfiles run before tp-basic.
case $family in
    debian) preamble='apt-get update --fix-missing && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y'; socket=libvirtd.socket ;;
    redhat) preamble='dnf clean all && dnf update -y'; socket=virtqemud.socket ;;
    arch) preamble='pacman -Syu --noconfirm'; socket=libvirtd.socket ;;
    *) die "unknown family '$family'" ;;
esac

[[ -x $ROOT/build/tp-basic ]] || die "build/tp-basic not found: run 'just musl' first"
[[ -f $ROOT/vars/container.toml ]] || die "vars/container.toml not found"
! command -v file >/dev/null || file "$ROOT/build/tp-basic" | grep -Eq 'statically linked|static-pie' || die "build/tp-basic is not a static binary: run 'just musl'"

base_ref=resurgentech/base-$distro:latest
base_id=$(docker image inspect -f '{{.Id}}' "$base_ref" 2>/dev/null) || die "$base_ref not found locally"
echo "base: $base_ref = $base_id"

out=$ROOT/build/test-services/$distro
mkdir -p "$out"
rm -f "$out"/*

name=tp-svc-$distro-$$
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker run -d --name "$name" --entrypoint sleep \
    -v "$ROOT/build/tp-basic:/tmp/tp-basic:ro" -v "$ROOT/vars:/tmp/tp-vars:ro" \
    "$base_id" infinity >/dev/null

echo "=== preamble ($family) ==="
docker exec "$name" sh -c "$preamble" >"$out/preamble.log" 2>&1 || { tail -20 "$out/preamble.log"; die "preamble failed (log: $out/preamble.log)"; }

run() { # n
    echo "=== run $1: tp-basic run desktop_services --local ==="
    local rc=0
    docker exec "$name" /tmp/tp-basic run desktop_services --local --vars /tmp/tp-vars/container.toml \
        >"$out/run$1.log" 2>&1 || rc=$?
    sed -n '/^HOST  *STATUS/,$p' "$out/run$1.log"
    return $rc
}

# changed_of <log> : the CHANGED cell of the table's single host row
changed_of() { awk '/^HOST  *STATUS/{getline; print $4; exit}' "$1"; }

rc1=0; run 1 || rc1=$?
if [[ $rc1 -ne 0 ]]; then
    tail -40 "$out/run1.log"
    echo "FAIL: first run exited $rc1 (log: $out/run1.log)"
    exit 1
fi
echo "--- run 1 prepare block ---"
grep '^== .* \[prepare\]' "$out/run1.log" || true
echo "--- run 1 svc prepare lines (verbatim) ---"
svc_lines=$(grep -E '^== .* \[prepare\] svc ' "$out/run1.log" || true)
if [[ -z $svc_lines ]]; then
    echo "FAIL: run 1's prepare block has no svc line (log: $out/run1.log)"
    exit 1
fi
printf '%s\n' "$svc_lines"
echo "--- run 1 svc op results ---"
awk '/^== .*\] #[0-9]+ svc /{h=$0; next} h && /^-> /{print h; print "  " $0; h=""}' "$out/run1.log"

rc2=0; run 2 || rc2=$?
grep '^== .* \[prepare\]' "$out/run2.log" || true
ch=$(changed_of "$out/run2.log")
if [[ $rc2 -ne 0 || $ch != 0 ]]; then
    echo "FAIL: second run exited $rc2, CHANGED ${ch:-?} (log: $out/run2.log)"
    echo "changed ops in the second run:"
    awk '/^== /{h=$0} /^-> changed/{print "  " h}' "$out/run2.log"
    exit 1
fi
echo "second run: exit 0, CHANGED 0"

# ---- after the runs ------------------------------------------------------------
echo "=== after the runs ==="
if docker exec "$name" sh -c 'command -v systemctl' >/dev/null 2>&1; then
    # systemctl reads the unit files and the enablement symlinks without a
    # running systemd, so is-enabled answers in an init-less container.
    fail=0
    for u in docker "$socket"; do
        rc=0; got=$(docker exec "$name" systemctl is-enabled "$u" 2>&1) || rc=$?
        echo "systemctl is-enabled $u: $(printf '%s' "$got" | tr '\n' ' ') (exit $rc)"
        [[ $got == enabled ]] || { echo "FAIL: systemctl is-enabled $u printed '$got', wanted enabled"; fail=1; }
    done
    if grep -q 'no systemctl: skipped' <<<"$svc_lines"; then
        echo "FAIL: systemctl exists after run 1, but its prepare promised 'no systemctl: skipped'"; fail=1
    fi
    [[ $fail -eq 0 ]] || exit 1
    echo "PASS: desktop_services on $distro, init-less: run 1 ok, run 2 CHANGED 0, docker and $socket enabled"
else
    echo "no systemctl in the image"
    if ! grep -Eq 'no systemctl: skipped|no systemctl yet: decided at run time' <<<"$svc_lines"; then
        echo "FAIL: no systemctl in the image, but run 1's prepare did not say 'no systemctl'"
        exit 1
    fi
    echo "PASS: desktop_services on $distro, init-less: run 1 ok (no systemctl: skipped), run 2 CHANGED 0"
fi
exit 0
