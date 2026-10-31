//! `playbooks/container/*.yml`: image-build playbooks, run as root with
//! `tp-basic run container/<name> --local --vars vars/container.toml`.

use telepatch::{Host, Playbook, PlaybookFuture, TraceError};

use crate::roles::dev_common::dev_common;
use crate::vars::Vars;

/// Every container playbook, registered under `container/<name>`.
pub fn all() -> Vec<Playbook<Vars>> {
    vec![Playbook {
        name: "container/dev_base",
        run: dev_base_entry,
    }]
}

fn dev_base_entry(h: Host<Vars>) -> PlaybookFuture {
    Box::pin(async move { dev_base(&h).await })
}

/// `playbooks/container/dev_base.yml:7-8`: roles in YAML order.
async fn dev_base(h: &Host<Vars>) -> Result<(), TraceError> {
    dev_common(h).await
}
