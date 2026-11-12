//! Playbook `edge`: role `edge`, then `edge_extra`, and nothing else.

use telepatch::{Host, Playbook, PlaybookFuture, TraceError};

use crate::roles::edge::edge;
use crate::roles::edge_extra::edge_extra;
use crate::vars::Vars;

pub fn all() -> Vec<Playbook<Vars>> {
    vec![Playbook::new("edge", edge_entry)]
}

fn edge_entry(h: Host<Vars>) -> PlaybookFuture {
    Box::pin(async move { edge_playbook(&h).await })
}

async fn edge_playbook(h: &Host<Vars>) -> Result<(), TraceError> {
    edge(h).await?;
    edge_extra(h).await
}
