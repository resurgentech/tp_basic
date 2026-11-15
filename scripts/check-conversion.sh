#!/usr/bin/env bash
# Verify conversion/ against its recorded provenance. Run from the repo root.
#   scripts/check-conversion.sh              check conversion/
#   scripts/check-conversion.sh --self-test  the originals check on fixtures
# Env (the self-test's seams): CONV_DIR (default conversion), ANSIBLE2_DIR
# (default ../ansible_labtwo_2, the sibling checkout the second source was
# taken from; optional).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

CONV_DIR=${CONV_DIR:-conversion}
ANSIBLE2_DIR=${ANSIBLE2_DIR:-../ansible_labtwo_2}

fail=0
note() { echo "check-conversion: $*" >&2; fail=1; }

# tree_hash <dir> : sha256 of the sorted `sha256sum` listing of the dir's files,
# run inside the dir (find . -type f, LC_ALL=C order).
tree_hash() {
    (cd "$1" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
}

# --- Section: originals (conversion/ansible vs conversion/SOURCE) -----------
# SOURCE is read top to bottom; `#` comments and blank lines are skipped.
#   repo: <url> / commit: <40 hex>       the first source: a git commit
#   source: <name> / head: <40 hex> /    a further source: a local checkout
#     state: working tree of <7 hex>       whose tree was dirty (head's first 7
#                                          hex must be the state's)
#   <64 hex>  <path under conversion/ansible/>   a sha256sum line, belonging to
#                                          the source above it
#   tree-equal: <dir> <64 hex>           the dir's tree hash (see tree_hash),
#                                          which is also that of the same dir
#                                          in ../ansible_labtwo_2 when present
# Every listed file must exist and match; every file under conversion/ansible/
# must be listed.
check_originals() {
    local source=$CONV_DIR/SOURCE root=$CONV_DIR/ansible
    if [[ ! -f $source ]]; then note "missing $source"; return; fi

    local -a listed=()
    local hash path line dir want got
    local have_repo=0 have_commit=0 sources=1 have_head=1 have_state=1 head="" cur=first
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -z ${line//[[:space:]]/} || $line == '#'* ]] && continue
        if [[ $line =~ ^repo:\ .+$ ]]; then have_repo=1
        elif [[ $line =~ ^commit:\ ([0-9a-f]{40})$ ]]; then have_commit=1
        elif [[ $line =~ ^source:\ ([A-Za-z0-9_.-]+)$ ]]; then
            if [[ $have_head -eq 0 || $have_state -eq 0 ]]; then note "$source: source '$cur' lacks head: or state:"; fi
            cur=${BASH_REMATCH[1]}; sources=$((sources + 1)); have_head=0 have_state=0 head=""
        elif [[ $line =~ ^head:\ ([0-9a-f]{40})$ ]]; then have_head=1; head=${BASH_REMATCH[1]}
        elif [[ $line =~ ^state:\ working\ tree\ of\ ([0-9a-f]{7})$ ]]; then
            have_state=1
            [[ -n $head && $head == "${BASH_REMATCH[1]}"* ]] || note "$source: state '$line' does not match head: of '$cur'"
        elif [[ $line =~ ^tree-equal:\ ([^[:space:]]+)\ ([0-9a-f]{64})$ ]]; then
            dir=${BASH_REMATCH[1]}; want=${BASH_REMATCH[2]}
            if [[ ! -d $root/$dir ]]; then note "tree-equal: missing $root/$dir"; continue; fi
            got=$(tree_hash "$root/$dir")
            [[ $got == "$want" ]] || note "tree-equal: $root/$dir is $got, SOURCE says $want"
            # the sibling checkout is optional (a clone without it still checks)
            if [[ -d $ANSIBLE2_DIR/$dir ]]; then
                got=$(tree_hash "$ANSIBLE2_DIR/$dir")
                [[ $got == "$want" ]] || note "tree-equal: $ANSIBLE2_DIR/$dir is $got, SOURCE says $want"
            fi
        elif [[ $line =~ ^([0-9a-f]{64})\ \ (.+)$ ]]; then
            hash=${BASH_REMATCH[1]}; path=${BASH_REMATCH[2]}
            listed+=("$path")
            if [[ ! -f $root/$path ]]; then note "missing: $root/$path"; continue; fi
            [[ $(sha256sum < "$root/$path" | cut -d' ' -f1) == "$hash" ]] || note "drifted: $root/$path"
        else
            note "$source: malformed line: $line"
        fi
    done <"$source"
    [[ $have_repo -eq 1 ]] || note "$source: no 'repo:' line"
    [[ $have_commit -eq 1 ]] || note "$source: no 40-hex 'commit:' line"
    if [[ $have_head -eq 0 || $have_state -eq 0 ]]; then note "$source: source '$cur' lacks head: or state:"; fi

    # An empty list is the finished state: every ported role has left.
    originals_count=${#listed[@]}

    local f rel
    if [[ -d $root ]]; then
        while IFS= read -r -d '' f; do
            rel=${f#"$root"/}
            if [[ ${#listed[@]} -eq 0 ]] || ! printf '%s\n' "${listed[@]}" | grep -qxF -- "$rel"; then note "unlisted: $f"; fi
        done < <(find "$root" -type f -print0)
    fi
}

# --- the originals section's self-test ----------------------------------------
# Fixtures in a scratch dir, through the CONV_DIR and ANSIBLE2_DIR seams; the
# real conversion/ and ../ansible_labtwo_2 are never read.
self_test() {
    local t fails=0
    t=$(mktemp -d)
    trap 'rm -rf "$t"' RETURN
    local c=$t/conv a2=$t/a2 h1 h2 hp ht
    mkdir -p "$c/ansible/roles/r/tasks" "$c/ansible/playbooks" "$a2/roles/r/tasks"
    printf 'one\n' >"$c/ansible/roles/r/tasks/main.yml"; cp "$c/ansible/roles/r/tasks/main.yml" "$a2/roles/r/tasks/main.yml"
    printf 'play\n' >"$c/ansible/playbooks/p.yml"
    h1=$(sha256sum <"$c/ansible/roles/r/tasks/main.yml" | cut -d' ' -f1)
    hp=$(sha256sum <"$c/ansible/playbooks/p.yml" | cut -d' ' -f1)
    ht=$(tree_hash "$c/ansible/roles/r")
    h2=0123456789abcdef0123456789abcdef01234567
    write_source() { # $1 = extra lines appended
        {
            echo "repo: git@example.invalid:x/y.git"
            echo "commit: $h2"
            echo "$h1  roles/r/tasks/main.yml"
            echo
            echo "# a second source"
            echo "source: second"
            echo "head: $h2"
            echo "state: working tree of ${h2:0:7}"
            echo "$hp  playbooks/p.yml"
            echo "tree-equal: roles/r $ht"
            [[ -z ${1:-} ]] || echo "$1"
        } >"$c/SOURCE"
    }
    # case <name> <want: ok|fail> <pattern the output must hold, or ''>
    case_() {
        local name=$1 want=$2 pat=${3:-} rc=0 out
        out=$( (CONV_DIR=$c ANSIBLE2_DIR=$a2; fail=0; originals_count=0; check_originals; [[ $fail -eq 0 ]]) 2>&1) || rc=$?
        if [[ $want == ok && $rc -eq 0 ]] || [[ $want == fail && $rc -ne 0 ]]; then echo "ok   $name"
        else echo "FAIL $name: wanted $want, rc $rc"; fails=1; fi
        if [[ -n $pat ]] && ! grep -qE -- "$pat" <<<"$out"; then echo "FAIL $name: output lacks /$pat/"; fails=1; fi
        [[ -z $out ]] || sed 's/^/     | /' <<<"$out"
    }
    write_source; case_ "two sources, files and trees match" ok
    # the real SOURCE shape: the first commit: line is the one test-vm-oracle.sh reads
    if [[ $(sed -n 's/^commit: //p' "$c/SOURCE" | head -1) == "$h2" ]]; then echo "ok   first commit: line unchanged by the second source"; else echo "FAIL commit line"; fails=1; fi
    printf 'two\n' >>"$c/ansible/roles/r/tasks/main.yml"
    case_ "a drifted file is flagged" fail 'drifted: .*roles/r/tasks/main.yml'
    printf 'one\n' >"$c/ansible/roles/r/tasks/main.yml"
    printf 'x\n' >"$c/ansible/roles/r/tasks/extra.yml"
    case_ "an unlisted file is flagged" fail 'unlisted: .*extra.yml'
    case_ "tree-equal sees the extra file too" fail 'tree-equal: '
    rm "$c/ansible/roles/r/tasks/extra.yml"
    printf 'two\n' >"$a2/roles/r/tasks/main.yml"
    case_ "the sibling's role dir differing is flagged" fail 'tree-equal: .*a2/roles/r'
    printf 'one\n' >"$a2/roles/r/tasks/main.yml"
    mv "$a2" "$t/a2.gone"
    case_ "no sibling checkout: still ok" ok
    mv "$t/a2.gone" "$a2"
    write_source "tree-equal: roles/nope $ht"; case_ "tree-equal of a missing dir" fail 'tree-equal: missing'
    write_source "tree-equal: roles/r ${ht:0:60}"; case_ "a short tree hash is malformed" fail 'malformed line'
    write_source; sed -i '/^state:/d' "$c/SOURCE"; case_ "a source without state: is flagged" fail "lacks head: or state:"
    write_source; sed -i 's/^state: .*/state: working tree of 1111111/' "$c/SOURCE"; case_ "state not matching head: is flagged" fail 'does not match head'
    write_source; sed -i '/^repo:/d' "$c/SOURCE"; case_ "no repo: line is flagged" fail "no 'repo:'"
    write_source; sed -i 's/^playbooks/x/; s/  playbooks\/p.yml/  playbooks\/gone.yml/' "$c/SOURCE"; case_ "a listed file that is missing" fail 'missing: .*gone.yml'
    return $fails
}

if [[ ${1:-} == --self-test ]]; then self_test; exit $?; fi

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
    docs=("$CONV_DIR"/*.md)
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
