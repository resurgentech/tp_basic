//! Test-only playbooks for the reboot barrier (T103), not in any YAML.
//!
//! `reboot_vm` proves the barrier; `reboot_vm_clean` (T171) removes the two
//! files `reboot_vm` leaves in `/etc` from a host it ran on (veritech03 in
//! T170; also a VM kept with `scripts/test-vm.sh --keep ... reboot_vm`). Its
//! reboot mark needs no cleanup: it lives in `/run/telepatch`, a tmpfs the
//! boot empties, and its undo stage is removed when the run ends.

use telepatch::{Host, Playbook, PlaybookFuture, TraceError};

use crate::vars::{RebootVmVars, Vars};

/// The file `reboot_vm` writes before the barrier, its op marked
/// `.needs_reboot()`.
const MARKED: &str = "/etc/tp-reboot-marked";
/// The file `reboot_vm` writes after the barrier.
const AFTER: &str = "/etc/tp-reboot-after";

/// Every reboot playbook.
pub fn all() -> Vec<Playbook<Vars>> {
    vec![
        Playbook::new("reboot_vm", reboot_vm_entry).defaults(reboot_vm_defaults),
        Playbook::new("reboot_vm_clean", reboot_vm_clean_entry),
    ]
}

/// The playbook's own bodies, the vars file `vars/reboot_vm.toml` repeats.
fn reboot_vm_defaults() -> Vars {
    Vars {
        reboot_vm: RebootVmVars {
            marked: "marked=1\n".to_string(),
            after: "after=1\n".to_string(),
        },
        ..Vars::default()
    }
}

fn reboot_vm_entry(h: Host<Vars>) -> PlaybookFuture {
    Box::pin(async move { reboot_vm(&h).await })
}

/// The proof of reboot marks and the barrier on a booted VM
/// (`scripts/test-vm.sh reboot_vm`). No role: a file op marked
/// `.needs_reboot()`, the barrier, a file op after it. The VM script makes
/// a fresh mark by changing `reboot_vm.marked`, and shows the barrier was
/// crossed by `reboot_vm.after` landing on the far side.
async fn reboot_vm(h: &Host<Vars>) -> Result<(), TraceError> {
    h.file(MARKED)
        .content(h.vars.reboot_vm.marked.as_str())
        .needs_reboot();
    h.reboot().if_pending();
    h.file(AFTER).content(h.vars.reboot_vm.after.as_str());
    Ok(())
}

fn reboot_vm_clean_entry(h: Host<Vars>) -> PlaybookFuture {
    Box::pin(async move { reboot_vm_clean(&h).await })
}

/// Removes `reboot_vm`'s two files, in the order it writes them. No vars,
/// no mark and no barrier: removing the marked file is not itself a reason
/// to reboot, so the ops are plain `file.absent()` (a var on `reboot_vm`
/// turning its own ops to absent would mark, and cross, a second reboot).
async fn reboot_vm_clean(h: &Host<Vars>) -> Result<(), TraceError> {
    h.file(MARKED).absent();
    h.file(AFTER).absent();
    Ok(())
}
