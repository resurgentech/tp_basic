# rust.yml: understanding doc

Scope: `playbooks/container/rust.yml` and the roles it applies, `dev_common`
and `rust_build`. All file:line citations are relative to `conversion/ansible/`
(byte copies of the ansible repo at 79d1ca1). Last read against those copies
on 2026-10-30.

`dev_common` has its own doc, `dev_base.md`; this doc cites it and does not
repeat it. `rust_build` has no separate doc: it is small, and only
`rust.yml` and `latest_kernel_build.yml` apply it.

## Purpose

`rust.yml` turns a `dev_base` image into one that can build Rust: it runs as
root (`playbooks/container/rust.yml:5`) and applies `dev_common` again
(`rust.yml:8`, see `dev_base.md`) and then `rust_build` (`rust.yml:9`).
`rust_build` installs the distro packages a Rust build needs, one task file
per family (`roles/rust_build/tasks/main.yml:4-14`), then runs
`per_user.yml` once per admin user and once more for root
(`main.yml:17-21`). `per_user.yml` installs rustup with the default
toolchain, repairs or updates an existing install, then adds `cargo-deb`,
`cargo-generate-rpm` and the `x86_64-unknown-linux-musl` target
(`roles/rust_build/tasks/per_user.yml:122-183`).

Who runs it:

- `docker_images` builds it as the `rust_build` container, parent `dev_base`,
  for all 13 distros (`../docker_images/docker-bake.hcl`, `CONTAINERS` line
  `rust_build = { parent = "dev_base", playbook = "playbooks/container/rust.yml" }`,
  and `DISTROS`): debian12, debian13, ubuntu2404, ubuntu2604, fedora43,
  fedora44, rockylinux9, rockylinux10, almalinux9, almalinux10,
  amazonlinux2023, arch, omarchy.
- Workstations run the role through the same flags; the user loop then
  covers the human `ansible_user` as well as root.

Who else applies `rust_build` (`grep -rn "rust_build" playbooks/`): only
`playbooks/container/latest_kernel_build.yml:11`, after `dev_common`,
`src_repos` and `kernel_build` (`latest_kernel_build.yml:8-10`) and before
`rust_kernel` (`latest_kernel_build.yml:12`). `docker-bake.hcl` builds that
playbook with parent `rust_build` and only for ubuntu2604, so on that image
`rust_build` runs a second time on a host that already has rustup (the update
path, not the install path). `kernel_build.yml` does not apply `rust_build`
(`kernel_build.yml:5-10`). `dev_common` is also applied by `dev_base.yml`,
`kernel_build.yml` and `latest_kernel_build.yml`.

Flags and variables, all in `inventories/group_vars/all`:

- Family flags `redhat_based` (`:4`), `arch_based` (`:5`), `debian_based`
  (`:6`), `amazonlinux2023_based` (`:10`).
- `admin_users: ["{{ ansible_user }}"]` (`:16`). The Dockerfiles pass
  `ansible_user=root` (`../docker_images/Dockerfiles/ansible.debian:13`, and
  the same line in `ansible.redhat:12` and `ansible.arch:12`), so in every
  image `admin_users = [root]`.
- `rustup_version: "1.29.0"` (`:43`), `cargo_version: "1.94.0"` (`:44`),
  `rustc_version: "1.94.0"` (`:45`). Only `per_user.yml` reads them
  (`per_user.yml:60-62`, `:67`, `:71`).

## Outcomes

The oracle (T18) compares per image: package names and arch, system pip
names, for each admin user plus root the rustup toolchains, installed
components and targets and the names in `~/.cargo/bin`,
`/etc/apt/sources.list*`, and `/usr/local/bin` names. Versions are a
non-gating side diff. State below is what `rust_build` adds on top of
`dev_base`. Package names are requested names; the oracle compares installed
names, which can differ where the manager resolves provides (`pkgconf-pkg-config`
on RedHat resolves through the `pkgconf` family).

### Debian family (debian12, debian13, ubuntu2404, ubuntu2604)

Selected by `debian_based` (`inventories/group_vars/all:6`).
`roles/rust_build/tasks/debian.yml:2-10`.

- apt: `g++`, `libssl-dev`, `pkg-config`, `clang`, `musl-tools`
  (`debian.yml:5-9`). No `update_cache` (`debian.yml:3-4`).
- Provides `/usr/bin/musl-gcc` (from `musl-tools`; observed, see Local probes).

### RedHat family (fedora43, fedora44, rockylinux9, rockylinux10, almalinux9, almalinux10)

Selected by `redhat_based` (`inventories/group_vars/all:4`).
`roles/rust_build/tasks/redhat.yml:2-17`.

- dnf: `gcc-c++`, `openssl-devel`, `pkgconf-pkg-config`, `clang`
  (`redhat.yml:5-8`).
- dnf `musl-gcc`, only when `ansible_distribution == 'Fedora' or
  ansible_distribution_major_version|int >= 10` (`redhat.yml:13-17`). That
  selects fedora43, fedora44, rockylinux10, almalinux10 and omits rockylinux9
  and almalinux9. On the EL10 images it comes from `epel` (observed, see
  Local probes).
- No repo is added by this role (`redhat.yml` has no `repo` or `yum_repository`
  task); EPEL comes from `base.el` (see `dev_base.md`).

### Amazon Linux 2023 (amazonlinux2023)

Selected by `amazonlinux2023_based` (`inventories/group_vars/all:10`); Amazon
is not in `redhat_based` (`inventories/group_vars/all:4`).
`roles/rust_build/tasks/amazonlinux2023.yml:3-10`.

- dnf: `gcc-c++`, `openssl-devel`, `pkgconf-pkg-config`, `clang`
  (`amazonlinux2023.yml:6-9`). No `musl-gcc`: the file says so
  (`amazonlinux2023.yml:2`).
- `main.yml` has no include for Amazon Linux 2 (`main.yml:4-14` lists debian,
  redhat, amazonlinux2023, archlinux): the role never ran there.

### Arch family (arch, omarchy)

Selected by `arch_based`, which tests `ansible_os_family`
(`inventories/group_vars/all:5`). `roles/rust_build/tasks/archlinux.yml:2-9`.

- pacman: `openssl`, `pkgconf`, `clang`, `musl` (`archlinux.yml:5-8`). The
  `musl` package owns `/usr/bin/musl-gcc` (observed).

### Every host, per user in `admin_users` plus root

`admin_users = [root]` in the containers, so the oracle's user set is `{root}`.

- rustup installed by the `sh.rustup.rs` script with `-y`
  (`per_user.yml:122-134`): default toolchain
  `stable-x86_64-unknown-linux-gnu`, profile `default`, hence components
  `cargo`, `clippy`, `rust-docs`, `rust-std` (gnu), `rustc`, `rustfmt`
  (observed in the existing images).
- Target `x86_64-unknown-linux-musl` added (`per_user.yml:179-183`), hence the
  component `rust-std-x86_64-unknown-linux-musl` and target list
  `x86_64-unknown-linux-gnu`, `x86_64-unknown-linux-musl`.
- `cargo-deb` and `cargo-generate-rpm` built with `cargo install` into
  `~/.cargo/bin` (`per_user.yml:147-148`, `:164-165`).
- `~/.cargo/bin` holds 16 names, identical on all 13 existing rust_build
  images (observed): `cargo`, `cargo-clippy`, `cargo-deb`, `cargo-fmt`,
  `cargo-generate-rpm`, `cargo-miri`, `clippy-driver`, `rls`, `rust-analyzer`,
  `rust-gdb`, `rust-gdbgui`, `rust-lldb`, `rustc`, `rustdoc`, `rustfmt`,
  `rustup`.
- No pip installs and no repo changes by this role (no `pip` or repo task in
  `roles/rust_build/tasks/`); `/usr/local/bin` gains no name; the `uv` and
  `uvx` names come from `dev_common` (`roles/dev_common/tasks/main.yml:34-37`).
- Shell profiles are edited by the rustup installer: `. "$HOME/.cargo/env"`
  is added to `~/.profile` and, where they exist, `~/.bashrc` and
  `~/.bash_profile` (observed). The oracle does not compare profile files.
- Users other than `admin_users` and root get nothing. The ubuntu2404 and
  ubuntu2604 bases carry an `ubuntu` user (uid 1000, home `/home/ubuntu`,
  observed) with no rustup.

### Mapping to the oracle checklist

| Oracle item | Debian family | RedHat family | Amazon 2023 | Arch family |
|---|---|---|---|---|
| package names + arch | apt list above | dnf list above, plus `musl-gcc` on fedora*, *10 | dnf list above | pacman list above |
| system pip names | unchanged | unchanged | unchanged | unchanged |
| rustup toolchains (root) | `stable-x86_64-unknown-linux-gnu` | same | same | same |
| components (root) | cargo, clippy, rust-docs, rust-std (gnu, musl), rustc, rustfmt | same | same | same |
| targets (root) | gnu, musl | same | same | same |
| `~/.cargo/bin` names | the 16 names above | same | same | same |
| /etc/apt/sources.list* | unchanged | n/a | n/a | n/a |
| /usr/local/bin names | `uv`, `uvx` (from `dev_common`) | same | same | same |

## Current method

_Generated by `tp classify playbooks/container/rust.yml`._

49 tasks in scope; 12 match no pattern and are plain module calls. A task is listed under every pattern it matches, so pattern counts overlap and do not sum to the task total.

### By pattern

| Pattern | Tasks | Proposed telepatch primitive |
|---|---|---|
| Distro dispatch | 11 | typed `os` fact and a `match`, or a per-family table on `pkg` |
| Per-user loop | 26 | `for u in users { let s = h.as_user(u); ... }`; the login shell is a fact of the user |
| Hand-rolled ensure | 9 | `sh!(..).unless(check)` or `.creates(path)` |
| Version pinning | 6 | `bin_version` fact plus the ensure combinator |
| Repo setup | 0 | `repo` primitive; one cache update per window |
| Shell for a primitive | 0 | the matching primitive (`svc`, `file`, `pkg`, `user`), not `sh` |
| Controller-side gather | 0 | `secret`, `fetch`, `local` (prepare phase) |
| Handler | 0 | a guard on the restart op; identical guarded ops merge |

#### Distro dispatch (11 tasks)

Becomes: typed `os` fact and a `match`, or a per-family table on `pkg`

- `roles/dev_common/tasks/main.yml:4` dev_common_debian (include_tasks -> Rust control flow)
- `roles/dev_common/tasks/main.yml:8` dev_common_redhat (include_tasks -> Rust control flow)
- `roles/dev_common/tasks/main.yml:12` dev_common_amazonlinux2 (include_tasks -> Rust control flow)
- `roles/dev_common/tasks/main.yml:16` dev_common_amazonlinux2023 (include_tasks -> Rust control flow)
- `roles/dev_common/tasks/main.yml:20` dev_common_archlinux (include_tasks -> Rust control flow)
- `roles/dev_common/tasks/main.yml:26` Various python dependancies (pip -> pkg::pip)
- `roles/rust_build/tasks/main.yml:4` (include_tasks -> Rust control flow)
- `roles/rust_build/tasks/main.yml:7` (include_tasks -> Rust control flow)
- `roles/rust_build/tasks/redhat.yml:13` RedHat musl-gcc for the musl target (dnf -> pkg), included from `roles/rust_build/tasks/main.yml:7`
- `roles/rust_build/tasks/main.yml:10` (include_tasks -> Rust control flow)
- `roles/rust_build/tasks/main.yml:13` (include_tasks -> Rust control flow)

#### Per-user loop (26 tasks)

Becomes: `for u in users { let s = h.as_user(u); ... }`; the login shell is a fact of the user

- `roles/rust_build/tasks/main.yml:17` (include_tasks -> Rust control flow)
- `roles/rust_build/tasks/per_user.yml:4` Get default shell for '{{ item }}' (command -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:9` Parse default shell for '{{ item }}' (set_fact -> Rust control flow), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:13` Check if cargo is installed for '{{ item }}' who uses '{{ user_shell }}'" (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:23` Get rustup version for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:33` Get cargo version for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:43` Get rustc version for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:53` Check for broken Rust installation (set_fact -> Rust control flow), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:57` Display Rust toolchain versions for '{{ item }}' (debug -> Rust control flow), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:65` Check if rustup needs update for '{{ item }}' (set_fact -> Rust control flow), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:69` Check if cargo/rustc needs update for '{{ item }}' (set_fact -> Rust control flow), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:75` Remove broken Rust installation (file -> file), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:87` Download rustup script for repair (get_url -> fetch), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:93` Reinstall Rust toolchain (command -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:99` Update rustup if needed for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:107` Update Rust toolchain if needed for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:115` Display update results for '{{ item }}' (debug -> Rust control flow), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:122` Download rustup script for '{{ item }}' (get_url -> fetch), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:130` Install rust and tools with the rustup script for '{{ item }}' (command -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:137` Check if cargo-deb is installed for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:147` Install cargo-deb (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:154` Check if cargo-generate-rpm is installed for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:164` Install cargo-generate-rpm for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:170` Check if x86_64-unknown-linux-musl is installed for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:179` Install rustup target x86_64-unknown-linux-musl for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/main.yml:20` (include_tasks -> Rust control flow)

#### Hand-rolled ensure (9 tasks)

Becomes: `sh!(..).unless(check)` or `.creates(path)`

- `roles/rust_build/tasks/per_user.yml:13` Check if cargo is installed for '{{ item }}' who uses '{{ user_shell }}'" (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:122` Download rustup script for '{{ item }}' (get_url -> fetch), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:130` Install rust and tools with the rustup script for '{{ item }}' (command -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:137` Check if cargo-deb is installed for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:147` Install cargo-deb (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:154` Check if cargo-generate-rpm is installed for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:164` Install cargo-generate-rpm for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:170` Check if x86_64-unknown-linux-musl is installed for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:179` Install rustup target x86_64-unknown-linux-musl for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`

#### Version pinning (6 tasks)

Becomes: `bin_version` fact plus the ensure combinator

- `roles/rust_build/tasks/per_user.yml:23` Get rustup version for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:33` Get cargo version for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:43` Get rustc version for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:53` Check for broken Rust installation (set_fact -> Rust control flow), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:65` Check if rustup needs update for '{{ item }}' (set_fact -> Rust control flow), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:69` Check if cargo/rustc needs update for '{{ item }}' (set_fact -> Rust control flow), included from `roles/rust_build/tasks/main.yml:17`

### By module category

| Category | Tasks | Modules | Proposed telepatch primitive |
|---|---|---|---|
| pkg | 13 | apt 4, dnf 5, pacman 2, pip 1, yum 1 | pkg, pkg::pip |
| file | 1 | file 1 | file |
| sh | 16 | command 3, shell 13 | sh |
| fetch | 2 | get_url 2 | fetch |
| control | 17 | debug 2, include_tasks 11, set_fact 4 | Rust control flow |

### Unclassified

None.

### Skipped: out of scope

None.

Regeneration: from the telepatch checkout run
`cargo run -q -p tp -- classify ../tp_basic/conversion/ansible/playbooks/container/rust.yml`
and paste its output over this section unedited (from `## Current method`
through `### Skipped: out of scope`). Regenerate whenever the YAML changes.

The classifier counts `dev_common` tasks too (the first six dispatch rows and
the `amazonlinux2` `yum` task come from it); those are covered in
`dev_base.md`. Read against Outcomes: every `rust_build` task appears there.
The `when` conditions the table hides are: the four family flags on
`main.yml:5`, `:8`, `:11`, `:14`; the musl-gcc condition on `redhat.yml:17`;
and on `per_user.yml` the `cargo_check.rc` and `rust_installation_broken`
flags (items 3 and 4 below).

## Preserved knowledge

Each item is something the YAML knows that a port must keep or fix.

1. Root is looped twice when `admin_users = [root]`. `main.yml:17-18` loops
   `admin_users`, `main.yml:20-21` loops `[root]`. In every image both pass
   over the same user. The second pass finds cargo installed and, because the
   installed versions never equal the pins (item 5), runs `rustup self update`
   and `rustup update` again (`per_user.yml:99-113`). The loop exists so root
   is always covered on a workstation where `admin_users` is a human. The port
   takes the union of `admin_users` and root and deduplicates it.
2. `/home/{{ item }}` is wrong for root. The repair block removes
   `/home/{{ item }}/.rustup` and `/home/{{ item }}/.cargo`
   (`per_user.yml:80-81`); root's home is `/root` (observed: `getent passwd
   root` gives `/root` on all 13 images, and `/home/root` does not exist). For
   root the removal is a no-op and `rustup.sh -y` then runs over the broken
   tree. The port reads the home directory from the user (the passwd entry),
   never builds it from the name.
3. The broken-install repair block. A host counts as broken when `which cargo`
   succeeds and `rustc --version` printed nothing (`per_user.yml:13-20`,
   `:43-55`). The version command pipes through `cut`, so the pipeline exit
   status is `cut`'s and hides a failing `rustc`; the empty output is the
   signal. The block removes both directories, downloads the script and
   reinstalls (`per_user.yml:73-97`). While the flag is set, the update tasks
   (`:104`, `:112`) and the cargo-deb, cargo-generate-rpm and musl-target
   steps (`:145`, `:151`, `:162`, `:168`, `:177`, `:183`) are skipped in the
   same run, so a repaired host gets its extra tools only on the next run. No
   image reaches the block (a fresh install is never broken); workstations
   can. The port keeps it (see Position) and, with a single flow, finishes the
   extras in the same run.
4. An install is detected as "not installed" when `which cargo` fails for any
   reason (`per_user.yml:13-20`, `:127`, `:134`). A broken install whose
   `~/.cargo/bin` is gone but whose `~/.rustup` remains takes the install path,
   not the repair path. A user whose passwd shell cannot run `-lc` (for
   example `nologin`) also reads as "not installed" and the install then runs
   as that user. The port's check must name the same states: absent, present
   and working, present and broken.
5. The version pins never pin. The installer is run with `-y` and no
   `--default-toolchain` (`per_user.yml:94`, `:131`), so it installs whatever
   `stable` is on the build day. Observed 2026-10-30: the existing images hold
   rustup 1.29.2, cargo and rustc 1.99.1, against the pins 1.29.0, 1.94.0 and
   1.94.0 (`inventories/group_vars/all:43-45`). The pins are compared with
   `!=` (`per_user.yml:67`, `:71`), so any host that is not on exactly the pin
   runs `rustup self update` and `rustup update`; those commands move to
   latest, not to the pin. Nothing in the role can produce the pinned versions.
6. `which` is not installed on every base. The login-shell check is
   `which cargo` and `which cargo-deb`, `which cargo-generate-rpm`
   (`per_user.yml:15`, `:139`, `:156`). Observed 2026-10-30 (Local probes):
   `which` is absent from dev_base on fedora43, fedora44, rockylinux10,
   almalinux10 and amazonlinux2023, and absent from the finished rust_build
   images there too (`which: command not found`, exit 127). On those images
   every check reads "not installed" even after installation. A fresh build is
   unaffected (nothing is installed yet). A re-run reinstalls rustup, rebuilds
   `cargo-deb` and `cargo-generate-rpm` from source, and re-adds the target.
   The oracle builds fresh and cannot see this. The port uses a check that
   needs no `which` (`command -v`, or `bin_exists`).
7. Checks run in the user's passwd login shell, installs partly do not. The
   checks are `{{ user_shell }} -lc '...'` (`per_user.yml:13-15`, `:25`, `:35`,
   `:45`, `:101`, `:109`, `:139`, `:156`) so `~/.cargo/bin` is on `PATH` once
   the profile has the `cargo/env` line. The installs and the musl check use
   `. ~/.cargo/env && ...` under the default shell (`:148`, `:165`, `:171`,
   `:180`). Both work because the installer writes the profile line. Observed:
   root's shell is `/bin/bash` on 11 images and `/usr/bin/bash` on arch and
   omarchy. Roadmap Open question 1 (fresh login environment for every
   `as_user` op) covers both forms.
8. musl-gcc is requested only where it is packaged. The comment says "musl-gcc
   is only packaged for Fedora and EL10+ (EPEL). Pure Rust musl builds work
   without it; crates that compile C code for musl need it"
   (`redhat.yml:11-12`). Amazon has no musl-gcc and says so
   (`amazonlinux2023.yml:2`); Debian gets it inside `musl-tools`
   (`debian.yml:9`), Arch inside `musl` (`archlinux.yml:8`). The musl target
   is added on every host regardless (`per_user.yml:179-183`). The condition
   `ansible_distribution == 'Fedora' or ansible_distribution_major_version|int
   >= 10` (`redhat.yml:17`) has a redundant first half: every Fedora major
   version in the fleet (43, 44) is already at least 10, and the condition is
   only evaluated inside the `redhat_based` include (`main.yml:7-8`). Over the
   six RedHat images it is true for fedora43, fedora44, rockylinux10 and
   almalinux10 and false for rockylinux9 and almalinux9. A port may write it
   as "major version at least 10" with the same result; a rebuilt EL9 gains
   nothing.
9. The pip/uv, curl and compiler dependencies come from `dev_common`, which
   `rust.yml` applies first (`rust.yml:8`). Observed 2026-10-30: every
   dev_base image has `curl` and `cc` (Local probes). The role never installs
   `curl` itself. The original downloads the installer with Ansible's
   `get_url`, which needs no `curl`; a port that runs `curl` depends on
   `dev_common` having run first, in the same program or the same image.
10. The installer script is downloaded once to the shared `/tmp/rustup.sh`
    with mode 0755 and run by each user (`per_user.yml:87-94`, `:122-131`).
    The Dockerfile deletes `/tmp/*` after the playbook
    (`../docker_images/Dockerfiles/ansible.debian:14-15`). The port does not
    depend on the file; it needs only that the script is fetched over HTTPS.
11. Tools are built from source, unpinned. `cargo install cargo-deb` and
    `cargo install cargo-generate-rpm` (`per_user.yml:148`, `:165`) take the
    newest release on the build day (observed on the arch image: cargo-deb
    v3.8.0, cargo-generate-rpm v0.21.1). The YAML does not say why
    `libssl-dev`, `openssl-devel`, `openssl`, `pkg-config` and `clang` are
    requested; they are build-time dependencies of something here. Keep all of
    them; the oracle compares the package list.
12. The apt call refreshes no cache (`debian.yml:3-4`, no `update_cache`). In
    the image build `apt-get update` runs at the start of the layer
    (`ansible.debian:6`); the package lists are removed afterwards. A port must
    refresh once before the first apt install (same as `dev_base.md` item 8).
13. A second rustup run on `ubuntu2604` happens in `latest_kernel_build`
    (see Purpose). That is the only image where the update path (`rustup self
    update`, `rustup update`) runs in a build. Roadmap Open question 2 puts
    that image into goal 1's acceptance set, so the update path gets
    exercised there.
14. Users outside `admin_users` and root are untouched. The `ubuntu` user in
    the ubuntu2404 and ubuntu2604 bases (observed, uid 1000) receives no
    rustup. The oracle's user set is `admin_users` plus root, so a port that
    looped over all passwd users would still pass the oracle and be wrong.

## Is the method current

Research date: 2026-10-30. Quotes and summaries are of the pages as fetched
that day. Fetch tools return model summaries of pages; each quoted claim below
was returned by the fetch of the page cited.

### rustup via `sh.rustup.rs`

- The project's install page still gives, for Linux and macOS, a `curl`
  with `--proto '=https' --tlsv1.2 -sSf` piped from the `sh.rustup.rs` host
  into `sh`.
  Source: https://rustup.rs/ (accessed 2026-10-30)
- The rustup book uses the same pipe with `-s -- --default-toolchain none -y`
  for the nightly-only install, so `-y` is a documented flag of the script.
  Source: https://rust-lang.github.io/rustup/installation/index.html (accessed 2026-10-30)
- `rustup-init` can be downloaded directly from `static.rust-lang.org` per
  target, with a SHA-256 file at the same URL plus `.sha256`; distro package
  managers carry rustup packages that the rustup project does not maintain.
  Source: https://rust-lang.github.io/rustup/installation/other.html (accessed 2026-10-30)
- Running with `-y` is also the book's route past the refusal rustup gives when
  a distro Rust is installed under `/usr` ("rustup will complain that you
  already have Rust installed in `/usr` and refuse to install").
  Source: https://rust-lang.github.io/rustup/installation/already-installed-rust.html (accessed 2026-10-30)
- Observed 2026-10-30 (Local probes): the script served by `sh.rustup.rs`
  prints `rustup-init 1.29.2 (a9cf5709f 2026-10-20)` and accepts `-y, --yes`.
- Verdict: still the documented install. The role downloads the script to a file
  and runs it with `-y`, the same two actions as `curl | sh -s -- -y`, so the
  YAML matches the current documentation. The project documents a checksum for
  `rustup-init` binaries only, not for the script, so the script download is
  unverified in both the YAML and any port.
- Open: whether a checksummed `rustup-init` download should replace the script.
  Settled by the reviewer's choice; it does not change the oracle's output
  (see Position, "After equivalence").

### What `-y` installs and what `rustup update` does

- The `default` profile holds `rustc`, `rust-std`, `cargo`, `rust-docs`,
  `rustfmt` and `clippy`, and the installer uses it unless told otherwise.
  Source: https://rust-lang.github.io/rustup/concepts/profiles.html (accessed 2026-10-30)
- `rustup update` updates the stable toolchain and then checks for a rustup
  self-update unless `--no-self-update` is given; `rustup self update` updates
  rustup itself and downloads no toolchain.
  Source: https://rust-lang.github.io/rustup/basics.html (accessed 2026-10-30)
- Verdict: matches the observed component set (cargo, clippy, rust-docs,
  rust-std, rustc, rustfmt) in the Outcomes. `rustup update` already performs a
  self-update check, so the role's separate `rustup self update`
  (`per_user.yml:101`) overlaps it.

### musl-gcc and the musl target

- `musl-gcc` ("Wrapper for using gcc with musl") is listed for Fedora Rawhide,
  Fedora 43 to 45 and Fedora EPEL 10.2 to 10.4, with no EPEL 9 build.
  Source: https://packages.fedoraproject.org/pkgs/musl/musl-gcc/epel-10.html (accessed 2026-10-30)
- Verdict: confirms the comment at `redhat.yml:11` that musl-gcc is packaged
  only for Fedora and EL10. The claim that pure-Rust musl builds work without it
  rests on the in-repo comment and the probe below; the rustc book page for the
  target returned HTTP 404 on 2026-10-30 at both the `rustc/platform-support`
  path and the `nightly/rustc/platform-support` path of doc.rust-lang.org, and a search for it returned only
  old Rust book chapters (secondary). Not retried.
- Observed 2026-10-30 (Local probes): a `cargo new` hello-world built offline with
  `--target x86_64-unknown-linux-musl` on `rust_build-rockylinux9`, which has no
  musl-gcc, produced a static-pie executable that runs.
- Open: a crate that compiles C code for the musl target on rockylinux9
  (`cargo build --target x86_64-unknown-linux-musl` with a `cc`-using crate)
  fails; this confirms the comment's second half. Not run; it needs a network
  fetch of crates and is not part of the oracle.

### cargo-deb and cargo-generate-rpm

- The cargo-deb README installs it with `rustup update` then `cargo install
  cargo-deb`, requires Rust 1.76 or newer, and warns that distro Rust
  packages (Bookworm's) are too old, pointing to rustup.
  Source: https://github.com/kornelski/cargo-deb (accessed 2026-10-30)
- The cargo-generate-rpm page returned HTTP 404 at
  `https://github.com/cargo-generate-rpm/cargo-generate-rpm` (accessed 2026-10-30);
  not retried.
- Verdict: `cargo install cargo-deb` is the documented method and it needs a
  rustup toolchain newer than 1.76, which the role installs first. Nothing
  moved. For cargo-generate-rpm the method is unconfirmed by documentation.
- Open: `cargo install --list` as root on each rust_build image (the oracle's
  `~/.cargo/bin` capture contains both names; version side diff shows drift).

### Local probes

Read-only probes run on 2026-10-30 against the pinned local images
`resurgentech/dev_base-<distro>:latest` and
`resurgentech/rust_build-<distro>:latest` (13 distros each; for example
rust_build ubuntu2404 fba03edf51ac, rockylinux9 0aae88bd3ed1, fedora43
43d9e612f316, arch 46fe268a7ed8). Command form:
`docker run --rm --entrypoint <sh|bash> <image> -c|-lc '<probe>'`. The
rust_build images were built from earlier ansible commits; they stand in for
the oracle's "before" capture and the oracle capture supersedes them.

| Probe | Result (2026-10-30) |
|---|---|
| `command -v curl cc which cargo` and `ls -d /root/.rustup` in each dev_base image | `curl` and `cc` present on all 13; `which` absent on fedora43, fedora44, rockylinux10, almalinux10, amazonlinux2023; no `cargo`, no `/root/.rustup` anywhere |
| `which cargo` in `bash -lc` on rust_build | rc 0 on ubuntu2404 (`/root/.cargo/bin/cargo`); `which: command not found`, rc 127 on fedora43, rockylinux10, amazonlinux2023 |
| `ls /root/.cargo/bin \| md5sum` on all 13 rust_build images | one distinct hash for all 13; `ls /root/.cargo/bin \| wc -l` on arch is 16 |
| `rustup --version; cargo --version; rustc --version; rustup target list --installed; rustup component list --installed` on ubuntu2404, rockylinux9, fedora43, arch | rustup 1.29.2, cargo and rustc 1.99.1; targets gnu and musl; components cargo, clippy, rust-docs, rust-std (gnu, musl), rustc, rustfmt, identical on the four |
| `cat ~/.rustup/settings.toml` (same four) | `default_toolchain = "stable-x86_64-unknown-linux-gnu"`, `profile = "default"`, `[overrides]` empty |
| `grep -n cargo ~/.profile ~/.bashrc ~/.bash_profile` (same four) | `. "$HOME/.cargo/env"` in `.profile` on all; also `.bashrc` and `.bash_profile` where they exist (not on arch) |
| `getent passwd root \| cut -d: -f6,7`; `ls /home/root` on all 13 rust_build | `/root:/bin/bash` on 11, `/root:/usr/bin/bash` on arch and omarchy; `/home/root` does not exist (checked on ubuntu2404, rockylinux9, fedora43, arch) |
| `ls /home` on rust_build | `ubuntu` on ubuntu2404 and ubuntu2604; empty elsewhere |
| `command -v musl-gcc` on all 13 rust_build | present on debian12/13, ubuntu2404/2604, fedora43/44, rockylinux10, almalinux10, arch, omarchy; absent on rockylinux9, almalinux9, amazonlinux2023 |
| `rpm -q musl-gcc --qf "%{vendor}"`; `dnf -q repoquery --qf "%{name} %{repoid}" musl-gcc` on rust_build rockylinux10 | `Fedora Project`; `musl-gcc epel` |
| the same repoquery on rust_build rockylinux9 and amazonlinux2023 | no output; the package is not installed |
| `pacman -Qo $(command -v musl-gcc)` (arch); `dpkg -S $(command -v musl-gcc)` (debian13) | `musl 1.2.6-2`; `musl-tools` |
| `cargo install --list` on rust_build arch | `cargo-deb v3.8.0`, `cargo-generate-rpm v0.21.1` |
| `cargo new --offline h && cargo build --offline --target x86_64-unknown-linux-musl && ./h` on rust_build rockylinux9 | builds; `file` reports static-pie; prints "Hello, world!" |
| `curl -sSf https://sh.rustup.rs \| grep -n -- '-y\|rustup-init'` | `rustup-init 1.29.2 (a9cf5709f 2026-10-20)`; `-y, --yes` option present |

Not probed: the update path (`rustup self update`, `rustup update`) on any
image, and the repair path; neither runs in a fresh build.

## Recommendation and decision

### Options

1. Port 1:1, keeping the YAML's structure: an `os` match for the package
   tables, then per user a `which`-style check, version fetches, comparison
   with pins, repair, update, install, extras. For: easiest to review against
   the YAML. Against: carries items 1, 2, 5 and 6 (root twice, `/home/root`,
   pins that never pin, `which` missing on five bases).
2. Port by outcome and fix what the oracle cannot see. Same package tables
   and same installed set; per user (deduplicated) one flow:
   absent, broken, present. Home from the user, `command -v` not `which`, no
   version comparison with pins. For: shortest correct program; fixes items
   1, 2, 6; nothing it changes appears in the oracle's names. Against: drops
   the pin variables from this role and changes when the update commands run,
   which shows in the non-gating version side diff only on a re-run.
3. Leave `rust_build` in Ansible. For: no work. Against: `latest_kernel_build`
   and every `rust_build` image depend on it and the corpus is the migration
   target.

### Position

Option 2. Equivalence on the 13 images first; the fixes below are ones the
oracle cannot see, so they are made in the port.

**Decision on version checks: `unless` or `bin_version`.** The YAML has two
kinds of check and they differ in what they need.

- Existence checks gate one op each: install rustup if no cargo, install
  `cargo-deb` if no `cargo-deb`, install `cargo-generate-rpm` if no
  `cargo-generate-rpm`, add the musl target if it is not listed. Use `unless`
  on those ops: `unless = "command -v cargo"`, `"command -v cargo-deb"`,
  `"command -v cargo-generate-rpm"` and
  `"rustup target list --installed | grep -qx x86_64-unknown-linux-musl"`. The
  check sits with the op it guards, runs in the same fresh login environment
  (Open question 1) so it sees `~/.cargo/bin` after the install step ran,
  needs no round trip of its own beyond the op, and matches the example in the
  design. The roadmap's design says an unmet `unless` skips the op without
  reporting it as changed.
- The three-state decision needs a value: absent, broken, working. Use one
  `bin_version("rustc")` per user: `bin_exists("cargo")` true and
  `bin_version("rustc")` `None` means broken (repair); `Some(_)` means working
  (update); `cargo` absent means install. A Rust `if` on that picks a
  multi-op branch (repair is three ops), which an op-level `unless` cannot
  express. The cost is one awaited round trip per user and per run; with the
  container user set `{root}` that is one.
- Stakes if the answer goes the other way. All-`unless`: the repair block has
  no fact to branch on, so it either becomes a chain of `unless` checks
  repeating `rustc --version` on each of three ops, or is dropped; the YAML's
  repair behaviour is lost or tripled. All-`bin_version`: each extra tool
  needs its own fact and a Rust `if`, and a fact read before the install ops
  can be stale after them; the extras would then be skipped or repeated
  depending on when facts are read. In both cases the oracle is unaffected on a
  fresh build (the extras are always absent), so the stakes are the re-run path
  (`ubuntu2604` `latest_kernel_build`, workstations).
- Open: whether a `bin_version` fact is read at plan time or at the op, which
  decides whether a fact taken before the install step can see the install.
  Settled by `tp plan` of the port on a bare dev_base container: the plan must
  list the cargo-deb op as unskipped, and an apply followed by a second apply
  must list no changed op.

**Pins.** The pins never pin (item 5) and the only effect of the `!=` tests
is to run the update commands on every re-run. The port keeps the effect and
drops the comparison: a working install gets `rustup update` (which
self-updates, see Is the method current), a missing one gets the install and
no update in the same run. `rustup_version`, `cargo_version` and
`rustc_version` stay in `group_vars/all` until no role reads them; the grep
shows only `per_user.yml` does.

**Fixes made in the port** (they do not show in the oracle diff):

- Users are `admin_users` plus root, deduplicated, in that order (item 1).
- The home directory of each user comes from the user's passwd entry, never
  from the name (item 2).
- Checks use `command -v` or `bin_exists`, not `which` (item 6).
- The extras (`cargo-deb`, `cargo-generate-rpm`, the musl target) are
  installed in the same run as a repair (item 3).
- Refresh the apt cache once before the first apt install (item 12).
- `musl-gcc` condition written as "RedHat family and major version at least
  10" (item 8).

**Kept as is:** the package names per family; `musl-gcc` only where the
condition holds; the Amazon file without it; the default profile; the musl
target on every host; `cargo install` for the two tools; the repair block
(removing `~/.rustup` and `~/.cargo`, then reinstalling). The repair block is
kept although no image reaches it, because workstations do (Purpose) and the
step names it as knowledge to preserve; the oracle cannot test it, so a unit
test on the command plan stands in.

Dropped branches (no image reaches them; recorded, not ported):

- Amazon Linux 2: `rust_build` has no file for it (`main.yml:4-14`); the
  `dev_common` file is dropped in `dev_base.md`.
- Debian 10 and Ubuntu 20.04 and 22.04 flags
  (`inventories/group_vars/all:7`, `:11-12`): `rust_build` does not read them.
  The flags stay in `group_vars` for other roles.
- `ansible_distribution == 'Fedora'` half of the musl-gcc condition
  (`redhat.yml:17`): redundant (item 8).
- The `ansible_user`-is-human case is not tested by any image; the port still
  accepts a list of users.

Bugs the oracle cannot see: root looped twice (item 1); the
`/home/{{ item }}` path for root (item 2); `which` missing on five bases
(item 6); the extras skipped in the run that repairs (item 3).

After equivalence (change what the oracle sees; not made yet):

- Pin the toolchain, or state that `stable` is the intent, and delete the pin
  variables. Pinning changes toolchain names (`1.94.0-...` instead of
  `stable-...`) and the component set's version.
- Replace the `curl | sh` script download by a checksummed `rustup-init`
  download (the `.sha256` file at `static.rust-lang.org`); no names change.
- Pin `cargo-deb` and `cargo-generate-rpm` (`cargo install --locked --version`)
  or fetch release binaries; changes build time and versions.
- Request `musl-gcc` on Rocky and Alma 9 if a crate needs it (there is no
  EPEL 9 build, so the answer is a different package source).
- Drop `rls` and `rust-analyzer` stub names from the `~/.cargo/bin` list by
  choosing the `minimal` profile; this changes the component list and the names.
- Install `which` (or drop it from the dev_common set of assumptions); only
  needed if another role calls `which`.

Open: nothing blocks the port. The Open lines under Is the method current and
in this section are checks that the oracle or `tp plan` runs.

Decision: Option 2, with `unless` for the four existence ops and one
`bin_version("rustc")` per user for the absent, broken, working decision, and
with the "after equivalence" list above. Decided by agent (agent-alone); not
yet reviewed by the user.

## Port notes

## Review

2026-10-30: first pass, written in one run (agent-alone). Re-read against the
YAML: every citation in Outcomes and Preserved knowledge was opened in
`conversion/ansible/`; line numbers for `per_user.yml`, `main.yml`,
`redhat.yml`, `debian.yml`, `amazonlinux2023.yml`, `archlinux.yml` and
`group_vars/all` were checked by `cat -n`. Counts rechecked by command: 25
`- name:` lines in `per_user.yml` (21 top-level, one block, three inside it),
six `include_tasks` in `main.yml`, 16 names in `~/.cargo/bin` identical on 13
images. The rustc book page and the cargo-generate-rpm page were not
reachable; both are recorded above.

## skill-feedback

Input for the next version of the `ansible-port` skill (v1, second trial doc
after `dev_base.md`). Each item is adoptable or rejectable on its own.

1. Local probes beat web research here. Three of the four questions the doc
   asks (is `which` present, which images get musl-gcc, what rustup actually
   installed) were settled in minutes by `docker run` on the existing
   rust_build images, and one of them (`which` missing on five bases) is a
   finding no document would have given. Adopt: when an old built image of the
   playbook exists, UNDERSTAND.md says to probe it first, and to treat it as
   the "before" for Outcomes with the caveat that it was built from earlier
   commits.
2. The skill has no step for "pins and variables that look like the contract".
   `rustup_version` and its siblings read as a version contract; only
   comparing them to the installed state shows they never pin anything.
   Adopt: a line in UNDERSTAND.md level 4: for every variable compared in the
   YAML, state what the YAML does when the comparison is true and false and
   whether any task can ever make it true.
3. The skill says Outcomes comes before Current method, but a playbook that
   applies a second role (here `dev_common`) makes the classifier output
   include that role's tasks. The doc had to explain that in prose after the
   unedited paste. Adopt: say in UNDERSTAND.md section 3 that tasks of roles
   documented elsewhere appear in the table and are covered by a pointer
   sentence under it; or give `tp classify` a `--role` filter.
4. "No hedge words" is a useful rule and cost real time on research
   conclusions (the hedge words the check bans); the rule is right but the skill gives no
   phrasing for a conclusion that rests on one summary-only page. Adopt: a
   sentence template, "The page says X; confirmed on a second page: no" for
   such claims, so the author does not reach for a hedge.
5. Failed fetches were common (the rustc book platform page, the
   cargo-generate-rpm repo both returned 404). The skill says to record a
   failed fetch; add that a search engine's result list is a lead and not a
   citation, so a failed primary page leaves the claim under an `Open:` line.
6. The interactive/agent-alone split worked. One gap: agent-alone says the
   port "may proceed", but this step's port waits for the equivalence harness.
   Adopt: the Decision line may carry "port pending: <dependency>" so the
   state is readable from the doc.
7. Questions to the reviewer: the template has no place for them apart from
   Position. Here the one real question (unless versus bin_version) fit under
   Position; keep it there, but the skill should say so.
8. The Outcomes table row for "rustup toolchains, components, targets" has no
   counterpart in the template's example mapping, which is package-shaped.
   Adopt: the template's mapping table lists the oracle's other rows (user
   tool state, `~/.cargo/bin` names) so a tool-state playbook does not invent
   rows.
