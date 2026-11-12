//! Tracked vars and inventory files give a `Secret` field a reference or
//! nothing, never a literal.

use std::path::PathBuf;
use std::process::Command;

use telepatch::vars::secret_literals;
use tp_basic::vars::Vars;

#[test]
fn tracked_vars_and_inventory_have_no_secret_literals() {
    let out = Command::new("git")
        .args(["ls-files", "-z", "vars", "inventory*"])
        .output()
        .expect("git ls-files");
    assert!(out.status.success(), "git ls-files failed");
    let paths: Vec<PathBuf> = out
        .stdout
        .split(|b| *b == 0)
        .filter(|p| !p.is_empty())
        .map(|p| PathBuf::from(String::from_utf8_lossy(p).into_owned()))
        .collect();
    let hits = secret_literals::<Vars>(&paths).unwrap_or_else(|e| panic!("{e}"));
    assert!(
        hits.is_empty(),
        "secret literals in tracked files: {hits:?}"
    );
}
