#!/usr/bin/env bash
# Review playbooks/edge against the edge list. No docker, no VM.
#   scripts/check-edge-playbook.sh
# Exit 1 when a required edge is missing or a forbidden token is present.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
EDGE=$ROOT/playbooks/edge
fails=0

die() { echo "check-edge: $*" >&2; exit 1; }

[[ -d $EDGE ]] || die "playbooks/edge is missing"
[[ -f $EDGE/edge.yml ]] || die "playbooks/edge/edge.yml is missing"
[[ -f $EDGE/requirements.txt ]] || die "playbooks/edge/requirements.txt is missing"
[[ -f $EDGE/roles/edge/tasks/main.yml ]] || die "roles/edge/tasks/main.yml is missing"
[[ -f $EDGE/roles/edge_extra/tasks/main.yml ]] || die "roles/edge_extra/tasks/main.yml is missing"

say() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=1; }

# ---- one play, hosts: all, roles edge then edge_extra -----------------------
play=$EDGE/edge.yml
if [[ $(grep -cE '^[[:space:]]*hosts: all[[:space:]]*$' "$play") -eq 1 ]]; then
    say "one play, hosts: all"
else
    bad "edge.yml must contain hosts: all exactly once"
fi
roles=$(awk '
    /^[[:space:]]*roles:[[:space:]]*$/ { on=1; next }
    on && /^[[:space:]]*- / { sub(/^[[:space:]]*-[[:space:]]*/, ""); print; n++; if (n==2) exit }
' "$play")
if [[ $roles == $'edge\nedge_extra' ]]; then
    say "roles are edge then edge_extra"
else
    bad "roles must be edge then edge_extra, got: ${roles//$'\n'/, }"
fi
if grep -E '^[[:space:]]*- ' "$play" | grep -vE '^[[:space:]]*- name:' | grep -vE '^[[:space:]]*- (edge|edge_extra)[[:space:]]*$' | grep -q .; then
    bad "edge.yml has a list item that is not the play name or the two roles"
fi

# ---- the pin ----------------------------------------------------------------
pin=$EDGE/requirements.txt
if [[ $(grep -cve '^[[:space:]]*$' "$pin") -eq 1 ]] && grep -qx 'ansible-core==2.22.0' "$pin"; then
    say "requirements.txt pins ansible-core==2.22.0"
else
    bad "requirements.txt must be exactly one pin: ansible-core==2.22.0"
fi

# ---- literals the edge list requires ----------------------------------------
tasks=$(find "$EDGE" -name '*.yml' -print)
need() {
    local label=$1 needle=$2
    if grep -qF -- "$needle" $tasks; then say "$label"; else bad "missing $label ($needle)"; fi
}
need "virtual name libz-dev" "libz-dev"
need "provider zlib1g-dev" "zlib1g-dev"
need "virtual name mailx" "mailx"
need "provider s-nail" "s-nail"
need "arch provider bash" "- bash"
need "arch virtual name sh" "- sh"
need "docker apt debian" "https://download.docker.com/linux/debian"
need "docker apt ubuntu" "https://download.docker.com/linux/ubuntu"
need "docker apt debian key" "https://download.docker.com/linux/debian/gpg"
need "docker apt ubuntu key" "https://download.docker.com/linux/ubuntu/gpg"
need "docker dnf fedora repo" "https://download.docker.com/linux/fedora/docker-ce.repo"
need "docker dnf rhel repo" "https://download.docker.com/linux/rhel/docker-ce.repo"
need "package docker-ce-cli" "docker-ce-cli"
need "marker path" "/usr/local/share/telepatch-edge.txt"
need "file scalar edge\\n" 'content: "edge\n"'
need "jq url" "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64"
need "jq dest" "/usr/local/bin/edge-jq"
need "jq mode 0755" 'mode: "0755"'
need "jq sha256 checksum" "sha256:5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5"
need "rustup installer" "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile default"
need "support package curl" "- curl"
need "support package ca-certificates" "- ca-certificates"

# docker URLs are only the four the table names
urls=$(grep -hoE 'https://download\.docker\.com/linux/[^[:space:]"]+' $tasks | sort -u)
want_urls=$'https://download.docker.com/linux/debian
https://download.docker.com/linux/debian/gpg
https://download.docker.com/linux/fedora/docker-ce.repo
https://download.docker.com/linux/rhel/docker-ce.repo
https://download.docker.com/linux/ubuntu
https://download.docker.com/linux/ubuntu/gpg'
if [[ $urls == "$want_urls" ]]; then
    say "docker URLs are only debian, ubuntu, fedora and rhel"
else
    bad "unexpected docker URLs:"; printf '%s\n' "$urls"
fi

# ---- rust-src only in edge_extra --------------------------------------------
extra=$EDGE/roles/edge_extra
if grep -qF 'rust-src' "$extra/tasks/main.yml"; then
    say "edge_extra requests rust-src"
else
    bad "edge_extra does not request rust-src"
fi
while IFS= read -r f; do
    [[ -n $f ]] || continue
    bad "rust-src outside edge_extra: ${f#"$ROOT"/}"
done < <(grep -RFl 'rust-src' "$EDGE" | grep -vF "$extra/")

# ---- curl and the virtual packages before the repo and before rustup --------
main=$EDGE/roles/edge/tasks/main.yml
lineno() { grep -nF -- "$1" "$main" | head -1 | cut -d: -f1 || true; }
curl_at=$(lineno "- curl")
repo_at=$(lineno "https://download.docker.com/linux/debian")
rust_at=$(lineno "https://sh.rustup.rs")
cli_at=$(lineno "docker-ce-cli")
if [[ -n $curl_at && -n $repo_at && -n $rust_at && -n $cli_at \
    && $curl_at -lt $repo_at && $curl_at -lt $rust_at && $repo_at -lt $cli_at ]]; then
    say "curl is before the repo and rustup; docker-ce-cli is after the repo"
else
    bad "task order: curl ($curl_at) must precede the repo ($repo_at) and rustup ($rust_at); docker-ce-cli ($cli_at) must follow the repo"
fi

# ---- packages: only curl, ca-certificates and the table ----------------------
# EL9 (T133): /usr/bin/curl (curl-minimal provides it) and /bin/mailx (EL9's
# s-nail provides it; nothing provides mailx there), chosen in the Red Hat
# task by an item of the one form
#   - "{{ '<EL9 name>' if ansible_distribution_major_version == '9' else '<name>' }}"
# which counts both names as seen.
allowed=" curl ca-certificates zlib1g-dev libz-dev docker-ce-cli s-nail mailx bash sh /usr/bin/curl /bin/mailx "
el9_item="^[[:space:]]*-[[:space:]]*\"\\{\\{ '([^']+)' if ansible_distribution_major_version == '9' else '([^']+)' \\}\\}\"[[:space:]]*$"
seen=" "
shopt -s nullglob
for f in "$EDGE"/roles/*/tasks/*.yml; do
    in_pkg=0 in_names=0
    while IFS= read -r line || [[ -n $line ]]; do
        # A task starts at column 0. Package names are indented list items.
        if [[ $line =~ ^-[[:space:]] ]]; then
            in_pkg=0; in_names=0
        fi
        if [[ $line =~ ansible\.builtin\.(apt|dnf|pacman|yum|package): ]]; then
            in_pkg=1; in_names=0; continue
        fi
        if [[ $in_pkg -eq 1 && $line =~ ^[[:space:]]*name:[[:space:]]*$ ]]; then
            in_names=1; continue
        fi
        if [[ $in_pkg -eq 1 && $line =~ ^[[:space:]]*name:[[:space:]]*([A-Za-z0-9][A-Za-z0-9.+-]*)[[:space:]]*$ ]]; then
            seen+="${BASH_REMATCH[1]} "
            in_names=0
            continue
        fi
        if [[ $in_names -eq 1 && $line =~ ^[[:space:]]*-[[:space:]]*([A-Za-z0-9][A-Za-z0-9.+-]*)[[:space:]]*$ ]]; then
            seen+="${BASH_REMATCH[1]} "
            continue
        fi
        if [[ $in_names -eq 1 && $line =~ $el9_item ]]; then
            seen+="${BASH_REMATCH[1]} ${BASH_REMATCH[2]} "
            continue
        fi
        if [[ $in_names -eq 1 ]]; then in_names=0; fi
    done <"$f"
done
for p in $seen; do
    case $allowed in
        *" $p "*) ;;
        *) bad "package not in the edge list or the support set: $p" ;;
    esac
done
for p in curl ca-certificates zlib1g-dev libz-dev docker-ce-cli s-nail mailx bash sh /usr/bin/curl /bin/mailx; do
    case $seen in
        *" $p "*) ;;
        *) bad "package list never names $p" ;;
    esac
done
if [[ $fails -eq 0 ]]; then say "packages are curl, ca-certificates and the table"; fi

# ---- FQCN modules in the role tasks -----------------------------------------
keywords="|name|when|register|changed_when|args|become|vars|tags|loop|notify|environment|check_mode|failed_when|ignore_errors|"
for f in "$EDGE"/roles/*/tasks/*.yml; do
    if grep -nE '^[[:space:]]*-[[:space:]]*[a-z0-9_]+:' "$f" | grep -vE -- '-[[:space:]]*name:' | grep -q .; then
        bad "short module name in ${f#"$ROOT"/}"
        grep -nE '^[[:space:]]*-[[:space:]]*[a-z0-9_]+:' "$f" | grep -vE -- '-[[:space:]]*name:' || true
    fi
    while IFS= read -r line; do
        [[ $line =~ ^[[:space:]][[:space:]]([A-Za-z0-9_.]+): ]] || continue
        key=${BASH_REMATCH[1]}
        case $keywords in
            *"|$key|"*) ;;
            *)
                if [[ $key != ansible.builtin.* ]]; then
                    bad "task key is not ansible.builtin.* or a task keyword: $key in ${f#"$ROOT"/}"
                fi
                ;;
        esac
    done <"$f"
done
if [[ $fails -eq 0 ]]; then say "role tasks use ansible.builtin.*"; fi

# ---- forbidden --------------------------------------------------------------
forb='build-dep|build_dep|dev_base|kernel|systemd|service:|ansible\.builtin\.systemd|password|token|\.env'
if grep -nE "$forb" $tasks "$pin"; then
    bad "forbidden token in the playbook (see lines above)"
else
    say "no build-dep, dev_base, kernel, systemd, service, password, token or .env"
fi

if [[ $fails -ne 0 ]]; then
    echo "check-edge: failed" >&2
    exit 1
fi
echo "check-edge: playbook matches the edge list"
