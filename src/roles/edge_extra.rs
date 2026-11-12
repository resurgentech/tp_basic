//! `edge_extra`: the component the edge list keeps out of `edge`.
//! Nothing else. It is the play's second role, so this rustup op sits
//! next to `edge`'s and the two merge into one `pkg[rustup]`.

use telepatch::{Host, TraceError, role};

use crate::vars::Vars;

#[role]
pub async fn edge_extra(h: &Host<Vars>) -> Result<(), TraceError> {
    h.pkg(["stable"]).rustup().components(["rust-src"]);
    Ok(())
}
