//! Test-only playbooks for the reboot barrier (T103), not in any YAML.

use telepatch::{Host, Playbook, PlaybookFuture, TraceError};

use crate::vars::{RebootVmVars, Vars};

/// Every reboot playbook.
pub fn all() -> Vec<Playbook<Vars>> {
    vec![Playbook::new("reboot_vm", reboot_vm_entry).defaults(reboot_vm_defaults)]
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
    h.file("/etc/tp-reboot-marked")
        .content(h.vars.reboot_vm.marked.as_str())
        .needs_reboot();
    h.reboot().if_pending();
    h.file("/etc/tp-reboot-after")
        .content(h.vars.reboot_vm.after.as_str());
    Ok(())
}
