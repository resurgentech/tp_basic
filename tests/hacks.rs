//! Every `sh!(` in a role is a missing primitive and says which one: the
//! line directly above it is `// HACK(<primitive>): what is missing`. The
//! engine warns about each `sh!`; this scan is what makes the comment
//! mandatory (design note: "No shell in a role body").

use std::path::{Path, PathBuf};

fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    for e in std::fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        if p.is_dir() {
            rust_files(&p, out);
        } else if p.extension().is_some_and(|x| x == "rs") {
            out.push(p);
        }
    }
}

/// The code part of a line: everything before a `//` comment.
fn code(line: &str) -> &str {
    line.find("//").map_or(line, |i| &line[..i])
}

/// Does `code` call the `sh!` macro (not `ssh!(`, not a comment)?
fn calls_sh(code: &str) -> bool {
    code.match_indices("sh!(").any(|(i, _)| {
        !code[..i]
            .chars()
            .next_back()
            .is_some_and(|c| c.is_alphanumeric() || c == '_')
    })
}

/// `// HACK(<primitive>): <why>`, both parts non-empty.
fn is_hack(line: &str) -> bool {
    let Some(rest) = line.trim().strip_prefix("// HACK(") else {
        return false;
    };
    let Some((prim, why)) = rest.split_once("): ") else {
        return false;
    };
    !prim.trim().is_empty() && !why.trim().is_empty()
}

/// `file:line` of every `sh!(` not directly under a HACK comment line.
fn unmarked(file: &str, src: &str) -> Vec<String> {
    let lines: Vec<&str> = src.lines().collect();
    (0..lines.len())
        .filter(|&i| calls_sh(code(lines[i])) && !(i > 0 && is_hack(lines[i - 1])))
        .map(|i| format!("{file}:{}", i + 1))
        .collect()
}

#[test]
fn every_sh_has_its_hack_comment() {
    let mut files = Vec::new();
    rust_files(
        &Path::new(env!("CARGO_MANIFEST_DIR")).join("src"),
        &mut files,
    );
    files.sort();
    assert!(!files.is_empty());
    let mut bad = Vec::new();
    for f in &files {
        let rel = f
            .strip_prefix(env!("CARGO_MANIFEST_DIR"))
            .unwrap()
            .to_string_lossy()
            .into_owned();
        bad.extend(unmarked(&rel, &std::fs::read_to_string(f).unwrap()));
    }
    assert!(
        bad.is_empty(),
        "sh! without `// HACK(<primitive>): <what is missing>` on the line above:\n  {}",
        bad.join("\n  ")
    );
}

#[test]
fn the_scan_itself_catches_the_bad_forms() {
    let ok = "    // HACK(repo: x): no primitive\n    sh!(h, \"x\");\n";
    assert!(unmarked("f", ok).is_empty());
    for bad in [
        "    sh!(h, \"x\");\n",
        "    // HACK(repo): \n    sh!(h, \"x\");\n",
        "    // HACK(): why\n    sh!(h, \"x\");\n",
        "    // HACK(repo) why\n    sh!(h, \"x\");\n",
        "    // HACK(repo): why\n\n    sh!(h, \"x\");\n",
        "    // note\n    let a = 1; sh!(h, \"x\");\n",
    ] {
        assert_eq!(unmarked("f", bad).len(), 1, "{bad}");
    }
    // comments and other macros are not calls
    assert!(unmarked("f", "// sh!(h, \"x\")\nssh!(h);\n").is_empty());
}

/// T84: `rust_kernel` has no `sh!` left (rustup components and `cargo
/// install --locked` are pkg ops now).
#[test]
fn rust_kernel_has_no_sh() {
    let src = std::fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("src/roles/rust_kernel.rs"),
    )
    .unwrap();
    let hits: Vec<usize> = src
        .lines()
        .enumerate()
        .filter(|(_, l)| calls_sh(code(l)))
        .map(|(i, _)| i + 1)
        .collect();
    assert!(hits.is_empty(), "rust_kernel.rs calls sh! at lines {hits:?}");
}
