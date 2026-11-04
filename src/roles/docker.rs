//! `docker`: Docker Engine for the admin users, from Docker's own
//! repository. Port of `roles/docker/tasks/{main,debian,redhat}.yml` and
//! `roles/docker/vars/main.yml`; the understanding is in
//! `conversion/docker.md` (accepted 2026-11-04).
//!
//! Purpose: `dev_desktop` applies it after `dev_common`. The YAML only
//! dispatched to the unpinned Galaxy role `geerlingguy.docker`
//! (`debian.yml:11`, `redhat.yml:19`), whose code is not in the repo, so the
//! port writes the steps the role stood for: Docker's repository, the five
//! packages, the `docker` group, every admin user in it, and the daemon
//! running. No `get.docker.com`: Docker's own page says that script is for
//! testing, and a plan with the repo and package steps shows each of them.
//!
//! Hacks (a `sh!` standing in for a primitive; a search for `HACK(` finds
//! them when the primitive lands):
//! - `HACK(svc)`: the daemon start on the families whose package leaves it
//!   stopped; there is no service primitive yet (non-goal of goal 5b, D2).

use telepatch::facts::os::{Distro, Family, Os};
use telepatch::ops::repo::AptRepo;
use telepatch::{Host, TraceError, role, sh};

use crate::vars::Vars;

/// Docker's engine packages, the set Docker's install pages list and the
/// Galaxy role installed by default (`docker.md` Preserved knowledge 5).
const PACKAGES: [&str; 5] = [
    "docker-ce",
    "docker-ce-cli",
    "containerd.io",
    "docker-buildx-plugin",
    "docker-compose-plugin",
];

const BASE: &str = "https://download.docker.com/linux";

/// How a host gets Docker.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Source {
    /// Docker's apt repository `linux/<path>`; the daemon starts itself.
    Apt { path: &'static str },
    /// Docker's dnf repository `linux/<path>`; the daemon stays stopped.
    Dnf { path: &'static str },
    /// The distro's own `docker` package (Docker lists neither Arch nor
    /// Amazon Linux). `starts_itself`: Amazon Linux 2023 ships
    /// `docker.socket` enabled by preset, Arch ships nothing.
    Distro { starts_itself: bool },
}

/// The distro to its source, or an error naming the distro.
pub fn source(os: &Os) -> Result<Source, TraceError> {
    Ok(match &os.distro {
        // Pop!_OS takes Docker's Ubuntu repository (`debian.yml:3-5`);
        // the YAML did it with a `set_fact` of the distribution name.
        Distro::Ubuntu | Distro::PopOs => Source::Apt { path: "ubuntu" },
        Distro::Debian => Source::Apt { path: "debian" },
        // The YAML sent every RedHat-family host to `rhel`, Fedora
        // included (`redhat.yml:3-5`, docker.md bug); Docker publishes
        // `fedora` for it (A-5b-6).
        Distro::Fedora => Source::Dnf { path: "fedora" },
        Distro::Rocky | Distro::Alma => Source::Dnf { path: "rhel" },
        // Ansible did nothing on these two (`main.yml:3-9`); the doc adds
        // the distro package.
        Distro::Amazon => Source::Distro { starts_itself: true },
        Distro::Arch => Source::Distro { starts_itself: false },
        // Omarchy is Arch underneath and parses as `Other("omarchy")`.
        Distro::Other(_) if os.family == Family::Arch => Source::Distro { starts_itself: false },
        other => {
            return Err(TraceError::new(format!(
                "docker: no Docker source for distro {other:?}"
            )));
        }
    })
}

/// Fails with the distro's name when `docker` has no source for it.
pub fn check_distro(os: &Os) -> Result<(), TraceError> {
    source(os).map(|_| ())
}

#[role]
pub async fn docker(h: &Host<Vars>) -> Result<(), TraceError> {
    let src = source(&h.os)?;
    let needs_start = match &src {
        Source::Apt { path } => {
            // The suite is the release codename; on a derivative it is the
            // base's (`UBUNTU_CODENAME` first, as Docker's Ubuntu page).
            let suite = h.os.codename().ok_or_else(|| {
                TraceError::new("docker: the host's os-release names no release codename")
            })?;
            h.repo("docker").apt(AptRepo {
                uris: vec![format!("{BASE}/{path}")],
                suites: vec![suite.to_string()],
                components: vec!["stable".to_string()],
                key_url: format!("{BASE}/{path}/gpg"),
            });
            h.pkg(PACKAGES);
            // Docker's Debian and Ubuntu pages: the service starts itself
            // on the Debian family (the VM gate is the proof).
            false
        }
        Source::Dnf { path } => {
            // The `.repo` file Docker publishes (Docker's RHEL and Fedora
            // pages). `containerd.io` replaces `runc` on install and
            // `podman` coexists, so the YAML's `podman`/`runc` removal
            // (`redhat.yml:11-17`) is dropped (A-5b-15, probed on Rocky 9
            // and 10).
            h.repo("docker").dnf_url(&format!("{BASE}/{path}/docker-ce.repo"));
            h.pkg(PACKAGES);
            true
        }
        Source::Distro { starts_itself } => {
            h.pkg(["docker"]);
            !starts_itself
        }
    };

    // HACK(svc): "enabled and running". The package does not start the
    // daemon here ("This command installs Docker, but it doesn't start
    // Docker"; `is-enabled` prints `disabled` after install, probed on
    // rockylinux/rockylinux:10 2026-11-03). The guard keeps a running
    // daemon untouched; replace with `h.svc("docker")` when it exists.
    // Source: https://docs.docker.com/engine/install/rhel/ (accessed 2026-11-03)
    if needs_start {
        sh!(
            h,
            "systemctl enable --now docker",
            unless = "systemctl is-active --quiet docker"
        );
    }

    // The package creates the group on the Debian family and the others;
    // the op makes sure of it on every source, whatever a package does.
    h.group("docker");

    // `roles/docker/vars/main.yml:2`: `docker_users` is `admin_users`. The
    // account exists (admin_users runs first); only the group is added,
    // appended, never replacing the user's others. The group is
    // root-equivalent, which is why only these users get it.
    for u in &h.vars.admin_users {
        h.user(u).groups_add(["docker"]);
    }
    Ok(())
}
