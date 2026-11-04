//! `golang` role, shell level: the version tokens, the latest lookup and
//! the installer's failure paths, run against fake `curl`/`uname` programs
//! and a temporary prefix instead of `/usr/local`.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

use tp_basic::roles::golang::{INSTALL, LATEST};

/// A scratch dir under the target dir, unique per test.
fn scratch(name: &str) -> PathBuf {
    let d = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("golang-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&d);
    fs::create_dir_all(&d).unwrap();
    d
}

fn write_exe(p: &Path, body: &str) {
    use std::os::unix::fs::PermissionsExt;
    fs::write(p, body).unwrap();
    fs::set_permissions(p, fs::Permissions::from_mode(0o755)).unwrap();
}

/// A fake `curl`: the last argument is the URL; `-o FILE` names the output
/// (stdout otherwise). `https://go.dev/dl/?mode=json` serves `$FAKE/dl.json`,
/// `https://go.dev/VERSION?m=text` serves `$FAKE/VERSION`, and
/// `https://go.dev/dl/<file>` serves `$FAKE/<file>`; anything else fails.
const FAKE_CURL: &str = r#"#!/bin/sh
out=-
url=
while [ $# -gt 0 ]; do
  case $1 in -o) out=$2; shift ;; -*) ;; *) url=$1 ;; esac
  shift
done
case $url in
  'https://go.dev/dl/?mode=json') src=$FAKE/dl.json ;;
  'https://go.dev/VERSION?m=text') src=$FAKE/VERSION ;;
  'https://go.dev/dl/'*) src=$FAKE/${url#https://go.dev/dl/} ;;
  *) echo "fake curl: unexpected $url" >&2; exit 22 ;;
esac
[ -f "$src" ] || { echo "fake curl: 404 $url" >&2; exit 22; }
if [ "$out" = - ]; then cat "$src"; else cat "$src" > "$out"; fi
"#;

fn arch() -> &'static str {
    match std::env::consts::ARCH {
        "x86_64" => "amd64",
        "aarch64" => "arm64",
        a => panic!("test host arch {a} unsupported"),
    }
}

fn sha256_of(p: &Path) -> String {
    let o = Command::new("sha256sum").arg(p).output().unwrap();
    String::from_utf8(o.stdout).unwrap().split_whitespace().next().unwrap().to_string()
}

struct Fixture {
    root: PathBuf,
    prefix: PathBuf,
    bin: PathBuf,
    fake: PathBuf,
}

/// A fake download site for `go1.99.1`: a tarball holding `go/bin/go` (a
/// script printing the version) and the dl JSON in go.dev's layout, with
/// decoys for the neighbouring filenames. `good` picks whether the JSON
/// carries the tarball's real sha256 or another one. The prefix already
/// holds an "old" Go whose marker file must survive a failed install.
fn fixture(name: &str, good: bool) -> Fixture {
    let root = scratch(name);
    let prefix = root.join("prefix");
    let bin = root.join("bin");
    let fake = root.join("fake");
    for d in [&prefix.join("go"), &bin, &fake, &root.join("tree/go/bin")] {
        fs::create_dir_all(d).unwrap();
    }
    fs::write(prefix.join("go/OLD"), "old go\n").unwrap();
    write_exe(&bin.join("curl"), FAKE_CURL);
    write_exe(
        &root.join("tree/go/bin/go"),
        "#!/bin/sh\necho 'go version go1.99.1 linux/amd64'\n",
    );
    let tgz = fake.join(format!("go1.99.1.linux-{}.tar.gz", arch()));
    let st = Command::new("tar")
        .args(["-C"])
        .arg(root.join("tree"))
        .arg("-czf")
        .arg(&tgz)
        .arg("go")
        .status()
        .unwrap();
    assert!(st.success());
    let real = sha256_of(&tgz);
    let wrong = "0".repeat(64);
    let sum = if good { real } else { wrong.clone() };
    let json = format!(
        r#"[
 {{
  "version": "go1.99.1",
  "stable": true,
  "files": [
   {{
    "filename": "go1.99.1.src.tar.gz",
    "sha256": "{wrong}",
    "kind": "source"
   }},
   {{
    "filename": "go1.99.1.linux-{a}.tar.gz.sig",
    "sha256": "{wrong}",
    "kind": "archive"
   }},
   {{
    "filename": "go1.99.1.linux-{a}.tar.gz",
    "os": "linux",
    "arch": "{a}",
    "version": "go1.99.1",
    "sha256": "{sum}",
    "size": 1,
    "kind": "archive"
   }},
   {{
    "filename": "go1.99.1.windows-{a}.zip",
    "sha256": "{wrong}",
    "kind": "archive"
   }}
  ]
 }}
]
"#,
        a = arch()
    );
    fs::write(fake.join("dl.json"), json).unwrap();
    Fixture { root, prefix, bin, fake }
}

impl Fixture {
    /// Run INSTALL with `/usr/local` swapped for the temp prefix.
    fn install(&self, want: &str, extra_path: Option<&Path>) -> (bool, String) {
        let script = INSTALL.replace("/usr/local", self.prefix.to_str().unwrap());
        assert!(script.contains(self.prefix.to_str().unwrap()), "INSTALL names no /usr/local");
        let mut path = String::new();
        if let Some(p) = extra_path {
            path.push_str(&format!("{}:", p.display()));
        }
        path.push_str(&format!("{}:{}", self.bin.display(), std::env::var("PATH").unwrap()));
        let o = Command::new("bash")
            .arg("-c")
            .arg(format!("( export TP_WANT={want}\n{script}\n)"))
            .env("PATH", path)
            .env("FAKE", &self.fake)
            .env("TMPDIR", &self.root)
            .output()
            .unwrap();
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&o.stdout),
            String::from_utf8_lossy(&o.stderr)
        );
        (o.status.success(), text)
    }

    /// Nothing the installer made in TMPDIR is left (it makes `tmp.*`).
    fn no_temp_left(&self) {
        let left: Vec<_> = fs::read_dir(&self.root)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| n.starts_with("tmp."))
            .collect();
        assert!(left.is_empty(), "temp dirs left: {left:?}");
    }
}

#[test]
fn version_tokens_of_both_commands() {
    for s in ["go version go1.25.3 linux/amd64", "go1.25.3", "go1.25.3\ntime 2026-10-19T22:20:36Z\n"] {
        assert_eq!(telepatch::ops::pkg::version_token(s).as_deref(), Some("1.25.3"), "{s:?}");
    }
}

#[test]
fn latest_command_prints_a_token_from_the_go_dev_text() {
    let fx = fixture("latest", true);
    fs::write(fx.fake.join("VERSION"), "go1.99.1\ntime 2026-10-19T22:20:36Z\n").unwrap();
    let o = Command::new("bash")
        .arg("-c")
        .arg(format!("({LATEST}) | grep -oE '[0-9]+(\\.[0-9A-Za-z+~-]+)*' | head -n1"))
        .env("PATH", format!("{}:{}", fx.bin.display(), std::env::var("PATH").unwrap()))
        .env("FAKE", &fx.fake)
        .output()
        .unwrap();
    assert_eq!(String::from_utf8(o.stdout).unwrap().trim(), "1.99.1");
}

#[test]
fn install_replaces_go_when_the_sha_matches() {
    let fx = fixture("good", true);
    let (ok, text) = fx.install("1.99.1", None);
    assert!(ok, "{text}");
    assert!(fx.prefix.join("go/bin/go").exists(), "{text}");
    assert!(!fx.prefix.join("go/OLD").exists(), "old tree not replaced: {text}");
    fx.no_temp_left();
}

#[test]
fn wrong_sha_fails_before_anything_is_removed() {
    let fx = fixture("badsha", false);
    let (ok, text) = fx.install("1.99.1", None);
    assert!(!ok, "{text}");
    assert!(fx.prefix.join("go/OLD").exists(), "old Go removed on mismatch: {text}");
    assert!(!fx.prefix.join("go/bin/go").exists(), "{text}");
    fx.no_temp_left();
}

#[test]
fn failed_download_and_missing_checksum_leave_go_alone() {
    let fx = fixture("nodl", true);
    // No tarball on the site.
    fs::remove_file(fx.fake.join(format!("go1.99.1.linux-{}.tar.gz", arch()))).unwrap();
    let (ok, text) = fx.install("1.99.1", None);
    assert!(!ok, "{text}");
    assert!(fx.prefix.join("go/OLD").exists(), "{text}");
    fx.no_temp_left();

    // A version the JSON does not list: no checksum, no install.
    let fx = fixture("nosum", true);
    let (ok, text) = fx.install("1.98.0", None);
    assert!(!ok, "{text}");
    assert!(fx.prefix.join("go/OLD").exists(), "{text}");
    fx.no_temp_left();
}

#[test]
fn unsupported_architecture_fails() {
    let fx = fixture("arch", true);
    let u = fx.root.join("u");
    fs::create_dir_all(&u).unwrap();
    write_exe(&u.join("uname"), "#!/bin/sh\necho riscv64\n");
    let (ok, text) = fx.install("1.99.1", Some(&u));
    assert!(!ok, "{text}");
    assert!(text.contains("riscv64"), "{text}");
    assert!(fx.prefix.join("go/OLD").exists(), "{text}");
    fx.no_temp_left();
}
