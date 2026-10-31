# latest_kernel_build.yml: understanding doc

Scope: `playbooks/container/latest_kernel_build.yml` and the role `rust_kernel`
that only this playbook applies. The other four roles it lists are covered by
sibling docs (see Purpose). All file:line citations are relative to
`conversion/ansible/` (byte copies of the ansible repo at 79d1ca1). Last read
against those copies on 2026-10-30.

## Purpose

`latest_kernel_build.yml` makes an image that can build the latest upstream
Linux kernel tree with the latest rustup toolchain, Rust-enabled. It runs on
all hosts as root (`playbooks/container/latest_kernel_build.yml:5-6`) and
applies five roles in order (`playbooks/container/latest_kernel_build.yml:7-12`):
`dev_common`, `src_repos`, `kernel_build`, `rust_build`, `rust_kernel`.

Which doc covers which role (this doc describes only `rust_kernel` and what
is specific to this playbook):

| Role | Covered by | Note |
|---|---|---|
| `dev_common` | `conversion/dev_base.md` | re-applied here (line 8) |
| `src_repos` | `conversion/kernel_build.md` | applied by `kernel_build.yml` too |
| `kernel_build` | `conversion/kernel_build.md` | same |
| `rust_build` | `conversion/rust.md` | applied by `rust.yml` too; this image's parent |
| `rust_kernel` | this doc | no other playbook applies it |

`grep -rn rust_kernel playbooks/ roles/` over the mirrored originals finds one
hit outside the role itself: `playbooks/container/latest_kernel_build.yml:12`.

Who runs it: `docker_images` builds it as the `latest_kernel_build` container,
parent `rust_build` (`../docker_images/docker-bake.hcl`, `CONTAINERS`), and
only for distros whose `set` is `latest`. Exactly one distro has that set:
`ubuntu2604` (`../docker_images/docker-bake.hcl`, `DISTROS`; the other 12 use
`default`, which ends at `rust_build`). So one image reaches `rust_kernel`:
`resurgentech/latest_kernel_build-ubuntu2604`. The image build runs
`./run targets <playbook> inventories/localhost.yml` with
`--extra-vars='ansible_user=root'` (`../docker_images/Dockerfiles/ansible.debian`),
after a full `apt-get upgrade`. The role's own acceptance test is `make rustavailable` in a
kernel tree (`roles/rust_kernel/tasks/main.yml:4`); the kernel documentation
spells it `make LLVM=1 rustavailable` (see Is the method current).

Flags and variables the role reads (open `inventories/group_vars/all` first):

- `debian_based` (`inventories/group_vars/all:6`): Ubuntu, Pop!_OS, Debian.
  Gates the one apt task (`roles/rust_kernel/tasks/main.yml:10`).
- `admin_users` (`inventories/group_vars/all:16`): `["{{ ansible_user }}"]`.
  The image build sets `ansible_user=root`, so `admin_users` is `["root"]`.
  The role loops over it (`roles/rust_kernel/tasks/main.yml:13`) and then
  over `[root]` (`roles/rust_kernel/tasks/main.yml:16`), so on this image
  `per_user.yml` runs twice for root.
- `rustup_version`, `cargo_version`, `rustc_version`
  (`inventories/group_vars/all:43-45`: 1.29.0, 1.94.0, 1.94.0): read by
  `rust_build`, not by `rust_kernel`. The role has no `defaults/` and no
  version of its own (`find roles/rust_kernel` lists `tasks/main.yml` and
  `tasks/per_user.yml` only). Those pins matter here for one reason: the
  playbook is named "latest" and `rust_build` compares against the pins
  (see `conversion/rust.md`); the image observed 2026-10-30 holds rustc 1.99.1
  and rustup 1.29.2 (see Local probes), so the pins do not hold the toolchain
  at 1.94.0 on a fresh build. This doc does not decide that; `rust.md` does.

## Outcomes

What `rust_kernel` adds on top of the `rust_build` image, on the one image
that runs it. The oracle compares per image: package names and arch, system
pip names, per admin user plus root the rustup toolchains, components, targets
and `~/.cargo/bin` names, `/etc/apt/sources.list*`, `/usr/local/bin` names
(versions non-gating).

### Debian family (ubuntu2604; the only image that reaches this role)

- Package installed by apt: `libclang-dev` (`roles/rust_kernel/tasks/main.yml:6-10`),
  the only package in the role. It is the development metapackage for libclang.
  Requested name `libclang-dev`; installed names include `libclang-dev` and,
  through its dependency, `libclang-21-dev` (observed 2026-10-30, see Local
  probes). The oracle compares installed names, so both appear in the diff
  if either is missing. No `update_cache` on the task (`main.yml:7-9` holds
  `name` and `state` only); the Dockerfile refreshed the cache before the
  playbook began.
- rustup component `rust-src` for root (`roles/rust_kernel/tasks/per_user.yml:3-4`).
- `~/.cargo/bin/bindgen` for root, from the crate `bindgen-cli`
  (`roles/rust_kernel/tasks/per_user.yml:10-13`).
- pip: nothing. `/etc/apt/sources.list*`: no change, the role adds no
  repository. `/usr/local/bin`: no change (cargo installs into `~/.cargo/bin`).
- Toolchains and targets: no change. The role adds one component and one
  binary to the toolchain `rust_build` installed.

### Other families (RedHat, Amazon, Arch)

The role has no branch for them: only the apt task carries a `when`
(`roles/rust_kernel/tasks/main.yml:10`), so on a non-Debian host the role would
run just the two per-user tasks and install no libclang package. No image
reaches this. They are listed under Dropped branches.

### Every image that runs it

- Both per-user tasks run for each of `admin_users` and for root
  (`main.yml:12-16`). With `admin_users = ["root"]` the effective user list is
  `[root, root]`; the end state is that of one pass (see Preserved knowledge 2).

### Mapping to the oracle checklist

| Oracle item | ubuntu2604 after this role |
|---|---|
| package names + arch | `rust_build` set plus `libclang-dev` and its dependencies (`libclang-21-dev`, amd64) |
| system pip names | unchanged |
| rustup toolchains (root) | unchanged: `stable-x86_64-unknown-linux-gnu` |
| rustup components (root) | `rust_build` set plus `rust-src` |
| rustup targets (root) | unchanged: `x86_64-unknown-linux-gnu`, `x86_64-unknown-linux-musl` |
| `~/.cargo/bin` names (root) | `rust_build` set plus `bindgen` |
| /etc/apt/sources.list* | unchanged |
| /usr/local/bin names | unchanged |

## Current method

_Generated by `tp classify playbooks/container/latest_kernel_build.yml`._

83 tasks in scope; 28 match no pattern and are plain module calls. A task is listed under every pattern it matches, so pattern counts overlap and do not sum to the task total.

### By pattern

| Pattern | Tasks | Proposed telepatch primitive |
|---|---|---|
| Distro dispatch | 22 | typed `os` fact and a `match`, or a per-family table on `pkg` |
| Per-user loop | 30 | `for u in users { let s = h.as_user(u); ... }`; the login shell is a fact of the user |
| Hand-rolled ensure | 9 | `sh!(..).unless(check)` or `.creates(path)` |
| Version pinning | 6 | `bin_version` fact plus the ensure combinator |
| Repo setup | 3 | `repo` primitive; one cache update per window |
| Shell for a primitive | 2 | the matching primitive (`svc`, `file`, `pkg`, `user`), not `sh` |
| Controller-side gather | 0 | `secret`, `fetch`, `local` (prepare phase) |
| Handler | 0 | a guard on the restart op; identical guarded ops merge |

#### Distro dispatch (22 tasks)

Becomes: typed `os` fact and a `match`, or a per-family table on `pkg`

- `roles/dev_common/tasks/main.yml:4` dev_common_debian (include_tasks -> Rust control flow)
- `roles/dev_common/tasks/main.yml:8` dev_common_redhat (include_tasks -> Rust control flow)
- `roles/dev_common/tasks/main.yml:12` dev_common_amazonlinux2 (include_tasks -> Rust control flow)
- `roles/dev_common/tasks/main.yml:16` dev_common_amazonlinux2023 (include_tasks -> Rust control flow)
- `roles/dev_common/tasks/main.yml:20` dev_common_archlinux (include_tasks -> Rust control flow)
- `roles/dev_common/tasks/main.yml:26` Various python dependancies (pip -> pkg::pip)
- `roles/src_repos/tasks/main.yml:4` Look for deb822 style apt sources (find -> fact (exists, stat, user_info, ...))
- `roles/src_repos/tasks/main.yml:11` (include_tasks -> Rust control flow)
- `roles/src_repos/tasks/main.yml:14` (include_tasks -> Rust control flow)
- `roles/kernel_build/tasks/main.yml:4` kernel_build_ubuntu (include_tasks -> Rust control flow)
- `roles/kernel_build/tasks/main.yml:8` kernel_build_debian10 (include_tasks -> Rust control flow)
- `roles/kernel_build/tasks/main.yml:12` kernel_build_debian (include_tasks -> Rust control flow)
- `roles/kernel_build/tasks/main.yml:16` kernel_build_redhat (include_tasks -> Rust control flow)
- `roles/kernel_build/tasks/main.yml:20` kernel_build_amazonlinux2 (include_tasks -> Rust control flow)
- `roles/kernel_build/tasks/main.yml:24` kernel_build_amazonlinux2023 (include_tasks -> Rust control flow)
- `roles/kernel_build/tasks/main.yml:28` kernel_build_archlinux (include_tasks -> Rust control flow)
- `roles/rust_build/tasks/main.yml:4` (include_tasks -> Rust control flow)
- `roles/rust_build/tasks/main.yml:7` (include_tasks -> Rust control flow)
- `roles/rust_build/tasks/redhat.yml:13` RedHat musl-gcc for the musl target (dnf -> pkg), included from `roles/rust_build/tasks/main.yml:7`
- `roles/rust_build/tasks/main.yml:10` (include_tasks -> Rust control flow)
- `roles/rust_build/tasks/main.yml:13` (include_tasks -> Rust control flow)
- `roles/rust_kernel/tasks/main.yml:6` Debian libclang for bindgen (apt -> pkg)

#### Per-user loop (30 tasks)

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
- `roles/rust_kernel/tasks/main.yml:12` (include_tasks -> Rust control flow)
- `roles/rust_kernel/tasks/per_user.yml:3` Add rustup component rust-src for '{{ item }}' (shell -> sh), included from `roles/rust_kernel/tasks/main.yml:12`
- `roles/rust_kernel/tasks/per_user.yml:10` Install bindgen-cli for '{{ item }}' (shell -> sh), included from `roles/rust_kernel/tasks/main.yml:12`
- `roles/rust_kernel/tasks/main.yml:15` (include_tasks -> Rust control flow)

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

#### Repo setup (3 tasks)

Becomes: `repo` primitive; one cache update per window

- `roles/src_repos/tasks/apt_sources_deb822.yml:7` Turn on source repos in /etc/apt/sources.list.d/*.sources (shell -> file (was `sh`)), included from `roles/src_repos/tasks/main.yml:11`
- `roles/src_repos/tasks/apt_sources_deb822.yml:17` Update apt package cache again (apt -> pkg), included from `roles/src_repos/tasks/main.yml:11`
- `roles/src_repos/tasks/apt_sources_list.yml:4` Turn on source repos to /etc/apt/sources.list (shell -> file (was `sh`)), included from `roles/src_repos/tasks/main.yml:14`

#### Shell for a primitive (2 tasks)

Becomes: the matching primitive (`svc`, `file`, `pkg`, `user`), not `sh`

- `roles/src_repos/tasks/apt_sources_deb822.yml:7` Turn on source repos in /etc/apt/sources.list.d/*.sources (shell -> file (was `sh`)), included from `roles/src_repos/tasks/main.yml:11`
- `roles/src_repos/tasks/apt_sources_list.yml:4` Turn on source repos to /etc/apt/sources.list (shell -> file (was `sh`)), included from `roles/src_repos/tasks/main.yml:14`

### By module category

| Category | Tasks | Modules | Proposed telepatch primitive |
|---|---|---|---|
| pkg | 29 | apt 12, dnf 7, pacman 3, pip 4, yum 3 | pkg, pkg::pip |
| file | 1 | file 1 | file |
| sh | 22 | command 3, shell 19 | sh |
| fetch | 2 | get_url 2 | fetch |
| fact | 1 | find 1 | fact (exists, stat, user_info, ...) |
| control | 28 | debug 2, include_tasks 22, set_fact 4 | Rust control flow |

### Unclassified

None.

### Skipped: out of scope

None.

Regeneration: from the telepatch checkout run
`cargo run -q -p tp -- classify ../tp_basic/conversion/ansible/playbooks/container/latest_kernel_build.yml`
and paste its output over this section unedited (from `## Current method`
through `### Skipped: out of scope`). Regenerate whenever the YAML changes.

The classifier lists 83 tasks across five roles. The `rust_kernel` rows are:
`roles/rust_kernel/tasks/main.yml:6` (Distro dispatch: the `apt` task gated
by `debian_based`), `main.yml:12` and `main.yml:15` (the two `include_tasks`
loops, counted under Per-user loop), and `per_user.yml:3` and `per_user.yml:10`
(the two `shell` tasks, `sh`). Every one is in Outcomes. The `when` on the
dispatch task is `debian_based|bool` (`main.yml:10`): it encodes "libclang
comes from `libclang-dev` on the Debian family", and no other family has an
equivalent task (Preserved knowledge 6). The other rows belong to the four
other roles and are read in their docs; the classifier counts them here
because it follows `roles:`.

## Preserved knowledge

1. The role is a layer on `rust_build`, not a second installer. Its header
   says it "adds what the kernel's Rust support needs on top of a rustup
   toolchain from rust_build" (`roles/rust_kernel/tasks/main.yml:2-3`), and
   it never installs rustup, cargo or a toolchain. It needs `~/.cargo/env`
   and `rustup` for each user (`per_user.yml:4`, `per_user.yml:11`). The port
   keeps the order `rust_build` then `rust_kernel` (playbook lines 11-12). If
   `~/.cargo/env` is absent the shell fails and the run stops, which is the
   right behaviour.
2. Root is processed twice on this image. `admin_users` is `["root"]` here
   (Purpose), and the role loops over `admin_users` and then over `[root]`
   (`main.yml:12-16`). The second pass changes nothing: `rustup component add
   rust-src` reports "is up to date" and `bindgen` exists so `creates` skips
   the build (Local probes). `rust_build` has the same double loop
   (`roles/rust_build/tasks/main.yml:17-21`). The oracle cannot see this
   (the end state is identical), so the port fixes it: the user list is
   `admin_users` plus root with duplicates removed, order kept (Position).
3. `changed_when: "'installing' in rust_src_result.stderr"`
   (`per_user.yml:8`) is the only change detection in the role, and it does
   not detect the change on the installed rustup. Observed 2026-10-30 with
   rustup 1.29.2 in `rust_build-ubuntu2604`: adding the missing component
   printed `info: downloading component rust-src` on stderr and nothing on
   stdout; the word "installing" never appeared. The already-installed case
   printed `info: component rust-src is up to date`. So the Ansible task
   reports unchanged on a real install and on a no-op alike. Only the
   reporting is wrong; the component is installed either way, which is why the
   oracle cannot see it. The step's `changed_if` replaces the Python
   substring test; its regex must be `downloading` (the word rustup 1.29.2
   prints on a real install), because a literal `installing` keeps the broken
   reporting. Position decides.
4. `changed_if` in telepatch matches combined stdout+stderr and requires
   rc 0, where the original tested stderr only. For this command stdout is
   empty (observed), so the two agree. rc is 0 on the install and on the
   no-op (observed). A failed `rustup` is a failure in both.
5. `creates: "~{{ item }}/.cargo/bin/bindgen"` (`per_user.yml:13`) is a
   path in the user's own home, so the guard is per user. Telepatch
   `creates = "path"` has no tilde expansion of its own, so the port gives
   the absolute home of the user: `/root/.cargo/bin/bindgen` for root. For a
   non-root admin user the home comes from `getent passwd`, not from
   `/home/<name>`. The `/home/<name>` form is a bug in `rust_build`
   (`roles/rust_build/tasks/per_user.yml:80-81` use `/home/{{ item }}`, which
   is `/home/root` for root, a path that does not exist); this role avoids it
   by using `~`.
6. `libclang-dev` exists on the Debian arm only (`main.yml:6-10`). On the
   other families the role relies on `clang` packages from `rust_build` to
   bring libclang (`roles/rust_build/tasks/redhat.yml:8` and
   `archlinux.yml:7` list `clang`). The kernel build needs libclang for
   bindgen (Is the method current). On Debian the `clang` package alone left
   no `libclang-dev` (observed in `rust_build-ubuntu2604`: `libclang1-21`
   present, `libclang-dev` absent), which is why the task exists. No image
   reaches the other families.
7. Both shell commands use `. ~/.cargo/env && ...` under Ansible's default
   `/bin/sh` with `become_user` (`per_user.yml:4-6`, `per_user.yml:11-14`), not
   the user's login shell that `rust_build` fetches with `getent`
   (`roles/rust_build/tasks/per_user.yml:4-15`). `~` resolves to the become
   user's home. The port's `as_user(u)` runs in a fresh login environment of
   `u` (Open question 1); the `. ~/.cargo/env` prefix stays, because it does
   not depend on a login profile having been written (`~/.cargo/env` exists in
   `rust_build-ubuntu2604`, observed).
8. `cargo install --locked bindgen-cli` (`per_user.yml:11`) builds from
   source with the published lockfile, takes minutes, and needs network and a
   C linker (`gcc`, from `dev_common`). The version is whatever crates.io
   serves on the build day (0.73.2 observed). Because `creates` guards it, a
   later play never rebuilds; there is no upgrade path. Versions are not an
   equivalence point.
9. The apt task has no `become_user` and runs as root (the play is root,
   playbook line 6). Components are per toolchain per user, so each user gets
   its own `rust-src` (kernel documentation, Is the method current).
10. `rust-src` is added to whichever toolchain is the user's default: there
    is no `--toolchain` (`per_user.yml:4`). On this image the only toolchain is
    `stable-x86_64-unknown-linux-gnu`, active and default (observed 2026-10-30).

## Is the method current

Research date: 2026-10-30. The fetch tool returns a model summary of each
page, so each claim below is a lead, confirmed against a local observation
where a probe exists.

### The kernel's Rust requirements

- The kernel documentation lists three needs: the standard library source
  ("required because the build system will cross-compile `core`"), installed
  with `rustup component add rust-src`; `bindgen`, installed with
  `cargo install --locked bindgen-cli`, which "will download and build the
  tool from source"; and `libclang` (part of LLVM), which bindgen uses to
  understand the kernel's C code. It names `make LLVM=1 rustavailable` as the
  check and calls a build with a complete LLVM toolchain the best supported
  setup.
  Source: https://docs.kernel.org/rust/quick-start.html (accessed 2026-10-30)
- The rust-bindgen requirements page: "bindgen leverages libclang to
  preprocess, parse, and type check C and C++ header files", and Clang 9.0 or
  greater is required.
  Source: https://rust-lang.github.io/rust-bindgen/requirements.html (accessed 2026-10-30)
- The rustup book describes `rust-src` as a local copy of the Rust standard
  library source and `rustup component add` as the way to add a component to
  an installed toolchain. It shows no `rust-src` example.
  Source: https://rust-lang.github.io/rustup/concepts/components.html (accessed 2026-10-30)
- Verdict: the three items the role installs are the three items the kernel
  documentation lists, by the same commands, so the method is current. The
  role's check `make rustavailable` omits `LLVM=1` (`main.yml:4`); the
  documented check is `make LLVM=1 rustavailable`. It is a comment; nothing
  executes it.
- The quick-start page gives no numeric minimum rustc or bindgen version, so
  documentation does not settle whether the installed rustc 1.99.1 and
  bindgen 0.73.2 satisfy a given kernel tree.
  Open: `make LLVM=1 rustavailable` in a kernel tree inside
  `resurgentech/latest_kernel_build-ubuntu2604:latest`. It is not an oracle
  item (the oracle compares names); it is the role's own acceptance check.

### libclang-dev on Ubuntu 26.04

- Ubuntu 26.04 LTS (resolute) carries `libclang-dev` 1:21.1.6-71 from
  `universe`, source package `llvm-defaults`, depending on `libclang-21-dev`.
  Source: https://packages.ubuntu.com/resolute/libclang-dev (accessed 2026-10-30)
- Verdict: the package name is still correct on the one image that runs it.
  Observed 2026-10-30 (Local probes): `libclang-dev 1:21.1.6-71` and
  `libclang-21-dev 1:21.1.8-6ubuntu1` are installed in
  `latest_kernel_build-ubuntu2604` and absent from `rust_build-ubuntu2604`.

### `changed_when` on rustup output

- Observed, not documented: rustup 1.29.2 prints `info: downloading component
  rust-src` on a real add and `info: component rust-src is up to date` on a
  repeat, both on stderr, rc 0 (Local probes). The rustup book page fetched
  does not describe these messages.
  Source: https://rust-lang.github.io/rustup/concepts/components.html (accessed 2026-10-30)
- Verdict: `'installing' in stderr` (`per_user.yml:8`) does not match the
  installed rustup's output. The wording of rustup's progress messages is not
  a documented interface, so the regex rests on one observation.
  Open: `docker run --rm --entrypoint sh resurgentech/rust_build-ubuntu2604:latest -c '. ~/.cargo/env; rustup component add rust-src 2>&1'`
  on the image the port is tested against, run before the port's `changed_if`
  regex is fixed.

### Ansible `command`/`shell` `creates`

- In the Ansible source the module declares `creates` with type `path`,
  checks `glob.glob(creates)` before running, exits with `changed` false when
  it matches, and otherwise sets `changed` true without reading the command's
  output. It does no tilde expansion in that file.
  Source: https://raw.githubusercontent.com/ansible/ansible/devel/lib/ansible/modules/command.py (accessed 2026-10-30)
- Verdict: the Ansible task `Install bindgen-cli` reports changed whenever it
  runs and is skipped when `~root/.cargo/bin/bindgen` exists, which
  `creates = "/root/.cargo/bin/bindgen"` reproduces. The tilde expansion rests
  on Ansible's `path` argument type, which the fetched file does not show; the
  port uses the absolute path and does not depend on it.

### Local probes

Read-only commands run 2026-10-30 against local pinned images (no builds, no
image changes). Command form: `docker run --rm --entrypoint bash <image> -lc '<probe>'`.
Image ids: `resurgentech/rust_build-ubuntu2604:latest` 42199dc45850,
`resurgentech/latest_kernel_build-ubuntu2604:latest` fd83216d39da.

| Probe | rust_build-ubuntu2604 | latest_kernel_build-ubuntu2604 |
|---|---|---|
| `ls ~/.cargo/bin` | cargo cargo-clippy cargo-deb cargo-fmt cargo-generate-rpm cargo-miri clippy-driver rls rust-analyzer rust-gdb rust-gdbgui rust-lldb rustc rustdoc rustfmt rustup | same plus `bindgen` |
| `rustup component list --installed` | cargo, clippy, rust-docs, rust-std (gnu, musl), rustc, rustfmt | same plus `rust-src` |
| `rustup target list --installed` | x86_64-unknown-linux-gnu, x86_64-unknown-linux-musl | same |
| `rustup toolchain list` | `stable-x86_64-unknown-linux-gnu (active, default)` | same |
| `rustup --version`, `rustc --version` | rustup 1.29.2, rustc 1.99.1 (58cf8f9c3 2026-10-13) | same |
| `dpkg -l` filtered on clang | clang, clang-21, clang-tools-21, libclang-common-21-dev, libclang-cpp21, libclang-rt-21-dev, libclang1-21 | same plus `libclang-21-dev` 1:21.1.8-6ubuntu1 and `libclang-dev` 1:21.1.6-71 |
| `bindgen --version` | not found | bindgen 0.73.2 |
| `cat ~/.cargo/.crates.toml` | cargo-deb 3.8.0, cargo-generate-rpm 0.21.1 | those plus bindgen-cli 0.73.2 |
| `getent passwd root`; `$HOME`; `$SHELL` | `root:x:0:0:root:/root:/bin/bash`; `/root`; `/bin/bash` | same |

Behaviour probe (throwaway container from `rust_build-ubuntu2604:latest`,
`sh -c '. ~/.cargo/env; ...'`, discarded after the run):

| Command | stdout | stderr | rc |
|---|---|---|---|
| `rustup component add rust-src` (first) | empty | `info: downloading component rust-src` | 0 |
| `rustup component add rust-src` (second) | empty | `info: component rust-src is up to date` | 0 |

Not probed: the other 12 images (none runs this role); a
`cargo install --locked bindgen-cli` build (minutes of network; its result is
in the `latest_kernel_build` image); `make LLVM=1 rustavailable` (no kernel
tree present).

## Recommendation and decision

### Options

1. Port 1:1 with the corrections the step names. Per user, two `sh!`:
   `rustup component add rust-src` with `changed_if`, and
   `cargo install --locked bindgen-cli` with `creates`; one `pkg` on the
   Debian arm. Root listed once. For: the oracle passes with no argument and
   each task keeps its meaning. Against: carries the unpinned bindgen build.
2. Port and tidy: pin bindgen-cli, drop the `. ~/.cargo/env` prefix, add the
   `LLVM=1` check as a step, add `libclang-dev` for every family. For: a
   tighter role. Against: a pin or an added package changes names and
   versions the oracle compares, so a diff cannot separate a port bug from a
   chosen change.
3. Leave it in ansible. For: no work. Against: this role is the one that
   closes goal 1 on `ubuntu2604`, and `conversion/` must hold no ported role.

### Position

Option 1. Stakes: the oracle sees `libclang-dev` and `libclang-21-dev`
(package names), `rust-src` (components) and `bindgen` (`~/.cargo/bin`) for
root. Any difference from Option 1 changes one of those four.

Port now (does not show in the oracle diff):

- `changed_if` matches rustup's real output on a real install, `downloading`,
  not the literal `installing`, so the task reports changed on a real install
  (Preserved knowledge 3). It is a report flag, not an end-state item.
- `creates` for bindgen, as an absolute path to the user's home (Preserved
  knowledge 5).
- Root appears once in the user list (Preserved knowledge 2).
- The ported plan for this role is one `pkg` op (Debian family only), then per
  user two `sh` ops.

Dropped branches (no image reaches them): the RedHat, Amazon and Arch
families of this playbook. No image of those families runs
`latest_kernel_build` (`DISTROS`, `set = "default"` for all 12; Purpose), and
the role has no task for them. Pop!_OS and other Debian-family hosts share the
Debian arm.

Bugs the oracle cannot see: (a) the `changed_when` test never matches the
installed rustup (Preserved knowledge 3), fixed as above; (b) root processed
twice (Preserved knowledge 2), fixed by deduplicating. No others found. The
check comment `make rustavailable` without `LLVM=1` is a comment, not a bug.

After equivalence (change what the oracle sees; not made yet): pin or
upgrade `bindgen-cli`; install `libclang-dev` on every family; run
`make LLVM=1 rustavailable` as a post-condition in a kernel tree; add
`--toolchain` to the component add.

Decision: Option 1. Decided by agent (agent-alone); not yet reviewed by the user.

## Port notes

Code: `src/roles/rust_kernel.rs` (role), `src/playbooks/container.rs`
(`container/latest_kernel_build`: `dev_common`, `src_repos`, `kernel_build`,
`rust_build`, `rust_kernel`, as `latest_kernel_build.yml:7-12`; the existing
role fns are reused unchanged). Plan snapshots for all 13 images:
`tests/plans.rs` (`latest_kernel_build_plans`), files
`tests/plans/snapshots/plans__latest_kernel_build__*.snap`. Citations are
against `conversion/ansible/`.

What each task became:

- `playbooks/container/latest_kernel_build.yml:5-12` (all hosts, root, five
  roles): the playbook fn `latest_kernel_build` calls the five role fns in
  order.
- `roles/rust_kernel/tasks/main.yml:1-4` (header comment, `make rustavailable`):
  kept as the module comment; nothing executed.
- `main.yml:6-10` (apt `libclang-dev`, `when debian_based`):
  `h.pkg(["libclang-dev"])` inside `if debian_based(&h.os)`. The flag fn is a
  copy of the one in `rust_build.rs` (private there). Snapshots: present on
  debian12, debian13, ubuntu2404, ubuntu2604; absent on the other nine
  (Dropped branches).
- `main.yml:12-16` (two `include_tasks` loops, `admin_users` then `[root]`):
  one `for u in users(..)` over `admin_users` plus root, deduplicated (item 2).
  `users` is a copy of the fn in `rust_build.rs` (private there). Ops go
  through `h.as_user(u)`.
- `per_user.yml:3-8` (rustup component add rust-src, `changed_when 'installing'
  in stderr`): `sh!(s, ". ~/.cargo/env && rustup component add rust-src",
  changed_if = "downloading")`. The regex is the word rustup 1.29.2 prints on
  a real add (item 3); a repeat prints `is up to date` and reports unchanged.
  This changes the reporting only (the Ansible task never reported changed);
  the end state is the same.
- `per_user.yml:10-13` (cargo install bindgen-cli, `creates`):
  `sh!(s, ". ~/.cargo/env && cargo install --locked bindgen-cli", creates =
  "~/.cargo/bin/bindgen")`. The tilde is not interpolated, so it stays
  unquoted and the shell expands it in the user's own login environment; the
  plan shows `[ -e ~/.cargo/bin/bindgen ]`. Same path as item 5's
  `/root/.cargo/bin/bindgen` for root and the passwd home for other users,
  without a `getent` op.
- `per_user.yml:4,11` (`. ~/.cargo/env &&` prefix): kept (item 7).

Dropped: the YAML's second pass for root (item 2); the `become` and
`become_user` keys (replaced by `as_user`); the `register`. The role had no
branch for RedHat, Amazon or Arch and none was added (Outcomes, Other
families). `make rustavailable` stays a comment.

Plans read: ubuntu2604 (the acceptance image) shows, after the `rust_build`
ops in the final window, the `pkg libclang-dev` op and the two `rust_kernel`
shell ops, as in the Outcomes table (libclang-dev, rust-src for root, bindgen
for root); no pip, apt-source or `/usr/local/bin` op comes from this role.
fedora44 shows only the two shell ops and no libclang package, as in the
Other-families section.

## Review

2026-10-30: pass 1, agent-alone. Read the playbook and both task files of
`rust_kernel` against the copies, spot-checked each citation, ran the local
probes above, fetched the web sources. No reviewer pass yet.

## skill-feedback

Written 2026-10-30, first use of the skill on a playbook whose own role is
small and whose other roles belong to sibling docs.

1. The template assumes one playbook and its roles. With four of five roles
   documented elsewhere, there is no place for the "which doc covers which
   role" table; it went into Purpose. A line in the template would help.
2. `tp classify` counts all five roles (83 tasks) although one is in scope
   for this doc. The paragraph after the table, mapping the rows that matter,
   was written by hand. A role filter would remove that step.
3. UNDERSTAND.md says to read each `when`; it does not say what to do when the
   YAML's own change test (`changed_when`) disagrees with the tool's real
   output. The probe that found it was an accident. Add a step: run each
   `changed_when` predicate against the real output.
4. The hedge-word check forbids ordinary phrasing and forced rewrites; it hid
   no doubt. No change asked.
5. Outcomes for a role that adds to a parent image needs the parent's state to
   say what is new. The skill does not say to probe the parent image; probing
   `rust_build-ubuntu2604` against `latest_kernel_build-ubuntu2604` produced
   the Outcomes table.
