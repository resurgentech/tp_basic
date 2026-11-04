//! `vm_server`: the host runs KVM guests through libvirt, and the admin
//! users manage the system libvirt without root. Port of
//! `roles/vm_server/tasks/{main,debian,redhat,vagrant_per_user}.yml` and
//! `roles/vm_server/vars/main.yml`, shrunk as the user decided on
//! 2026-11-04 (accepted), of the ansible repo at commit 79d1ca1.
//!
//! Purpose: `dev_desktop.yml:11` applies it fourth, after `admin_users`
//! (so the accounts exist), and `playbooks/minikube.yml` applies it too
//! (not ported here). The YAML installed a long per-family list (KVM,
//! libvirt, virt tools, `ansible`, and on RedHat `ruby*` and `*-devel`;
//! `vars/main.yml:3-37`: `debian_packages_kvm`, `redhat_packages_kvm`) and
//! a `/usr/bin/vagrant` wrapper that ran Vagrant in a container
//! (`debian.yml:3-13`, `redhat.yml:3-13`), then per admin user the group
//! `libvirt` and four `.vagrant.d` directories
//! (`vagrant_per_user.yml:3-40`); dispatch was by `debian_based` and
//! `redhat_based` (`main.yml:2-8`), the per-user include looped over
//! `admin_users` (`main.yml:10-11`). There is no Ansible baseline for the
//! shrunk role; the VM check is `virsh --version` for an admin user in a
//! login shell (client only: `virsh -c qemu:///system version` needs the
//! daemon and KVM and is printed only, A-5b-13) and `id -nG <u>` showing
//! `libvirt`. Probed `virsh --version` after the kept packages, 2026-11-03:
//! 10.0.0 (Ubuntu 24.04), 9.0.0 (Debian 12), 11.10.0 (Rocky 10), 12.0.0
//! (Amazon Linux 2023), 12.9.0 (Arch).
//!
//! Dropped (what the YAML did beyond the shrunk role):
//! - the `/usr/bin/vagrant` wrappers (`debian.yml:9-13`, `redhat.yml:9-13`)
//!   and the four `.vagrant.d` directories (`vagrant_per_user.yml:10-40`).
//!   Bug fixed: they were mode 0777, so any local user could replace an
//!   executable others run or write into the others' homes; the wrapper ran
//!   an unpinned image (`vagrant-libvirt:latest`) through `eval`.
//! - `ansible`, `ruby`, `ruby-devel`, `openssl-devel`, `libvirt-devel`
//!   (`vars/main.yml:3-37`): they served Vagrant plugins or nothing.
//! - the python and nss bindings, `virt-manager`, `virt-top`,
//!   `libguestfs-tools`, `genisoimage` and the SELinux python tools: the
//!   user kept only KVM, the libvirt daemon and clients, virt-install and
//!   bridge utils ("a workstation that wants `virt-manager` installs it by
//!   hand"; `virsh` and the group are the proof, the list was written for
//!   the Vagrant workflow). `qemu-utils`/`qemu-img` are no separate
//!   request: the `qemu-kvm` request pulls `qemu-utils` on Ubuntu.
//!   `ansible`, `ruby*`, `*-devel` and the SELinux tools
//!   (`policycoreutils-python-utils`, `libselinux-python3`; the first is
//!   also requested on Debian, `vars/main.yml:24`, where it exists) served
//!   the dropped Vagrant plugins and `selinux_booleans_kvm`, which no task
//!   read (`vars/main.yml:39-40` is its only mention).
//! - `selinux_booleans_kvm` and `vagrant_version` (`vars/main.yml:1,39-40`):
//!   no task read either. `vagrant_version: '2.2.19'` is defined and read
//!   by nothing, and the commented-out download at `main.yml:13-18` is a
//!   TODO for a `vagrant_tools` file with no known source.
//! - The two wrappers differed by container tool and mount set (docker
//!   mounts `~/.vagrant.d:/.vagrant.d`; podman mounts `boxes`, `data` and
//!   `tmp` separately and runs `--privileged`), which is why the four
//!   `.vagrant.d` directories were 0777 (`files/vagrant.docker:14-24`,
//!   `files/vagrant.podman:14-29`). There is no vendor method to compare:
//!   the role installed no Vagrant, only the wrappers.
//!
//! Bug fixed: the YAML dispatched on `debian_based` and `redhat_based`
//! only (`main.yml:2-8`), so Arch and Amazon Linux 2023 installed nothing
//! and then failed at the `libvirt` group task (`vagrant_per_user.yml:3-8`).
//! The port gives them the distro packages: Arch `libvirt`, `qemu-base`,
//! `virt-install`; Amazon Linux 2023 `qemu-kvm`, `libvirt`,
//! `libvirt-client` (the repository has no `virt-install`). `dnsmasq` and
//! `iptables-nft` are optional dependencies of Arch's `libvirt` for the
//! default NAT network and are not requested.
//!
//! Hacks: none.

use telepatch::facts::os::{Distro, Family, Os};
use telepatch::{Host, TraceError, role};

use crate::vars::Vars;

/// Where the packages put the daemon, which decides the socket start.
enum Kit {
    /// Debian family: the packages enable `libvirtd.socket` themselves.
    Debian,
    /// Fedora, Rocky, Alma: the preset enables `virtqemud.socket`.
    RedHat,
    /// Amazon Linux 2023: modular daemons, units left disabled.
    Amazon,
    /// Arch and Omarchy: units left disabled.
    Arch,
}

fn kit(os: &Os) -> Result<Kit, TraceError> {
    // Amazon Linux is `Family::RedHat` in the engine but not `redhat_based`
    // in the YAML (`inventories/group_vars/all:4`) and has its own package
    // set (no `virt-install`), so it is tested first, by distribution.
    if os.distro == Distro::Amazon {
        return Ok(Kit::Amazon);
    }
    Ok(match os.family {
        Family::Debian => Kit::Debian,
        Family::RedHat => Kit::RedHat,
        Family::Arch => Kit::Arch,
        _ => {
            return Err(TraceError::new(format!(
                "vm_server: no libvirt packages for distro {:?}",
                os.distro
            )));
        }
    })
}

#[role]
pub async fn vm_server(h: &Host<Vars>) -> Result<(), TraceError> {
    // The package sets are the user's decision (2026-11-04) and resolve on
    // every family covered (probed 2026-11-03 in throwaway containers):
    // Ubuntu 24.04 libvirt 10.0.0, `virtinst` 4.1.0, `bridge-utils` 1.7.1;
    // Debian 12 libvirt 9.0.0 and the same two; Rocky 9 and 10 `qemu-kvm`
    // 10.1.0, `libvirt` 11.10.0, `virt-install` 5.1.0 (appstream); Fedora
    // 43 `qemu-kvm` 10.1.5, `libvirt` 11.6.0, `virt-install` 5.1.0
    // (updates); Amazon Linux 2023 `qemu-kvm` 11.0.0, `libvirt` 12.0.0
    // (amazonlinux repo); Arch `libvirt` 1:12.9.0, `qemu-base` 11.1.3,
    // `virt-install` 5.1.0 (extra). Ubuntu's own server page installs
    // `qemu-kvm libvirt-daemon-system` and adds the user with `adduser
    // $USER libvirt`, and does not say whether the system daemon starts.
    // Source: https://ubuntu.com/server/docs/how-to/virtualisation/libvirt/ (accessed 2026-11-03)
    match kit(&h.os)? {
        // The YAML requested `qemu-kvm` (`vars/main.yml:25`). On this family
        // it is a virtual package provided by `qemu-system-x86`, with no
        // candidate: `apt-get install` succeeds but the name is never
        // installed, so `pkg` would report it missing on every run and the
        // second pass would never reach `CHANGED 0`. Request the real name.
        // Probed 2026-11-03: `apt-get install qemu-kvm` on ubuntu:24.04
        // exits 0 and installs `qemu-system-x86` 1:8.2.2, after which
        // `dpkg -l qemu-kvm` shows status `un`; Debian 12 behaves the same.
        // Open: `docker run --rm ubuntu:24.04 sh -c 'apt-get update -qq &&
        // apt-get install -y -qq qemu-kvm && dpkg -l qemu-system-x86
        // qemu-kvm'` shows the installed name (`qemu-system-x86` `ii`,
        // `qemu-kvm` `un`); the VM gate's second pass (`CHANGED 0`) settles
        // whether `pkg` would count the virtual name as installed, which
        // the real name makes moot.
        Kit::Debian => h.pkg([
            "qemu-system-x86",
            "libvirt-daemon-system",
            "libvirt-clients",
            "virtinst",
            "bridge-utils",
        ]),
        Kit::RedHat => h.pkg(["qemu-kvm", "libvirt", "libvirt-client", "virt-install"]),
        // The repository has no `virt-install` package.
        Kit::Amazon => h.pkg(["qemu-kvm", "libvirt", "libvirt-client"]),
        Kit::Arch => h.pkg(["libvirt", "qemu-base", "virt-install"]),
    };

    // "Socket enabled and running", one `svc` per kit. The Debian family and
    // the Fedora/EL preset leave the socket enabled (`is-enabled` probed in
    // containers 2026-11-03), where the op finds nothing to do; on Amazon
    // Linux 2023 `virtqemud.socket` is disabled after install and on Arch
    // `libvirtd.socket` is. libvirt starts the daemon on the first
    // connection once the socket is enabled ("There is no need to start the
    // services").
    // Source: https://libvirt.org/daemons.html (accessed 2026-11-03)
    // Probe 2026-11-03 (containers have no running systemd, so
    // "enabled" is the unit state, not proof the service answers): Ubuntu
    // 24.04 and Debian 12 have `libvirtd.socket` and `libvirtd.service`
    // enabled; Fedora 43 and Rocky 10 have `virtqemud.socket` and
    // `virtqemud.service` enabled by the preset (`libvirtd.*` disabled);
    // Amazon Linux 2023 has `virtqemud.*` disabled and no `libvirtd` units;
    // Arch has all four disabled.
    // Open: on an `amazonlinux:2023` VM, `dnf -y install libvirt qemu-kvm
    // libvirt-client && systemctl enable --now virtqemud.socket && virsh -c
    // qemu:///system version` shows whether the modular socket is the unit
    // to enable there.
    // Open: on an Arch VM, `pacman -S --noconfirm libvirt qemu-base &&
    // systemctl enable --now libvirtd.socket && virsh -c qemu:///system
    // version` shows whether the monolithic socket is the unit to enable.
    // Open: on a `rockylinux/rockylinux:10` VM, `dnf -y install libvirt
    // qemu-kvm libvirt-client && systemctl is-active virtqemud.socket` shows
    // whether the install also started the socket.
    let socket = match kit(&h.os)? {
        Kit::Debian | Kit::Arch => "libvirtd.socket",
        Kit::RedHat | Kit::Amazon => "virtqemud.socket",
    };
    h.svc(socket).enabled().started();

    // `vagrant_per_user.yml:3`: "Admin users need this group to avoid
    // annoying GUI warnings"; it is what lets a user manage the system
    // libvirt without root. A package creates the group (`libvirt-daemon-
    // system`, `libvirt-daemon-common`, or a sysusers entry), so there is
    // no `group` op: its name must be the package's. The user op runs after
    // the packages; appended, never replacing the user's other groups.
    // Probed 2026-11-03: after `libvirt-clients` alone the group is absent
    // on Debian 12; after `libvirt-daemon-system` it exists on Ubuntu 24.04
    // (`libvirt:x:104:ubuntu`) and Debian 12 (`libvirt:x:108:`; its postinst
    // runs `addgroup --quiet --system libvirt`); on the RedHat family after
    // `libvirt-daemon` (the `libvirt-daemon-common` scriptlet, seen on Rocky
    // 10), on Fedora 43, Rocky 9 and 10 and Amazon Linux 2023; on Arch
    // after `libvirt` + `qemu-base` (the sysusers entry
    // `/usr/lib/sysusers.d/libvirt.conf`). The YAML asked for it on Arch and
    // Amazon Linux too and failed there, having installed nothing.
    for u in &h.vars.admin_users {
        h.user(u).groups_add(["libvirt"]);
    }
    Ok(())
}
