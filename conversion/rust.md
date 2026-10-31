# rust.yml: understanding doc

Scope: `playbooks/container/rust.yml` and the roles it applies: `dev_common`
(covered by `conversion/dev_base.md`; its rows are repeated below only
because the checker counts every in-scope task) and `rust_build` (this
doc). All file:line citations are relative to `conversion/ansible/` (byte
copies of the originals at 79d1ca16bfdeb678496986e1d7a0d407b06f4b45).
Last read against those copies on 2026-10-31.

## Purpose

`rust.yml` turns a `dev_base` image into a Rust build image: the distro's
C/C++ build dependencies that Rust crates link against, then a
rustup-managed toolchain, two cargo packaging tools (`cargo-deb`,
`cargo-generate-rpm`) and the `x86_64-unknown-linux-musl` target, installed
per user (`playbooks/container/rust.yml:8-9`, `roles/rust_build/tasks/main.yml:3`,
`roles/rust_build/tasks/main.yml:16`). The play runs as root on every host
of the inventory (`playbooks/container/rust.yml:5-6`).

- Who runs it. The `rust_build` container of every distro in the
  docker_images matrix: `rust_build = { parent = "dev_base", playbook =
  "playbooks/container/rust.yml" }` in `docker-bake.hcl` (sibling repo
  `../docker_images`, line 30), built for all 13 distros (debian12,
  debian13, ubuntu2404, ubuntu2604, fedora43, fedora44, rockylinux9,
  rockylinux10, almalinux9, almalinux10, amazonlinux2023, arch, omarchy;
  `docker-bake.hcl:47-59`). The Dockerfile clones the ansible repo at a
  commit, refreshes the package cache, and runs `./run targets <playbook>
  inventories/localhost.yml` with `ANSIBLE_HACKS="--extra-vars='ansible_user=root'"`
  (`../docker_images/Dockerfiles/ansible.debian:6-13`, `ansible.redhat:6-12`,
  `ansible.arch:7-12`). `latest_kernel_build` builds on top of the
  `rust_build` image (`docker-bake.hcl:31`), so what this playbook leaves
  behind is the base of that image too.
- Who else applies `rust_build` (`grep -rn rust_build playbooks/`):
  `playbooks/container/latest_kernel_build.yml:11` (after `dev_common`,
  `src_repos`, `kernel_build`; on the `rust_build` image, so the role runs
  a second time on a host that already has the toolchain) and
  `playbooks/dev_desktop.yml:14` (after `admin_users`, `dev_common`,
  `docker`, `vm_server`, `nvm_node`, `golang`; before `rust_tools`,
  `tmux`). `rust_kernel` depends on this role's toolchain
  (`roles/rust_kernel/tasks/main.yml:3`, not mirrored: "rust_build: the
  rust-src component, bindgen-cli, and libclang for bindgen"). The port of
  `rust_build` has to be re-entrant: the second application on
  `latest_kernel_build` takes the "cargo already installed" path.
- Who else applies `dev_common`: every container playbook and
  `dev_desktop.yml` (`playbooks/container/dev_base.yml:8`,
  `playbooks/container/kernel_build.yml:8`,
  `playbooks/container/latest_kernel_build.yml:8`,
  `playbooks/container/qt5_dev.yml:8`, `playbooks/container/rust.yml:8`,
  `playbooks/dev_desktop.yml:9`). On the `rust_build` image it has already
  run once on the parent `dev_base` image; the port is `dev_base.md`'s.
- Flags and variables, all from `inventories/group_vars/all`:
  `debian_based` (Ubuntu, Pop!_OS, Debian; line 6), `redhat_based`
  (CentOS, RedHat, Fedora, Rocky, AlmaLinux; line 4; omits Amazon),
  `amazonlinux2023_based` (line 10), `arch_based` (`ansible_os_family ==
  Archlinux`; line 5), `admin_users: ["{{ ansible_user }}"]` (line 16; root
  under the Dockerfile's extra-vars, the invoking user under `./run
  basic_install`, `run:96`), `rustup_version: "1.29.0"`, `cargo_version:
  "1.94.0"`, `rustc_version: "1.94.0"` (lines 43-45). The role has no
  `defaults/` or `vars/` of its own (the role directory at the commit holds
  only `tasks/`). `redhat.yml:17` reads the raw facts
  `ansible_distribution` and `ansible_distribution_major_version`, not a
  flag. The inventory sets `ansible_become: true` and the python
  interpreter (`inventories/localhost.yml:5-6`).

## Outcomes

Requested names with their citation. The oracle (`scripts/image-state.sh`)
compares installed names, which equal the requested names here: none of
these packages is a virtual name resolved through provides, and every one
was found as a real package on its image (probe table in "Is the method
current"). One subsection per branch of `rust_build`, then what every host
gets, then the oracle checklist.

### Debian family (debian12, debian13, ubuntu2404, ubuntu2604)

- apt, state present (`roles/rust_build/tasks/debian.yml:3-10`): `g++`,
  `libssl-dev`, `pkg-config`, `clang`, `musl-tools` (lines 5-9). No
  `update_cache` (line 10 is the last line of the task; the Dockerfile's
  `apt-get update` is what makes the install resolvable). On the
  `dev_base` images `g++` and `clang` are already installed; the role adds
  `libssl-dev`, `pkg-config`, `musl-tools` (probe 2026-10-31).

### RedHat family (fedora43, fedora44, rockylinux9, rockylinux10, almalinux9, almalinux10)

- dnf, state present (`roles/rust_build/tasks/redhat.yml:3-9`): `gcc-c++`,
  `openssl-devel`, `pkgconf-pkg-config`, `clang` (lines 5-8). Already
  installed on every `dev_base` RedHat image except `openssl-devel`
  (probe 2026-10-31).
- dnf, state present, only when `ansible_distribution == 'Fedora' or
  ansible_distribution_major_version|int >= 10`
  (`roles/rust_build/tasks/redhat.yml:13-17`): `musl-gcc` (line 15). So
  fedora43, fedora44, rockylinux10, almalinux10 get it (from Fedora's own
  repo on Fedora, from EPEL on EL10); rockylinux9 and almalinux9 do not,
  and no `musl-gcc` package exists for them (comment at lines 11-12;
  probe). No musl C compiler on EL9 is a documented limitation, not a
  bug: "Pure Rust musl builds work without it".

### Amazon Linux 2023

- dnf, state present (`roles/rust_build/tasks/amazonlinux2023.yml:4-10`):
  `gcc-c++`, `openssl-devel`, `pkgconf-pkg-config`, `clang` (lines 6-9).
  No musl package (comment line 2; omits `musl-gcc`; probe: not in any
  AL2023 repo). The `rust_build` main file dispatches Amazon on
  `amazonlinux2023_based`, not on `redhat_based`, which omits Amazon
  (`inventories/group_vars/all:4`, `:10`; `roles/rust_build/tasks/main.yml:10-11`).

### Arch (arch, omarchy)

- pacman, state present (`roles/rust_build/tasks/archlinux.yml:3-9`):
  `openssl`, `pkgconf`, `clang`, `musl` (lines 5-8). The first three are
  already installed on the `dev_base` Arch images; the role adds `musl`
  (probe 2026-10-31).

### Every host, per user

Per user in `admin_users` and then for `root`
(`roles/rust_build/tasks/main.yml:17-21`). In the container builds
`admin_users == ["root"]`, so root is processed twice; on `dev_desktop`
the invoking user and then root.

- A rustup installation under the user's `~/.rustup` and `~/.cargo`,
  created by `sh.rustup.rs` run with `-y` and nothing else
  (`roles/rust_build/tasks/per_user.yml:122-134`): default profile, the
  stable channel at whatever version `static.rust-lang.org` serves on the
  day (line 131 omits `--default-toolchain`, `--profile`,
  `--no-modify-path`). Trial on 2026-10-31: toolchain
  `stable-x86_64-unknown-linux-gnu`, rustc and cargo 1.99.1, rustup
  1.29.2, components `cargo`, `clippy`, `rust-docs`, `rust-std`, `rustc`,
  `rustfmt`, and in `~/.cargo/bin`: `cargo cargo-clippy cargo-fmt
  cargo-miri clippy-driver rls rust-analyzer rust-gdb rust-gdbgui rust-lldb
  rustc rustdoc rustfmt rustup`.
- A `. "$HOME/.cargo/env"` line appended by the installer to `~/.profile`
  always, and to `~/.bash_profile`, `~/.bash_login`, `~/.bashrc` where
  they already exist (installer behaviour, see "Is the method current";
  trial: ubuntu2404 root got `.profile:10` and `.bashrc:100`,
  amazonlinux2023 root got a new `.profile:1`).
- `cargo-deb` and `cargo-generate-rpm` in `~/.cargo/bin`, built from
  crates.io at the latest version on the day
  (`roles/rust_build/tasks/per_user.yml:147-151`, `:164-168`; no
  `--version`, no `--locked`). Trial 2026-10-31: 3.8.0 and 0.21.1.
- The `x86_64-unknown-linux-musl` target (`rust-std` for musl) added to
  the default toolchain (`roles/rust_build/tasks/per_user.yml:179-183`).
- `/tmp/rustup.sh`, mode 0755, owned by root, left on the host
  (`roles/rust_build/tasks/per_user.yml:122-127`; the Dockerfiles remove
  `/tmp/*` afterwards, `ansible.debian:15`).
- Nothing in `/usr/local/bin`, no repo, no service, no user created
  (every task cited above; the role has no `user`, `apt_repository`,
  `yum_repository` or `systemd` task).

### Oracle checklist

| Item | Oracle section (`scripts/image-state.sh`) | Expected on the `rust_build` image |
|---|---|---|
| Distro packages | `== packages ==` (dpkg-query / rpm -qa / pacman -Qi, names and arch) | the family's list above added to the `dev_base` list; `musl-gcc` only on fedora43/44, rockylinux10, almalinux10 |
| pip names | `== pip ==` | unchanged by `rust_build` (no pip task) |
| rustup toolchains [root] | `== rustup toolchains [root] ==` (`rustup toolchain list`, the `(active, default)` suffix stripped) | `stable-x86_64-unknown-linux-gnu` |
| rustup components [root] | `== rustup components [root] ==` | the six default-profile components for `x86_64-unknown-linux-gnu` plus `rust-std-x86_64-unknown-linux-musl` |
| rustup targets [root] | `== rustup targets [root] ==` | `x86_64-unknown-linux-gnu`, `x86_64-unknown-linux-musl` |
| cargo bin [root] | `== cargo bin [root] ==` (`ls -A ~/.cargo/bin`) | the 14 rustup proxies plus `cargo-deb`, `cargo-generate-rpm` |
| rust versions [root] | `== rust versions [root] ==` (non-gating) | whatever stable is on the build day, same on both sides when built the same day |
| apt sources | `== apt sources ==` | unchanged |
| `/usr/local/bin` | `== /usr/local/bin ==` | unchanged (`uv`, `uvx`, and `pyaml` on the RedHat family, all from `dev_common`) |
| Other users | only with `ADMIN_USERS=<names>` | none in the container builds (`vars/container.toml:3` has `admin_users = ["root"]`) |

Count check (by command, 2026-10-31): `grep -c '^      - ' roles/rust_build/tasks/debian.yml` = 5,
`redhat.yml` = 4 (plus the single-name `name: musl-gcc` at line 15), `amazonlinux2023.yml` = 4,
`archlinux.yml` = 4. Rows in Task intent: 49 (`tp check-understanding --playbook`).

## Task intent

_Skeleton generated by `tp classify playbooks/container/rust.yml --roles-path roles --intent-skeleton`: Task, Method and Signals are the tool's. Fill Intent, Shape, Adequate and Primitive by hand, in this order; the checker rejects an empty cell._

The first 14 rows are `dev_common`; their judgments are kept short and
`dev_base.md` is the doc that owns them. From `roles/rust_build/tasks/main.yml:4`
on, the rows are this doc's. Rows under `per_user.yml` run once per user
in `admin_users` (`main.yml:17`) and once more for `root` (`main.yml:20`);
`item` is the user.

| Task | Intent | Shape | Method | Signals | Adequate | Primitive |
|---|---|---|---|---|---|---|
| `roles/dev_common/tasks/main.yml:4` dev_common_debian | Debian-family hosts take the Debian package list (dev_common; dev_base.md) | dispatch | `include_tasks` debian.yml | when `debian_based\|bool` | yes | none: `match h.os.family` |
| `roles/dev_common/tasks/debian.yml:2` Debian Install python | python3-apt and python3-pip present (dev_common; dev_base.md) | package | `apt` 2 name(s), state present | included when `debian_based\|bool` | yes | pkg |
| `roles/dev_common/tasks/debian.yml:7` Debian Common development tools | the 31 distinct Debian build tools present (`rsync` is listed twice, lines 16 and 34) (dev_common; dev_base.md) | package | `apt` 32 name(s), state present | included when `debian_based\|bool` | yes: apt ignores the duplicate | pkg |
| `roles/dev_common/tasks/debian.yml:44` Ubuntu2404 python deps | the four python3-* distro packages present on every Debian-family host, not only Ubuntu 24.04 (dev_common; dev_base.md) | package | `apt` 4 name(s) | included when `debian_based\|bool` | yes: no `state` means present | pkg |
| `roles/dev_common/tasks/main.yml:8` dev_common_redhat | RedHat-family hosts (not Amazon) take the dnf list (dev_common; dev_base.md) | dispatch | `include_tasks` redhat.yml | when `redhat_based\|bool` | yes | none: `match h.os.family` |
| `roles/dev_common/tasks/redhat.yml:2` RedHat Common development tools | the Development Tools group and 25 packages present (dev_common; dev_base.md) | package | `dnf` 26 name(s), state present | included when `redhat_based\|bool` | yes for this doc: how the group name renders on dnf5 is dev_base.md's question | pkg |
| `roles/dev_common/tasks/main.yml:12` dev_common_amazonlinux2 | Amazon Linux 2 hosts take the yum list; no image reaches it (dev_common; dev_base.md) | dispatch | `include_tasks` amazonlinux2.yml | when `amazonlinux2_based\|bool` | yes | none: dropped arm |
| `roles/dev_common/tasks/amazonlinux2.yml:2` AmazonLinux2 Common development tools | the AL2 group and 14 packages present on AL2; unreached (dev_common; dev_base.md) | package | `yum` 15 name(s), state present | included when `amazonlinux2_based\|bool` | yes | pkg (`h.yum`) |
| `roles/dev_common/tasks/main.yml:16` dev_common_amazonlinux2023 | AL2023 hosts take their dnf list (dev_common; dev_base.md) | dispatch | `include_tasks` amazonlinux2023.yml | when `amazonlinux2023_based\|bool` | yes | none: `match` on distro |
| `roles/dev_common/tasks/amazonlinux2023.yml:2` AmazonLinux2023 Common development tools | the group and 19 packages present (dev_common; dev_base.md) | package | `dnf` 20 name(s), state present | included when `amazonlinux2023_based\|bool` | yes | pkg |
| `roles/dev_common/tasks/main.yml:20` dev_common_archlinux | Arch hosts take the pacman list (dev_common; dev_base.md) | dispatch | `include_tasks` archlinux.yml | when `arch_based\|bool` | yes | none: `match h.os.family` |
| `roles/dev_common/tasks/archlinux.yml:2` Arch Common development tools | base-devel and 18 packages present (dev_common; dev_base.md) | package | `pacman` 19 name(s), state present | included when `arch_based\|bool` | yes | pkg |
| `roles/dev_common/tasks/main.yml:26` Various python dependancies | jinja2, GitPython, pyaml importable by the system python on RedHat and Amazon (dev_common; dev_base.md) | package | `pip` 3 name(s) | when `not (debian_based\|bool or arch_based\|bool)` | yes: pip reports present | pkg (`h.pip`) |
| `roles/dev_common/tasks/main.yml:34` Installing uv for python | `uv` and `uvx` present in `/usr/local/bin` (dev_common; dev_base.md) | installer | `shell: set -o pipefail && curl -LsSf https://astral.sh/uv/install.sh \| UV_INSTALL_DIR=/usr/local/…` | downloads from the network and executes it; no creates; reports changed every run | no: no version, no guard, runs the network installer every run | tool |
| `roles/rust_build/tasks/main.yml:4`  | Debian-family hosts get the Debian rust build dependencies | dispatch | `include_tasks` debian.yml | when `debian_based\|bool` | yes | none: `match h.os.family { Debian => .. }` |
| `roles/rust_build/tasks/debian.yml:2` Debian rust build Dependancies | `g++`, `libssl-dev`, `pkg-config`, `clang`, `musl-tools` installed | package | `apt` 5 name(s), state present | included when `debian_based\|bool` | yes: apt knows installed state; no `update_cache` (line 10) is covered by the Dockerfile's `apt-get update` and by pkg's own stale-lists guard | pkg |
| `roles/rust_build/tasks/main.yml:7`  | RedHat-family hosts (Fedora, EL; not Amazon) get the dnf rust build dependencies | dispatch | `include_tasks` redhat.yml | when `redhat_based\|bool` | yes | none: `match h.os.family { RedHat => .. }` with Amazon split by distro |
| `roles/rust_build/tasks/redhat.yml:2` RedHat rust build Dependancies | `gcc-c++`, `openssl-devel`, `pkgconf-pkg-config`, `clang` installed | package | `dnf` 4 name(s), state present | included when `redhat_based\|bool` | yes | pkg |
| `roles/rust_build/tasks/redhat.yml:13` RedHat musl-gcc for the musl target | `musl-gcc` installed where a package exists: Fedora, and EL 10 and later (EPEL); EL9 left without | package | `dnf` 1 name(s), state present | when `ansible_distribution == 'Fedora' or ansible_distribution_maj…`; included when `redhat_based\|bool` | yes: the guard matches where the package exists (probe: EPEL on rockylinux10/almalinux10, none on EL9) | pkg, under `os.distro == Fedora \|\| os.version.major() >= 10` |
| `roles/rust_build/tasks/main.yml:10`  | Amazon Linux 2023 hosts get their dnf rust build dependencies | dispatch | `include_tasks` amazonlinux2023.yml | when `amazonlinux2023_based\|bool` | yes | none: `match` on `os.distro` |
| `roles/rust_build/tasks/amazonlinux2023.yml:3` AmazonLinux2023 rust build Dependancies | `gcc-c++`, `openssl-devel`, `pkgconf-pkg-config`, `clang` installed; no musl package on AL2023 | package | `dnf` 4 name(s), state present | included when `amazonlinux2023_based\|bool` | yes | pkg |
| `roles/rust_build/tasks/main.yml:13`  | Arch hosts get the pacman rust build dependencies | dispatch | `include_tasks` archlinux.yml | when `arch_based\|bool` | yes | none: `match h.os.family { Arch => .. }` |
| `roles/rust_build/tasks/archlinux.yml:2` Arch rust build Dependancies | `openssl`, `pkgconf`, `clang`, `musl` installed | package | `pacman` 4 name(s), state present | included when `arch_based\|bool` | yes | pkg |
| `roles/rust_build/tasks/main.yml:17`  | every admin user has the toolchain, the two cargo tools and the musl target in their own home | dispatch | `include_tasks` per_user.yml | loop `{{ admin_users }}` | no: with `admin_users == ["root"]` (containers) root is processed here and again at `main.yml:20`, so the second pass takes the update path on the same user | none: `for u in admin_users.iter().chain(["root"])`, deduplicated, each with `h.as_user(u)` |
| `roles/rust_build/tasks/per_user.yml:4` Get default shell for '{{ item }}' | the user's login shell is known, so later checks run in it and see `~/.cargo/env` | derived fact | `command: getent passwd {{ item }}` | included under loop `{{ admin_users }}`; no creates; changed_when `false`; register `passwd_info`, read by `roles/rust_build/tasks/per_user.yml:9` | yes as a fact; the home field (`:6`) that line 75 needs is read from the same line and ignored | none: `h.as_user(u)` opens the user's login shell; no task |
| `roles/rust_build/tasks/per_user.yml:9` Parse default shell for '{{ item }}' | `user_shell` holds the shell path for lines 13, 23, 33, 43, 99, 107, 137, 154 | derived fact | `set_fact` (user_shell) | included under loop `{{ admin_users }}` | yes | none: the scope's login shell replaces it |
| `roles/rust_build/tasks/per_user.yml:13` Check if cargo is installed for '{{ item }}' who uses '{{ user_shell }}'" | know whether the user already has a toolchain, to pick install (`:122`, `:130`) or inspect-and-update (`:23` to `:120`) | check | `shell: {{ user_shell }} -lc 'which cargo'` | included under loop `{{ admin_users }}`; become_user `{{ item }}`; no creates; changed_when `false`; ignore_errors; register `cargo_check`, read by `roles/rust_build/tasks/per_user.yml:23`, `roles/rust_build/tasks/per_user.yml:33`, `roles/rust_build/tasks/per_user.yml:43`, `roles/rust_build/tasks/per_user.yml:53`, `roles/rust_build/tasks/per_user.yml:57`, `roles/rust_build/tasks/per_user.yml:65`, `roles/rust_build/tasks/per_user.yml:69`, `roles/rust_build/tasks/per_user.yml:115`, `roles/rust_build/tasks/per_user.yml:122`, `roles/rust_build/tasks/per_user.yml:130` | no: `which` is not installed on fedora43, fedora44, rockylinux10, almalinux10, amazonlinux2023 (probe), so rc is 127 there whatever is installed and the installer path runs on every pass; `command -v` is what the shell guarantees | absorbed by `:130` as the `tool` primitive's presence probe (`bin_exists("cargo")` in the user's scope, or `unless = "command -v cargo"`) |
| `roles/rust_build/tasks/per_user.yml:23` Get rustup version for '{{ item }}' | the installed rustup version is known for the comparison at `:65` | check | `shell: {{ user_shell }} -lc 'rustup --version \| head -n 1 \| cut -d " " -f 2'` | when `cargo_check.rc == 0`; included under loop `{{ admin_users }}`; become_user `{{ item }}`; installs a tool outside the package manager; mentions a version; no creates; changed_when `false`; ignore_errors; register `rustup_version_result`, read by `roles/rust_build/tasks/per_user.yml:57`, `roles/rust_build/tasks/per_user.yml:65` | yes: prints `1.29.2` on the trial (rustup's `info:` lines go to stderr) | tool: the installed-version probe (`bin_version("rustup")` in the user's scope) |
| `roles/rust_build/tasks/per_user.yml:33` Get cargo version for '{{ item }}' | the installed cargo version is known for `:69` | check | `shell: {{ user_shell }} -lc 'cargo --version \| cut -d " " -f 2'` | when `cargo_check.rc == 0`; included under loop `{{ admin_users }}`; become_user `{{ item }}`; mentions a version; no creates; changed_when `false`; ignore_errors; register `cargo_version_result`, read by `roles/rust_build/tasks/per_user.yml:57`, `roles/rust_build/tasks/per_user.yml:69` | yes: prints `1.99.1` on the trial | tool: installed-version probe (`bin_version("cargo")`) |
| `roles/rust_build/tasks/per_user.yml:43` Get rustc version for '{{ item }}' | the installed rustc version is known for `:53` and `:69` | check | `shell: {{ user_shell }} -lc 'rustc --version \| cut -d " " -f 2'` | when `cargo_check.rc == 0`; included under loop `{{ admin_users }}`; become_user `{{ item }}`; mentions a version; no creates; changed_when `false`; ignore_errors; register `rustc_version_result`, read by `roles/rust_build/tasks/per_user.yml:53`, `roles/rust_build/tasks/per_user.yml:57`, `roles/rust_build/tasks/per_user.yml:69` | yes: prints `1.99.1` on the trial | tool: installed-version probe (`bin_version("rustc")`) |
| `roles/rust_build/tasks/per_user.yml:53` Check for broken Rust installation | `rust_installation_broken` is true when `cargo` is on PATH but `rustc --version` prints nothing (rustup proxies with no toolchain); read by `:73`, `:99`, `:107`, `:115`, `:137`, `:147`, `:154`, `:164`, `:170`, `:179` | derived fact | `set_fact` (rust_installation_broken) | included under loop `{{ admin_users }}` | yes: a real state, unreachable on a fresh image | tool: the "present but no version" state (`bin_exists` true and `bin_version` None) |
| `roles/rust_build/tasks/per_user.yml:57` Display Rust toolchain versions for '{{ item }}' | the run log shows installed versus target versions; no host state | glue | `debug` (msg) | when `cargo_check.rc == 0`; included under loop `{{ admin_users }}`; mentions a version | yes: nothing to reach | none: dropped; the plan prints the facts |
| `roles/rust_build/tasks/per_user.yml:65` Check if rustup needs update for '{{ item }}' | `rustup_needs_update` is true when the installed rustup version differs from `rustup_version` (1.29.0) | derived fact | `set_fact` (rustup_needs_update) | included under loop `{{ admin_users }}` | no: `!=` against a var, and the action at `:99` moves to latest (1.29.2 today), never to the var, so the flag is true on every pass after the first and cannot be cleared; a drift detector, not a pin | tool: the wanted-version rule (pin or "latest from the source") |
| `roles/rust_build/tasks/per_user.yml:69` Check if cargo/rustc needs update for '{{ item }}' | `rust_needs_update` is true when installed cargo or rustc differs from `cargo_version`/`rustc_version` (1.94.0) | derived fact | `set_fact` (rust_needs_update) | included under loop `{{ admin_users }}` | no: same as `:65`; stable is 1.99.1 today, `:107` updates to latest, the flag stays true | tool: the wanted-version rule |
| `roles/rust_build/tasks/per_user.yml:75` Remove broken Rust installation | the user's `~/.rustup` and `~/.cargo` are gone before a reinstall | file | `file` (path, state) | loop `["/home/{{ item }}/.rustup","/home/{{ it…`; included under loop `{{ admin_users }}`; become_user `{{ item }}` | no: the path is `/home/<user>`, which is wrong for root (`/root`) and for any user whose home is elsewhere; the home was in `passwd_info` (`:4`) and not used | file (`.absent()`) in the user's scope with the home from the user fact |
| `roles/rust_build/tasks/per_user.yml:87` Download rustup script for repair | the installer script is at `/tmp/rustup.sh` for the repair | fetch | `get_url` (dest, mode, url) | included under loop `{{ admin_users }}`; downloads from the network | no: no checksum, no `RUSTUP_VERSION`, fetched by root to a shared world-readable path and executed by another user | fetch (prepare phase, checksum), or the `tool` primitive's source |
| `roles/rust_build/tasks/per_user.yml:93` Reinstall Rust toolchain | a working default toolchain for the user after a broken one | installer | `command: /tmp/rustup.sh -y` | included under loop `{{ admin_users }}`; become_user `{{ item }}`; installs a tool outside the package manager; no creates; reports changed every run | no: same unpinned install as `:130`; its guard is the block's `when` at `:97` | tool: the install command of the same tool as `:130` |
| `roles/rust_build/tasks/per_user.yml:99` Update rustup if needed for '{{ item }}' | rustup itself at the wanted version | installer | `shell: {{ user_shell }} -lc 'rustup self update'` | when `rustup_needs_update and not rust_installation_broken`; included under loop `{{ admin_users }}`; become_user `{{ item }}`; installs a tool outside the package manager; no creates; reports changed whenever its when holds; register `rustup_update_result`, read by `roles/rust_build/tasks/per_user.yml:115` | no: `rustup self update` goes to latest, not to `rustup_version`; runs on every pass where `which` exists; reports changed even when rustup says unchanged | tool: the update command |
| `roles/rust_build/tasks/per_user.yml:107` Update Rust toolchain if needed for '{{ item }}' | cargo and rustc at the wanted version | installer | `shell: {{ user_shell }} -lc 'rustup update'` | when `rust_needs_update and not rust_installation_broken`; included under loop `{{ admin_users }}`; become_user `{{ item }}`; installs a tool outside the package manager; no creates; reports changed whenever its when holds; register `rust_update_result`, read by `roles/rust_build/tasks/per_user.yml:115` | no: `rustup update` tracks the stable channel, it cannot reach 1.94.0; a pin needs `rustup default <ver>` or `--default-toolchain`; runs on every pass where `which` exists | tool: the update command |
| `roles/rust_build/tasks/per_user.yml:115` Display update results for '{{ item }}' | the run log says whether updates ran; no host state | glue | `debug` (msg) | when `cargo_check.rc == 0 and (rustup_needs_update or rust_needs_u…`; included under loop `{{ admin_users }}` | yes: nothing to reach | none: dropped |
| `roles/rust_build/tasks/per_user.yml:122` Download rustup script for '{{ item }}' | the installer script is at `/tmp/rustup.sh` for the first install | fetch | `get_url` (dest, mode, url) | when `cargo_check.rc != 0`; included under loop `{{ admin_users }}`; downloads from the network | no: no checksum, no `RUSTUP_VERSION`, written by root 0755 into `/tmp` shared by every user of the loop, left behind | fetch (prepare phase), or the `tool` primitive's source |
| `roles/rust_build/tasks/per_user.yml:130` Install rust and tools with the rustup script for '{{ item }}' | the user has a rustup-managed stable toolchain with cargo, rustc, rustup in `~/.cargo/bin` and on the login PATH | installer | `command: /tmp/rustup.sh -y` | when `cargo_check.rc != 0`; included under loop `{{ admin_users }}`; become_user `{{ item }}`; installs a tool outside the package manager; no creates; reports changed whenever its when holds | no: installs whatever stable is on the day (1.99.1 on 2026-10-31) with no `--default-toolchain`, so `cargo_version` is never the installed version; the only guard is `which cargo` (`:13`), broken on five images; the installer edits the user's rc files unasked (no `--no-modify-path`) | tool: binary `~/.cargo/bin/cargo`, version `rustc --version`, wanted `rustc_version`, source `static.rust-lang.org` stable manifest, install `rustup-init -y --default-toolchain <ver>`, update `rustup default <ver>` |
| `roles/rust_build/tasks/per_user.yml:137` Check if cargo-deb is installed for '{{ item }}' | know whether `cargo-deb` is on the user's login PATH, to guard `:147` | check | `shell: {{ user_shell }} -lc 'which cargo-deb'` | when `not rust_installation_broken`; included under loop `{{ admin_users }}`; become_user `{{ item }}`; no creates; changed_when `false`; ignore_errors; register `cargodeb_check`, read by `roles/rust_build/tasks/per_user.yml:147` | no: `which` absent on five images (rc 127 every time), and presence says nothing about the version | absorbed by `:147` (`creates = "~/.cargo/bin/cargo-deb"` on the hack, or the tool's probe) |
| `roles/rust_build/tasks/per_user.yml:147` Install cargo-deb | `cargo-deb` in the user's `~/.cargo/bin` | installer | `shell: . ~/.cargo/env && cargo install cargo-deb` | when `cargodeb_check.rc != 0 and not rust_installation_broken`; included under loop `{{ admin_users }}`; become_user `{{ item }}`; installs a tool outside the package manager; no creates; reports changed whenever its when holds | no: no `--version` (crates.io latest, 3.8.0 today) and no `--locked`; cargo itself skips a reinstall at the same version ("Ignored package ... is already installed"), which is what makes the five `which`-less images survive the broken guard | tool (a cargo-managed binary: path `~/.cargo/bin/cargo-deb`, version `cargo-deb --version`, source crates.io, install `cargo install --locked cargo-deb --version <v>`) |
| `roles/rust_build/tasks/per_user.yml:154` Check if cargo-generate-rpm is installed for '{{ item }}' | know whether `cargo-generate-rpm` is on the user's login PATH, to guard `:164` | check | `shell: {{ user_shell }} -lc 'which cargo-generate-rpm'` | when `not rust_installation_broken`; included under loop `{{ admin_users }}`; become_user `{{ item }}`; no creates; changed_when `false`; ignore_errors; register `cargorpm_check`, read by `roles/rust_build/tasks/per_user.yml:164` | no: same as `:137` | absorbed by `:164` |
| `roles/rust_build/tasks/per_user.yml:164` Install cargo-generate-rpm for '{{ item }}' | `cargo-generate-rpm` in the user's `~/.cargo/bin` | installer | `shell: . ~/.cargo/env && cargo install cargo-generate-rpm` | when `cargorpm_check.rc != 0 and not rust_installation_broken`; included under loop `{{ admin_users }}`; become_user `{{ item }}`; installs a tool outside the package manager; no creates; reports changed whenever its when holds | no: same as `:147` (0.21.1 today) | tool (cargo-managed binary, as `:147`) |
| `roles/rust_build/tasks/per_user.yml:170` Check if x86_64-unknown-linux-musl is installed for '{{ item }}' | know whether the musl target is installed for the default toolchain, to guard `:179` | check | `shell: . ~/.cargo/env && rustup target list \| grep x86_64-unknown-linux-musl \| grep installed` | when `not rust_installation_broken`; included under loop `{{ admin_users }}`; become_user `{{ item }}`; installs a tool outside the package manager; no creates; changed_when `false`; ignore_errors; register `musl_check`, read by `roles/rust_build/tasks/per_user.yml:179` | yes: asks rustup, no `which`; `rustup target list --installed` is the direct form | absorbed by `:179` as its `unless` |
| `roles/rust_build/tasks/per_user.yml:179` Install rustup target x86_64-unknown-linux-musl for '{{ item }}' | the `x86_64-unknown-linux-musl` target (musl `rust-std`) installed on the user's default toolchain | package | `shell: . ~/.cargo/env && rustup target add x86_64-unknown-linux-musl` | when `musl_check.rc != 0 and not rust_installation_broken`; included under loop `{{ admin_users }}`; become_user `{{ item }}`; installs a tool outside the package manager; no creates; reports changed whenever its when holds | yes: rustup owns the state and the guard reads it; `rustup target add` is itself idempotent | sh with `unless = "rustup target list --installed \| grep -qx x86_64-unknown-linux-musl"` in the user's scope (the design note's own example); a component of the `tool`, not a tool |
| `roles/rust_build/tasks/main.yml:20`  | root has the toolchain, the two cargo tools and the musl target too | dispatch | `include_tasks` per_user.yml | loop `["root"]` | no: duplicates the `admin_users` pass when it contains root (containers); a second pass that only triggers the update path | none: part of the deduplicated user list at `main.yml:17` |

Primitive gaps: `tool` for the rustup toolchain (rows `per_user.yml:13`, `:23`, `:33`, `:43`, `:53`, `:65`, `:69`, `:87`, `:93`, `:99`, `:107`, `:122`, `:130`: one tool with a binary, an installed version, a wanted version, a source and install/update commands, run in a user scope); `tool` again for the two cargo-managed binaries (rows `:137`, `:147`, `:154`, `:164`: same shape with crates.io as the source and `cargo install --locked --version` as the install, or a `cargo` manager on `pkg` as the design note sketches); `fetch` for the installer script (rows `:87`, `:122`) if the tool is not given its own source; and the `dev_common` row `main.yml:34` (`uv`), which is `dev_base.md`'s gap.

Built-primitive defects: none found. Probes 2026-10-31: `g++` passes `check_names` (only empty or control characters are rejected, `crates/telepatch/src/ops/pkg.rs:328-336`) and `dpkg-query -W -f='${db:Status-Status}' g++` prints `installed` on dev_base-ubuntu2404; `rpm -q musl-gcc` and the `epel` repo are visible on dev_base-rockylinux10, so `pkg(["musl-gcc"])` renders to a plain `dnf install` that resolves there. `h.as_user("root")` opens a login shell for root (`crates/telepatch/src/host.rs:138-146`), which is what the per-user rows need.

## Current method

_Generated by `tp classify playbooks/container/rust.yml --roles-path roles`._

49 tasks in scope; 11 match no pattern and are plain module calls. A task is listed under every pattern it matches, so pattern counts overlap and do not sum to the task total.

### By pattern

| Pattern | Tasks | Proposed telepatch primitive |
|---|---|---|
| Distro dispatch | 9 | typed `os` fact and a `match`, or a per-family table on `pkg` |
| Guarded by a distro flag | 2 | the task's own primitive inside the `match` arm; the flag is not a dispatch point |
| Installer outside the package manager | 10 | `tool` (binary, installed version, wanted version, source, install/update); not built |
| Per-user loop | 26 | `for u in users { let s = h.as_user(u); ... }`; the login shell is a fact of the user |
| Hand-rolled ensure | 9 | `sh!(..).unless(check)` or `.creates(path)` |
| Version pinning | 6 | `bin_version` fact plus the ensure combinator |
| Repo setup | 0 | `repo` primitive; one cache update per window |
| Shell for a primitive | 0 | the matching primitive (`svc`, `file`, `pkg`, `user`), not `sh` |
| Controller-side gather | 0 | `secret`, `fetch`, `local` (prepare phase) |
| Handler | 0 | a guard on the restart op; identical guarded ops merge |

#### Distro dispatch (9 tasks)

Becomes: typed `os` fact and a `match`, or a per-family table on `pkg`

- `roles/dev_common/tasks/main.yml:4` dev_common_debian (include_tasks -> Rust control flow)
- `roles/dev_common/tasks/main.yml:8` dev_common_redhat (include_tasks -> Rust control flow)
- `roles/dev_common/tasks/main.yml:12` dev_common_amazonlinux2 (include_tasks -> Rust control flow)
- `roles/dev_common/tasks/main.yml:16` dev_common_amazonlinux2023 (include_tasks -> Rust control flow)
- `roles/dev_common/tasks/main.yml:20` dev_common_archlinux (include_tasks -> Rust control flow)
- `roles/rust_build/tasks/main.yml:4` (include_tasks -> Rust control flow)
- `roles/rust_build/tasks/main.yml:7` (include_tasks -> Rust control flow)
- `roles/rust_build/tasks/main.yml:10` (include_tasks -> Rust control flow)
- `roles/rust_build/tasks/main.yml:13` (include_tasks -> Rust control flow)

#### Guarded by a distro flag (2 tasks)

Becomes: the task's own primitive inside the `match` arm; the flag is not a dispatch point

- `roles/dev_common/tasks/main.yml:26` Various python dependancies (pip -> pkg::pip)
- `roles/rust_build/tasks/redhat.yml:13` RedHat musl-gcc for the musl target (dnf -> pkg), included from `roles/rust_build/tasks/main.yml:7`

#### Installer outside the package manager (10 tasks)

Becomes: `tool` (binary, installed version, wanted version, source, install/update); not built

- `roles/dev_common/tasks/main.yml:34` Installing uv for python (shell -> sh)
- `roles/rust_build/tasks/per_user.yml:23` Get rustup version for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:93` Reinstall Rust toolchain (command -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:99` Update rustup if needed for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:107` Update Rust toolchain if needed for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:130` Install rust and tools with the rustup script for '{{ item }}' (command -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:147` Install cargo-deb (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:164` Install cargo-generate-rpm for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:170` Check if x86_64-unknown-linux-musl is installed for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:179` Install rustup target x86_64-unknown-linux-musl for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`

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

Regenerate with: `cd ../tp_basic && cargo run -q --manifest-path ../telepatch/Cargo.toml -p tp -- classify conversion/ansible/playbooks/container/rust.yml --roles-path conversion/ansible/roles`.

Comparison with Task intent (2026-10-31): every task the classifier lists
has a row and the reverse (49 each). Pattern readings that differ from the
Shape column, each recorded in skill-feedback: "Installer outside the
package manager" lists `per_user.yml:23` (a version check) and `:170` (a
check) as installers; "Hand-rolled ensure" lists the check halves
(`:13`, `:137`, `:154`, `:170`) and the fetch (`:122`) as ensures beside
the ops they guard; "Version pinning" names the probes and flags but not
the ops that act on them (`:99`, `:107`), and the YAML pins nothing (see
Preserved knowledge 6). The dispatch tasks' `when` conditions: `debian_based`,
`redhat_based`, `amazonlinux2023_based`, `arch_based` are the flag
definitions cited under Purpose; `redhat.yml:17` encodes "a musl package
exists for this release" (Preserved knowledge 3).

## Preserved knowledge

1. The role runs once per user in `admin_users`, then once for root
   (`roles/rust_build/tasks/main.yml:17-21`), because the toolchain lives
   in the user's home. In the container builds `admin_users == ["root"]`
   (`inventories/group_vars/all:16` with the Dockerfile's
   `ansible_user=root`, `../docker_images/Dockerfiles/ansible.debian:13`;
   mirrored in `vars/container.toml:3`), so root is processed twice; the
   second pass finds cargo and takes the update path. The port processes
   each user once and must still end with root having everything.
2. The guard for "is the toolchain installed" is `which cargo` in the
   user's login shell (`roles/rust_build/tasks/per_user.yml:13-15`), and
   the same for the two cargo tools (`:137-139`, `:154-156`). `which` is
   not installed on fedora43, fedora44, rockylinux10, almalinux10 and
   amazonlinux2023 (probe 2026-10-31), so on those images every pass
   reinstalls the toolchain with `rustup-init -y` (which updates the
   existing toolchain in place, trial 2026-10-31) and reruns `cargo
   install`, which skips a package already installed at the same version.
   The end state is the same; the time and the network traffic are not.
   The port uses `command -v` or a `bin_exists` fact, which the oracle
   cannot distinguish.
3. `musl-gcc` is requested only where a package exists: Fedora, and EL 10
   and later from EPEL (`roles/rust_build/tasks/redhat.yml:11-17`; probe:
   `epel` on rockylinux10 and almalinux10, no package on rockylinux9,
   almalinux9, amazonlinux2023). The port keeps the condition as a
   distro-and-version match; dropping it would fail EL9, widening it to
   Amazon would fail AL2023.
4. Amazon Linux 2023 is not `redhat_based` (`inventories/group_vars/all:4`
   omits Amazon); it has its own include (`roles/rust_build/tasks/main.yml:10-11`,
   `amazonlinux2023.yml`) with the same four packages as RedHat and no
   musl. In telepatch AL2023 is `Family::RedHat`
   (`crates/telepatch/src/ops/pkg.rs:348-350`), so the port splits it on
   `os.distro`, not on the family.
5. The three version variables (`inventories/group_vars/all:43-45`:
   rustup 1.29.0, cargo 1.94.0, rustc 1.94.0) are compared with `!=`
   (`roles/rust_build/tasks/per_user.yml:67`, `:71`) and acted on with
   `rustup self update` and `rustup update` (`:99-113`), which move to the
   latest release, never to the variable. Installed today: rustup 1.29.2,
   cargo and rustc 1.99.1 (trial 2026-10-31). So the variables detect
   drift and the "fix" is "go to latest"; nothing in the role can produce
   1.94.0. The port must decide what the variables mean (Recommendation,
   question 1); whichever way, the oracle sees the same toolchain on both
   sides only when both are built on the same day against the same
   stable release.
6. The repair block (`roles/rust_build/tasks/per_user.yml:73-97`) exists
   for the state "cargo on PATH, `rustc --version` prints nothing"
   (`:55`): rustup proxies present with no default toolchain. It removes
   `/home/<user>/.rustup` and `/home/<user>/.cargo` (`:80-81`), which is
   not root's home; for root the removal is a no-op and the reinstall at
   `:93` runs over the existing directories. After a repair the cargo
   tools and the musl target are skipped for that pass (`:145`, `:162`,
   `:177`: `when: not rust_installation_broken`), so a repaired host is
   complete only on the next run. No image reaches this block (fresh
   `dev_base` has no cargo; probe). The port keeps the state as the
   `tool` primitive's "present, no version" case and uses the real home.
7. The installer script is downloaded by root to `/tmp/rustup.sh` with
   mode 0755 (`roles/rust_build/tasks/per_user.yml:122-127`, `:87-91`) so
   that the `become_user` at `:132-133` can execute it; the same path is
   reused for every user in the loop and the file stays until the
   Dockerfile's `rm -rf /tmp/*`. It is run with `-y` alone
   (`:131`), which means: default profile, stable channel, PATH edits in
   the user's rc files. The port that keeps the rc-file edits keeps the
   `. "$HOME/.cargo/env"` lines the oracle does not capture but the next
   role (`rust_kernel`, `rust_tools`) and the user's shell rely on; the
   `. ~/.cargo/env &&` prefix at `:148`, `:165`, `:171`, `:180` is how the
   role itself gets `cargo` on PATH in a non-login shell.
8. Every per-user shell task runs under `become_user: {{ item }}`
   (`roles/rust_build/tasks/per_user.yml:16-17` and the rest), and the
   `which`/version probes run through `<shell> -lc` (`:15`, `:25`, `:35`,
   `:45`, `:101`, `:109`, `:139`, `:156`) so the user's rc files are read
   and `~/.cargo/bin` is on PATH. Telepatch's `as_user` scope is a login
   shell for the user, which is the same contract (`crates/telepatch/src/host.rs:138-146`).
9. `dev_common` has already run on the parent image, so `g++`, `clang`,
   `gcc-c++`, `pkgconf-pkg-config`, `openssl`, `pkgconf` are installed
   before this role asks for them (probe 2026-10-31). The role's own
   additions are `libssl-dev`, `pkg-config`, `musl-tools` (Debian),
   `openssl-devel` (RedHat, Amazon), `musl-gcc` (Fedora, EL10), `musl`
   (Arch). The port keeps the full lists: `pkg` is idempotent and the
   lists are the contract when the role is applied on a desktop
   (`playbooks/dev_desktop.yml:14`).
10. The Debian task has no `update_cache` (`roles/rust_build/tasks/debian.yml:10`);
    the Dockerfile runs `apt-get update` before the playbook
    (`../docker_images/Dockerfiles/ansible.debian:6`) and the `dev_base`
    image ships with `/var/lib/apt/lists` emptied (`:15`). `pkg` on apt
    refreshes stale lists itself (`APT_LISTS_GUARD`,
    `crates/telepatch/src/ops/pkg.rs`), so the port adds no explicit
    update.
11. `latest_kernel_build` applies `rust_build` again on the `rust_build`
    image (`playbooks/container/latest_kernel_build.yml:11`), where
    everything is already installed: that run is the "update path" (items
    2 and 5) and is where the port's idempotence is exercised by the
    oracle's `latest` set (`just test-acceptance` builds
    `ubuntu2604 latest_kernel_build`).

## Is the method current

Research date: 2026-10-31.

### The rustup installer (`sh.rustup.rs`, rows `per_user.yml:87`, `:122`, `:130`, `:93`)

- The script served at `https://sh.rustup.rs` on 2026-10-31
  (sha256 `9502b514362a21096210d498f143b8cdacda365d3dfcf45e8f5541e089ccafc0`,
  930 lines, downloaded to a file for the trial) downloads
  `${RUSTUP_UPDATE_ROOT}/dist/<arch>/rustup-init`, or
  `${RUSTUP_UPDATE_ROOT}/archive/${RUSTUP_VERSION}/<arch>/rustup-init` when
  `RUSTUP_VERSION` is set (script lines 28-29, 98-103), and needs `curl` or
  `wget` (lines 671-691). Its options include `-y`, `--default-toolchain
  <name>`, `--profile minimal|default|complete`, `-c`, `-t`,
  `--no-update-default-toolchain`, `--no-modify-path` (lines 40-62).
  Source: https://sh.rustup.rs (accessed 2026-10-31)
- Rustup's documented environment: "RUSTUP_VERSION: Overrides the rustup
  version (e.g. 1.27.1) to be downloaded when executing rustup-init.sh or
  rustup self update."
  Source: https://rust-lang.github.io/rustup/environment-variables.html (accessed 2026-10-31)
- Version served today: `release-stable.toml` says `version = '1.29.2'`;
  the stable channel manifest is dated 2026-10-15 with `rustc 1.99.1
  (58cf8f9c3 2026-10-13)`.
  Source: https://static.rust-lang.org/rustup/release-stable.toml (accessed 2026-10-31)
  Source: https://static.rust-lang.org/dist/channel-rust-stable.toml (accessed 2026-10-31)
- The rustup changelog's newest heading is `[1.29.0] - 2026-03-05`; 1.29.1
  and 1.29.2 have no entry in the first 100000 characters of the file, so
  the served version is ahead of the changelog.
  Source: https://raw.githubusercontent.com/rust-lang/rustup/master/CHANGELOG.md (accessed 2026-10-31)
- Rust releases: `Version 1.99.1 (2026-10-15)`, `Version 1.99.0
  (2026-10-01)`, `Version 1.98.1 (2026-09-03)`.
  Source: https://raw.githubusercontent.com/rust-lang/rust/master/RELEASES.md (accessed 2026-10-31)
- PATH edits: the installer writes `. "$HOME/.cargo/env"` to `~/.profile`
  unconditionally ("Write to .profile even if it doesn't exist"), to
  `~/.bash_profile`, `~/.bash_login`, `~/.bashrc` only where they exist
  (`.filter(|rc| rc.is_file())`), and to one zsh `.zshenv`; the env file is
  `$HOME/.cargo/env`.
  Source: https://raw.githubusercontent.com/rust-lang/rustup/master/src/cli/self_update/shell.rs (accessed 2026-10-31)
- Rerunning the installer over an existing install: "warn: it looks like
  you have an existing rustup settings file", "Updating existing toolchain,
  profile choice will be ignored", then it syncs the stable channel (trial
  output below). The rustup book's "already installed" page only covers a
  distro-packaged Rust ("pass the `-y` option to make it ignore the
  packaged Rust toolchain").
  Source: https://rust-lang.github.io/rustup/installation/already-installed-rust.html (accessed 2026-10-31)
- `rustup update` updates toolchains to the latest of their channel and,
  depending on `auto-self-update`, rustup itself; `rustup self update`
  updates rustup only ("This will not download new toolchains").
  Source: https://rust-lang.github.io/rustup/basics.html (accessed 2026-10-31)
- The three facts the `tool` primitive needs: the source serves rustup
  1.29.2 and stable 1.99.1 today; a toolchain is pinned with
  `--default-toolchain 1.94.0` at install or `rustup default 1.94.0`
  later, and rustup itself with `RUSTUP_VERSION=1.29.0` on the script;
  the tool prints `rustup 1.29.2 (d8c92c676 2026-10-21)` as the first
  stdout line of `rustup --version` (the `info:` lines are stderr),
  `cargo 1.99.1 (5f94df478 2026-08-27)`, `rustc 1.99.1 (58cf8f9c3
  2026-10-13)`; the role's `cut -d " " -f 2` yields `1.29.2`, `1.99.1`,
  `1.99.1` (trial).
- Verdict: the one-liner is still the vendor's method and the script's
  flags still match the YAML; what changed is the version it serves, which
  is five minor releases past `cargo_version`. The YAML's method cannot
  reach the pinned versions; the pins need `--default-toolchain` /
  `rustup default` and `RUSTUP_VERSION`.
- Open: `docker run --rm resurgentech/rust_build-<distro>:latest sh -lc
  'rustc --version; rustup --version'` on the published images to see
  which stable the current images carry.

### `cargo install` for `cargo-deb` and `cargo-generate-rpm` (rows `:147`, `:164`)

- crates.io API: `cargo-deb` max stable 3.8.0 (published 2026-09-01;
  3.7.0 2026-05-02); `cargo-generate-rpm` 0.21.1 (2026-10-17; 0.21.0
  2026-05-04).
  Source: https://crates.io/api/v1/crates/cargo-deb (accessed 2026-10-31)
  Source: https://crates.io/api/v1/crates/cargo-generate-rpm (accessed 2026-10-31)
- Pinning: "--version ... If the version does not have a requirement
  operator ... it must be in the form MAJOR.MINOR.PATCH, and will install
  exactly that version"; reinstall: "If the package is already installed,
  Cargo will reinstall it if the installed version does not appear to be
  up-to-date"; `--locked` forces the packaged `Cargo.lock`; `cargo install
  --list` lists installed packages and versions.
  Source: https://doc.rust-lang.org/cargo/commands/cargo-install.html (accessed 2026-10-31)
- Trial (ubuntu2404, 2026-10-31): `cargo install cargo-deb
  cargo-generate-rpm` built both (cargo-generate-rpm in 1m 01s);
  `cargo-deb --version` prints `cargo-deb 3.8.0`, `cargo generate-rpm
  --version` prints `cargo-generate-rpm 0.21.1`, `cargo install --list`
  prints `cargo-deb v3.8.0:` and `cargo-generate-rpm v0.21.1:`; a rerun of
  `cargo install cargo-deb` prints "Ignored package `cargo-deb v3.8.0` is
  already installed, use --force to override" and exits 0.
- Verdict: still the way these tools are installed; the YAML's form is
  unpinned (whatever crates.io serves) and unlocked. The `tool` shape:
  binary `~/.cargo/bin/<name>`, version `<name> --version`, wanted from
  a var, source crates.io, install `cargo install --locked <name>
  --version <v>`.
- Open: `docker run --rm resurgentech/rust_build-ubuntu2404:latest sh -lc
  'cargo install --list'` for the versions the current images carry.

### The musl target and its C compiler (rows `redhat.yml:13`, `debian.yml:9`, `archlinux.yml:8`, `per_user.yml:179`)

- `x86_64-unknown-linux-musl` is "Tier 2 with Host Tools", notes "64-bit
  Linux with musl 1.2.5".
  Source: https://doc.rust-lang.org/rustc/platform-support.html (accessed 2026-10-31)
- Fedora packages `musl-gcc` for Fedora 43 (1.2.5-5.fc43), 44 (1.2.5-6.fc44)
  and EPEL 10 (1.2.5-5.el10_2); the page has no EPEL 9 row.
  Source: https://packages.fedoraproject.org/pkgs/musl/musl-gcc/ (accessed 2026-10-31)
- Debian's `musl` source package builds `musl-tools`: bookworm 1.2.3-1,
  trixie 1.2.5-3.1~deb13u1, sid 1.2.6-2.
  Source: https://tracker.debian.org/pkg/musl (accessed 2026-10-31)
- Trial: `rustup target add x86_64-unknown-linux-musl` downloaded
  `rust-std` and `rustup target list --installed` then lists both
  targets; before it, the YAML's `rustup target list | grep
  x86_64-unknown-linux-musl | grep installed` exits 1.
- Verdict: current. The guard at `redhat.yml:17` matches the package
  reality exactly (Fedora and EL10 yes, EL9 and AL2023 no).

### `which` as the presence probe (rows `:13`, `:137`, `:154`)

- Probe table below: `which` is absent on five of the thirteen `dev_base`
  images; `command -v` worked on every image (`sh -lc "command -v cargo"`
  printed `/root/.cargo/bin/cargo` after the trial install on
  amazonlinux2023).
- Verdict: not current on the RedHat-family images built from minimal
  containers; the method is wrong there and only the idempotence of the
  installers hides it.

### Local probes (2026-10-31, `docker run --rm` on `resurgentech/dev_base-<distro>:latest`, read-only)

| Probe | Result |
|---|---|
| `getent passwd root` | `/root:/bin/bash` on all images except arch, omarchy (`/usr/bin/bash`); nowhere `/home/root` |
| `command -v which` | present: ubuntu2404, ubuntu2604, debian12, debian13, rockylinux9, almalinux9, arch, omarchy; MISSING: fedora43, fedora44, rockylinux10, almalinux10, amazonlinux2023 |
| `command -v curl` | present on all 13 (the installer's downloader) |
| `command -v cargo`, `rustup`; `~/.cargo`, `~/.rustup` | absent on all 13 (fresh `dev_base`) |
| root rc files | debian family: `.bashrc .profile`; fedora, EL: `.bash_profile .bashrc`; amazonlinux2023, arch, omarchy: none |
| `apt-cache policy` (after `apt-get update`) `g++ libssl-dev pkg-config clang musl-tools` | all five have candidates on the four Debian images; `g++`, `clang` already installed; `musl-tools` 1.2.4-2 (ubuntu2404), 1.2.5-3build1 (ubuntu2604), 1.2.3-1 (debian12), 1.2.5-3.1~deb13u1 (debian13) |
| `dnf repoquery gcc-c++ openssl-devel pkgconf-pkg-config clang musl-gcc` | first four available on all seven dnf images and all but `openssl-devel` already installed; `musl-gcc` 1.2.5 from `Fedora 43/44` repos and from `epel` on rockylinux10/almalinux10; no `musl-gcc` on rockylinux9, almalinux9, amazonlinux2023 |
| `dnf --version` | dnf5 5.2.18 (fedora43), 5.4.6 (fedora44); dnf 4.14 (EL9, AL2023), 4.20 (EL10) |
| `pacman -Si openssl pkgconf clang musl` | all available; `musl` 1.2.6-2 not installed, the other three installed |
| `/usr/local/bin` | `uv uvx` (plus `pyaml` on the seven dnf images), from `dev_common` |
| Installer trial: `sh /i.sh -y` as root, script mounted read-only, on amazonlinux2023 and ubuntu2404 | rustup 1.29.2, stable 1.99.1, six components, one target; `.profile` created on amazonlinux2023 (`. "$HOME/.cargo/env"` at line 1); on ubuntu2404 `.profile:10` and `.bashrc:100`; `bash -lc 'which cargo'` exit 0 on ubuntu2404, exit 127 on amazonlinux2023; second `sh /i.sh -y` updates in place |

## Recommendation and decision

### Options

1. Build `tool` first, then port. Shape, from the rows: a builder in a
   user scope, `s.tool("rust").bin("~/.cargo/bin/cargo").version("rustc
   --version").want(vars.rustc_version or Latest).install("sh
   rustup-init.sh -y --default-toolchain {want}").update("rustup default
   {want}")`, writing `tool:<user>:rust` with postcondition `Installed(v)`;
   the probe is `bin_exists` plus `bin_version` in the login shell
   (`crates/telepatch/src/facts/read.rs:83-95` already exist for the host
   scope); "present, no version" is the repair state. The same builder
   with source `crates.io` and `cargo install --locked {name} --version
   {want}` covers the two cargo tools. For: the role is nothing but this
   shape (13 of its 35 rows are the toolchain, 4 more the cargo tools);
   with `tool` the port is a dozen lines and the plan shows installed
   versus wanted versions per user; the same primitive is what
   `dev_common`'s `uv`, `golang`, `nvm_node` need. Against: it is a
   telepatch change this skill does not make; the design note does not
   yet name `tool`; the port waits.
2. Port now with the hack marked: `sh!(s, "sh /tmp/rustup.sh -y", unless
   = "command -v cargo")`, `sh!(s, "rustup update", unless = ...)`,
   `sh!(s, "cargo install {t}", creates = "~/.cargo/bin/{t}")`, each line
   `// HACK(tool)`, the fetch as `h.file("/tmp/rustup.sh")` from a
   prepare-phase download once `fetch` exists or a `sh!(curl)` until
   then. For: the oracle can be run now; the design note's own sketch of
   `rust_build` is this. Against: the engine learns nothing about
   versions (the stale pins become `unless` strings or are dropped), four
   `sh!` lines without `.undo`, and the plan cannot say "root has 1.99.1,
   wants 1.94.0".
3. Port now and change the contract: drop the version variables, declare
   "latest stable" as the wanted state, pin nothing. For: it is what the
   YAML does in practice. Against: it decides question 1 by default and
   hides the drift the variables were put there to show.

### Position

Option 1, build `tool` first. The toolchain install is the role's one
real task, the version pins are the role's one piece of intent the YAML
fails to honour, and the primitive is reused by the next three roles in
the queue. Stakes: under option 1 the port is delayed by the primitive
and the oracle run is unchanged in what it sees (same packages, same
toolchain on the same day); under option 2 the port lands now with four
marked hacks and the version intent lives in a comment; under either, the
oracle's gating sections are the same, since `rustup-init -y` and
`cargo install` produce the same names on both sides.

Dropped branches (no image reaches them): the repair block
`roles/rust_build/tasks/per_user.yml:73-97` (needs cargo present with no
toolchain; fresh images have neither) is kept as the tool's "present, no
version" state, not as code; `dev_common`'s Amazon Linux 2 arm
(`roles/dev_common/tasks/main.yml:12-14`) is `dev_base.md`'s.

Bugs the oracle cannot see (fixed in the port): (a) the `which` guard
fails on five images and reinstalls every pass (Preserved knowledge 2):
the port probes with `command -v` / `bin_exists`; (b) root processed
twice when `admin_users` contains root (Preserved knowledge 1): the port
deduplicates; (c) the repair's `/home/<user>` paths
(`per_user.yml:80-81`): the port uses the user's home; (d) the
unpinned installer: the port passes the wanted toolchain explicitly (or,
under option 3, states "latest" explicitly); (e) `rustup self update` and
`rustup update` running on every pass because the pins can never be
matched (`per_user.yml:65-71`): the port compares against what it will
install; (f) the installer script fetched without a checksum and run from
a shared `/tmp` path (`per_user.yml:122-127`): the port fetches to a
per-run path and verifies.

After equivalence (change what the oracle sees; not made yet): pin
`cargo-deb` and `cargo-generate-rpm` with `--locked --version` (changes
nothing today, 3.8.0 and 0.21.1 are the latest, but will diverge from the
YAML side on the next release); install with `--profile minimal` and add
`clippy`/`rustfmt` explicitly if wanted (removes `rust-docs` from the
components section); pass `--no-modify-path` and write one `profile.d`
line instead of editing user rc files (not captured by the oracle, still
a behaviour change for users).

Primitive gaps: `tool` for the rustup toolchain (build first; it is the
role's one real task and the version intent has nowhere else to live);
`tool` for the cargo-managed binaries (build first, same primitive with a
crates.io source; marked hack `sh!(.., creates = "~/.cargo/bin/<name>")`
is acceptable if the primitive ships without a cargo source); `fetch`
for the installer script (marked hack: a `sh!` line that runs `curl -sSf`
against `sh.rustup.rs` with `-o /tmp/rustup.sh` until `fetch` is built;
the checksum is the hack's cost).

Built-primitive defects: none found (probes under Task intent).

Questions to the reviewer:

1. What do `rustup_version`, `cargo_version`, `rustc_version` mean?
   Situation: the YAML compares against them and then updates to latest,
   so they have never been pins (Preserved knowledge 5). Options: (a)
   pins: the port installs `--default-toolchain 1.94.0` and `RUSTUP_VERSION=1.29.0`;
   for: the variables say what they say, the oracle then sees the YAML
   side at 1.99.1 and the port at 1.94.0, a gating diff in `rust
   versions` only if the oracle gated versions (it does not) but a real
   difference in `rustup toolchains [root]` (`1.94.0-x86_64-unknown-linux-gnu`
   versus `stable-x86_64-unknown-linux-gnu`), so equivalence fails;
   against: nobody has ever built an image at 1.94.0 from this YAML. (b)
   "latest stable", variables dropped or turned into a drift report; for:
   equivalence passes and matches two years of images; against: loses
   the one place the fleet's wanted Rust version is written. Agent's
   position: (b) for the port, with the three variables kept and reported
   by the `tool` primitive as "wanted 1.94.0, installed 1.99.1" in the
   plan, no action; once the reviewer wants a pin, it is one argument.
   Stakes: (a) fails the oracle on every distro until the variables are
   bumped to 1.99.1 and 1.29.2; (b) changes nothing the oracle sees.
2. Keep the installer's rc-file edits? Situation: `-y` without
   `--no-modify-path` appends `. "$HOME/.cargo/env"` to `~/.profile`
   and existing bash rc files (Preserved knowledge 7); `rust_kernel` and
   `rust_tools` and interactive users rely on cargo being on the login
   PATH. Options: keep (equivalent, including on desktops) or replace
   with `/etc/profile.d/cargo.sh` (one file, not per user, not captured
   by the oracle). Agent's position: keep for the port; the profile.d
   change is listed under "after equivalence". Stakes: none for the
   oracle; a different file for desktop users.

Decision: Option 1, build `tool` first with the shape above, then port
`rust_build` using it; until `tool` exists no port of this playbook is
started. Decided by agent (agent-alone); not yet reviewed by the user.

## Port notes

(Phase 2. Not started: the decision is to build `tool` first.)

## Review

2026-10-31: pass 1 (agent-alone). All ten levels written from the
mirrored YAML at 79d1ca16; 13 `dev_base` images probed; the installer
run once on amazonlinux2023 and ubuntu2404; `tp check-understanding
conversion/rust.md --playbook conversion/ansible/playbooks/container/rust.yml
--roles-path conversion/ansible/roles` prints `ok`.

## skill-feedback

Dated 2026-10-31, trial of ansible-port v3 on `rust.yml`.

1. Scope versus the row count. The task scoped this doc to what
   `rust.yml` adds, but `tp check-understanding --playbook` counts every
   in-scope task of the playbook, `dev_common` included (49, of which 14
   are `dev_common`), and the skeleton emits all 49. There is no way to
   say "role X is covered by doc Y": the 14 rows are repeated here with
   pointer judgments. The tool wants a `--skip-role <name>` (or the doc a
   `Covered elsewhere:` line the checker honours), and SKILL.md's "one
   doc per playbook; a role gets its own doc only when it does not fit"
   wants a sentence about a playbook that reapplies a role another doc
   owns.
2. The skeleton ends with a bare `Primitive gaps:` line and no
   `Built-primitive defects:` line, while the checker rejects a bare
   `Primitive gaps:` and the method asks for both lists. Emit both
   labels, or neither.
3. The skeleton's attribution line prints the command with paths relative
   to the roles parent (`tp classify playbooks/container/rust.yml
   --roles-path roles`), not the command that was run
   (`conversion/ansible/...`); a reader cannot rerun it from the doc. Same
   for the Current method header; the regeneration command had to be
   added by hand.
4. Current method versus Shape, where the tool and the doc differ: (a)
   "Installer outside the package manager" lists `per_user.yml:23` (a
   version probe, Shape `check`) and `:170` (a target check, Shape
   `check`); the pattern fires on the word `rustup` in the command. (b)
   "Hand-rolled ensure" lists the check halves (`:13`, `:137`, `:154`,
   `:170`) and the `get_url` at `:122` as ensures; the doc's shapes are
   `check` and `fetch`, with the ensure attributed to the op each guards.
   (c) "Version pinning" lists the six probe/flag tasks but not the two
   update ops (`:99`, `:107`) that act on them, and the pattern name says
   "pinning" for a YAML that pins nothing (Preserved knowledge 5); the
   doc's shapes are `check` and `derived fact`. (d) The Signals column
   says "installs a tool outside the package manager" for `:23` and
   `:170`, which is an observation that is false for a probe; the signal
   wants to be "mentions rustup/cargo" or be dropped for `changed_when:
   false` tasks. (e) `per_user.yml:179` (`rustup target add`) is Shape
   `package` here (rustup is the manager of targets) with primitive `sh`
   under `unless`; the tool says installer -> `tool`.
5. The skeleton leaves the Task cell's name empty for unnamed includes
   (`roles/rust_build/tasks/main.yml:4`, `:7`, `:10`, `:13`, `:17`,
   `:20`), which is correct but makes the row unreadable; printing the
   include target (`include_tasks per_user.yml`) in the name slot would
   help.
6. The per-user loop is shown once in the skeleton (under
   `main.yml:17`), with `main.yml:20` as a separate include row and no
   note that the same 25 tasks run again for `[root]`. The Signals of the
   per_user rows say "included under loop `{{ admin_users }}`" only. A
   reader of the skeleton alone misses that root runs twice in the
   container builds; the doc had to derive it from `group_vars/all:16`
   and the Dockerfile.
7. UNDERSTAND.md level 6 says to mount the downloaded script and run `sh
   /i.sh`; the YAML runs the file directly (`/tmp/rustup.sh -y`, mode
   0755). The first trial copied the YAML's form and failed with
   "Permission denied" on the read-only mount. The instruction is right;
   it wants a sentence that the mounted copy is not executable, so the
   YAML's invocation cannot be reproduced verbatim.
8. The shell hook refused every `> $VAR/file` redirect (dynamic path), so
   the mirroring had to go through `git archive | tar -x` and every
   capture through a literal path. The procedure's step 1 ("mirror the
   originals") wants a command that works under the hook, for example
   `git -C <repo> archive <commit> <paths> | tar -x -C conversion/ansible`.
9. The hedge-word rule and the dated-source rule were workable; the
   `(accessed YYYY-MM-DD)` form on one line forced the two
   `static.rust-lang.org` manifests to be cited as sources, which is the
   right primary source for "what does the installer serve today" and
   deserves a mention in level 6 beside "a releases page, an API".
10. The Shape list has no name for a `debug` task (shape `glue` was used,
    "a command with no state", which it is not: it is not a command). A
    `report` or `none` shape, or a sentence saying `debug`/`assert` rows
    are `glue`, would settle it.
11. The level 3 column rule "Primitive: ... `none` with a one-line
    sketch" and the dispatch rows: every `include_tasks` row needs a
    Primitive cell, and `none: match h.os.family` was repeated nine
    times. A documented spelling for control-flow rows (`none: control
    flow`) would make the table less noisy and the checker could accept
    it.
12. The skeleton's Signals column cites every reader of a registered
    variable by `file:line` (`cargo_check` has ten readers), which makes
    the row 600 characters wide. A count ("read by 10 tasks") with the
    first reader would keep the table readable; the full list belongs in
    the JSON output.
13. The dated-source check works per line, so a backtick code span that
    wraps across a line break (a `sh!` example containing a URL) is read
    as an undated source on its second line. Either the rule says "keep a
    code span with a URL on one line" or the checker tracks open
    backticks across lines.
