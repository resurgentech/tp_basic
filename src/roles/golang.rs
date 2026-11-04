//! `golang`: the Go toolchain on every host, from go.dev. Replaces
//! `roles/golang/tasks/main.yml` (decision in `conversion/golang.md`,
//! "Position": rewrite as a `Script` source wanting Latest; godoc dropped).
//!
//! The Ansible role includes the Galaxy role `gantsign.golang`
//! (`roles/golang/tasks/main.yml:3-5`), pinned to Go 1.26.1 in the
//! inventory (`inventories/group_vars/all:40`) and installing under
//! `/opt/go/<version>`. Its code is not in the repo, so nothing here
//! imitates it. The port reaches the intent instead: `/usr/local/go/bin/go`
//! is the newest stable release, and login shells have it on `PATH`.
//!
//! Dropped: the per-user `godoc` install with `go install ...@latest`
//! (`roles/golang/tasks/main.yml:7-8`, `godoc.yml:1-29`). The tool is
//! deprecated upstream and the loop shared register names with
//! `rust_build` (`conversion/golang.md`, task table). There is no `GOPATH`
//! setting either: `$HOME/go` (`roles/golang/vars/main.yml:1`) is Go's own
//! default.

use telepatch::ops::pkg::{Latest, ScriptSpec};
use telepatch::{Host, TraceError, role};

use crate::vars::Vars;

/// Prints the newest stable release; the engine takes the first version
/// token of the output. `https://go.dev/VERSION?m=text` prints
/// `go1.27.3` then a `time ...` line, so the first token is `1.27.3`
/// (probed 2026-11-03). `head -n1` keeps the second line out.
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
/// (one key per line, checked 2026-11-03). The `awk` remembers whether the
/// last `"filename"` was exactly ours (quotes included, so `...tar.gz.sig`
/// or another platform never match) and prints the next `"sha256"`. No
/// `jq` or python. Without `?include=all` the list holds only the current
/// stable releases and the previous one; `.latest()` always asks for the
/// newest, so it is listed. A pinned older `TP_WANT` would find no
/// checksum and fail here, which is the safe outcome (`include=all` would
/// serve it; add it if a pin is ever wanted).
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
/// the same token the latest lookup gives for `go1.27.3`), the install and
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
