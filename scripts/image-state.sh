#!/bin/sh
# Prints the state of the image it runs in, for the docker equivalence oracle
# (scripts/test-container.sh). POSIX sh, runs inside a container of the image.
#   image-state.sh             gating sections: names (+arch), no versions
#   image-state.sh --versions  the same facts with versions (informational)
#   image-state.sh --users a,b also the account sections for those users
#                              (names mode only; never a hash: `passwd -S`
#                              gives the status letter alone)
# Env: ADMIN_USERS  space-separated users checked besides root (default none)
# Every section is sorted with LC_ALL=C so two runs diff cleanly.
set -u
export LC_ALL=C
mode=names
users=
while [ $# -gt 0 ]; do
    case $1 in
        --versions) mode=versions ;;
        --users) users=$(printf '%s' "${2:-}" | tr ',' ' '); shift ;;
    esac
    shift
done

section() { printf '== %s ==\n' "$1"; }

# The distro's own database decides: Rocky also has a dpkg-query binary (build tools).
packages() {
    if [ -s /var/lib/dpkg/status ] && command -v dpkg-query >/dev/null 2>&1; then
        if [ $mode = names ]; then dpkg-query -W -f '${Package} ${Architecture}\n'
        else dpkg-query -W -f '${Package} ${Architecture} ${Version}\n'; fi
    elif [ ! -d /var/lib/pacman/local ] && command -v rpm >/dev/null 2>&1; then
        if [ $mode = names ]; then rpm -qa --qf '%{NAME} %{ARCH}\n'
        else rpm -qa --qf '%{NAME} %{ARCH} %{VERSION}-%{RELEASE}\n'; fi
    elif [ -d /var/lib/pacman/local ] && command -v pacman >/dev/null 2>&1; then
        pacman -Qi | awk -v m=$mode '/^Name/{n=$3} /^Version/{v=$3} /^Architecture/{if(m=="names")print n, $3; else print n, $3, v}'
    fi | sort
}

# Python distributions visible to the system python3, via importlib.metadata so
# it works with or without pip installed (no base image has pip).
pip_dists() {
    command -v python3 >/dev/null 2>&1 || return 0
    python3 -c '
import importlib.metadata as m, re, sys
for d in m.distributions():
    n = re.sub(r"[-_.]+", "-", d.metadata["Name"] or "").lower()
    print(n + (" " + d.version if sys.argv[1] == "versions" else ""))
' $mode | sort -u
}

# Run the rest of the arguments as user $1 with the cargo dir on PATH.
as_user() {
    u=$1; shift
    home=$(getent passwd "$u" | cut -d: -f6)
    cmd="HOME=$home; export HOME; PATH=$home/.cargo/bin:\$PATH; export PATH; $*"
    if [ "$(id -un)" = "$u" ]; then sh -c "$cmd"; else su "$u" -s /bin/sh -c "$cmd"; fi
}

rust_state() {
    u=$1
    home=$(getent passwd "$u" | cut -d: -f6)
    section "rustup toolchains [$u]"
    if as_user "$u" 'command -v rustup' >/dev/null 2>&1; then
        as_user "$u" 'rustup toolchain list' 2>&1 | sed 's/ *(.*)$//' | sort
        section "rustup components [$u]"
        as_user "$u" 'rustup component list --installed' 2>&1 | sort
        section "rustup targets [$u]"
        as_user "$u" 'rustup target list --installed' 2>&1 | sort
    else
        echo "(no rustup)"
        section "rustup components [$u]"
        section "rustup targets [$u]"
    fi
    section "cargo bin [$u]"
    ls -A "$home/.cargo/bin" 2>/dev/null | sort
    if [ $mode = versions ]; then
        section "rust versions [$u]"
        as_user "$u" 'rustc --version; cargo --version' 2>&1
    fi
}

sources() {
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*; do
        [ -f "$f" ] || continue
        echo "-- $f"
        cat "$f"
    done
}

# mise, names only (versions go to "mise versions"): the shims, the installed
# tools, the config lines and the profile.d entries. Header only when none exist.
mise_state() {
    {
        ls -A /usr/local/share/mise/shims 2>/dev/null | sed 's/^/shim /'
        for d in /usr/local/share/mise/installs/*; do
            [ -d "$d" ] && echo "tool ${d##*/}"
        done
        [ -f /etc/mise/config.toml ] && grep -Ev '^[[:space:]]*(#|$)' /etc/mise/config.toml | sed 's/^/config /'
        ls -A /etc/profile.d 2>/dev/null | sed 's/^/profile.d /'
    } | sort
    return 0
}

# The admin-user sections (--users), names mode only. Per user: the passwd
# entry minus the secret fields (name, home, shell), `id -nG` sorted, the
# `passwd -S` status letter (never the hash), the drop-in's mode, owner and
# lines, and ~/.ssh's mode and owner. /etc/sudoers: the include and
# secure_path lines.
user_sections() {
    section "users"
    for u in $users; do
        e=$(getent passwd "$u") || { echo "$u (no account)"; continue; }
        echo "$e" | awk -F: '{ print $1, $6, $7 }'
    done | sort
    section "user groups"
    for u in $users; do
        getent passwd "$u" >/dev/null || continue
        echo "$u: $(id -nG "$u" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
    done | sort
    section "password status"
    for u in $users; do
        getent passwd "$u" >/dev/null || continue
        passwd -S "$u" 2>/dev/null | awk '{ print $1, $2 }'
    done | sort
    section "sudoers"
    [ -f /etc/sudoers ] && grep -E 'includedir|secure_path' /etc/sudoers | sort
    section "sudoers.d"
    for u in $users; do
        f=/etc/sudoers.d/$u
        [ -f "$f" ] || { echo "$u (no drop-in)"; continue; }
        echo "$u $(stat -c '%a %U:%G' "$f")"
        sed "s/^/$u | /" "$f"
    done | sort
    section "ssh dirs"
    for u in $users; do
        h=$(getent passwd "$u" | cut -d: -f6)
        if [ -n "$h" ] && [ -d "$h/.ssh" ]; then echo "$u $(stat -c '%a %U:%G' "$h/.ssh")"; else echo "$u (no ~/.ssh)"; fi
    done | sort
}

section "packages"; packages
if [ $mode = names ]; then
    section "pip"; pip_dists
else
    section "pip versions"; pip_dists
fi
for u in root ${ADMIN_USERS:-}; do
    echo "$u"
done | awk '!seen[$0]++' | sort | while read -r u; do
    rust_state "$u"
done
if [ $mode = names ]; then
    section "apt sources"; sources
    section "/usr/local/bin"; ls -A /usr/local/bin 2>/dev/null | sort
    section "mise"; mise_state
    [ -z "$users" ] || user_sections
fi
if [ $mode = versions ]; then
    section "mise versions"
    [ -x /usr/local/bin/mise ] && /usr/local/bin/mise ls 2>&1
fi
exit 0
