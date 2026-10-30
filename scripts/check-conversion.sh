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

    if [[ ${#listed[@]} -eq 0 ]]; then note "$source lists no files"; fi

    local f rel
    if [[ -d $root ]]; then
        while IFS= read -r -d '' f; do
            rel=${f#"$root"/}
            printf '%s\n' "${listed[@]}" | grep -qxF -- "$rel" || note "unlisted: $f"
        done < <(find "$root" -type f -print0)
    fi
}
check_originals

# --- Later sections (understanding docs, ...) are added below ---------------

if [[ $fail -ne 0 ]]; then echo "check-conversion: FAILED" >&2; exit 1; fi
echo "check-conversion: ok"
