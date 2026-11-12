#!/usr/bin/env bash
# Prepares the VM host (TP_VM_HOST, see scripts/lib/vm.sh) to create the tp-*
# VMs, and checks that it is ready. Nothing here creates, touches or names a VM.
#
#   scripts/vm-host.sh check        read-only; one ok / WARN / FAIL line per item
#   scripts/vm-host.sh setup        idempotent; each part is skipped when its
#                                   check already passes; ends with `check`
#   scripts/vm-host.sh --self-test  stub ssh/scp/virsh/git/apt-get on PATH that
#                                   record argv; no network, no host
#
# Env: TP_VM_HOST (default from vm.sh; `local` = this workstation's vmtool),
#      TP_VM_HOST_DIR, TP_VM_POOL (vm.sh), VMTOOL_DIR (the vmtool checkout whose
#      HEAD is shipped), TP_VM_IMAGE (the base image, default
#      /var/lib/libvirt/images/ubuntu2404.qcow2).
#
# Every remote command is ONE string, `bash -c <script>`, with the script
# quoted by printf %q. The host's login shell may be zsh, which splits and
# expands the string before bash sees it; %q output (backslashes and $'...')
# means the same to bash and zsh, so bash receives the script verbatim. $HOME
# inside a script is bash's, after that. Remote scripts are one line.
#
# setup, in order (a part is skipped when its check passes):
#   1. Packages: the ONLY sudo, `sudo -n apt-get install -y
#      --no-install-recommends golang-1.24-go libvirt-dev`, after `apt-get -s`
#      shows exactly golang-1.24-go, golang-1.24-src, libvirt-dev as new
#      installs (no Remv, no upgrade, nothing else): otherwise exit 2.
#   2. Source: `git archive HEAD` of VMTOOL_DIR, extracted into ~/<dir>.
#   3. Build there with the host's Go 1.24 (cgo, no libvirt_dlopen tag), then
#      `./vmtool list` must run, then ~/<dir>/.tp-source gets the HEAD sha.
#   4. libvirt pool tp (dir pool, /var/lib/libvirt/images/tp), started and
#      autostarted.
#   5. Image: scp to ~/<dir>/staging, vol-create-as + vol-upload into pool tp,
#      staging deleted, vol-download (to a file) sha256 must equal the local file's, then
#      ~/<dir>/.tp-image-sha256 records it (so an interrupted upload is redone,
#      not trusted).
# Only virsh -c qemu:///system, and no verb that deletes or redefines anything.
# The vt-* VMs, docker and .machines/ are never named.
#
# Exit: 0 ok; 2 on any FAIL, a usage error or a refused install simulation.
# WARN lines never fail the check.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SELF=$HERE/$(basename "${BASH_SOURCE[0]}")
die() { echo "vm-host: $*" >&2; exit 2; }
VM_TAG=vm-host
# shellcheck source=lib/vm.sh
source "$HERE/lib/vm.sh"

IMAGE_NAME=ubuntu2404.qcow2
TP_VM_IMAGE=${TP_VM_IMAGE:-/var/lib/libvirt/images/ubuntu2404.qcow2}
IMAGE_BYTES=10737418240   # 10 GiB virtual
NEED_GIB=20
INSTALL='sudo -n apt-get install -y --no-install-recommends golang-1.24-go libvirt-dev'
SIM='apt-get -s install -y --no-install-recommends golang-1.24-go libvirt-dev'
V='virsh -c qemu:///system'
SSH_OPTS=(-o BatchMode=yes)

# validate_settings : exit 2 unless the host, dir and pool are plain words.
validate_settings() {
    [[ -n $TP_VM_HOST ]] || die "TP_VM_HOST is empty"
    [[ $TP_VM_HOST =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]] || die "TP_VM_HOST '$TP_VM_HOST': only letters, digits and . _ @ - are allowed (no space or shell metacharacter)"
    [[ $TP_VM_HOST_DIR =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]*$ && $TP_VM_HOST_DIR != *..* ]] || die "TP_VM_HOST_DIR '$TP_VM_HOST_DIR': a relative path of letters, digits and . _ / - only"
    if [[ $TP_VM_HOST != local ]]; then
        [[ $TP_VM_POOL =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "TP_VM_POOL '$TP_VM_POOL': letters, digits and . _ - only"
    fi
    RD="\"\$HOME/$TP_VM_HOST_DIR\""   # the dir as bash on the host sees it
}

# ---- remote execution -------------------------------------------------------
# rcmd_string <script> : the one string ssh sends (see the header).
rcmd_string() { printf 'bash -c %q' "$1"; }
# rs <script> : run the script on the host; stdin is the caller's.
rs() { ssh "${SSH_OPTS[@]}" "$TP_VM_HOST" "$(rcmd_string "$1")"; }
# rq <script> : the same with no stdin.
rq() { rs "$1" </dev/null; }
# rr <word...> : run one command, each word quoted; no expansion on the host.
rr() { local s; s=$(printf '%q ' "$@"); rs "${s% }" </dev/null; }

# ---- check ------------------------------------------------------------------
QUIET=0 FAILS=0
say() { if [[ $QUIET -eq 0 ]]; then printf '%s\n' "$*"; fi; }
ok() { say "ok    $*"; }
fail() { say "FAIL  $*"; FAILS=$((FAILS + 1)); }
warn() { say "WARN  $*"; }

PKGS_OK=0 SRC_OK=0 VMTOOL_OK=0 POOL_STATE=missing VOL_STATE=missing POOL_INFO=

item_pkgs() {
    local out
    PKGS_OK=0
    if ! out=$(rq 'for p in golang-1.24-go libvirt-dev; do dpkg -s "$p" 2>/dev/null | grep -q "^Status: install ok installed" || echo "$p"; done' 2>/dev/null); then
        fail "packages: could not run dpkg -s on $TP_VM_HOST"
    elif [[ -z $out ]]; then
        PKGS_OK=1; ok "packages golang-1.24-go and libvirt-dev installed (dpkg -s)"
    else
        fail "packages not installed: ${out//$'\n'/ }"
    fi
}

item_go() {
    local out
    if out=$(rr /usr/lib/go-1.24/bin/go version 2>&1) && [[ $out =~ go1\.24 ]]; then
        ok "go: $out"
    else
        fail "go: /usr/lib/go-1.24/bin/go version did not print go1.24 (${out:-no output})"
    fi
}

item_vmtool() {
    VMTOOL_OK=0
    if rq "cd $RD && ./vmtool list >/dev/null 2>&1"; then
        VMTOOL_OK=1; ok "~/$TP_VM_HOST_DIR/vmtool list runs (libvirt loads)"
    else
        fail "~/$TP_VM_HOST_DIR/vmtool list does not run"
    fi
}

item_source() {
    local head built
    SRC_OK=0
    head=$(git -C "$VMTOOL_DIR" rev-parse HEAD) || die "git -C $VMTOOL_DIR rev-parse HEAD failed"
    built=$(rq "cat $RD/.tp-source 2>/dev/null" 2>/dev/null) || built=
    if [[ $built == "$head" ]]; then
        SRC_OK=1; ok "vmtool on the host was built from HEAD ${head:0:12}"
    else
        [[ -n $built ]] && built=${built:0:12} || built="nothing recorded (no .tp-source)"
        warn "vmtool on the host was built from $built, local HEAD is ${head:0:12}: rerun setup"
    fi
}

item_tools() {
    local out
    if out=$(rq 'for t in ansible-playbook sshpass; do command -v "$t" >/dev/null || echo "$t"; done' 2>/dev/null) && [[ -z $out ]]; then
        ok "ansible-playbook and sshpass present"
    else
        fail "missing on the host: ${out//$'\n'/ }"
    fi
}

item_syntax() {
    if rq "ansible-playbook --syntax-check $RD/ansible/playbooks/setup_bot.yml >/dev/null 2>&1"; then
        ok "ansible-playbook --syntax-check setup_bot.yml passes"
    else
        fail "ansible-playbook --syntax-check ~/$TP_VM_HOST_DIR/ansible/playbooks/setup_bot.yml fails"
    fi
}

item_net() {
    local out
    if out=$(rr virsh -c qemu:///system net-info default 2>/dev/null) && grep -Eq '^Active:[[:space:]]+yes' <<<"$out"; then
        ok "network default is active"
    else
        fail "network default is not active"
    fi
}

item_pool() {
    POOL_STATE=missing POOL_INFO=
    if POOL_INFO=$(rr virsh -c qemu:///system pool-info "$TP_VM_POOL" 2>/dev/null); then
        if ! grep -Eq '^State:[[:space:]]+running' <<<"$POOL_INFO"; then
            POOL_STATE=inactive; fail "pool $TP_VM_POOL is defined but not active"
        elif ! grep -Eq '^Autostart:[[:space:]]+yes' <<<"$POOL_INFO"; then
            POOL_STATE=noauto; fail "pool $TP_VM_POOL is active but not autostarted"
        else
            POOL_STATE=ok; ok "pool $TP_VM_POOL is active and autostarted"
        fi
    else
        POOL_INFO=; fail "pool $TP_VM_POOL is not defined"
    fi
}

item_vol() {
    local out cap
    VOL_STATE=missing
    if [[ $POOL_STATE == missing ]]; then fail "volume $IMAGE_NAME: pool $TP_VM_POOL is not defined"; return; fi
    if ! out=$(rr virsh -c qemu:///system vol-info --pool "$TP_VM_POOL" "$IMAGE_NAME" 2>/dev/null); then
        fail "volume $IMAGE_NAME is not in pool $TP_VM_POOL"; return
    fi
    cap=$(awk '/^Capacity:/ { print $2, $3 }' <<<"$out")
    if awk -v c="$cap" 'BEGIN { split(c, a, " "); exit !(a[1] + 0 == 10 && a[2] == "GiB") }'; then
        VOL_STATE=ok; ok "volume $IMAGE_NAME in pool $TP_VM_POOL, capacity $cap"
    else
        VOL_STATE=badcap; fail "volume $IMAGE_NAME in pool $TP_VM_POOL has capacity '${cap:-unknown}', wanted 10 GiB"
    fi
}

item_free() {
    local avail gib
    avail=$(awk '/^Available:/ { print $2, $3 }' <<<"$POOL_INFO")
    if [[ -z $avail ]]; then fail "pool $TP_VM_POOL free space: unknown (pool-info gave no Available line)"; return; fi
    gib=$(awk -v a="$avail" 'BEGIN { split(a, x, " "); u = x[2]; v = x[1] + 0
        if (u == "B") v /= 1073741824; else if (u == "KiB") v /= 1048576; else if (u == "MiB") v /= 1024
        else if (u == "TiB") v *= 1024; else if (u == "PiB") v *= 1048576
        else if (u != "GiB") v = -1
        printf "%.2f", v }')
    if awk -v g="$gib" -v n="$NEED_GIB" 'BEGIN { exit !(g >= n) }'; then
        ok "pool $TP_VM_POOL has $avail available (need $NEED_GIB GiB)"
    else
        fail "pool $TP_VM_POOL has $avail available, need $NEED_GIB GiB"
    fi
}

item_dup() {
    local out
    [[ $POOL_STATE != missing ]] || return 0
    out=$(rq "for p in \$($V pool-list --name); do [ \"\$p\" = $TP_VM_POOL ] || { $V vol-list --pool \"\$p\" 2>/dev/null | grep -q $IMAGE_NAME && echo \"\$p\"; }; done" 2>/dev/null) || return 0
    if [[ -n $out ]]; then
        warn "another pool also has $IMAGE_NAME: ${out//$'\n'/ } (vmtool finds the image by name across pools)"
    fi
}

# local: only VMTOOL_DIR/vmtool and its image list.
check_local() {
    local out
    if [[ -x $VMTOOL_DIR/vmtool ]]; then ok "$VMTOOL_DIR/vmtool is executable"; else fail "$VMTOOL_DIR/vmtool is not executable"; fi
    if out=$(vmtool images list 2>&1) && grep -q "$IMAGE_NAME" <<<"$out"; then
        ok "vmtool images list names $IMAGE_NAME"
    else
        fail "vmtool images list does not name $IMAGE_NAME"
    fi
}

check_items() {
    FAILS=0
    if [[ $TP_VM_HOST == local ]]; then check_local; return; fi
    item_pkgs; item_go; item_vmtool; item_source; item_tools; item_syntax
    item_net; item_pool; item_vol; item_free; item_dup
}

cmd_check() {
    check_items
    if [[ $FAILS -gt 0 ]]; then echo "check: $FAILS FAIL on $TP_VM_HOST"; exit 2; fi
    echo "check: ok on $TP_VM_HOST"
}

# ---- setup ------------------------------------------------------------------
# A sha256 line: the first field of `sha256sum` output.
sha_of() { awk '{ print $1 }'; }

setup_packages() {
    local sim line name
    echo "== 1. packages"
    if ! sim=$(rr $SIM 2>&1); then echo "$sim"; die "apt-get -s failed; nothing installed"; fi
    local news=0 refuse=
    while IFS= read -r line; do
        case $line in
            Remv*) refuse="$line removes a package" ;;
            Inst*)
                name=${line#Inst }; name=${name%% *}
                [[ $line =~ ^Inst\ [^\ ]+\ \[ ]] && refuse="$line upgrades an installed package"
                case $name in golang-1.24-go|golang-1.24-src|libvirt-dev) news=$((news + 1)) ;; *) refuse="$line installs $name, which is not on the list" ;; esac ;;
        esac
    done <<<"$sim"
    [[ -n $refuse || $news -eq 0 ]] && { echo "$sim"; die "refusing to install: ${refuse:-the simulation lists no install}"; }
    echo "$sim"
    # shellcheck disable=SC2086
    rr ${INSTALL} || die "the install failed (stale package lists? setup does not run apt-get update): stopping"
}

setup_source() {
    local dirty
    echo "== 2. vmtool source (git archive HEAD of $VMTOOL_DIR)"
    dirty=$(git -C "$VMTOOL_DIR" status --porcelain)
    [[ -z $dirty ]] || echo "note: $VMTOOL_DIR has uncommitted changes; they are not shipped (only HEAD is)"
    git -C "$VMTOOL_DIR" archive --format=tar HEAD | rs "mkdir -p $RD && tar -x -C $RD" || die "shipping the source failed"
}

setup_build() {
    local head out
    echo "== 3. build vmtool on the host"
    head=$(git -C "$VMTOOL_DIR" rev-parse HEAD)
    [[ $head =~ ^[0-9a-f]{40}$ ]] || die "HEAD of $VMTOOL_DIR is not a sha: $head"
    if ! out=$(rq "cd $RD && GOTOOLCHAIN=local GOFLAGS=-mod=readonly GOPATH=$RD/.go GOCACHE=$RD/.gocache /usr/lib/go-1.24/bin/go build -o vmtool ./cmd/vmtool 2>&1"); then
        echo "$out"; die "go build failed on the host (no fallback to a build here)"
    fi
    rq "cd $RD && ./vmtool list >/dev/null && printf '%s\\n' $head > $RD/.tp-source" || die "the built vmtool does not run (list failed); .tp-source not written"
}

setup_pool() {
    local p=$TP_VM_POOL
    echo "== 4. pool $p"
    if [[ $POOL_STATE == missing ]]; then
        rr virsh -c qemu:///system pool-define-as "$p" dir --target "/var/lib/libvirt/images/$p" || die "pool-define-as $p failed"
        rr virsh -c qemu:///system pool-build "$p" || die "pool-build $p failed"
    fi
    if [[ $POOL_STATE == missing || $POOL_STATE == inactive ]]; then rr virsh -c qemu:///system pool-start "$p" || die "pool-start $p failed"; fi
    rr virsh -c qemu:///system pool-autostart "$p" || die "pool-autostart $p failed"
}

setup_image() {
    local p=$TP_VM_POOL img=$TP_VM_IMAGE info bytes lsha rsha urc=0
    echo "== 5. image $IMAGE_NAME"
    [[ $VOL_STATE != badcap ]] || die "volume $IMAGE_NAME in pool $p has the wrong capacity; setup never deletes a volume, remove it by hand"
    [[ -r $img ]] || die "cannot read $img"
    lsha=$(sha256sum "$img" | sha_of)
    rq "mkdir -p $RD/staging" || die "cannot make ~/$TP_VM_HOST_DIR/staging"
    scp "${SSH_OPTS[@]}" "$img" "$TP_VM_HOST:$TP_VM_HOST_DIR/staging/$IMAGE_NAME" || die "scp of $img failed"
    info=$(rq "qemu-img info --output=json $RD/staging/$IMAGE_NAME") || info=
    # top-level keys only (four-space indent): the "file" child has its own
    # virtual-size (the file's bytes) and format ("file")
    bytes=$(sed -n 's/^    "virtual-size": *\([0-9][0-9]*\).*/\1/p' <<<"$info")
    if ! grep -q '^    "format": "qcow2"' <<<"$info" || [[ $bytes != "$IMAGE_BYTES" ]]; then
        rq "rm -f $RD/staging/$IMAGE_NAME; rmdir $RD/staging 2>/dev/null; true" || true
        die "$img is not a 10 GiB (${IMAGE_BYTES} bytes) qcow2 (got '${bytes:-?}'); nothing created"
    fi
    if [[ $VOL_STATE == missing ]]; then
        rr virsh -c qemu:///system vol-create-as "$p" "$IMAGE_NAME" "$bytes" --format qcow2 || die "vol-create-as failed"
    fi
    rq "$V vol-upload --pool $p $IMAGE_NAME $RD/staging/$IMAGE_NAME" || urc=$?
    rq "rm -f $RD/staging/$IMAGE_NAME; rmdir $RD/staging 2>/dev/null; true" || true
    [[ $urc -eq 0 ]] || die "vol-upload failed (rc $urc); the volume stays, rerun setup"
    # into a file, not /dev/stdout: virsh prints a newline on stdout after the
    # download, which would land in the hash (observed with virsh 10.0)
    rsha=$(rq "mkdir -p $RD/staging && { $V vol-download --pool $p $IMAGE_NAME $RD/staging/verify.qcow2 >/dev/null && sha256sum <$RD/staging/verify.qcow2; }; rc=\$?; rm -f $RD/staging/verify.qcow2; rmdir $RD/staging 2>/dev/null; exit \$rc" | sha_of)
    [[ $rsha == "$lsha" ]] || die "sha256 of the volume ($rsha) differs from $img ($lsha); the volume stays, nothing is deleted"
    echo "sha256 $lsha (volume equals $img)"
    rq "printf '%s\\n' $lsha > $RD/.tp-image-sha256" || die "cannot record the image sha256"
}

cmd_setup() {
    if [[ $TP_VM_HOST == local ]]; then
        echo "TP_VM_HOST=local: vmtool is this workstation's, nothing to set up"
        cmd_check; return
    fi
    QUIET=1; check_items; QUIET=0
    if [[ $PKGS_OK -eq 1 ]]; then echo "== 1. packages: present, skipped"; else setup_packages; fi
    if [[ $SRC_OK -eq 1 ]]; then echo "== 2. source: at HEAD, skipped"; else setup_source; fi
    if [[ $SRC_OK -eq 1 && $VMTOOL_OK -eq 1 ]]; then echo "== 3. build: current, skipped"; else setup_build; fi
    if [[ $POOL_STATE == ok ]]; then echo "== 4. pool $TP_VM_POOL: ready, skipped"; else setup_pool; fi
    if [[ $VOL_STATE == ok ]] && rq "test -s $RD/.tp-image-sha256"; then echo "== 5. image: present and verified, skipped"; else setup_image; fi
    echo "== check"
    cmd_check
}

# ---- self-test ----------------------------------------------------------------
self_test() {
    set +e
    local d npass=0 nfail=0 out rc
    d=$(mktemp -d)
    trap "rm -rf '$d'" EXIT
    mkdir -p "$d/bin" "$d/st" "$d/vmtool"
    export TP_LOG=$d/log TP_ST=$d/st
    local head_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    printf 'fake qcow2 bytes\n' >"$d/img"
    local img_sha; img_sha=$(sha256sum "$d/img" | awk '{print $1}')

    pass() { echo "ok   $1"; npass=$((npass + 1)); }
    flunk() { echo "FAIL $1${2:+: $2}"; nfail=$((nfail + 1)); }
    # t <name> <rc of the condition>
    t() { if [[ $2 -eq 0 ]]; then pass "$1"; else flunk "$1" "${3:-}"; fi; }

    # ---- stubs: record argv; nothing reaches a network ----
    local n
    for n in virsh apt-get go sudo dpkg docker; do
        printf '#!/bin/bash\necho "LOCAL %s $*" >>"$TP_LOG"\nexit 99\n' "$n" >"$d/bin/$n"
    done
    cat >"$d/bin/git" <<'EOF'
#!/bin/bash
echo "git $*" >>"$TP_LOG"
[[ $1 == -C ]] || exit 99
shift 2
case "$*" in
    "rev-parse HEAD") echo "${SC_HEAD:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" ;;
    "status --porcelain") printf '%s' "${SC_DIRTY:-}" ;;
    "archive --format=tar HEAD") printf 'TARDATA' ;;
    *) exit 99 ;;
esac
EOF
    cat >"$d/bin/scp" <<'EOF'
#!/bin/bash
echo "scp $*" >>"$TP_LOG"
touch "$TP_ST/staged"
EOF
    # The host: the stub decodes the one string exactly as a login shell would
    # (eval of the word list), logs the script, and answers from the state files
    # in $TP_ST that its own "writes" change.
    cat >"$d/bin/ssh" <<'EOF'
#!/bin/bash
args=("$@"); i=0
while [[ ${args[i]:-} == -o ]]; do i=$((i + 2)); done
host=${args[i]}; cmd="${args[*]:i+1}"
eval "set -- $cmd"
if [[ ${1:-} != bash || ${2:-} != -c || $# -ne 3 ]]; then echo "BADCMD $cmd" >>"$TP_LOG"; exit 97; fi
script=$3
echo "ssh ${args[*]:0:i} $host :: $script" >>"$TP_LOG"
st() { [[ -e $TP_ST/$1 ]]; }
V='virsh -c qemu:///system'
case $script in
    "sudo -n apt-get install "*) touch "$TP_ST/pkgs" ;;
    "apt-get -s install "*) cat "$TP_ST/sim" ;;
    "for p in golang-1.24-go "*) st pkgs || printf 'golang-1.24-go\nlibvirt-dev\n' ;;
    "/usr/lib/go-1.24/bin/go version") if st pkgs; then echo "go version go1.24.13 linux/amd64"; else exit 127; fi ;;
    *"go build -o vmtool"*) if [[ -n ${SC_BUILD_FAIL:-} ]]; then echo "vmtool.go:1: compile error"; exit 1; fi; touch "$TP_ST/vmtool" ;;
    *"./vmtool list >/dev/null && printf"*) st vmtool || exit 1; grep -o '[0-9a-f]\{40\}' <<<"$script" >"$TP_ST/src" ;;
    *"./vmtool list"*) st vmtool ;;
    "cat "*".tp-source"*) [[ -s $TP_ST/src ]] && cat "$TP_ST/src" ;;
    "for t in ansible-playbook "*) : ;;
    "ansible-playbook --syntax-check "*) : ;;
    "mkdir -p "*"&& tar -x"*) cat >/dev/null; touch "$TP_ST/tarred" ;;
    # the verify download goes to a staging file (see the /dev/stdout case below)
    "mkdir -p "*"/staging && { $V vol-download "*) st uploaded && echo "${SC_REMOTE_SHA:-$(cat "$TP_ST/img_sha")}  -" ;;
    "mkdir -p "*) : ;;
    "$V net-info default") printf 'Name:           default\nActive:         yes\nAutostart:      yes\n' ;;
    "$V pool-info "*)
        st pool_def || { echo "error: failed to get pool" >&2; exit 1; }
        printf 'Name:           tp\nState:          %s\nPersistent:     yes\nAutostart:      %s\nCapacity:       99.00 GiB\nAllocation:     3.00 GiB\nAvailable:      %s\n' \
            "$(st pool_run && echo running || echo inactive)" "$(st pool_auto && echo yes || echo no)" "${SC_FREE:-96.50 GiB}" ;;
    "$V vol-info "*)
        st vol || { echo "error: failed to get vol" >&2; exit 1; }
        printf 'Name:           ubuntu2404.qcow2\nType:           file\nCapacity:       %s\nAllocation:     4.30 GiB\n' "${SC_CAP:-10.00 GiB}" ;;
    "for p in \$($V pool-list --name)"*) [[ -n ${SC_DUP:-} ]] && echo boot-scratch ;;
    "$V pool-define-as "*) touch "$TP_ST/pool_def" ;;
    "$V pool-build "*) : ;;
    "$V pool-start "*) touch "$TP_ST/pool_run" ;;
    "$V pool-autostart "*) touch "$TP_ST/pool_auto" ;;
    "$V vol-create-as "*) touch "$TP_ST/vol" ;;
    "$V vol-upload "*) st vol && st staged || exit 1; touch "$TP_ST/uploaded" ;;
    # virsh 10.0 prints a newline on stdout after vol-download, so a download
    # to /dev/stdout is the volume plus one byte (observed on the VM host, virsh 10.0)
    "set -o pipefail; $V vol-download "*"/dev/stdout"*) st uploaded && { cat "$TP_VM_IMAGE"; echo; } | sha256sum ;;
    # the shape qemu-img 8.2 prints: the file child (its virtual-size is the
    # file's bytes) comes before the top-level qcow2 keys
    "qemu-img info "*) printf '{\n    "children": [\n        {\n            "name": "file",\n            "info": {\n                "virtual-size": 4706402304,\n                "format": "file"\n            }\n        }\n    ],\n    "virtual-size": %s,\n    "filename": "x",\n    "format": "qcow2"\n}\n' "${SC_VSIZE:-10737418240}" ;;
    "test -s "*".tp-image-sha256") st marker ;;
    "printf "*".tp-image-sha256") touch "$TP_ST/marker" ;;
    "rm -f "*) rm -f "$TP_ST/staged" ;;
    *) echo "UNEXPECTED $script" >>"$TP_LOG"; exit 98 ;;
esac
EOF
    chmod +x "$d"/bin/*

    # scn full|empty : the host's state, a clean log.
    scn() {
        rm -rf "$d/st"; mkdir -p "$d/st"; : >"$TP_LOG"
        echo "$img_sha" >"$d/st/img_sha"
        printf 'Inst golang-1.24-src (1.24.13 Ubuntu:24.04/noble-updates [all])\nInst golang-1.24-go (1.24.13 Ubuntu:24.04/noble-updates [amd64])\nInst libvirt-dev (10.0.0 Ubuntu:24.04/noble-updates [amd64])\nConf libvirt-dev (10.0.0 Ubuntu:24.04/noble-updates [amd64])\n' >"$d/st/sim"
        if [[ ${1:-} == full ]]; then
            touch "$d/st"/{pkgs,vmtool,pool_def,pool_run,pool_auto,vol,uploaded,marker}
            echo "$head_sha" >"$d/st/src"
        fi
    }
    # vh <args...> : the script under test, against the stubs; sets out and rc.
    vh() {
        out=$(PATH="$d/bin:$PATH" TP_VM_HOST=${HOSTV:-vmhost.test} VMTOOL_DIR=$d/vmtool TP_VM_IMAGE=$d/img \
            SC_HEAD=$head_sha bash "$SELF" "$@" 2>&1)
        rc=$?
    }
    # remote_lines : the scripts that went to the host, one per line.
    remote_lines() { sed -n 's/^ssh .* :: //p' "$TP_LOG"; }
    local WRITE_TOKENS='sudo|apt-get install|mkdir|tar -x|go build|rm -f|printf|vol-create-as|vol-upload|pool-define-as|pool-build|pool-start|pool-autostart'

    # allowed_script <script> : true when it is one of the scripts setup may send.
    allowed_script() {
        local s=$1 rd='"$HOME/tp-vmtool"' v='virsh -c qemu:///system' pf="printf '%s\\n'"
        case $s in
            "for p in golang-1.24-go libvirt-dev;"*|"/usr/lib/go-1.24/bin/go version"|"for t in ansible-playbook sshpass;"*) ;;
            "cd $rd && ./vmtool list >/dev/null 2>&1"|"cat $rd/.tp-source 2>/dev/null") ;;
            "ansible-playbook --syntax-check $rd/ansible/playbooks/setup_bot.yml >/dev/null 2>&1") ;;
            "$v net-info default"|"$v pool-info tp"|"$v vol-info --pool tp ubuntu2404.qcow2") ;;
            "for p in \$($v pool-list --name);"*) ;;
            "$SIM"|"qemu-img info --output=json $rd/staging/ubuntu2404.qcow2"|"test -s $rd/.tp-image-sha256") ;;
            "mkdir -p $rd/staging && { $v vol-download --pool tp ubuntu2404.qcow2 $rd/staging/verify.qcow2 >/dev/null && sha256sum <$rd/staging/verify.qcow2; }; rc=\$?; rm -f $rd/staging/verify.qcow2; rmdir $rd/staging 2>/dev/null; exit \$rc") ;;
            "$INSTALL") ;;
            "mkdir -p $rd && tar -x -C $rd"|"mkdir -p $rd/staging") ;;
            "cd $rd && GOTOOLCHAIN=local GOFLAGS=-mod=readonly GOPATH=$rd/.go GOCACHE=$rd/.gocache /usr/lib/go-1.24/bin/go build -o vmtool ./cmd/vmtool 2>&1") ;;
            "cd $rd && ./vmtool list >/dev/null && $pf "[0-9a-f]*" > $rd/.tp-source") ;;
            "$v pool-define-as tp dir --target /var/lib/libvirt/images/tp"|"$v pool-build tp"|"$v pool-start tp"|"$v pool-autostart tp") ;;
            "$v vol-create-as tp ubuntu2404.qcow2 "[0-9]*" --format qcow2") ;;
            "$v vol-upload --pool tp ubuntu2404.qcow2 $rd/staging/ubuntu2404.qcow2") ;;
            "rm -f $rd/staging/ubuntu2404.qcow2; rmdir $rd/staging 2>/dev/null; true") ;;
            "$pf "[0-9a-f]*" > $rd/.tp-image-sha256") ;;
            *) return 1 ;;
        esac
    }

    # ---- settings in vm.sh ----
    local sh_out
    sh_out=$(env -u TP_VM_HOST -u TP_VM_POOL -u TP_VM_HOST_DIR bash -c 'source "$1"; echo "$TP_VM_HOST|$TP_VM_HOST_DIR|$TP_VM_POOL"' _ "$HERE/lib/vm.sh")
    [[ $sh_out =~ ^[^|]+\|tp-vmtool\|tp$ && ${sh_out%%|*} != local ]]; t "vm.sh defaults: a named host, tp-vmtool, pool tp" $? "$sh_out"
    sh_out=$(env -u TP_VM_POOL -u TP_VM_HOST_DIR TP_VM_HOST=local bash -c 'source "$1"; echo "$TP_VM_HOST|$TP_VM_HOST_DIR|$TP_VM_POOL"' _ "$HERE/lib/vm.sh")
    [[ $sh_out == "local|tp-vmtool|" ]]; t "vm.sh: TP_VM_HOST=local leaves the pool empty" $? "$sh_out"

    # ---- check, everything present ----
    scn full; vh check
    local want
    t "check (all present): exit 0" "$rc" "rc=$rc"
    want=0; [[ $(grep -c '^ok ' <<<"$out") -eq 10 && $out != *FAIL* && $out != *WARN* ]] || want=1
    t "check (all present): 10 ok lines, no FAIL, no WARN" $want "$out"
    grep -Eq '^ok +pool tp has 96\.50 GiB available' <<<"$out"; t "check: the pool-free line prints the number" $? "$out"
    local verbs bad=0 line
    verbs=$(grep -o 'qemu:///system [a-z-]*' "$TP_LOG" | awk '{print $2}' | sort -u | tr '\n' ' ')
    for line in $verbs; do case $line in list|net-list|net-info|pool-list|pool-info|vol-list|vol-info) ;; *) bad=1 ;; esac; done
    [[ -n $verbs ]] || bad=1
    t "check: virsh verbs are read-only ($verbs)" $bad
    ! grep -Eq "$WRITE_TOKENS|^scp|^git .*archive" "$TP_LOG"; t "check: no write verb, no scp, no archive" $?
    ! grep -q 'sudo' "$TP_LOG"; t "check: never sudo" $?
    grep -q 'dpkg -s' "$TP_LOG" && grep -q 'go version' "$TP_LOG"; t "check: uses dpkg -s and go version" $?
    [[ $(grep -c '^ssh ' "$TP_LOG") -eq $(grep -c '^ssh -o BatchMode=yes ' "$TP_LOG") ]] && grep -q '^ssh' "$TP_LOG"; t "check: every ssh has -o BatchMode=yes" $?
    ! grep -Eq 'LOCAL|BADCMD|UNEXPECTED' "$TP_LOG"; t "check: nothing ran locally; every remote string decodes to bash -c <script>" $?

    # ---- check, failures and warnings ----
    scn full; rm "$d/st/pkgs"; vh check
    [[ $rc -eq 2 ]] && grep -q '^FAIL  packages' <<<"$out"; t "check: a missing package is a FAIL, exit 2" $? "rc=$rc"
    scn full; SC_FREE='12.00 GiB' vh check
    [[ $rc -eq 2 ]] && grep -Eq '^FAIL .*12\.00 GiB' <<<"$out"; t "check: under 20 GiB free is a FAIL that prints the number" $? "rc=$rc"
    scn full; rm "$d/st/pool_def" "$d/st/vol"; vh check
    [[ $rc -eq 2 ]] && grep -q '^FAIL  pool tp' <<<"$out"; t "check: no pool tp is a FAIL" $? "rc=$rc"
    scn full; rm "$d/st/pool_auto"; vh check
    [[ $rc -eq 2 ]] && grep -q '^FAIL  pool tp' <<<"$out"; t "check: a pool not autostarted is a FAIL" $? "rc=$rc"
    scn full; SC_CAP='20.00 GiB' vh check
    [[ $rc -eq 2 ]] && grep -q '^FAIL  volume' <<<"$out"; t "check: a volume that is not 10 GiB is a FAIL" $? "rc=$rc"
    scn full; echo bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb >"$d/st/src"; vh check
    [[ $rc -eq 0 ]] && grep -q '^WARN  .*rerun setup' <<<"$out"; t "check: a .tp-source mismatch is a WARN, exit 0" $? "rc=$rc"
    scn full; SC_DUP=1 vh check
    [[ $rc -eq 0 ]] && grep -q "^WARN  .*boot-scratch" <<<"$out"; t "check: another pool with the image is a WARN, exit 0" $? "rc=$rc"

    # ---- setup from nothing ----
    scn empty; vh setup; local setup_out=$out setup_rc=$rc
    t "setup (empty host): exit 0, ends with a passing check" "$setup_rc" "$setup_out"
    local bad_lines=0
    while IFS= read -r line; do allowed_script "$line" || { bad_lines=1; echo "  not allowed: $line"; }; done < <(remote_lines)
    [[ $(remote_lines | wc -l) -ge 20 ]] || bad_lines=1
    t "setup: every remote script is one of the allowed reads or writes" $bad_lines
    local sudo_lines
    sudo_lines=$(remote_lines | grep -c sudo)
    [[ $sudo_lines -eq 1 && $(remote_lines | grep sudo) == "$INSTALL" ]] && ! grep -v '^ssh ' "$TP_LOG" | grep -q sudo
    t "setup: sudo is in exactly one argv, byte-equal to the install command" $? "n=$sudo_lines"
    [[ $(remote_lines | grep -n . | grep -E 'apt-get -s' | cut -d: -f1) -lt $(remote_lines | grep -n . | grep sudo | cut -d: -f1) ]]
    t "setup: the apt-get -s simulation runs before the install" $?
    ! grep -Eq 'vt-|docker|\.machines|destroy|undefine|net-define|net-start|pool-delete|vol-delete|apt-get update|upgrade|remove|purge' "$TP_LOG"
    t "setup: no argv names vt-, docker or .machines, or a destroying verb" $?
    ! grep -Eq 'libvirt_dlopen|-tags' "$TP_LOG" && ! grep -q '^LOCAL' "$TP_LOG" && [[ $(grep -c 'go build' "$TP_LOG") -eq 1 ]]
    t "setup: no -tags libvirt_dlopen, no local go/virsh/apt-get, one go build and it is remote" $?
    bad=0
    while IFS= read -r line; do
        [[ $line == "git -C $d/vmtool rev-parse HEAD" || $line == "git -C $d/vmtool status --porcelain" || $line == "git -C $d/vmtool archive --format=tar HEAD" ]] || bad=1
    done < <(grep '^git ' "$TP_LOG")
    [[ $(grep -c '^git ' "$TP_LOG") -ge 3 ]]; local g=$?
    t "setup: the vmtool checkout only sees archive, rev-parse and status" $((bad | g))
    grep -q "^scp -o BatchMode=yes $d/img vmhost.test:tp-vmtool/staging/ubuntu2404.qcow2$" "$TP_LOG"
    t "setup: the image goes by scp to ~/tp-vmtool/staging" $?
    [[ -e $d/st/marker && ! -e $d/st/staged ]]; t "setup: sha256 verified, marker written, staging removed" $?

    # ---- setup again: nothing to do ----
    cp "$TP_LOG" "$d/log.first"; : >"$TP_LOG"; vh setup
    t "setup (second run): exit 0" "$rc" "$out"
    [[ $(remote_lines | wc -l) -ge 8 ]] && ! grep -Eq "$WRITE_TOKENS|^scp|^git .*archive|sudo" "$TP_LOG"; t "setup (second run): reads only; no write, no sudo, no scp, no archive" $?

    # ---- setup refuses a risky simulation ----
    local variant sim
    for variant in "Remv htop [3.3]" "Inst libc6 [2.39-0ubuntu8] (2.39-0ubuntu8.7 Ubuntu:24.04/noble-updates [amd64])" "Inst libvirt-dev [9.0] (10.0.0 Ubuntu:24.04/noble-updates [amd64])" "Inst htop (3.3 Ubuntu:24.04/noble [amd64])"; do
        scn empty
        printf 'Inst golang-1.24-go (1.24.13 Ubuntu:24.04/noble-updates [amd64])\nInst libvirt-dev (10.0.0 Ubuntu:24.04/noble-updates [amd64])\n%s\n' "$variant" >"$d/st/sim"
        vh setup
        sim=${variant%% *}
        [[ $rc -eq 2 ]] && ! grep -q 'sudo' "$TP_LOG" && grep -qF "$variant" <<<"$out"
        t "setup: a simulation with '${variant:0:30}' exits 2, prints it, installs nothing" $? "rc=$rc"
    done

    # ---- setup stops on a failed build, a sha mismatch, a wrong image ----
    scn empty; SC_BUILD_FAIL=1 vh setup
    [[ $rc -ne 0 && ! -s $d/st/src && ! -e $d/st/uploaded ]] && grep -q 'compile error' <<<"$out"; t "setup: a failed build stops, prints the compiler output, writes no .tp-source" $? "rc=$rc"
    scn empty; SC_REMOTE_SHA=0000 vh setup
    [[ $rc -eq 2 && ! -e $d/st/marker ]] && ! remote_lines | grep -Eq 'vol-delete'; t "setup: a sha256 mismatch exits 2 and records nothing" $? "rc=$rc"
    scn empty; SC_VSIZE=21474836480 vh setup
    [[ $rc -eq 2 && ! -e $d/st/vol ]]; t "setup: an image that is not 10 GiB virtual creates no volume" $? "rc=$rc"
    scn empty; SC_DIRTY=' M x.go' vh setup
    [[ $rc -eq 0 ]] && grep -q 'uncommitted' <<<"$out"; t "setup: uncommitted changes in vmtool are reported, not shipped" $? "rc=$rc"

    # ---- TP_VM_HOST with a metacharacter or a space ----
    local h
    for h in 'a;b' 'a b' 'a$(x)' 'a|b' 'a`x`' 'a&b' 'a>b' "a'b" '-oProxyCommand=x' 'a*'; do
        scn full; HOSTV=$h vh check
        [[ $rc -eq 2 && ! -s $TP_LOG ]]; t "TP_VM_HOST='$h' exits 2 before any command" $? "rc=$rc"
    done
    scn full; HOSTV=$h vh setup; [[ $rc -eq 2 && ! -s $TP_LOG ]]; t "setup refuses a bad TP_VM_HOST too" $?

    # ---- local ----
    cat >"$d/vmtool/vmtool" <<'EOF'
#!/bin/bash
echo "vmtool $*" >>"$TP_LOG"
case "$*" in "images list") printf 'default:\n  %s\n' "${SC_IMG:-ubuntu2404.qcow2}" ;; esac
EOF
    chmod +x "$d/vmtool/vmtool"
    scn full; HOSTV=local vh check
    [[ $rc -eq 0 && $(grep -c '^ok ' <<<"$out") -eq 2 ]] && [[ $(cat "$TP_LOG") == "vmtool images list" ]]; t "local: check needs VMTOOL_DIR/vmtool and 'images list' naming the image; no ssh" $? "$out"
    scn full; SC_IMG=other.qcow2 HOSTV=local vh check
    [[ $rc -eq 2 ]]; t "local: an image list without ubuntu2404.qcow2 is a FAIL" $? "rc=$rc"

    # ---- quoting: what a zsh login shell makes of the string ----
    local S='printf "%s|" "$HOME" '"'a b'"' '"'*'"' '"'"'$(x)'"'"' '"'!'"' "it'"'"'s" "q\"q"; echo ";&|<>()"'
    local want_q got_q
    want_q=$(HOME=/h bash -c "$S")
    if command -v zsh >/dev/null 2>&1; then
        got_q=$(HOME=/h zsh -c "$(rcmd_string "$S")")
        [[ $got_q == "$want_q" ]]; t "quoting: the string survives zsh -c (\$HOME, quotes, * ! ; & | < > ( ) \$( ))" $?
    else
        echo "skip quoting under zsh (not installed here); the ssh stub's eval of the word list is the check"
    fi
    got_q=$(HOME=/h bash -c "$(rcmd_string "$S")" 2>&1)
    [[ $got_q == "$want_q" ]]; t "quoting: the string run by bash -c gives bash the script verbatim" $?

    echo "$npass passed, $nfail failed"
    [[ $nfail -eq 0 ]]
}

if [[ ${1:-} == --self-test ]]; then self_test; exit $?; fi
case ${1:-} in
    check) validate_settings; cmd_check ;;
    setup) validate_settings; cmd_setup ;;
    *) die "usage: vm-host.sh check | setup | --self-test" ;;
esac
