# Sourced by the docker scripts that run the telepatch side.
#
#   dist_require <dir>
#       <dir> (build/dist, tp_basic's `just dist` output) must hold an
#       executable tp-basic that is static, vars/container.toml and a
#       non-empty PROVENANCE. Returns 2 with a message on stderr otherwise.
#       A `_dirty` PROVENANCE is fine; it is printed, never gated.
#   preamble_of <Dockerfile>
#       Prints the shell the Dockerfile's first RUN runs before tp-basic
#       (mounts and line continuations dropped, spaces squeezed, trailing
#       `&&` removed), e.g. `dnf clean all && dnf update -y`.
#   preamble_check <family> <Dockerfile> <expected>
#       Returns 2 with a message naming both when preamble_of differs from
#       <expected>, the copy a script keeps for its own `docker exec`.

dist_require() {
    local d=$1 f
    for f in tp-basic vars/container.toml PROVENANCE; do
        [[ -e $d/$f ]] || { echo "$d/$f not found: run 'just dist' first" >&2; return 2; }
    done
    [[ -x $d/tp-basic ]] || { echo "$d/tp-basic is not executable: run 'just dist' first" >&2; return 2; }
    [[ -s $d/PROVENANCE ]] || { echo "$d/PROVENANCE is empty: run 'just dist' first" >&2; return 2; }
    if command -v file >/dev/null && ! file "$d/tp-basic" | grep -Eq 'statically linked|static-pie'; then
        echo "$d/tp-basic is not a static binary: run 'just dist' first" >&2
        return 2
    fi
    echo "dist: $d ($(sed -n 's/^tp_basic_hash: //p' "$d/PROVENANCE" | head -n 1))"
}

preamble_of() {
    awk '
        !run && /^RUN / { run = 1 }
        run { l = $0; cont = (l ~ /\\$/); sub(/\\$/, "", l); s = s " " l; if (!cont) exit }
        END {
            sub(/^ *RUN +/, "", s)
            gsub(/--mount=[^ ]+/, "", s)
            sub(/ *\/tmp\/tp-basic run.*/, "", s)
            gsub(/ +/, " ", s)
            sub(/^ /, "", s); sub(/ *&&$/, "", s)
            print s
        }' "$1"
}

preamble_check() {
    local family=$1 file=$2 want=$3 got
    got=$(preamble_of "$file")
    if [[ $got != "$want" ]]; then
        echo "the $family preamble drifted from $file:" >&2
        echo "  file:   $got" >&2
        echo "  script: $want" >&2
        echo "update the script's copy (or the Dockerfile) so both run the same" >&2
        return 2
    fi
}
