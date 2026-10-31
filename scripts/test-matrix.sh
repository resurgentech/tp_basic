#!/usr/bin/env bash
# Not a gate. Runs the equivalence oracle (test-container.sh) for every
# container of every distro's set in ../docker_images/docker-bake.hcl,
# JOBS distros at a time, and writes a pass/diff table to build/matrix.md.
#
#   scripts/test-matrix.sh [jobs]        (default 3)
#
# Result per cell: pass (gating diff empty), diff (gating diff), error
# (a build or capture failed before a diff was possible).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

jobs=${1:-3}
hcl=../docker_images/docker-bake.hcl
out=build/matrix
mkdir -p "$out"
: > "$out/rows.txt"

# DISTROS lines: `name = { root = "...", ..., set = "default" }`
distros() { sed -nE 's/^ *([a-z0-9]+) += \{ root = .*/\1/p' "$hcl"; }
set_of() { sed -nE "s/^ *$1 += \{ root = .*set = \"([^\"]+)\".*/\1/p" "$hcl"; }
# SETS lines: `default = ["dev_base", "kernel_build", "rust_build"]`
containers_of() { sed -nE "s/^ *$1 += \[(.*)\].*/\1/p" "$hcl" | tr -d '" ' | tr ',' ' '; }

run_distro() {
    local d=$1 s c log r
    s=$(set_of "$d")
    for c in $(containers_of "$s"); do
        log=$out/$c-$d.log
        if bash scripts/test-container.sh "$d" "$c" >"$log" 2>&1; then
            r=pass
        elif grep -q '^GATING' "$log"; then
            r=diff
        else
            r=error
        fi
        echo "| $d | $c | $r | \`$log\` |" >>"$out/rows.txt"
        echo "matrix: $c on $d: $r" >&2
    done
}
export -f run_distro set_of containers_of
export hcl out

distros | xargs -P "$jobs" -I{} bash -c 'run_distro "$@"' _ {}

{
    echo "# Equivalence matrix"
    echo
    echo "ansible: ${ANSIBLE_SHA:-master}"
    echo
    echo "| distro | container | result | log |"
    echo "|---|---|---|---|"
    LC_ALL=C sort "$out/rows.txt"
} >build/matrix.md
cat build/matrix.md
