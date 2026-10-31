#!/usr/bin/env bash
# Verify conversion/ against its recorded provenance. Run from the repo root.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0
note() { echo "check-conversion: $*" >&2; fail=1; }

# --- Section: originals (conversion/ansible vs conversion/SOURCE) -----------
# SOURCE: header lines `repo: <url>` and `commit: <sha>`, then sha256sum-format
# lines `<hash>  <path relative to conversion/ansible/>`, sorted.
check_originals() {
    local source=conversion/SOURCE root=conversion/ansible
    if [[ ! -f $source ]]; then note "missing $source"; return; fi
    grep -q '^repo: .\+' "$source" || note "$source: no 'repo:' line"
    grep -Eq '^commit: [0-9a-f]{40}$' "$source" || note "$source: no 40-hex 'commit:' line"

    local -a listed=()
    local hash path line
    while IFS= read -r line; do
        [[ $line =~ ^([0-9a-f]{64})\ \ (.+)$ ]] || { note "$source: malformed line: $line"; continue; }
        hash=${BASH_REMATCH[1]}; path=${BASH_REMATCH[2]}
        listed+=("$path")
        if [[ ! -f $root/$path ]]; then note "missing: $root/$path"; continue; fi
        [[ $(sha256sum < "$root/$path" | cut -d' ' -f1) == "$hash" ]] || note "drifted: $root/$path"
    done < <(grep -Ev '^(repo|commit): |^$' "$source")

    # An empty list is the finished state: every ported role has left.
    originals_count=${#listed[@]}

    local f rel
    if [[ -d $root ]]; then
        while IFS= read -r -d '' f; do
            rel=${f#"$root"/}
            printf '%s\n' "${listed[@]}" | grep -qxF -- "$rel" || note "unlisted: $f"
        done < <(find "$root" -type f -print0)
    fi
}
check_originals

# --- Section: understanding docs (conversion/*.md) -------------------------
# Delegated to `tp check-understanding` (levels, dated sources, hedge words,
# a Decision: line). tp_basic sits next to telepatch; override with
# TP="path/to/tp" to use an installed binary.
tp_check() {
    if [[ -n ${TP:-} ]]; then
        $TP check-understanding "$@"
    else
        cargo run -q --manifest-path ../telepatch/Cargo.toml -p tp -- check-understanding "$@"
    fi
}
check_understanding_docs() {
    local -a docs=()
    local f out
    shopt -s nullglob
    docs=(conversion/*.md)
    shopt -u nullglob
    # Originals are only kept while a doc still needs them.
    if [[ ${#docs[@]} -eq 0 ]]; then
        if [[ ${originals_count:-0} -gt 0 ]]; then note "originals under conversion/ansible but no understanding doc: conversion/*.md"; fi
        return
    fi
    for f in "${docs[@]}"; do
        if ! out=$(tp_check "$f" 2>&1); then
            note "$f: tp check-understanding failed"
            printf '%s\n' "$out" >&2
        fi
    done
}
check_understanding_docs

# --- Later sections are added below ------------------------------------------

if [[ $fail -ne 0 ]]; then echo "check-conversion: FAILED" >&2; exit 1; fi
echo "check-conversion: ok"
