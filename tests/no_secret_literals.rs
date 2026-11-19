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

/// The labtwo vars files are checked by name, so they are covered before
/// `git ls-files` lists them. Neither holds a literal, and neither sets
/// `default_password` or names a `bao` reference (user ruling, 2026-11-18:
/// the reference left `vars/labtwo.toml`), so no labtwo run reads a secret
/// store.
#[test]
fn labtwo_vars_files_hold_no_secret_and_no_reference() {
    let files = [
        PathBuf::from("vars/labtwo.toml"),
        PathBuf::from("vars/labtwo_vm.toml"),
    ];
    let hits = vars::secret_literals::<Vars>(&files).unwrap_or_else(|e| panic!("{e}"));
    assert!(hits.is_empty(), "secret literals: {hits:?}");
    let inv =
        inventory::secret_literals::<Vars>(&[PathBuf::from("inventories/labtwo.example.toml")])
            .unwrap_or_else(|e| panic!("{e}"));
    assert!(inv.is_empty(), "secret literals: {inv:?}");
    for f in &files {
        let text = std::fs::read_to_string(f).unwrap();
        for line in text.lines().filter(|l| !l.trim_start().starts_with('#')) {
            assert!(!line.contains("bao"), "{}: {line}", f.display());
            assert!(
                !line.contains("default_password"),
                "{}: {line}",
                f.display()
            );
        }
    }
}

/// The check still refuses a literal beside the reference form.
#[test]
fn a_literal_default_password_is_still_refused() {
    let dir = std::env::temp_dir().join(format!("tp-secret-lit-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let f = dir.join("lit.toml");
    std::fs::write(&f, "default_password = \"not-a-real-hash\"\n").unwrap();
    let hits = vars::secret_literals::<Vars>(&[f]).unwrap_or_else(|e| panic!("{e}"));
    std::fs::remove_dir_all(&dir).ok();
    assert_eq!(hits.len(), 1, "{hits:?}");
    assert!(!hits[0].contains("not-a-real-hash"), "{hits:?}");
}
