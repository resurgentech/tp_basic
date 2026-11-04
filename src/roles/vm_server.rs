//! `vm_server`: the host runs KVM guests through libvirt, and the admin
//! users manage the system libvirt without root. Port of
//! `roles/vm_server/tasks/{main,debian,redhat,vagrant_per_user}.yml` and
//! `roles/vm_server/vars/main.yml`, shrunk as the user decided on
//! 2026-11-04; the understanding is in `conversion/vm_server.md`
//! (accepted).
//!
//! Dropped (`vm_server.md` Outcomes, "Every host"):
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
//!   bridge utils (`vm_server.md` Position).
//! - `selinux_booleans_kvm` and `vagrant_version` (`vars/main.yml:1,39-40`):
//!   no task read either.
//!
//! Bug fixed: the YAML dispatched on `debian_based` and `redhat_based`
//! only (`main.yml:2-8`), so Arch and Amazon Linux 2023 installed nothing
//! and then failed at the `libvirt` group task (`vagrant_per_user.yml:3-8`).
//! The port gives them the distro packages.
//!
//! Hacks (a `sh!` standing in for a primitive; a search for `HACK(` finds
//! them when the primitive lands):
//! - `HACK(svc)`: the libvirt socket on Arch and Amazon Linux 2023, where
//!   the packages leave it disabled; there is no service primitive yet
//!   (non-goal of goal 5b, D2).

use telepatch::facts::os::{Distro, Family, Os};
use telepatch::{Host, TraceError, role, sh};

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
    // The package sets are `vm_server.md` Position, probed on all 13
    // images 2026-11-03.
    match kit(&h.os)? {
        // The YAML requested `qemu-kvm` (`vars/main.yml:25`). On this family
        // it is a virtual package provided by `qemu-system-x86`, with no
        // candidate: `apt-get install` succeeds but the name is never
        // installed, so `pkg` would report it missing on every run and the
        // second pass would never reach `CHANGED 0`. Request the real name.
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

    // HACK(svc): "socket enabled and running". The Debian family and the
    // Fedora/EL preset leave the daemon enabled (`is-enabled` probed in
    // containers 2026-11-03); on Amazon Linux 2023 `virtqemud.socket` is
    // disabled after install and on Arch `libvirtd.socket` is. libvirt
    // starts the daemon on the first connection once the socket is
    // enabled ("There is no need to start the services"). The guard keeps a
    // running socket untouched; replace with `h.svc(..)` when it exists.
    // Source: https://libvirt.org/daemons.html (accessed 2026-11-03)
    // `sh!` takes literals, so each unit has its own call.
    match kit(&h.os)? {
        Kit::Amazon => {
            sh!(
                h,
                "systemctl enable --now virtqemud.socket",
                unless = "systemctl is-active --quiet virtqemud.socket"
            );
        }
        Kit::Arch => {
            sh!(
                h,
                "systemctl enable --now libvirtd.socket",
                unless = "systemctl is-active --quiet libvirtd.socket"
            );
        }
        Kit::Debian | Kit::RedHat => {}
    }

    // `vagrant_per_user.yml:3`: "Admin users need this group to avoid
    // annoying GUI warnings"; it is what lets a user manage the system
    // libvirt without root. A package creates the group (`libvirt-daemon-
    // system`, `libvirt-daemon-common`, or a sysusers entry), so there is
    // no `group` op: its name must be the package's. The user op runs after
    // the packages; appended, never replacing the user's other groups.
    for u in &h.vars.admin_users {
        h.user(u).groups_add(["libvirt"]);
    }
    Ok(())
}
