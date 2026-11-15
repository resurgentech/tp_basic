//! `H11SSL_reboot_fix`: make the kernel reboot through EFI, for Supermicro
//! H11SSL-i boards that hang on the default reboot method. Port of
//! `roles/H11SSL_reboot_fix/{tasks,handlers}/*.yml` of the ansible repo at
//! 79d1ca1 (identical in `ansible_labtwo_2`). Applied by `labtwo.yml`'s second
//! play (`playbooks/labtwo.yml:9-12`, group `H11SSL_motherboards`) and nowhere
//! else. The Rust module is `h11ssl_reboot_fix`, the role name the registry
//! holds; the YAML directory keeps its capitals.
//!
//! Gate: Ubuntu 24.04 and later, and Pop!_OS 24.04 and later. The YAML gates
//! its one include on `ubuntu2404_based`, Ubuntu or Pop!_OS at exactly 24.04
//! (`inventories/group_vars/all:13`); "and later" is the user's Q-L10-4
//! default (as in `maasfix`). Ubuntu 22.04 is deprecated (user ruling,
//! 2026-11-14): no branch. Every other distro does nothing.
//!
//! The end state is `reboot=efi` on the kernel command line of every boot.
//! One op reaches it, `h.kernel_args().set("reboot", "efi")`. It owns the
//! drop-in `/etc/default/grub.d/99-telepatch-kernel-args.cfg`, runs
//! `update-grub` when the drop-in changes, and marks the host
//! `reboot pending`, so the role has no reboot and no handler (the YAML's
//! `Update Grub` handler, `handlers/main.yml:3-4`, is the op's own
//! `update-grub`). The marking is the op's: a change marks the host unless
//! `/proc/cmdline` already holds `reboot=efi` and no other `reboot=` value,
//! the case below. The op needs `update-grub` (`grub-common`) and fails
//! before writing anything when the host lacks it; if `update-grub` fails
//! the drop-in is put back.
//!
//! The YAML has three faults (`tasks/ubuntu2404.yml:3-16`), none carried over:
//!
//! 1. The `replace` text is `\1\2` inside a Jinja expression. Jinja runs on
//!    the literal text, before the regex match, so `regex_replace` never sees
//!    the captured value: an existing `reboot=` value is not stripped, and an
//!    empty `GRUB_CMDLINE_LINUX_DEFAULT=""` is rewritten with a leading
//!    space. The drop-in strips every `reboot=*` token of the composed value
//!    (`case $tp_ka_t in reboot=*) ;;`) before appending `reboot=efi`, so a
//!    stale `reboot=bios` or `reboot=acpi` cannot survive.
//! 2. The guard is `grep -c "reboot=efi" /etc/default/grub`, which also
//!    counts a commented line (`# reboot=efi`), so the edit is skipped
//!    though nothing is in effect. The op's guard is the drop-in's content,
//!    not a text search.
//! 3. It edits `/etc/default/grub` only. On Ubuntu cloud images (and MAAS
//!    deploys of them) `/etc/default/grub.d/50-cloudimg-settings.cfg` sets
//!    `GRUB_CMDLINE_LINUX_DEFAULT` again after that file is read, which can
//!    replace the edit. The drop-in is named `99-...`, sorted after every
//!    cloud-image file, so it is applied last whatever they set.
//!
//! Converged hosts. T149 found the YAML's token already in
//! `/etc/default/grub` on 01, 02 and 04 (with a leading space on 01: fault
//! 1). The port leaves it alone. The drop-in is sourced after that file and
//! strips every `reboot=` token, that one included, before it appends its
//! own, so the generated `grub.cfg` carries exactly one `reboot=efi` either
//! way. Worst case of leaving it: if the role is later removed and the
//! drop-in deleted, the old token keeps `reboot=efi` in effect, which is the
//! state before the port and harmless. Removing it would take a regex edit of
//! `GRUB_CMDLINE_LINUX_DEFAULT` for no change in effect; not built.
//!
//! First run on a converged host. The drop-in is created and `update-grub`
//! runs, but no reboot is marked: `/proc/cmdline` already holds `reboot=efi`
//! and no other `reboot=` value, so the host already runs what the drop-in
//! says (the op's `already in effect; no reboot` result). A fresh host, or one
//! whose running line lacks the token, ends `reboot pending`.
//!
//! Not proved here: the H11SSL board's reboot behaviour. No VM has that board;
//! the oracle shows `reboot=efi` in `grub.cfg`, and a run on a real board
//! shows it in `/proc/cmdline` after a reboot (T161 observes it, and cannot
//! make the board fail on demand).
//!
//! Equivalence: VM oracle `ubuntu2404 labtwo_h11ssl_reboot_fix` (Ansible side
//! the wrapper role `H11SSL_reboot_fix`, telepatch side
//! `vars/container.toml`). The oracle's `grub` section lists each kernel
//! argument of `grub.cfg`'s `linux` lines. Passed 2026-11-15 (T155): captures
//! identical, no intended difference
//! (`tests/oracle/intended/labtwo_h11ssl_reboot_fix.txt` says why), both
//! sides' `grub.cfg` carry `reboot=efi`. The oracle's image is an autoinstall
//! build, not the cloud image, so fault 3 (a `50-cloudimg-settings.cfg` that
//! masks the YAML's edit) cannot show there; the MAAS hosts run the cloud
//! image, where the drop-in sorting last is what makes the token stick. The
//! telepatch side ends `reboot pending` (CHANGED 1, `kernel_args: will set
//! reboot=efi`), and run 2 is CHANGED 0, still `reboot pending` because
//! `/proc/cmdline` lacks the token until a boot.
//!
//! Bugs the oracle cannot see: the leading space of fault 1 (the Ansible
//! token's whitespace is not a kernel argument) and the commented-line guard
//! of fault 2 (no stock image holds that line).

use telepatch::facts::os::Distro;
use telepatch::{Host, TraceError, role};

use crate::vars::Vars;

#[role]
pub async fn h11ssl_reboot_fix(h: &Host<Vars>) -> Result<(), TraceError> {
    // `main.yml:3-4`: `ubuntu2404_based`, widened to "and later" (module
    // comment). `major()` is the year of an Ubuntu or Pop!_OS release.
    if !matches!(h.os.distro, Distro::Ubuntu | Distro::PopOs)
        || !h.os.version.major().is_some_and(|m| m >= 24)
    {
        return Ok(());
    }
    // `ubuntu2404.yml:3-16` and `handlers/main.yml:3-4`: the guard, the edit
    // and `update-grub`, as one op that marks the reboot itself.
    h.kernel_args().set("reboot", "efi");
    Ok(())
}

// Intended differences: none on the oracle's image (see the oracle file); on
// a cloud image the `grub` section would differ by fault 3.
// Open choices: none.
