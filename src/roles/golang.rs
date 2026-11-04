//! `golang`: the Go toolchain on every host, from go.dev. Replaces
//! `roles/golang/tasks/main.yml` of the ansible repo at commit 79d1ca1
//! (decision of the user, 2026-11-04: rewrite as a `Script` source wanting
//! Latest, install from go.dev sha256-checked; godoc dropped). Only
//! `playbooks/dev_desktop.yml:13` applies the role.
//!
//! The Ansible role includes the Galaxy role `gantsign.golang`
//! (`roles/golang/tasks/main.yml:3-5`), pinned to Go 1.26.1 in the
//! inventory (`inventories/group_vars/all:40`) and installing under
//! `/opt/go/<version>`. Its code is not in the repo, so nothing here
//! imitates it. Its README (unpinned in the ansible repo's
//! `tools/scripts/requirements.yml`, not mirrored) lists `golang_version`
//! (default `1.24.2`), `golang_install_dir` (default
//! `/opt/go/{{ golang_version }}`), a tarball fetched from
//! `https://storage.googleapis.com/golang` and verified against a sha256
//! (`golang_redis_sha256sum`, "required only for versions the role doesn't
//! preconfigure"), tested platforms Debian 11 and 12, Ubuntu 22.04 and
//! 24.04, Rocky Linux 9, Fedora 41 and openSUSE Tumbleweed, and no
//! `/etc/profile.d` script.
//! Source: https://github.com/gantsign/ansible-role-golang (accessed 2026-11-03)
//! The port reaches the intent instead: `/usr/local/go/bin/go`
//! is the newest stable release (the pin was the staleness, so there is
//! no `golang_version` in `Vars`), and login shells have it on `PATH`.
//! The old tree under `/opt/go/1.26.1` stays on a host that ran the Ansible
//! role; nothing here removes it. The VM check is `go version` in a login
//! shell (there is no Ansible baseline to diff: the Galaxy role installs
//! elsewhere and pins another version).
//!
//! Dropped: the per-user `godoc` install with `go install ...@latest`
//! (`roles/golang/tasks/main.yml:7-8`, `godoc.yml:1-29`). The tool is
//! deprecated upstream (`golang.org/x/tools/cmd/godoc` is marked
//! "Deprecated: godoc cannot select what version of a package is
//! displayed. Instead, use golang.org/x/pkgsite/cmd/pkgsite", module
//! version `v0.1.0-deprecated`; deprecated, not removed, and the page shows
//! no install command for `pkgsite`), telepatch has no `go install`
//! source, and the loop shared register names (`passwd_info`, `user_shell`)
//! with `rust_build`. Its login-shell check also treated a missing shell
//! like a missing godoc (`godoc.yml:19`, `ignore_errors`).
//! Source: https://pkg.go.dev/golang.org/x/tools/cmd/godoc (accessed 2026-11-03)
//! There is no `GOPATH` setting either: `$HOME/go`
//! (`roles/golang/vars/main.yml:1`, a literal `$HOME` only a shell
//! expands) is Go's own default.
//!
//! Go's own method (go.dev/doc/install, Linux): "Remove any previous Go
//! installation by deleting the `/usr/local/go` folder (if it exists), then
//! extract the archive ... into `/usr/local`", and "Do not untar the archive
//! into an existing `/usr/local/go` tree. This is known to produce broken Go
//! installations." Its example archive name is outdated; the current one
//! comes from go.dev/dl. The port therefore verifies the download before it
//! removes anything.
//! Source: https://go.dev/doc/install (accessed 2026-11-03)
//!
//! `GOTOOLCHAIN` defaults to `auto` (`go env GOTOOLCHAIN` and
//! `/usr/local/go/go.env` both said so, probed 2026-11-03): inside a module
//! whose `go` or `toolchain` line asks for a newer Go, `go version` can
//! print the downloaded toolchain's version, not `/usr/local/go`'s. A
//! version probe must run with `GOTOOLCHAIN=local` or outside a module;
//! the installed toolchain stays what this role installed, and toolchains
//! downloaded into a user's module cache are not this role's.
//! Source: https://go.dev/doc/toolchain (accessed 2026-11-03)

use telepatch::ops::pkg::{Latest, ScriptSpec};
use telepatch::{Host, TraceError, role};

use crate::vars::Vars;

/// Prints the newest stable release; the engine takes the first version
/// token of the output. `https://go.dev/VERSION?m=text` prints
/// `go1.27.3` then a `time 2026-10-19T22:20:36Z` line, so the first token
/// is `1.27.3` (probed 2026-11-03). `head -n1` keeps the second line out.
/// A settled host makes one request to go.dev per run, as rustup's
/// `Latest` does (A-5b-14), and a new release upgrades hosts on the next
/// run.
/// Source: https://go.dev/dl/ (accessed 2026-11-03)
pub const LATEST: &str = "curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1";

/// Install or update, run on the host with `TP_WANT` set to the wanted
/// version as the engine's version token: `1.27.3`, without the `go`
/// prefix (`script.rs` `version_token` drops it). A subshell with `set -eu`
/// keeps the failure rule out of the persistent shell. Only curl, tar and
/// coreutils are needed.
///
/// Order is the safety property: the tarball and the checksum list are
/// both fetched and `sha256sum -c` passes before `/usr/local/go` is
/// touched, so a failed download, an unlisted file or a mismatch leaves
/// the old Go in place. The temp dir goes on every path (`trap ... EXIT`).
/// Only the `rm -rf` and `tar` pair can leave a half tree, and only on a
/// full disk or a killed shell; the next run sees a wrong or missing
/// `go` and installs again.
///
/// The checksum comes from `https://go.dev/dl/?mode=json`, which lists
/// each file as an object with `"filename"` and, after it, `"sha256"`
/// (one key per line, checked 2026-11-03; the listing is newest first, each
/// file also has `os`, `arch`, `version`, `size` and `kind`, which is
/// `archive`, `installer` or `source`, the last with empty `os` and `arch`;
/// on that day the Linux amd64 archive was `go1.27.3.linux-amd64.tar.gz`,
/// sha256 `65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40`,
/// and the archive downloaded from `go.dev/dl/` on ubuntu:24.04 matched it
/// under `sha256sum -c`). Arch names are `amd64` and `arm64`, so `uname -m`
/// (`x86_64`, `aarch64`) maps to them. The `awk` remembers whether the
/// last `"filename"` was exactly ours (quotes included, so `...tar.gz.sig`
/// or another platform never match) and prints the next `"sha256"`. No
/// `jq` or python. Without `?include=all` the list holds only the current
/// stable releases and the previous one; `.latest()` always asks for the
/// newest, so it is listed. A pinned older `TP_WANT` would find no
/// checksum and fail here, which is the safe outcome (`include=all` would
/// serve it; add it if a pin is ever wanted).
/// Source: https://go.dev/dl/?mode=json (accessed 2026-11-03)
/// Source: https://go.dev/doc/install (accessed 2026-11-03)
pub const INSTALL: &str = r#"(
set -eu
case "$(uname -m)" in
  x86_64) a=amd64 ;;
  aarch64) a=arm64 ;;
  *) echo "golang: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac
f="go$TP_WANT.linux-$a.tar.gz"
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
curl -fsSL -o "$d/$f" "https://go.dev/dl/$f"
curl -fsSL -o "$d/dl.json" 'https://go.dev/dl/?mode=json'
sum=$(awk -v f="$f" '
  /"filename"/ { hit = (index($0, "\"" f "\"") > 0) }
  hit && /"sha256"/ { gsub(/.*"sha256"[ \t]*:[ \t]*"/, ""); gsub(/".*/, ""); print; exit }
' "$d/dl.json")
case "$sum" in
  *[!0-9a-f]*|"") echo "golang: no sha256 for $f in go.dev/dl/?mode=json" >&2; exit 1 ;;
esac
[ "${#sum}" -eq 64 ] || { echo "golang: bad sha256 for $f" >&2; exit 1; }
printf '%s  %s\n' "$sum" "$f" > "$d/sum"
(cd "$d" && sha256sum -c sum >/dev/null) || { echo "golang: sha256 mismatch for $f" >&2; exit 1; }
rm -rf /usr/local/go
tar -C /usr/local -xzf "$d/$f"
)"#;

/// Intent: any user's login shell runs `go`; Go is the newest stable
/// release. A `pkg` with a `Script` source wanting `Latest`: the probe
/// is `go version` (`go version go1.27.3 linux/amd64`, token `1.27.3`,
/// the same token the latest lookup gives for `go1.27.3`; the probe runs
/// outside a module, so `GOTOOLCHAIN=auto` cannot swap the toolchain, see
/// the module comment), the install and
/// update are the same replace-the-tree step, and a run with nothing newer
/// released changes nothing. Needs curl (`dev_common` installs it on
/// Debian-family hosts, the other bases ship it).
#[role]
pub async fn golang(h: &Host<Vars>) -> Result<(), TraceError> {
    h.script(
        "go",
        ScriptSpec::new()
            .bin("/usr/local/go/bin/go")
            .version("/usr/local/go/bin/go version")
            .latest(Latest::command(LATEST))
            .install(INSTALL)
            .update(INSTALL),
    )
    .latest();

    // `/usr/local/go/bin` on every login shell's PATH: intent is `go` by
    // name for every user. `/etc/profile.d` is read by login shells only
    // (as `mise.sh` in `dev_common`); the whole file is the one line,
    // mode 0644 like the other profile.d files. Appended, not prepended,
    // so a distro `go` or a mise shim keeps precedence.
    // Source: https://go.dev/doc/install (accessed 2026-11-03)
    h.file("/etc/profile.d/go.sh")
        .content("export PATH=\"$PATH:/usr/local/go/bin\"\n")
        .mode(0o644);
    Ok(())
}
