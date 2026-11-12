//! Tracked vars and inventory files give a `Secret` field a reference or
//! nothing, never a literal.

use std::path::PathBuf;
use std::process::Command;

use telepatch::{inventory, vars};
use tp_basic::vars::Vars;

fn tracked(pathspecs: &[&str]) -> Vec<PathBuf> {
    let out = Command::new("git")
        .arg("ls-files")
        .arg("-z")
        .args(pathspecs)
        .output()
        .expect("git ls-files");
    assert!(out.status.success(), "git ls-files failed");
    out.stdout
        .split(|b| *b == 0)
        .filter(|p| !p.is_empty())
        .map(|p| PathBuf::from(String::from_utf8_lossy(p).into_owned()))
        .collect()
}

#[test]
fn tracked_vars_and_inventory_have_no_secret_literals() {
    // A vars file and an inventory are different formats: each goes to its
    // own loader.
    let mut hits =
        vars::secret_literals::<Vars>(&tracked(&["vars"])).unwrap_or_else(|e| panic!("{e}"));
    hits.extend(
        inventory::secret_literals::<Vars>(&tracked(&["inventory*"]))
            .unwrap_or_else(|e| panic!("{e}")),
    );
    assert!(
        hits.is_empty(),
        "secret literals in tracked files: {hits:?}"
    );
}
