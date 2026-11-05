#!/usr/bin/env bash
# The tp-basic dist that ../docker_images builds images with (its bake named
# context `tp`, TP_DIST overrides): the static x86_64 musl binary, the vars
# file the image builds use, and a PROVENANCE file naming what it was built
# from.
#
#   scripts/dist.sh                  build build/dist/ and check it
#   scripts/dist.sh --check <file>   check a PROVENANCE file only
#   scripts/dist.sh --self-test      the checker against good and bad files
#
# build/dist/
#   tp-basic             as `just musl` builds it (static-pie, stripped)
#   vars/container.toml  copied from vars/
#   PROVENANCE           "key: value" lines:
#     tp_basic_url     this repo's origin, as an https URL with no credentials
#     tp_basic_hash    HEAD, with `_dirty` appended when the tree has changes
#                      (untracked files included; build/ and target/ are ignored)
#     telepatch_hash   HEAD of the telepatch checkout the Cargo.toml [patch]
#                      points at, `_dirty` likewise
#     tp_basic_sha256  sha256 of build/dist/tp-basic
#     rustc            `rustc --version`
# The check fails on a missing or empty field, a line that is not "key: value",
# or an absolute home path anywhere in the file. No secrets go in it: the URL
# is stripped of any user:password@ part.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FIELDS=(tp_basic_url tp_basic_hash telepatch_hash tp_basic_sha256 rustc)

die() { echo "dist: $*" >&2; exit 2; }

# check_provenance <file> : 0 when every field is present once and non-empty.
check_provenance() {
    local f=$1 bad=0 k n v
    [[ -s $f ]] || { echo "dist: $f is missing or empty" >&2; return 1; }
    for k in "${FIELDS[@]}"; do
        n=$(grep -c "^$k: " "$f" || true)
        v=$(sed -n "s/^$k: //p" "$f" | head -n 1)
        if [[ $n -ne 1 || -z $v ]]; then
            echo "dist: PROVENANCE field '$k' missing, empty or repeated" >&2; bad=1
        fi
    done
    if grep -vqE '^[a-z0-9_]+: .+$' "$f"; then
        echo "dist: PROVENANCE has a line that is not 'key: value'" >&2; bad=1
    fi
    if grep -qE '(^|[^A-Za-z0-9])/(home|root|Users)/' "$f"; then
        echo "dist: PROVENANCE names an absolute home path" >&2; bad=1
    fi
    return $bad
}

# https_url <git remote url> : git@host:path and ssh:// as https, credentials dropped.
https_url() {
    printf '%s\n' "$1" | sed -E \
        -e 's#^git@([^:]+):#https://\1/#' \
        -e 's#^ssh://(git@)?([^/]+)/#https://\2/#' \
        -e 's#^(https?://)[^/@]+@#\1#'
}

# rev_of <dir> : HEAD of the repo at <dir>, `_dirty` when it has changes.
rev_of() {
    local h
    h=$(git -C "$1" rev-parse HEAD) || return 1
    [[ -z $(git -C "$1" status --porcelain) ]] || h=${h}_dirty
    printf '%s\n' "$h"
}

self_test() {
    local t fails=0
    t=$(mktemp -d)
    good() {
        printf '%s\n' 'tp_basic_url: https://github.com/resurgentech/tp_basic.git' \
            'tp_basic_hash: 0123456789abcdef0123456789abcdef01234567' \
            'telepatch_hash: 89abcdef0123456789abcdef0123456789abcdef_dirty' \
            'tp_basic_sha256: 00ff' 'rustc: rustc 1.99.1 (abc 2026-10-01)'
    }
    case_() { # name want(0|1) file
        local got=0
        check_provenance "$3" 2>/dev/null || got=1
        if [[ $got -eq $2 ]]; then echo "ok   $1"; else echo "FAIL $1 (got $got, wanted $2)"; fails=1; fi
    }
    good >"$t/good"; case_ "complete file" 0 "$t/good"
    good | grep -v '^rustc' >"$t/norustc"; case_ "missing rustc" 1 "$t/norustc"
    good | sed 's/^telepatch_hash: .*/telepatch_hash: /' >"$t/empty"; case_ "empty telepatch_hash" 1 "$t/empty"
    { good; echo 'rustc: again'; } >"$t/twice"; case_ "repeated field" 1 "$t/twice"
    { good; echo 'path: /home/someone/repo'; } >"$t/home"; case_ "home path" 1 "$t/home"
    { good; echo 'not a field'; } >"$t/junk"; case_ "junk line" 1 "$t/junk"
    : >"$t/none"; case_ "empty file" 1 "$t/none"
    [[ $(https_url git@github.com:resurgentech/tp_basic.git) == https://github.com/resurgentech/tp_basic.git ]] \
        && echo "ok   url: git@ form" || { echo "FAIL url: git@ form"; fails=1; }
    [[ $(https_url https://user:secret@github.com/x/y.git) == https://github.com/x/y.git ]] \
        && echo "ok   url: credentials dropped" || { echo "FAIL url: credentials dropped"; fails=1; }
    rm -f "$t"/*; rmdir "$t"
    return $fails
}

case ${1:-} in
    --self-test) self_test; exit $? ;;
    --check) [[ -n ${2:-} ]] || die "usage: dist.sh --check <file>"; check_provenance "$2"; exit $? ;;
    "") ;;
    *) die "usage: dist.sh [--check <file> | --self-test]" ;;
esac

cd "$ROOT"
# The telepatch checkout of the [patch] block (the crate path's repo).
patch_path=$(sed -nE 's/^telepatch = \{ path = "([^"]+)" \}.*/\1/p' Cargo.toml | head -n 1)
[[ -n $patch_path ]] || die "no telepatch [patch] path in Cargo.toml"
[[ -d $patch_path ]] || die "telepatch [patch] path $patch_path not found"

cargo build --release --target x86_64-unknown-linux-musl --bin tp-basic
dist=$ROOT/build/dist
mkdir -p "$dist/vars"
cp target/x86_64-unknown-linux-musl/release/tp-basic "$dist/tp-basic"
cp vars/container.toml "$dist/vars/container.toml"
info=$(file -b "$dist/tp-basic")
case "$info" in
    *"statically linked"*|*"static-pie linked"*) ;;
    *) die "build/dist/tp-basic is not static: $info" ;;
esac

url=$(https_url "$(git remote get-url origin)")
{
    echo "tp_basic_url: $url"
    echo "tp_basic_hash: $(rev_of "$ROOT")"
    echo "telepatch_hash: $(rev_of "$patch_path")"
    echo "tp_basic_sha256: $(sha256sum "$dist/tp-basic" | cut -d' ' -f1)"
    echo "rustc: $(rustc --version)"
} >"$dist/PROVENANCE.tmp"
mv -f "$dist/PROVENANCE.tmp" "$dist/PROVENANCE"

echo "== build/dist/PROVENANCE =="
cat "$dist/PROVENANCE"
check_provenance "$dist/PROVENANCE" || die "PROVENANCE check failed"
echo "dist: ok ($dist)"
