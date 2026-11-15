//! `hashicorp_packer`: `packer` from HashiCorp's apt repository, and the
//! admin users in `kvm` and `libvirt`. Port of
//! `roles/hashicorp_packer/tasks/{main,per_user}.yml` of the ansible repo at
//! 79d1ca1 (identical in `ansible_labtwo_2`). Applied by `labtwo.yml`'s
//! `servers` / `storage_servers` play, after `vm_server` (`playbooks/labtwo.yml`),
//! and nowhere else. Role vars: `admin_users` (`HashicorpPackerVars`,
//! `src/vars.rs`).
//!
//! Gate: the Debian family only. The YAML is apt only (it dearmors a key into
//! `/etc/apt/trusted.gpg.d`, writes a `.list` file and calls `apt`), so on
//! any other family the role does nothing, as the YAML would fail there
//! (the labtwo fleet is Ubuntu). No op, and this comment line says why.
//!
//! The port, in order:
//!
//! 1. `curl` and `ca-certificates`, the repo op's prerequisites (the YAML
//!    uses the host's `curl` without installing it).
//! 2. The two legacy files the YAML left are removed:
//!    `/etc/apt/sources.list.d/hashicorp.list` (its one-line source) and
//!    `/etc/apt/trusted.gpg.d/hashicorp.gpg` (the dearmored key, which apt
//!    trusts for every repository, not only this one). Both go before the
//!    repo op and in the same run, so apt never reads the repository twice
//!    (a `.list` and a `.sources` for one URI is a "Target ... is configured
//!    multiple times" warning, and two `Signed-By` values for it is an
//!    error). Worst case without the removals: a duplicate source and a key
//!    trusted for every repo. The T149 survey (2026-11-15) found both files
//!    on three of the lab servers, with key files of different sizes (the
//!    YAML never refreshes a key once the file exists).
//! 3. `h.repo("hashicorp").apt(..)`: a deb822
//!    `/etc/apt/sources.list.d/hashicorp.sources` for
//!    `https://apt.releases.hashicorp.com`, suite the release codename
//!    (`ansible_lsb.codename` in the YAML; the host's `os-release`
//!    codename here, which reads no `lsb_release`), component `main`, the
//!    armored key from `https://apt.releases.hashicorp.com/gpg` kept at
//!    `/etc/apt/keyrings/hashicorp.asc` and named in `Signed-By`, so the key
//!    is trusted for this repo alone. The YAML's `gpg --dearmor` is not
//!    needed (apt reads an armored `.asc` key). The `Architectures` line is
//!    read from `dpkg --print-architecture` on the host by the op.
//! 4. `packer`. The repo op writes a `repo:` key, so the cache is refreshed
//!    before this install (the YAML's `update_cache` task, which ran only
//!    when the `.list` line changed, is the op's job).
//! 5. Each admin user is appended to `kvm` and `libvirt`
//!    (`per_user.yml:3-10`), through `groups_add`, which never removes a
//!    group. The role relies on `vm_server` for the groups, as the YAML did
//!    (`vm_server` installs libvirt and qemu, which create them); the
//!    `user` op reads each group, so it orders after the package ops.
//!
//! Bugs of the YAML the port does not carry:
//!
//! - Hard-coded architecture: the `.list` line says `[arch=amd64]`, so on an
//!   arm64 host apt would ask for the wrong index. The op reads the host's
//!   architecture.
//! - The list-as-path cleanup: the "Clean up temporary" task gives `file`
//!   a list under `path:` (`main.yml:25-30`), which is not a path, so the
//!   two temp files were never removed. The port has no temp files: the key
//!   goes straight to its keyring file.
//! - Unguarded temp files: the key is downloaded into the fixed, world
//!   writable `/tmp/hashicorp.asc`, and `rm -f` the `.asc.gpg` name that
//!   `gpg --dearmor` would refuse to overwrite. Another user could plant
//!   either name. Gone with the temp files.
//! - A key already in `trusted.gpg.d` was never refreshed or checked; and
//!   the key was trusted for every repo (above).
//!
//! Equivalence: VM oracle `ubuntu2404 labtwo_hashicorp_packer`
//! (`admin_users = ["bot"]` on both sides: `vars/labtwo_hashicorp_packer.toml`
//! for telepatch, `--extra-vars` for Ansible). Both VMs are pre-seeded with
//! the `vm_server` port's Debian packages
//! (`scripts/oracle-preseed/labtwo_hashicorp_packer.sh`), which create the
//! `libvirt` group; the Ansible side runs `hashicorp_packer` alone, because
//! the Ansible `vm_server` installs much more than its port (ansible, ruby,
//! ...) and would put `vm_server`'s rewrite into this diff. The telepatch side
//! runs the test playbook, `vm_server` then `hashicorp_packer`. Intended
//! differences, declared in `tests/oracle/intended/labtwo_hashicorp_packer.txt`:
//! the `apt sources` section, where Ansible has the one-line `hashicorp.list`
//! and telepatch the deb822 `hashicorp.sources`. Passed 2026-11-15 (T154):
//! packages and the `groups` section (`kvm: bot`, `libvirt: bot`) equal, the
//! nine declared lines the whole gating diff, run 2 changed 0 on both sides.
//! Source: https://developer.hashicorp.com/packer/install (accessed 2026-11-15)

use telepatch::facts::os::Family;
use telepatch::ops::repo::AptRepo;
use telepatch::{Host, TraceError, role};

use crate::vars::Vars;

/// `main.yml:1-30`, the legacy `.list` the YAML wrote.
const LEGACY_LIST: &str = "/etc/apt/sources.list.d/hashicorp.list";

/// `main.yml:1-23`, the dearmored key the YAML moved in: trusted by apt for
/// every repository.
const LEGACY_KEY: &str = "/etc/apt/trusted.gpg.d/hashicorp.gpg";

const BASE: &str = "https://apt.releases.hashicorp.com";

#[role]
pub async fn hashicorp_packer(h: &Host<Vars>) -> Result<(), TraceError> {
    // The YAML is apt only; other families get no op.
    if h.os.family != Family::Debian {
        return Ok(());
    }
    let suite =
        h.os.codename()
            .ok_or_else(|| {
                TraceError::new("hashicorp_packer: the host's os-release names no release codename")
            })?
            .to_string();
    h.pkg(["curl", "ca-certificates"]);
    // Converge the YAML's result in the same run, before the new source is
    // written and before apt reads sources for the install (module comment).
    h.file(LEGACY_LIST).absent();
    h.file(LEGACY_KEY).absent();
    h.repo("hashicorp").apt(AptRepo {
        uris: vec![BASE.to_string()],
        suites: vec![suite],
        components: vec!["main".to_string()],
        key_url: format!("{BASE}/gpg"),
    });
    h.pkg(["packer"]);
    // per_user.yml:3-10. The groups come from `vm_server`.
    for u in &h.vars.hashicorp_packer.admin_users {
        h.user(u).groups_add(["kvm", "libvirt"]);
    }
    Ok(())
}

// Intended differences: the `apt sources` section (a one-line `.list` against
// a deb822 `.sources`); see the oracle file. The legacy `trusted.gpg.d` key
// is not captured by the oracle. Open choices: none.
