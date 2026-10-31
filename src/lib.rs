//! tp-basic: resurgentech's playbooks and roles on telepatch.

pub mod playbooks;
pub mod roles;
pub mod vars;

use telepatch::Playbook;
use vars::Vars;

/// Every playbook this binary knows, by name (`container/<playbook>`).
pub fn playbooks() -> Vec<Playbook<Vars>> {
    playbooks::container::all()
}
