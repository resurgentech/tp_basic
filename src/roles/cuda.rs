//! `cuda`: NVIDIA's CUDA apt repository, the driver and CUDA packages, the
//! NVIDIA container toolkit pinned from its own flat apt repository, and the
//! `PATH` entry. Port of `roles/cuda/{tasks,handlers,templates,vars}` of the
//! ansible repo at 79d1ca1 (identical in `ansible_labtwo_2`). Applied by
//! `labtwo.yml`'s last play (`playbooks/labtwo.yml`, group `gpu_servers`) and
//! nowhere else. Role vars: `CudaVars` (`src/vars.rs`), named as
//! `roles/cuda/vars/main.yml` names them.
//!
//! Gate: Ubuntu and Pop!_OS 24.04 and later, as `maasfix` (the YAML's
//! `ubuntu2404_based`, widened to "and later" by Q-L10-4). Ubuntu 22.04 is
//! deprecated (user ruling, 2026-11-14): the `ubuntu2204_based` branches of
//! `vars/main.yml` are dropped. Every other distro does nothing: the vendor
//! repository is NVIDIA's `ubuntu2404` one, and the YAML is apt only.
//! Ubuntu 26.04: NVIDIA has an `ubuntu2604` repository (checked 2026-11-15:
//! its `Packages.gz` answers 200 and lists `cuda-keyring` 1.1-1, 4362 bytes,
//! sha256 `f7f474b5...a3099e`), but the default vars still name the
//! `ubuntu2404` file, so on a 26.04 host the vars must name the `ubuntu2604`
//! keyring URL and sum (the plan snapshot for `ubuntu2604` shows the
//! `ubuntu2404` default; nothing here proves 26.04).
//!
//! The port, in order:
//!
//! 1. `curl` and `ca-certificates`, the repo op's prerequisites (the YAML
//!    uses the host's `curl` without installing it).
//! 2. The keyring (`tasks/install_keyring.yml`): `cuda-keyring` from NVIDIA's
//!    `.deb` through `h.pkg(..).from(h.fetch(url).sha256(sum)).pin(version)`.
//!    The sum is the `SHA256` of the `cuda-keyring` stanza of NVIDIA's
//!    `Packages` index (Version 1.1-1, Filename `./cuda-keyring_1.1-1_all.deb`,
//!    Size 4328).
//!    Source: https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/Packages.gz (accessed 2026-11-15)
//!    The pin is read from the file name in the URL, so the version follows
//!    the file. This fixes the YAML's reinstall on every run: it compared the
//!    installed version with `cuda_keyring_version: "1.2-1"`
//!    (`vars/main.yml:7`), which the fetched 1.1-1 file never equals, so the
//!    package was downloaded, reinstalled and its `/tmp` copy removed on
//!    every run (changed every time). The download is checked against the
//!    sum, and has no fixed `/tmp` name. The package owns
//!    `/etc/apt/sources.list.d/cuda-ubuntu2404-x86_64.list` and
//!    `/usr/share/keyrings/cuda-archive-keyring.gpg`: the port leaves both
//!    alone (1.1-1 installed means the package op does nothing).
//! 3. The container toolkit's repository (`install_nvidia_container_toolkit.yml:9-35`).
//!    The YAML wrote `/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg`
//!    and `/etc/apt/sources.list.d/nvidia-container-toolkit.list` through two
//!    shell pipelines (no `pipefail`, `sudo` inside the shell, the list the
//!    vendor's `nvidia-container-toolkit.list` with a `sed` for `signed-by`).
//!    The port removes both legacy files and writes the deb822
//!    `nvidia-container-toolkit.sources` with `h.repo(..).apt(..)`:
//!    URI `https://nvidia.github.io/libnvidia-container/stable/deb/$(ARCH)`
//!    (apt substitutes `$(ARCH)`; the op keeps it literal), suite `/` and no
//!    components (a flat repository, `repo` op of T142), the armored key from
//!    `https://nvidia.github.io/libnvidia-container/gpgkey` at
//!    `/etc/apt/keyrings/nvidia-container-toolkit.asc`, named in `Signed-By`.
//!    The removals and the new source happen in one run and in program order,
//!    removals first, so apt never reads the repository twice (a `.list` and a
//!    `.sources` for one URI is a "configured multiple times" warning). T149
//!    found both legacy files on one of the lab servers (the shell wrote them
//!    there); the old keyring is also a key apt trusted for that one source
//!    only, so removing it loses nothing. The vendor's list also carries a
//!    commented `experimental` line, which the port does not write.
//!    Source: https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list (accessed 2026-11-15)
//!    Basis: the install guide the YAML cites, `https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html` (not fetched)
//! 4. The driver (`tasks/main.yml:6-12`): `h.pkg(driver).needs_reboot()`. An
//!    empty `nvidia_driver_packages` is no op, so no reboot mark. The role
//!    never reboots: the playbook places `h.reboot().if_pending()`.
//! 5. The CUDA packages (`:14-20`): `h.pkg(cuda_packages)`, no reboot mark.
//!    The YAML notified `restart host` from this task and from the toolkit
//!    install too; only a driver needs a reboot (the doc's finding), so the
//!    port marks the driver alone.
//! 6. The toolkit packages (`install_nvidia_container_toolkit.yml:37-42`):
//!    one `h.pkg(toolkit).pin(version)` (`1.19.0-1`, `vars/main.yml:42-46`;
//!    the YAML wrote the version into four names). One op, because the four
//!    depend on each other at `=` one version: apt must get them in one
//!    `install a=v b=v ..`. One name at a time, apt resolves
//!    `nvidia-container-toolkit=1.19.0-1`'s `Depends: ... (= 1.19.0-1)`
//!    against the newer candidates and fails (seen on the first oracle run,
//!    2026-11-15, when the repo's candidate was 1.20.1-1; telepatch's distro
//!    pin took one name until T156 lifted that for apt and dnf).
//! 7. `h.svc("docker").restart_on(&toolkit)`: the YAML's
//!    `restart docker daemon` handler (`systemctl restart docker`), which ran
//!    whenever the toolkit apt task changed. Kept, with the guard: docker
//!    restarts only when a toolkit package changed. The gpu host is also in
//!    `servers`, so `docker` has installed the daemon by then (the oracle
//!    pre-seeds `docker.io` on both sides, `scripts/oracle-preseed/
//!    labtwo_cuda.sh`).
//! 8. `/etc/profile.d/cuda.sh` (`main.yml:25-28`) from the askama template
//!    `templates/cuda_profile.sh`, `0644 root:root`: `CUDA_HOME`, `PATH` and
//!    `LD_LIBRARY_PATH` for `cuda_install_path`. The template's bytes are the
//!    Jinja template's with the path filled in, "Ansible managed" comment
//!    included, so the oracle's `profile.d` sha256 compares equal (an
//!    intended difference would otherwise be needed for the header alone).
//!
//! Where the ops sit. The repo op (step 3) comes before the driver and CUDA
//! packages, although the YAML installed the toolkit last. Reason: `apt-get
//! update` runs before the first package op after a source is written
//! (`apt_update_needed`), and a package op that installs `cuda-keyring`
//! writes its source behind the engine's back. The repo op is the next
//! source write, so the first package op after it refreshes the cache once
//! for both sources, where the YAML's `update_cache: true` ran on each task.
//!
//! The driver op has its own timeout (an hour, for the DKMS build; the
//! default for a package op is 30 minutes), so it stays a separate op from
//! the CUDA one. Were they folded, only the marked members would mark the
//! reboot: a folded op's plan line names them (`needs_reboot [..]`) and the
//! executor marks per member, so a CUDA package that changed alone would not.
//!
//! Bugs of the YAML the port does not carry:
//!
//! - The keyring version that never matches (above): reinstalled every run.
//! - `restart host` notified by every install (above): a reboot for a CUDA
//!   package or the toolkit.
//! - `update_cache: true` on every apt task: a cache refresh per task. One
//!   refresh now serves the run.
//! - The toolkit key and list shells: no `pipefail`, `sudo` inside `shell`,
//!   a key refetched into a fixed `/tmp/new-nvidia-container-toolkit-
//!   keyring.gpg` that nothing removes, `NCT_DIFF` read from the environment
//!   (so the key was only ever written when the file was missing), and a
//!   `sed` on the vendor's list that also rewrites its commented line.
//! - The architecture: the vendor's `$(ARCH)` is kept, and the key is
//!   scoped by `Signed-By`.
//!
//! Equivalence: VM oracle `ubuntu2404 labtwo_cuda` (`OC_ROLES=cuda`, the
//! docker pre-seed, small lists on both sides: `nvidia_driver_packages = []`
//! and `cuda_packages = ["nvtop"]`, as `-e` overrides for Ansible and
//! `vars/labtwo_cuda.toml` for telepatch). Packages (the keyring, `nvtop`,
//! the four toolkit packages at `1.19.0-1`) and `profile.d` (equal sha256)
//! are equal. Intended differences, declared in
//! `tests/oracle/intended/labtwo_cuda.txt`: the `apt sources` section, where
//! Ansible has the one-line `nvidia-container-toolkit.list` and telepatch the
//! deb822 `nvidia-container-toolkit.sources`; the `cuda-keyring` package's
//! own `cuda-ubuntu2404-x86_64.list` is on both sides. Passed 2026-11-15
//! (T156, second run): the nine declared lines the whole gating diff,
//! telepatch CHANGED 6 then 0. Ansible's run 2 changed 4 (the keyring
//! download and file removal of the reinstall-every-run bug, the driver
//! task's cache update with an empty list, and the profile template). The
//! first run failed on the toolkit: four pinned ops, one name each, let apt
//! resolve `nvidia-container-toolkit=1.19.0-1`'s `=` dependencies against
//! the 1.20.1-1 candidates (item 6).
//!
//! Not proved here: the full driver and CUDA lists (large, and the driver
//! needs a GPU and a reboot), the GPU itself. T159 and T160 prove more.
//! Source: https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/Packages.gz (accessed 2026-11-15)

use std::time::Duration;

use telepatch::facts::os::Distro;
use telepatch::ops::repo::AptRepo;
use telepatch::{Host, TraceError, role};

use crate::vars::Vars;

/// `install_nvidia_container_toolkit.yml:23-35`, the legacy `.list` the YAML wrote.
const LEGACY_LIST: &str = "/etc/apt/sources.list.d/nvidia-container-toolkit.list";

/// `install_nvidia_container_toolkit.yml:9-21`, the legacy key the YAML wrote.
const LEGACY_KEY: &str = "/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg";

/// `install_nvidia_container_toolkit.yml:23-35`, the vendor's flat repository: the URI of its `nvidia-container-toolkit.list`.
const TOOLKIT_URI: &str = "https://nvidia.github.io/libnvidia-container/stable/deb/$(ARCH)";

/// `install_nvidia_container_toolkit.yml:9-21`.
const TOOLKIT_KEY_URL: &str = "https://nvidia.github.io/libnvidia-container/gpgkey";

/// `templates/profile.j2`, byte for byte once `cuda_install_path` is filled
/// in, "Ansible managed" comment included (module comment, step 8).
///
/// Askama drops one trailing newline when it reads a template file, so
/// `templates/cuda_profile.sh` ends with a blank line and the render keeps
/// the file's final newline.
#[derive(Clone, askama::Template)]
#[template(path = "cuda_profile.sh", escape = "none")]
struct CudaProfile {
    cuda_install_path: String,
}

/// The package version in a `cuda-keyring_<version>_all.deb` URL.
fn keyring_version(url: &str) -> Result<&str, TraceError> {
    url.rsplit('/')
        .next()
        .and_then(|f| f.strip_prefix("cuda-keyring_"))
        .and_then(|f| f.split('_').next())
        .filter(|v| !v.is_empty())
        .ok_or_else(|| {
            TraceError::new(format!(
                "cuda: cuda_keyring_url `{url}` does not end in cuda-keyring_<version>_<arch>.deb"
            ))
        })
}

#[role]
pub async fn cuda(h: &Host<Vars>) -> Result<(), TraceError> {
    // The YAML's `ubuntu2404_based`, widened to "and later" (module comment).
    if !matches!(h.os.distro, Distro::Ubuntu | Distro::PopOs)
        || !h.os.version.major().is_some_and(|m| m >= 24)
    {
        return Ok(());
    }
    let v = &h.vars.cuda;
    h.pkg(["curl", "ca-certificates"]);
    // install_keyring.yml:2-25; the version follows the file.
    h.pkg(["cuda-keyring"])
        .from(h.fetch(&v.cuda_keyring_url).sha256(&v.cuda_keyring_sha256))
        .pin(keyring_version(&v.cuda_keyring_url)?);
    // install_nvidia_container_toolkit.yml:9-35: the legacy shell results go
    // before the repo op, in the same run (module comment, step 3).
    h.file(LEGACY_LIST).absent();
    h.file(LEGACY_KEY).absent();
    h.repo("nvidia-container-toolkit").apt(AptRepo {
        uris: vec![TOOLKIT_URI.to_string()],
        suites: vec!["/".to_string()],
        components: vec![],
        key_url: TOOLKIT_KEY_URL.to_string(),
    });
    // main.yml:6-12. An empty list is no op and no reboot mark.
    if !v.nvidia_driver_packages.is_empty() {
        // The longer timeout is for the DKMS build (module comment).
        h.pkg(&v.nvidia_driver_packages)
            .timeout(Duration::from_secs(3600))
            .needs_reboot();
    }
    // main.yml:14-20. No reboot mark (module comment, step 5).
    if !v.cuda_packages.is_empty() {
        h.pkg(&v.cuda_packages);
    }
    // install_nvidia_container_toolkit.yml:37-42: one pinned op, one apt
    // transaction (the four depend on each other at `=` one version).
    let toolkit = h
        .pkg(&v.nvidia_container_toolkit_packages)
        .pin(&v.nvidia_container_toolkit_version);
    // handlers/main.yml:3-4, guarded on the toolkit install.
    h.svc("docker").restart_on(&toolkit);
    // main.yml:25-28.
    h.file("/etc/profile.d/cuda.sh")
        .content(CudaProfile {
            cuda_install_path: v.cuda_install_path.clone(),
        })
        .mode(0o644)
        .owner("root");
    Ok(())
}

// Intended differences: the `apt sources` section (a one-line `.list` against
// a deb822 `.sources`); see the oracle file. The legacy key in
// `/usr/share/keyrings` is not captured by the oracle. Open choices: none.

#[cfg(test)]
mod tests {
    use super::*;
    use askama::Template;

    /// `roles/cuda/templates/profile.j2` with `cuda_install_path` filled in
    /// (Ansible keeps the final newline).
    #[test]
    fn profile_matches_the_j2_bytes() {
        let got = CudaProfile {
            cuda_install_path: "/usr/local/cuda-13.2".to_string(),
        }
        .render()
        .unwrap();
        assert_eq!(
            got,
            "#!/bin/sh\n\n#\n# Ansible managed\n#\n\nexport CUDA_HOME=/usr/local/cuda-13.2\nexport PATH=/usr/local/cuda-13.2/bin:$PATH\nexport LD_LIBRARY_PATH=/usr/local/cuda-13.2/lib64:$LD_LIBRARY_PATH\n"
        );
    }

    #[test]
    fn keyring_version_comes_from_the_file_name() {
        assert_eq!(
            keyring_version("https://x/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb").unwrap(),
            "1.1-1"
        );
        assert!(keyring_version("https://x/cuda.deb").is_err());
    }
}
