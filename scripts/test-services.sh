#!/usr/bin/env bash
# svc check in an init-less container: in one container of the pinned
# resurgentech/base-<distro> image (`sleep infinity`, `docker exec` only: no
# privileges, no extra mounts, no systemd as init, never), apply the
# `desktop_services` playbook (docker and vm_server after curl and
# ca-certificates) twice with the static tp-basic (copied in with `docker cp`, with
# build/dist/vars/container.toml, from `just dist`, as test-idempotent.sh does).
#
# Then, in the same container, the test-only `services_vm` playbook (units,
# a drop-in, enabled/disabled/masked states, a guarded restart and reload;
# `h.unit` and the svc states offline) is applied twice: run 1 exits 0, its
# unit writes say `will create`, no daemon-reload is tried (no running
# systemd), the guarded restart and reload end `ok (skipped)` (or
# `skipped (when ..)`), and with systemctl `is-enabled` of tp-probe.service,
# tp-probe-off.service and tp-probe-masked.service print enabled, disabled and
# masked; run 2 is CHANGED 0 with both guarded ops `skipped (when ..)`.
# Logs: build/test-services/<distro>/{sv1,sv2}.log.
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
# Env: DI_SHA  docker_images commit the hcl is read from (required; just passes ported_docker_images)
#
# Outputs (gitignored): build/test-services/<distro>/{preamble,run1,run2}.log
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/docker-images.sh
source "$ROOT/scripts/lib/docker-images.sh"
# shellcheck source=lib/dist-input.sh
source "$ROOT/scripts/lib/dist-input.sh"

die() { echo "test-services: $*" >&2; exit 2; }

# docker only in a tp-* VM (scripts/docker-vm.sh): refused before anything else
# shellcheck source=lib/docker-guard.sh
source "$ROOT/scripts/lib/docker-guard.sh"
docker_guard

[[ $# -eq 1 && -n ${1:-} ]] || die "usage: test-services.sh <distro>"
distro=$1

# the pinned docker_images commit, exported once (never the working tree)
di_export "$ROOT" || exit 2
HCL=$DI_DIR/docker-bake.hcl

family=$(sed -nE "s/^ *$distro += \{ root = .*ansible = \"([^\"]+)\".*/\1/p" "$HCL")
[[ -n $family ]] || die "distro '$distro' not in $HCL DISTROS"

# The preamble ../docker_images/Dockerfiles/telepatch.<family> runs before
# tp-basic; checked against the file below, so a drift fails here.
case $family in
    debian) preamble='apt-get update --fix-missing && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y'; socket=libvirtd.socket ;;
    redhat) preamble='dnf clean all && dnf update -y'; socket=virtqemud.socket ;;
    arch) preamble='pacman -Syu --noconfirm'; socket=libvirtd.socket ;;
    *) die "unknown family '$family'" ;;
esac

dist_require "$ROOT/build/dist" || exit 2
# the copy above must be what the working tree's Dockerfile runs (fails on drift)
preamble_check "$family" "$ROOT/../docker_images/Dockerfiles/telepatch.$family" "$preamble" || exit 2

base_ref=resurgentech/base-$distro:latest
di_base "$distro" || exit 2
base_id=$(docker image inspect -f '{{.Id}}' "$base_ref" 2>/dev/null) || die "$base_ref not found in the VM's daemon"
echo "base: $base_ref = $base_id"

out=$ROOT/build/test-services/$distro
mkdir -p "$out"
rm -f "$out"/*

name=tp-svc-$distro-$$
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
# the dist goes in with docker cp (no bind mount: the daemon is the VM's)
docker create --name "$name" --entrypoint sleep "$base_id" infinity >/dev/null
docker cp -q "$ROOT/build/dist/tp-basic" "$name:/tmp/tp-basic"
docker cp -q "$ROOT/build/dist/vars" "$name:/tmp/tp-vars"
docker start "$name" >/dev/null

echo "=== preamble ($family) ==="
docker exec "$name" sh -c "$preamble" >"$out/preamble.log" 2>&1 || { tail -20 "$out/preamble.log"; die "preamble failed (log: $out/preamble.log)"; }

run() { # n [playbook [log prefix]]
    local pb=${2:-desktop_services} log=${3:-run}
    echo "=== run $1: tp-basic run $pb --local ==="
    local rc=0
    docker exec "$name" /tmp/tp-basic run "$pb" --local --vars /tmp/tp-vars/container.toml \
        >"$out/$log$1.log" 2>&1 || rc=$?
    sed -n '/^HOST  *STATUS/,$p' "$out/$log$1.log"
    return $rc
}

# result_of <log> <op description> : the `-> ...` line that ends the op whose
# header names the description (`svc tp-probe.service restart`), the first one
result_of() { awk -v d=" $2 ==" '/^== /{h=(index($0, d) > 0); next} h && /^-> /{print; exit}' "$1"; }

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
    have_systemctl=1
    echo "PASS: desktop_services on $distro, init-less: run 1 ok, run 2 CHANGED 0, docker and $socket enabled"
else
    have_systemctl=0
    echo "no systemctl in the image"
    if ! grep -Eq 'no systemctl: skipped|no systemctl yet: decided at run time' <<<"$svc_lines"; then
        echo "FAIL: no systemctl in the image, but run 1's prepare did not say 'no systemctl'"
        exit 1
    fi
    echo "PASS: desktop_services on $distro, init-less: run 1 ok (no systemctl: skipped), run 2 CHANGED 0"
fi

# ---- services_vm: unit files and the svc states offline ------------------------
# Same container: no init, so the unit files are written and verified, the
# enable, disable and mask links are made offline, start, stop, restart and
# reload are skipped, and no daemon-reload is tried.
echo "=== services_vm, init-less ==="
rc1=0; run 1 services_vm sv || rc1=$?
if [[ $rc1 -ne 0 ]]; then
    tail -40 "$out/sv1.log"
    echo "FAIL: services_vm run 1 exited $rc1 (log: $out/sv1.log)"
    exit 1
fi
echo "--- services_vm run 1 prepare block (verbatim) ---"
grep '^== .* \[prepare\]' "$out/sv1.log" || true
echo "--- services_vm run 1 op results ---"
fail=0
for d in "svc tp-probe.service" "svc tp-probe.service restart" "svc tp-probe.service reload" "svc tp-probe-off" "svc tp-probe-masked"; do
    echo "  $d: $(result_of "$out/sv1.log" "$d")"
done
for u in tp-probe.service tp-probe-off.service tp-probe.service.d/override.conf; do
    if ! grep -qF "[prepare] unit $u: will create ==" "$out/sv1.log"; then
        echo "FAIL: run 1's prepare lacks 'unit $u: will create'"; fail=1
    fi
done
# the offline skip lines: the guarded restart and reload did nothing, said so
for a in restart reload; do
    r=$(result_of "$out/sv1.log" "svc tp-probe.service $a")
    if [[ $r != '-> ok (skipped)' && $r != '-> skipped (when '* ]]; then
        echo "FAIL: run 1's svc tp-probe.service $a ended '$r', wanted '-> ok (skipped)' or '-> skipped (when ..)'"; fail=1
    fi
done
if grep -qE 'daemon-reload|has not been booted' "$out/sv1.log"; then
    echo "FAIL: run 1 mentions daemon-reload or 'has not been booted' (no running systemd: nothing to reload)"
    grep -nE 'daemon-reload|has not been booted' "$out/sv1.log"; fail=1
fi
if [[ $have_systemctl -eq 1 ]]; then
    for pair in tp-probe.service:enabled tp-probe-off.service:disabled tp-probe-masked.service:masked; do
        u=${pair%%:*} want=${pair##*:}
        rc=0; got=$(docker exec "$name" systemctl is-enabled "$u" 2>&1) || rc=$?
        echo "systemctl is-enabled $u: $(printf '%s' "$got" | tr '\n' ' ') (exit $rc)"
        [[ $got == "$want" ]] || { echo "FAIL: systemctl is-enabled $u printed '$got', wanted $want"; fail=1; }
    done
fi
for f in /etc/systemd/system/tp-probe.service /etc/systemd/system/tp-probe.service.d/override.conf /etc/systemd/system/tp-probe-off.service /etc/tp-probe.conf; do
    docker exec "$name" test -f "$f" || { echo "FAIL: $f is missing"; fail=1; }
done
[[ $fail -eq 0 ]] || exit 1

rc2=0; run 2 services_vm sv || rc2=$?
grep '^== .* \[prepare\]' "$out/sv2.log" || true
ch=$(changed_of "$out/sv2.log")
if [[ $rc2 -ne 0 || $ch != 0 ]]; then
    echo "FAIL: services_vm run 2 exited $rc2, CHANGED ${ch:-?} (log: $out/sv2.log)"
    awk '/^== /{h=$0} /^-> changed/{print "  " h}' "$out/sv2.log"
    exit 1
fi
for a in restart reload; do
    r=$(result_of "$out/sv2.log" "svc tp-probe.service $a")
    echo "  run 2 svc tp-probe.service $a: $r"
    [[ $r == '-> skipped (when '* ]] || { echo "FAIL: run 2's svc tp-probe.service $a ended '$r', wanted '-> skipped (when ..)'"; fail=1; }
done
[[ $fail -eq 0 ]] || exit 1
echo "PASS: services_vm on $distro, init-less: run 1 ok (units written, restart and reload skipped), run 2 CHANGED 0 (guards skipped)"
exit 0
