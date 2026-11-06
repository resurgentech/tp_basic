//! `golang`: the Go toolchain on every host, from go.dev. Replaces
//! `roles/golang/tasks/main.yml` of the ansible repo at commit 79d1ca1
//! (decision of the user, 2026-11-04: install from go.dev sha256-checked,
//! wanting Latest; godoc dropped; 2026-11-06: on the `binary_release` source
//! instead of an installer script). Only
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

use telepatch::ops::pkg::{BinaryRelease, Latest, Sum};
use telepatch::{Host, TraceError, role};

use crate::vars::Vars;

/// Intent: any user's login shell runs `go`; Go is the newest stable
/// release. A `pkg` with a `binary_release` source wanting `Latest`.
/// What the engine does with it:
///
/// - `Latest::text("https://go.dev/VERSION?m=text")`: that URL prints
///   `go1.27.3` then a `time 2026-10-19T22:20:36Z` line; the engine takes
///   the first version token of the output, `1.27.3`, which fills
///   `{version}` (probed 2026-11-03). A settled host makes one request to
///   go.dev per run, and a new release upgrades hosts on the next run.
/// - `{arch}` defaults to go.dev's own naming, `x86_64` -> `amd64` and
///   `aarch64` -> `arm64`.
/// - The checksum comes from `https://go.dev/dl/?mode=json`, which lists
///   each file as an object with `"filename"` and `"sha256"` (the listing is
///   newest first; each file also has `os`, `arch`, `version`, `size` and
///   `kind`). `Sum::json` picks the entry whose `filename` is exactly the
///   archive's name. Without `?include=all` the list holds only the current
///   stable releases and the previous one; `.latest()` always asks for the
///   newest, so it is listed. A pinned older version would find no checksum
///   and fail, which is the safe outcome (`include=all` would serve it; add
///   it if a pin is ever wanted).
/// - Order is the safety property: download and verification happen in
///   prepare, and `/usr/local/go` is swapped only after the sha256 matches,
///   so a failed download, an unlisted file or a mismatch leaves the old Go
///   in place (Go's own method removes the old tree and never untars over
///   it).
/// - `.unpack_to("/usr/local/go").strip(1)`: the archive's top `go/`
///   directory is dropped, so its contents land directly in
///   `/usr/local/go`.
/// - `.version("go version")` prints `go version go1.27.3 linux/amd64`,
///   token `1.27.3`, the same token the latest lookup gives for `go1.27.3`.
///   The engine runs it with `bin`'s directory first on `PATH`, so it finds
///   `/usr/local/go/bin/go`. The probe runs outside a module, so
///   `GOTOOLCHAIN=auto` cannot swap the toolchain (see the module comment).
///
/// Needs curl or wget on the host in prepare (`dev_common` installs curl on
/// Debian-family hosts, the other bases ship it). When `dev_common`'s op is
/// in the same window and the host has neither tool, the engine splits the
/// window after that op (the plan's `-- split after ..` line), so no
/// barrier is written here.
/// Source: https://go.dev/dl/?mode=json (accessed 2026-11-03)
/// Source: https://go.dev/dl/ (accessed 2026-11-03)
/// Source: https://go.dev/doc/install (accessed 2026-11-03)
#[role]
pub async fn golang(h: &Host<Vars>) -> Result<(), TraceError> {
    h.pkg(["go"])
        .binary_release(
            BinaryRelease::new()
                .url("https://go.dev/dl/go{version}.linux-{arch}.tar.gz")
                .sha256(Sum::json("https://go.dev/dl/?mode=json", "filename", "sha256"))
                .unpack_to("/usr/local/go")
                .strip(1)
                .bin("/usr/local/go/bin/go")
                .version("go version")
                .latest(Latest::text("https://go.dev/VERSION?m=text")),
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
