//! `edge`: the Goal 8 edge list, one role. The Ansible side is
//! `playbooks/edge`. This role is that play's first role; `edge_extra`
//! follows and only adds the `rust-src` component.
//!
//! Order is the list's order. Support packages (`curl`, `ca-certificates`)
//! and the family's virtual name go in one `pkg` before the repo and
//! before rustup. Debian asks for `libz-dev` (provided by `zlib1g-dev`).
//! Red Hat, Amazon included, asks for `mailx` (provided by `s-nail`).
//! Arch, omarchy included, asks for `sh` (provided by `bash`). Docker's
//! repo is the one `docker` spells: apt `linux/{debian,ubuntu}` or a dnf
//! `.repo` of `fedora` or `rhel`, then only `docker-ce-cli`. Amazon and
//! Arch get no repo and no `docker-ce-cli`. The marker file is the five
//! bytes `edge\n`. The jq binary is the 1.7.1 `jq-linux-amd64` release,
//! checksummed, at `/usr/local/bin/edge-jq`. Rustup is toolchain `stable`,
//! profile `default` (the unset profile), not `.latest()`, and it is the
//! last op so `edge_extra`'s component merges into the same op.

use telepatch::facts::os::{Distro, Family};
use telepatch::ops::repo::AptRepo;
use telepatch::{Host, TraceError, role};

use crate::vars::Vars;

const BASE: &str = "https://download.docker.com/linux";

/// `jq-linux-amd64` line of the jq 1.7.1 `sha256sum.txt`.
const JQ_URL: &str = "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64";
const JQ_SHA256: &str = "5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5";

/// Docker's apt repository for `path` (`debian` or `ubuntu`), then
/// `docker-ce-cli` only.
fn docker_apt(h: &Host<Vars>, path: &str) -> Result<(), TraceError> {
    let suite = h
        .os
        .codename()
        .ok_or_else(|| TraceError::new("edge: the host's os-release names no release codename"))?;
    h.repo("docker").apt(AptRepo {
        uris: vec![format!("{BASE}/{path}")],
        suites: vec![suite.to_string()],
        components: vec!["stable".to_string()],
        key_url: format!("{BASE}/{path}/gpg"),
    });
    h.pkg(["docker-ce-cli"]);
    Ok(())
}

/// The family's Docker edge. Amazon and Arch stop after the virtual name.
fn docker(h: &Host<Vars>) -> Result<(), TraceError> {
    match &h.os.distro {
        Distro::Ubuntu | Distro::PopOs => docker_apt(h, "ubuntu"),
        Distro::Debian => docker_apt(h, "debian"),
        Distro::Fedora => {
            h.repo("docker")
                .dnf_url(&format!("{BASE}/fedora/docker-ce.repo"));
            h.pkg(["docker-ce-cli"]);
            Ok(())
        }
        Distro::Rocky | Distro::Alma => {
            h.repo("docker")
                .dnf_url(&format!("{BASE}/rhel/docker-ce.repo"));
            h.pkg(["docker-ce-cli"]);
            Ok(())
        }
        Distro::Amazon | Distro::Arch => Ok(()),
        Distro::Other(_) if h.os.family == Family::Arch => Ok(()),
        other => Err(TraceError::new(format!(
            "edge: no docker source for distro {other:?}"
        ))),
    }
}

#[role]
pub async fn edge(h: &Host<Vars>) -> Result<(), TraceError> {
    match h.os.family {
        Family::Debian => h.pkg(["curl", "ca-certificates", "zlib1g-dev", "libz-dev"]),
        Family::RedHat => h.pkg(["curl", "ca-certificates", "s-nail", "mailx"]),
        Family::Arch => h.pkg(["curl", "ca-certificates", "bash", "sh"]),
        Family::Other(ref name) => {
            return Err(TraceError::new(format!(
                "edge: no package edge for family {name}"
            )));
        }
    };
    docker(h)?;
    // Five bytes, not a secret. `file().content()` is not redacted, so the
    // plan shows the base64.
    h.file("/usr/local/share/telepatch-edge.txt")
        .content("edge\n")
        .mode(0o644);
    let jq = h.fetch(JQ_URL).sha256(JQ_SHA256);
    h.file("/usr/local/bin/edge-jq").from(&jq).mode(0o755);
    // Last, so `edge_extra`'s `rust-src` is the next rustup op and the two
    // merge. Profile stays the default. Not `.latest()`.
    h.pkg(["stable"]).rustup();
    Ok(())
}
