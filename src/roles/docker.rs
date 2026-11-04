//! `docker`: Docker Engine for the admin users, from Docker's own
//! repository. Port of `roles/docker/tasks/{main,debian,redhat}.yml` and
//! `roles/docker/vars/main.yml` of the ansible repo at commit 79d1ca1
//! (rewrite accepted by the user 2026-11-04).
//!
//! Purpose: `dev_desktop` applies it after `dev_common`, third of the
//! roles (`playbooks/dev_desktop.yml:10`); `admin_users` runs first so the
//! accounts exist, and `playbooks/minikube.yml` applies it too (not ported
//! here). The YAML only dispatched to the unpinned Galaxy role
//! `geerlingguy.docker` (`debian.yml:11`, `redhat.yml:19`) by `debian_based`
//! and `redhat_based` (`main.yml:3-9`, `inventories/group_vars/all:4,6`).
//! Its code is not in the repo (it is listed without a version in the
//! ansible repo's `tools/scripts/requirements.yml`, not mirrored); from its
//! README: `docker_users` are added to the `docker` group, the service is
//! started and enabled, Docker's repository is added and
//! `docker-compose-plugin` is installed by default, and it lists no Rocky
//! or Alma support.
//! Source: https://github.com/geerlingguy/ansible-role-docker (accessed 2026-11-03)
//! So the port writes the steps the role stood for: Docker's repository,
//! the five packages, the `docker` group, every admin user in it, and the
//! daemon running. No `get.docker.com`: Docker's Ubuntu page says the
//! script "isn't recommended for production environments" and is only for
//! testing and development, and a plan with the repo and package steps
//! shows each of them while a settled host makes no call to a script.
//! Source: https://docs.docker.com/engine/install/ubuntu/ (accessed 2026-11-03)
//!
//! The YAML also carried, and the port drops, two `set_fact` overrides of
//! the family: `debian.yml:7` sets `ansible_os_family` to `Pop!_OS` where
//! Ansible's own table already says `Debian`, so its condition is never
//! true; `redhat.yml:7` sets `RedHat` where it already is. Both are no-ops.
//!
//! Docker's platform table lists CentOS, Debian, Fedora, Raspberry Pi OS,
//! RHEL and Ubuntu; Arch Linux and Amazon Linux are not in it, Pop!_OS is
//! not named, Ubuntu derivatives follow the Ubuntu steps and "Docker
//! doesn't test or verify installation on distribution derivatives."
//! Source: https://docs.docker.com/engine/install/ (accessed 2026-11-03)
//!
//! The VM gate is `docker run --rm hello-world` for an admin user in a
//! login shell (no Ansible baseline exists for this role, so nothing is
//! diffed against it); the five package names, `docker.sources`, the key,
//! and `id -nG <u>` showing `docker` are what a run is checked on.
//!
//! Hacks: none.

use telepatch::facts::os::{Distro, Family, Os};
use telepatch::ops::repo::AptRepo;
use telepatch::{Host, TraceError, role};

use crate::vars::Vars;

/// Docker's engine packages, the set Docker's install pages list and the
/// Galaxy role installed by default (the YAML itself holds no list or pin
/// for the Debian family: the list is the role's defaults). Docker's pages
/// give the same five names for apt and dnf.
/// Source: https://docs.docker.com/engine/install/ubuntu/ (accessed 2026-11-03)
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
    /// Docker's apt repository `linux/<path>`.
    Apt { path: &'static str },
    /// Docker's dnf repository `linux/<path>`.
    Dnf { path: &'static str },
    /// The distro's own `docker` package (Docker lists neither Arch nor
    /// Amazon Linux).
    Distro,
}

/// The distro to its source, or an error naming the distro.
pub fn source(os: &Os) -> Result<Source, TraceError> {
    Ok(match &os.distro {
        // Pop!_OS takes Docker's Ubuntu repository (`debian.yml:3-5`);
        // the YAML did it with a `set_fact` of the distribution name.
        Distro::Ubuntu | Distro::PopOs => Source::Apt { path: "ubuntu" },
        Distro::Debian => Source::Apt { path: "debian" },
        // The YAML sent every RedHat-family host to `rhel`, Fedora
        // included (`redhat.yml:3-5`; a bug, and Docker publishes a
        // `centos` one for CentOS the same way); Docker publishes
        // `fedora` for it (A-5b-6). Rocky and Alma are named by no Docker
        // page, yet the `rhel` repository installs `docker-ce` 29.9.3 and
        // `containerd.io` 2.4.2 on rockylinux/rockylinux:10, rockylinux:9
        // and almalinux:10, and the `fedora` one on fedora:43 (probed
        // 2026-11-03, each creates the group `docker`). All five
        // `download.docker.com/linux/{rhel,centos,fedora,debian,ubuntu}/gpg`
        // paths answered 200 that day.
        // Open: `docker run --rm almalinux:9 sh -c 'dnf -y -q install
        // dnf-plugins-core && dnf config-manager --add-repo
        // https://download.docker.com/linux/rhel/docker-ce.repo && dnf -y -q
        // install docker-ce containerd.io && rpm -q docker-ce'` for Alma 9.
        Distro::Fedora => Source::Dnf { path: "fedora" },
        Distro::Rocky | Distro::Alma => Source::Dnf { path: "rhel" },
        // Ansible did nothing on these two (`main.yml:3-9`: neither is
        // `debian_based` or `redhat_based`); the port adds the distro
        // package, which Docker's repositories do not list. Arch `extra`
        // served `docker` 1:29.9.2-1 and Amazon Linux 2023 served `docker`
        // 25.0.16 from its own repository (probed 2026-11-03), four majors
        // behind Docker's 29.x: Amazon's package is the only one for that
        // platform, so the version gap is recorded, not fixed.
        // Source: https://docs.aws.amazon.com/linux/al2023/ug/install-docker.html (accessed 2026-11-03; the URL served the page titled "Using AL2023 in containers", which names the `docker` package and gives no start step)
        Distro::Amazon => Source::Distro,
        Distro::Arch => Source::Distro,
        // Omarchy is Arch underneath and parses as `Other("omarchy")`.
        Distro::Other(_) if os.family == Family::Arch => Source::Distro,
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
    match &src {
        Source::Apt { path } => {
            // The suite is the release codename; on a derivative it is the
            // base's (`UBUNTU_CODENAME` first, as Docker's Ubuntu page:
            // `${UBUNTU_CODENAME:-$VERSION_CODENAME}`; the Debian page uses
            // `$VERSION_CODENAME`). Docker's page writes
            // `/etc/apt/sources.list.d/docker.sources` (deb822: `Types: deb`,
            // `Components: stable`, `Architectures:` from `dpkg
            // --print-architecture`, `Signed-By:
            // /etc/apt/keyrings/docker.asc`) from the armored key at
            // `<path>/gpg`; the ops below write the same. An armored `.asc`
            // key needs no `gnupg` (probed 2026-11-03: `apt-get update`
            // against `noble/stable` on ubuntu:24.04 and `bookworm/stable`
            // on debian:12 with no `gnupg` installed, then the five
            // packages, docker-ce 5:29.9.3, containerd.io 2.4.2; the group
            // `docker` exists afterwards, from the `docker-ce` postinst
            // `groupadd --system docker`; A-5b-9). Supported by Docker:
            // Ubuntu 26.10, 26.04, 24.04, 22.04.
            // Source: https://docs.docker.com/engine/install/ubuntu/ (accessed 2026-11-03)
            // Source: https://docs.docker.com/engine/install/debian/ (accessed 2026-11-03)
            // Open: `grep -E 'UBUNTU_CODENAME|VERSION_CODENAME' /etc/os-release`
            // on a Pop!_OS host prints the Ubuntu codename the suite must
            // use.
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
        }
        Source::Dnf { path } => {
            // The `.repo` file Docker publishes (Docker's RHEL and Fedora
            // pages: the RHEL page adds it with `dnf config-manager
            // --add-repo` after `dnf-plugins-core`, the Fedora page with the
            // dnf5 form `config-manager addrepo --from-repofile`; the file's
            // `baseurl` is `.../linux/rhel/$releasever/$basearch/stable`).
            // `containerd.io` replaces `runc` on install and
            // `podman` coexists, so the YAML's `podman`/`runc` removal
            // (`redhat.yml:11-17`, which Docker's RHEL page also lists) is
            // dropped (A-5b-15), as is deleting a tool the host may use.
            // Probe 2026-11-03, rockylinux/rockylinux:10: podman 5.8.2 and
            // crun installed first (no runc), the `rhel` repo, then the five
            // packages complete with no conflict and podman stays;
            // rockylinux:9: podman, runc and crun first, afterwards
            // `docker-ce` and `containerd.io` are present, podman stays and
            // runc is gone (replaced by `containerd.io`). The repo step
            // needs `dnf-plugins-core` first on those images. Docker
            // supports RHEL 8, 9 and 10, CentOS Stream 9 and 10 and Fedora
            // 45, 44 and 43.
            // Source: https://docs.docker.com/engine/install/rhel/ (accessed 2026-11-03)
            // Source: https://docs.docker.com/engine/install/centos/ (accessed 2026-11-03)
            // Source: https://docs.docker.com/engine/install/fedora/ (accessed 2026-11-03)
            h.repo("docker").dnf_url(&format!("{BASE}/{path}/docker-ce.repo"));
            h.pkg(PACKAGES);
        }
        Source::Distro => {
            h.pkg(["docker"]);
        }
    }

    // "Docker enabled and running", on every family. The package already
    // does it on the Debian family, where the op finds nothing to do; the
    // others leave the daemon stopped ("This command installs Docker, but it
    // doesn't start Docker"; `is-enabled` prints `disabled` after install,
    // probed on rockylinux/rockylinux:10 2026-11-03).
    // Daemon state after install, per family (probed 2026-11-03):
    // Ubuntu, Debian, Pop!_OS running and enabled ("The `docker` service
    // starts automatically on Debian based distributions"; the Ubuntu page
    // is ambiguous, saying so only in its convenience-script section and
    // telling the reader to check `systemctl status docker`, so the VM
    // gate `docker run --rm hello-world` on Ubuntu 24.04 is the proof);
    // Fedora, Rocky, Alma neither started nor enabled; Arch not enabled
    // (the `docker` pacman package ships no install script and no preset
    // entry; the Arch Wiki's Docker page answered "Access Denied" on
    // 2026-11-03, so that row rests on the probe only); Amazon Linux 2023
    // has `docker.socket` enabled by preset (`rpm -q --scripts docker`
    // calls `systemd-update-helper install-system-units docker.service
    // docker.socket`; `/usr/lib/systemd/system-preset/90-default.preset:270`
    // is `enable docker.socket`), which starts the service on first use; the
    // op enables and starts `docker.service` itself all the same.
    // Docker's post-install page: `systemctl enable docker.service` and
    // `containerd.service` start them at boot.
    // Source: https://docs.docker.com/engine/install/rhel/ (accessed 2026-11-03)
    // Source: https://docs.docker.com/engine/install/linux-postinstall/ (accessed 2026-11-03)
    // Source: https://wiki.archlinux.org/title/Docker (accessed 2026-11-03)
    // Open: on an `amazonlinux:2023` VM, `dnf -y install docker && systemctl
    // is-enabled docker.socket docker.service && docker run --rm
    // hello-world` shows what the package leaves there.
    // Open: on an Arch VM, `pacman -S --noconfirm docker && systemctl
    // is-enabled docker.service docker.socket` prints what the package
    // leaves.
    h.svc("docker").enabled().started();

    // The package creates the group on the Debian family and the others;
    // the op makes sure of it on every source, whatever a package does.
    h.group("docker");

    // `roles/docker/vars/main.yml:2`: `docker_users` is `admin_users`. The
    // account exists (admin_users runs first); only the group is added,
    // appended, never replacing the user's others. The group is
    // root-equivalent ("grants root-level privileges to the user", Docker's
    // post-install page), which is why only these users get it.
    // Source: https://docs.docker.com/engine/install/linux-postinstall/ (accessed 2026-11-03)
    for u in &h.vars.admin_users {
        h.user(u).groups_add(["docker"]);
    }
    Ok(())
}
