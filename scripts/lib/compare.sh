# shellcheck shell=bash
# The oracle's comparison, shared by scripts/test-container.sh and
# scripts/test-vm-oracle.sh (source it; it runs nothing). It runs on this
# machine only: just scripts/image-state.sh goes into a container or VM.

# apply_intended <dir> <intended file> [<distro>] : writes <dir>/ansible.intended.state,
# ansible.state with the intended differences applied, and prints one line per
# applied difference on stdout and each problem on stderr, as "ERR <text>".
# Returns 1 when any line was a problem (the applied ones are still written).
#
# File format, one per line: "+<section>|<line>" (telepatch adds the line) or
# "-<section>|<line>" (telepatch lacks it); "#" comments and blank lines are
# skipped. <section> is the text between "== " and " ==" in the capture.
# A line may start with a distro scope, "[rockylinux9,rockylinux10]+sec|line":
# it applies only when <distro> (the cell's distro id) is listed, and is
# ignored otherwise (no check at all). A malformed scope (unclosed, empty list
# or member, anything but [a-z0-9] in a member) is an error naming file:line.
#
# A section that is already in LC_ALL=C sort order in ansible.state (every
# section image-state.sh sorts) gets its "+" lines merged with
# `LC_ALL=C sort`; any other section (apt sources, in file order) gets them
# appended at its end. A "-" line removes one occurrence.
apply_intended() {
    local dir=$1 file=$2 distro=${3:-} rc=0 line kind rest sect text n=0 i lineno=0 scope members m
    local -A adds=() dels=() known=()
    local t; t=$(mktemp -d)
    while IFS= read -r line || [[ -n $line ]]; do
        known[${line:3:${#line}-6}]=1
    done < <(grep -E '^== .* ==$' "$dir/ansible.state")
    while IFS= read -r line || [[ -n $line ]]; do
        lineno=$((lineno + 1))
        [[ -z ${line//[[:space:]]/} || $line == '#'* ]] && continue
        if [[ $line == '['* ]]; then
            scope=${line%%]*}
            if [[ $scope == "$line" ]]; then
                echo "ERR bad distro scope (unclosed '[') at $file:$lineno: $line" >&2; rc=1; continue
            fi
            members=${scope:1}
            line=${line#*]}
            if [[ ! $members =~ ^[a-z0-9]+(,[a-z0-9]+)*$ ]]; then
                echo "ERR bad distro scope (want [distro,distro] of [a-z0-9]) at $file:$lineno: [$members]$line" >&2; rc=1; continue
            fi
            # a scoped line on a cell whose distro is not listed is ignored
            [[ ,$members, == *",$distro,"* && -n $distro ]] || continue
        fi
        kind=${line:0:1}; rest=${line:1}; sect=${rest%%|*}; text=${rest#*|}
        if [[ ($kind != + && $kind != -) || $rest != *'|'* ]]; then
            echo "ERR bad intended line (want +section|line or -section|line): $line" >&2; rc=1; continue
        fi
        if [[ -z ${known[$sect]:-} ]]; then
            echo "ERR unknown section '$sect' in intended line: $line" >&2; rc=1; continue
        fi
        if [[ $kind == + ]]; then adds[$sect]+="$text"$'\n'
        else
            if ! sed -n "/^== $(printf '%s' "$sect" | sed 's/[][\.*^$/]/\\&/g') ==\$/,/^== /p" "$dir/ansible.state" | grep -qxF -- "$text"; then
                echo "ERR intended removal not on the ansible side: $line" >&2; rc=1; continue
            fi
            dels[$sect]+="$text"$'\n'
        fi
        echo "$line"
    done <"$file"
    # one pass over ansible.state: a section at a time into $t/sec.<n>
    awk -v d="$t" '/^== .* ==$/ { n++; print substr($0, 4, length($0) - 6) > (d "/name." n); next }
                   { print > (d "/sec." (n + 0)) }
                   END { print n + 0 > (d "/count") }' "$dir/ansible.state"
    : >"$dir/ansible.intended.state"
    [[ -f $t/sec.0 ]] && cat "$t/sec.0" >>"$dir/ansible.intended.state"
    for ((i = 1; i <= $(<"$t/count"); i++)); do
        sect=$(<"$t/name.$i")
        [[ -f $t/sec.$i ]] || : >"$t/sec.$i"
        if [[ -n ${dels[$sect]:-} ]]; then
            printf '%s' "${dels[$sect]}" >"$t/del"
            awk 'NR == FNR { d[$0]++; next } d[$0] > 0 { d[$0]--; next } { print }' "$t/del" "$t/sec.$i" >"$t/sec.$i.new"
            mv "$t/sec.$i.new" "$t/sec.$i"
        fi
        if [[ -n ${adds[$sect]:-} ]]; then
            if LC_ALL=C sort -c "$t/sec.$i" 2>/dev/null; then
                { cat "$t/sec.$i"; printf '%s' "${adds[$sect]}"; } | LC_ALL=C sort >"$t/sec.$i.new"
                mv "$t/sec.$i.new" "$t/sec.$i"
            else
                printf '%s' "${adds[$sect]}" >>"$t/sec.$i"
            fi
        fi
        { printf '== %s ==\n' "$sect"; cat "$t/sec.$i"; } >>"$dir/ansible.intended.state"
    done
    rm -rf "$t"
    return $rc
}

# compare_captures <dir> [<intended file> [<distro>]] : diffs <dir>/ansible.state vs
# telepatch.state (gating) and the .versions files (informational). With an
# intended-differences file (format at apply_intended) the gating diff is
# against ansible.intended.state instead. Returns 1 on a gating diff.
compare_captures() {
    local dir=$1 intended=${2:-} distro=${3:-} rc=0 left=ansible.state applied="" n=0 bad=0
    if [[ -n $intended ]]; then
        [[ -f $intended ]] || { echo "intended-differences file not found: $intended"; return 1; }
        applied=$(apply_intended "$dir" "$intended" "$distro" 2>"$dir/intended.err") || bad=1
        [[ -z $applied ]] || n=$(printf '%s\n' "$applied" | wc -l)
        [[ $n -gt 0 || $bad -eq 1 ]] && left=ansible.intended.state
    fi
    if [[ $bad -eq 1 ]]; then
        echo "GATING DIFF (ansible vs telepatch):"
        sed 's/^ERR //' "$dir/intended.err"
        : >"$dir/gating.diff"
        rc=1
    elif diff -u --label ansible.state --label telepatch.state "$dir/$left" "$dir/telepatch.state" >"$dir/gating.diff"; then
        if [[ $n -gt 0 ]]; then
            echo "GATING: names/arch, pip, rustup, apt sources, /usr/local/bin: identical ($n intended differences applied)"
            printf '%s\n' "$applied" | sed 's/^/  intended: /'
        else
            echo "GATING: names/arch, pip, rustup, apt sources, /usr/local/bin: identical"
        fi
    else
        echo "GATING DIFF (ansible vs telepatch):"
        cat "$dir/gating.diff"
        rc=1
    fi
    if [[ -f $dir/ansible.versions && -f $dir/telepatch.versions ]]; then
        if diff -u --label ansible.versions --label telepatch.versions "$dir/ansible.versions" "$dir/telepatch.versions" >"$dir/versions.diff"; then
            echo "VERSIONS (non-gating): identical"
        else
            echo "VERSIONS (non-gating) side diff:"
            cat "$dir/versions.diff"
        fi
    fi
    return $rc
}

# intended_for <container> : the intended-differences file path, or nothing.
intended_for() {
    local f=$ROOT/tests/oracle/intended/$1.txt
    [[ -f $f ]] && echo "$f"
    return 0
}

# selftest_intended <fn> <dir> : shared self-test cases.
# <fn> is compare_captures or oracle_compare; <dir> a scratch dir.
selftest_intended() {
    local fn=$1 t=$2 fails=0 dist=rockylinux9
    local base=$'== packages ==\nbash amd64\ncurl amd64\n== /usr/local/bin ==\nuv\n== mise ==\nprofile.d mise.sh\n'
    rm -f "$t"/*.versions "$t"/ansible.intended.state
    # case_ <name> <want rc> <intended file content, or -> <telepatch state> [egrep pattern for the output]
    case_() {
        local name=$1 want=$2 content=$3 tele=$4 pat=${5:-} rc=0 f=""
        printf '%s' "$base" >"$t/ansible.state"
        printf '%s' "$tele" >"$t/telepatch.state"
        if [[ $content != - ]]; then f=$t/intended.txt; printf '%s' "$content" >"$f"; fi
        "$fn" "$t" "$f" "$dist" >"$t/out" 2>&1 || rc=$?
        if [[ $rc -eq $want ]]; then echo "ok   $name (exit $rc)"; else echo "FAIL $name: exit $rc, wanted $want"; fails=1; fi
        if [[ -n $pat ]] && ! grep -qE -- "$pat" "$t/out"; then echo "FAIL $name: output lacks /$pat/"; fails=1; fi
        sed 's/^/     | /' "$t/out"
    }
    local plus=$'# telepatch also installs awk\n\n+packages|awk amd64\n'
    case_ "intended: no file" 0 - "$base" '^GATING: names/arch, pip, rustup, apt sources, /usr/local/bin: identical$'
    [[ ! -e $t/ansible.intended.state ]] || { echo "FAIL intended: no file wrote ansible.intended.state"; fails=1; }
    case_ "intended: + applied" 0 "$plus" "${base/bash/awk amd64$'\n'bash}" 'identical \(1 intended differences applied\)'
    cmp -s "$t/ansible.intended.state" "$t/telepatch.state" || { echo "FAIL intended: + not inserted in sort order"; fails=1; }
    case_ "intended: + in a section that sorts last" 0 $'+mise|shim node\n' "${base}shim node"$'\n' 'identical \(1 intended'
    case_ "intended: + missing on telepatch" 1 "$plus" "$base" '^GATING DIFF'
    case_ "intended: - applied" 0 $'-packages|curl amd64\n' "${base/curl amd64$'\n'/}" 'identical \(1 intended differences applied\)'
    case_ "intended: - absent on ansible" 1 $'-packages|zsh amd64\n' "$base" 'intended removal not on the ansible side: -packages\|zsh amd64'
    case_ "intended: unknown section" 1 $'+nosuch|x\n' "$base" 'nosuch'
    case_ "intended: unrelated extra with a file present" 1 "$plus" "${base/bash/awk amd64$'\n'bash}zzz amd64"$'\n' '^\+zzz amd64'
    case_ "intended: comments only" 0 $'# nothing\n\n' "$base" '^GATING: .*: identical$'
    # distro-scoped lines: [a,b]+section|line (the cell's distro is rockylinux9)
    case_ "intended: scoped + applied on a listed distro" 0 $'[rockylinux9,rockylinux10]+packages|awk amd64\n' "${base/bash/awk amd64$'\n'bash}" 'identical \(1 intended differences applied\)'
    case_ "intended: scoped + ignored on an unlisted distro" 0 $'[fedora43,debian13]+packages|awk amd64\n' "$base" '^GATING: .*: identical$'
    case_ "intended: scoped - applied on a listed distro" 0 $'[rockylinux9]-packages|curl amd64\n' "${base/curl amd64$'\n'/}" 'identical \(1 intended differences applied\)'
    case_ "intended: scoped - absent on a listed distro fails" 1 $'[rockylinux9]-packages|zsh amd64\n' "$base" 'intended removal not on the ansible side'
    case_ "intended: scoped - absent but unlisted is ignored" 0 $'[fedora43]-packages|zsh amd64\n' "$base" '^GATING: .*: identical$'
    case_ "intended: scoped + missing on telepatch on a listed distro fails" 1 $'[rockylinux9]+packages|awk amd64\n' "$base" '^GATING DIFF'
    case_ "intended: scope unclosed" 1 $'[rockylinux9+packages|awk amd64\n' "$base" 'bad distro scope.*intended\.txt:1'
    case_ "intended: scope empty" 1 $'[]+packages|awk amd64\n' "$base" 'bad distro scope'
    case_ "intended: scope empty member" 1 $'[rockylinux9,]+packages|awk amd64\n' "$base" 'bad distro scope'
    case_ "intended: scope bad characters" 1 $'[Rocky-9]+packages|awk amd64\n' "$base" 'bad distro scope'
    case_ "intended: malformed scope fails even on an unlisted distro" 1 $'# c\n[fedora43,]+packages|x\n' "$base" 'intended\.txt:2'
    case_ "intended: scope with no sign" 1 $'[rockylinux9]packages|awk amd64\n' "$base" 'bad intended line'
    return $fails
}

# selftest_no_local_copy <script> ... : none defines compare_captures, each
# sources this lib.
selftest_no_local_copy() {
    local s fails=0
    for s in "$@"; do
        if grep -q '^compare_captures()' "$s"; then echo "FAIL $(basename "$s") defines compare_captures"; fails=1; fi
        if ! grep -q '^source "\$ROOT/scripts/lib/compare.sh"' "$s"; then echo "FAIL $(basename "$s") does not source lib/compare.sh"; fails=1; fi
    done
    [[ $fails -eq 1 ]] || echo "ok   compare_captures defined only in lib/compare.sh; both scripts source it"
    return $fails
}
