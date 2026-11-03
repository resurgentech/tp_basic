#!/bin/sh
# Prints the state of the image it runs in, for the docker equivalence oracle
# (scripts/test-container.sh). POSIX sh, runs inside a container of the image.
#   image-state.sh             gating sections: names (+arch), no versions
#   image-state.sh --versions  the same facts with versions (informational)
# Env: ADMIN_USERS  space-separated users checked besides root (default none)
# Every section is sorted with LC_ALL=C so two runs diff cleanly.
set -u
export LC_ALL=C
mode=names
[ "${1:-}" = "--versions" ] && mode=versions

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
fi
if [ $mode = versions ]; then
    section "mise versions"
    [ -x /usr/local/bin/mise ] && /usr/local/bin/mise ls 2>&1
fi
exit 0
