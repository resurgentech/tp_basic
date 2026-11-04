# dev_desktop.yml: understanding doc

Scope: `playbooks/dev_desktop.yml` and the nine roles it applies. All
file:line citations are relative to `conversion/ansible/` (byte copies of
the ansible repo at 79d1ca1, hashes in `conversion/SOURCE`). Last read
against those copies on 2026-11-03.

## Purpose

`dev_desktop.yml` configures a developer workstation. It is a bare role
list: `hosts: all`, `remote_user: root`, nine roles in this order,
`admin_users`, `dev_common`, `docker`, `vm_server`, `nvm_node`, `golang`,
`rust_build`, `rust_tools`, `tmux` (`playbooks/dev_desktop.yml:4-16`). It is
the first **host** playbook to be ported: every earlier port was an image
build under `playbooks/container/`. For this playbook Ansible is a
statement of intent, not the oracle. The user's triage (2026-11-04) treats
most of its workstation roles as behind, broken, or no longer the correct
way to install (the user's words: "trash: behind, don't work, or no longer
the correct way of doing the install"); each role below got its own
decision.

Who runs it and who else applies its roles (`git grep` over
`playbooks/` at 79d1ca1):

- `admin_users`, `nvm_node`, `golang`, `rust_tools`, `tmux`: only this
  playbook.
- `docker` and `vm_server`: this playbook and `playbooks/minikube.yml`
  (out of scope for this port, so its use does not constrain the rewrite).
- `dev_common`: this playbook and the four `playbooks/container/` image
  builds; `rust_build`: this playbook, `container/rust.yml` and
  `container/latest_kernel_build.yml`. Both are already ported, see
  `src/roles/{dev_common,rust_build}.rs`.

Role docs in this directory, one per substantial role:

- `conversion/admin_users.md`: all ten levels for `admin_users`.
- `conversion/docker.md`, `conversion/golang.md`, `conversion/vm_server.md`:
  one per rewritten role.
- This doc rows the three roles that do not need ten levels of their own:
  `nvm_node` (dropped), `rust_tools` (dropped), `tmux` (kept as one `pkg`).

`dev_common` and `rust_build` are skipped with `--skip-role` on both the
skeleton and the check, because `src/roles/dev_common.rs` and
`src/roles/rust_build.rs` carry their understanding as code comments.
The skip list for this doc is therefore `admin_users`, `dev_common`,
`docker`, `vm_server`, `golang`, `rust_build`.

Flags and variables, from `inventories/group_vars/all` (read first, it is
the file the playbook never names):

- `admin_users: ["{{ ansible_user }}"]` (`inventories/group_vars/all:16`),
  `full_users` the same list (`:22`), `vnc_users` the same list (`:19`).
  The only reader of `full_users` in this doc's scope is `rust_tools`
  (`roles/rust_tools/tasks/main.yml:19`).
- `default_password: ""` (`inventories/group_vars/all:26`). The comment above it
  says the value is a `openssl passwd -6` hash; at 79d1ca1 it is the empty
  string, so no secret is mirrored.
- `nvm_version: 0.40.4`, `nvm_node_version: lts`, `nvm_install_path:
  /var/lib/nvm`, `nvm_shell_init_file: /etc/bash.bashrc`
  (`inventories/group_vars/all:34-37`): the inputs of the Galaxy role
  `stephdewit.nvm`.
- `golang_version: '1.26.1'` (`inventories/group_vars/all:40`): the input of
  `gantsign.golang`, covered by `golang.md`.
- Distro flags `redhat_based`, `arch_based`, `debian_based`, `ubuntu_based`
  and the per-release `ubuntu2204_based`/`ubuntu2404_based`
  (`inventories/group_vars/all:4-13`). The file's own comment: "Only Ubuntu 2404
  is fully implemented at the moment" (`:3`).

## Outcomes

End state per family for the roles this doc rows. The other roles' end
states are in their own docs (`admin_users.md`, `docker.md`, `golang.md`,
`vm_server.md`) and in `src/roles/{dev_common,rust_build}.rs`.

### Ubuntu 22.04 and 24.04 (and Pop!_OS, which `ubuntu_based` includes)

- apt packages from `rust_tools`: `ffmpegthumbnailer`, `7zip`, `jq`,
  `poppler-utils`, `poppler-data`, `fzf`, `imagemagick`, `xclip`,
  `wl-clipboard`, `xsel` (`roles/rust_tools/tasks/ubuntu2204.yml:5-14`),
  included when `ubuntu2404_based or ubuntu2204_based`
  (`roles/rust_tools/tasks/main.yml:9-10`). Dropped, see Recommendation.
- Cargo tools for each `full_users` user, built from source: `zoxide`,
  `riffdiff`, `fd-find`, `eza`, `ripgrep`, `yazi-fm`, `yazi-cli`
  (`roles/rust_tools/tasks/per_user.yml:19-26`). Dropped.
- apt packages from `tmux`: `tmux`, `tmuxp` (`roles/tmux/tasks/main.yml:4-6`).
  `tmuxp` is in Ubuntu's archive.
- Node through the Galaxy role `stephdewit.nvm`: an nvm install under
  `/var/lib/nvm` with the node LTS line, shell init in `/etc/bash.bashrc`
  (`inventories/group_vars/all:34-37`, `roles/nvm_node/tasks/main.yml:3-5`).
  Dropped, replaced by mise.

### Debian family other than Ubuntu (Debian 12 and 13)

- `tmux`, `tmuxp` by apt, as above (`roles/tmux/tasks/main.yml:4-6`).
  `ubuntu2204.yml` is skipped: no `ubuntu*_based` flag is true
  (`roles/rust_tools/tasks/main.yml:10`, `inventories/group_vars/all:8,12,13`).
- The cargo tools are built for each `full_users` user (same loop).
- Node: nvm as above.

### RedHat family, Amazon Linux 2023 and Arch

- Every `tmux` task is an `apt` call with no `when` guard (the file has no
  `when:` at all, `roles/tmux/tasks/main.yml:1-6`), so on a host without
  `apt-get` it fails. Observed 2026-11-03 in `rockylinux:9` with ansible-core
  2.15.13: `"[Errno 2] No such file or directory: b'apt-get'"`. The role
  works on the Debian family only; no other family gets `tmux` from it.
- `rust_tools` skips `ubuntu2204.yml` (no flag true) and builds the cargo
  tools; the cargo tools need the cargo that `rust_build` installs per user.
- Node: nvm as above.

### Every host

- `rust_tools` fails the run when a `full_users` user has no cargo
  (`roles/rust_tools/tasks/per_user.yml:13-16`); `rust_build` runs earlier in
  the same playbook (`playbooks/dev_desktop.yml:14-15`) and provides it.

### Mapping to the oracle checklist

| Item | Oracle checklist entry |
|---|---|
| `tmux`, `tmuxp` | apt package names (Debian family only) |
| the `rust_tools` apt list | apt package names (Ubuntu 22.04, 24.04 only) |
| seven cargo tools per user | `~/.cargo/bin` names; dropped, not compared |
| nvm under `/var/lib/nvm` | files under `/var/lib/nvm`, lines in `/etc/bash.bashrc`; dropped, not compared |

Only `tmux` is proved against Ansible, by the two-role VM oracle
(`admin_users` + `tmux`) planned in the roadmap; the other rows have no port
to compare.

## Task intent

_Skeleton generated by `tp classify conversion/ansible/playbooks/dev_desktop.yml --roles-path conversion/ansible/roles --intent-skeleton --skip-role admin_users --skip-role dev_common --skip-role docker --skip-role vm_server --skip-role golang --skip-role rust_build`: Task, Method and Signals are the tool's. Intent, Shape, Adequate and Primitive are filled by hand._

| Task | Intent | Shape | Method | Signals | Adequate | Primitive |
|---|---|---|---|---|---|---|
| `roles/nvm_node/tasks/main.yml:3` nvm for node | Node and npm usable by every login shell on the host | installer | `include_role` stephdewit.nvm | | no: wraps an unpinned Galaxy role whose code is not in the repo; wanted version is `nvm_node_version: lts` (`inventories/group_vars/all:35`) with no probe here | `pkg: Mise` via `h.mise(["node"])` |
| `roles/rust_tools/tasks/main.yml:9` `include_tasks` ubuntu2204.yml | Pick the apt dependency list for the two Ubuntu releases | dispatch | `include_tasks` ubuntu2204.yml | when `ubuntu2404_based\|bool or ubuntu2204_based\|bool` | no: Debian 12/13 and Ubuntu 20.04 get no dependencies although the cargo tools build the same | `match` (dropped with the role) |
| `roles/rust_tools/tasks/ubuntu2204.yml:2` Ubuntu2204 rust tools Dependancies | The ten apt packages the cargo tools' runtime features use are present | package | `apt` 10 name(s), state present | included when `ubuntu2404_based\|bool or ubuntu2204_based\|bool` | yes: `state: present` over a package list is idempotent | `pkg` (dropped with the role) |
| `roles/rust_tools/tasks/main.yml:19` `include_tasks` per_user.yml | Run the cargo tool installs once for each user in `full_users` | dispatch | `include_tasks` per_user.yml | loop `{{ full_users }}` | yes: a plain per-user loop | `for u in users` (dropped with the role) |
| `roles/rust_tools/tasks/per_user.yml:3` Check if cargo is installed '{{ item }}' | Learn whether the user has cargo, so a missing one stops the run | check | `shell: source ~/.cargo/env && which cargo` | included under loop `{{ full_users }}`; become_user `{{ item }}`; no creates; changed_when `false`; ignore_errors; register `cargo_check`, read by `roles/rust_build/tasks/per_user.yml:23`, `roles/rust_build/tasks/per_user.yml:33` and 9 more | no: `cargo_check` is a register shared by name with `rust_build`'s tasks, so a rename in either role changes the other | absorbed by the `fail` row below; dropped |
| `roles/rust_tools/tasks/per_user.yml:13` Fail if cargo is not installed | The run stops with a message when the user has no cargo | check | `fail` (msg) | when `cargo_check.rc != 0`; included under loop `{{ full_users }}` | yes | `unless on :18` (dropped with the role) |
| `roles/rust_tools/tasks/per_user.yml:18` `include_tasks` per_app.yml | Run the check-then-install pair once for each of seven crate names | dispatch | `include_tasks` per_app.yml | loop `["zoxide","riffdiff","fd-find","eza","ri…`; included under loop `{{ full_users }}` | yes | `for app in apps` (dropped with the role) |
| `roles/rust_tools/tasks/per_app.yml:3` Check if '{{ app_name }}' is installed for '{{ current_user }}' | Learn whether the crate is already installed for the user | check | `shell: source ~/.cargo/env && cargo install --list \| grep {{ app_name }}` | included under loop `["zoxide","riffdiff","fd-find","eza","ri…`; become_user `{{ current_user }}`; no creates; changed_when `false`; ignore_errors; register `app_check`, read by `roles/rust_tools/tasks/per_app.yml:14` | no: `grep` matches the crate name as a substring of any line of `cargo install --list`, so `eza` also matches a crate whose name merely contains `eza` | absorbed by the install row below (`unless` on :14); dropped |
| `roles/rust_tools/tasks/per_app.yml:14` Install '{{ app_name }}' for '{{ current_user }}' | The crate's binary is installed for the user, built with `--locked` and `opt-level=3` | installer | `shell: source ~/.cargo/env && RUSTFLAGS='-C opt-level=3' cargo install {{ app_name }} --locked --…` | when `app_check.rc != 0`; included under loop `["zoxide","riffdiff","fd-find","eza","ri…`; become_user `{{ current_user }}`; installs a tool outside the package manager; no creates; reports changed whenever its when holds | no: no version wanted and no update path (a settled host never upgrades a crate), source build on every new host | `pkg: Cargo` (dropped with the role) |
| `roles/tmux/tasks/main.yml:1` Install tmux | `tmux` (and the `tmuxp` session manager) are installed from the distro | package | `apt` 2 name(s) | | no: apt only with no guard, fails on every non-Debian family (observed 2026-11-03); installs `tmuxp` whose presence differs per family | `pkg` |

Primitive gaps: none. The kept row maps to the built `pkg`; the Node row maps to the built `Mise` source (`h.mise`); the dropped rows have no port.

Built-primitive defects: none known for these rows.

Skipped by the loader (no row; decide each by hand):

- `roles/docker/tasks/debian.yml:11` galaxy_role: geerlingguy.docker: name has a dot, treated as a galaxy role. The Galaxy role `geerlingguy.docker` is listed in `tools/scripts/requirements.yml` with no version; its code is not in the repo, so the Ansible side of Docker cannot be read. `docker.md` replaces it with Docker's own repository method.
- `roles/docker/tasks/redhat.yml:19` galaxy_role: geerlingguy.docker: name has a dot, treated as a galaxy role. Same role from the RedHat branch, after the role removes `podman` and `runc` and overrides the distribution to `RedHat`; covered by `docker.md`.
- `roles/golang/tasks/main.yml:3` galaxy_role: gantsign.golang: name has a dot, treated as a galaxy role. Listed unpinned in `tools/scripts/requirements.yml`, driven by `golang_version: '1.26.1'` (`inventories/group_vars/all:40`); `golang.md` replaces it with a latest-release installer.
- `roles/nvm_node/tasks/main.yml:3` galaxy_role: stephdewit.nvm: name has a dot, treated as a galaxy role. Listed unpinned in `tools/scripts/requirements.yml`; it has a row above because `include_role` is a task in this repo, and the Node decision below replaces the whole role.

## Current method

_Generated by `tp classify playbooks/dev_desktop.yml --roles-path roles`._

94 tasks in scope; 23 match no pattern and are plain module calls. A task is listed under every pattern it matches, so pattern counts overlap and do not sum to the task total.

### By pattern

| Pattern | Tasks | Proposed telepatch primitive |
|---|---|---|
| Distro dispatch | 14 | typed `os` fact and a `match`, or a per-family table on `pkg` |
| Guarded by a distro flag | 7 | the task's own primitive inside the `match` arm; the flag is not a dispatch point |
| Installer outside the package manager | 9 | `pkg` with a non-distro source (`Script`, `Cargo`, `Rustup`, `Pip`) |
| Per-user loop | 49 | `for u in users { let s = h.as_user(u); ... }`; the login shell is a fact of the user |
| Hand-rolled ensure | 15 | `sh!(..).unless(check)` or `.creates(path)` |
| Version pinning | 6 | `bin_version` fact plus the ensure combinator |
| Repo setup | 0 | `repo` primitive; one cache update per window |
| Shell for a primitive | 0 | the matching primitive (`svc`, `file`, `pkg`, `user`), not `sh` |
| Controller-side gather | 0 | `secret`, `fetch`, `local` (prepare phase) |
| Handler | 0 | a guard on the restart op; identical guarded ops merge |

#### Distro dispatch (14 tasks)

Becomes: typed `os` fact and a `match`, or a per-family table on `pkg`

- `roles/dev_common/tasks/main.yml:4` dev_common_debian (include_tasks -> Rust control flow)
- `roles/dev_common/tasks/main.yml:8` dev_common_redhat (include_tasks -> Rust control flow)
- `roles/dev_common/tasks/main.yml:12` dev_common_amazonlinux2 (include_tasks -> Rust control flow)
- `roles/dev_common/tasks/main.yml:16` dev_common_amazonlinux2023 (include_tasks -> Rust control flow)
- `roles/dev_common/tasks/main.yml:20` dev_common_archlinux (include_tasks -> Rust control flow)
- `roles/docker/tasks/main.yml:3` docker_debian (include_tasks -> Rust control flow)
- `roles/docker/tasks/main.yml:7` docker_redhat (include_tasks -> Rust control flow)
- `roles/vm_server/tasks/main.yml:2` vm_server_debian (include_tasks -> Rust control flow)
- `roles/vm_server/tasks/main.yml:6` vm_server_redhat (include_tasks -> Rust control flow)
- `roles/rust_build/tasks/main.yml:4` (include_tasks -> Rust control flow)
- `roles/rust_build/tasks/main.yml:7` (include_tasks -> Rust control flow)
- `roles/rust_build/tasks/main.yml:10` (include_tasks -> Rust control flow)
- `roles/rust_build/tasks/main.yml:13` (include_tasks -> Rust control flow)
- `roles/rust_tools/tasks/main.yml:9` (include_tasks -> Rust control flow)

#### Guarded by a distro flag (7 tasks)

Becomes: the task's own primitive inside the `match` arm; the flag is not a dispatch point

- `roles/dev_common/tasks/main.yml:26` Various python dependancies (pip -> pkg::pip)
- `roles/docker/tasks/debian.yml:3` Override ansible_distribution for Pop!_OS compatibility (set_fact -> Rust control flow), included from `roles/docker/tasks/main.yml:3`
- `roles/docker/tasks/debian.yml:7` Override ansible_os_family for Pop!_OS compatibility (set_fact -> Rust control flow), included from `roles/docker/tasks/main.yml:3`
- `roles/docker/tasks/redhat.yml:3` Override ansible_distribution for Rocky compatibility (set_fact -> Rust control flow), included from `roles/docker/tasks/main.yml:7`
- `roles/docker/tasks/redhat.yml:7` Override ansible_os_family for Rocky compatibility (set_fact -> Rust control flow), included from `roles/docker/tasks/main.yml:7`
- `roles/docker/tasks/redhat.yml:11` RedHat has podman installed, probably could work but lets install docker (dnf -> pkg), included from `roles/docker/tasks/main.yml:7`
- `roles/rust_build/tasks/redhat.yml:13` RedHat musl-gcc for the musl target (dnf -> pkg), included from `roles/rust_build/tasks/main.yml:7`

#### Installer outside the package manager (9 tasks)

Becomes: `pkg` with a non-distro source (`Script`, `Cargo`, `Rustup`, `Pip`)

- `roles/dev_common/tasks/main.yml:34` Installing uv for python (shell -> sh)
- `roles/golang/tasks/godoc.yml:23` install godoc (shell -> sh), included from `roles/golang/tasks/main.yml:7`
- `roles/rust_build/tasks/per_user.yml:93` Reinstall Rust toolchain (command -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:99` Update rustup if needed for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:107` Update Rust toolchain if needed for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:130` Install rust and tools with the rustup script for '{{ item }}' (command -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:147` Install cargo-deb (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:164` Install cargo-generate-rpm for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_tools/tasks/per_app.yml:14` Install '{{ app_name }}' for '{{ current_user }}' (shell -> sh), included from `roles/rust_tools/tasks/per_user.yml:18`

#### Per-user loop (49 tasks)

Becomes: `for u in users { let s = h.as_user(u); ... }`; the login shell is a fact of the user

- `roles/admin_users/tasks/main.yml:19` (include_tasks -> Rust control flow)
- `roles/admin_users/tasks/per_user.yml:3` Create user '{{ item }}' (user -> user), included from `roles/admin_users/tasks/main.yml:19`
- `roles/admin_users/tasks/per_user.yml:12` Set default password for '{{ item }}' (when user is new) (user -> user), included from `roles/admin_users/tasks/main.yml:19`
- `roles/admin_users/tasks/per_user.yml:20` Add user '{{ item }}' to sudoers group (user -> user), included from `roles/admin_users/tasks/main.yml:19`
- `roles/admin_users/tasks/per_user.yml:27` Ensure SSH path for user '{{ item }}' exists (file -> file), included from `roles/admin_users/tasks/main.yml:19`
- `roles/admin_users/tasks/per_user.yml:35` Fixing sudo access for user '{{ item }}' (template -> file), included from `roles/admin_users/tasks/main.yml:19`
- `roles/vm_server/tasks/main.yml:10` (include_tasks -> Rust control flow)
- `roles/vm_server/tasks/vagrant_per_user.yml:3` Admin users need this group to avoid annoying GUI warnings (user -> user), included from `roles/vm_server/tasks/main.yml:10`
- `roles/vm_server/tasks/vagrant_per_user.yml:10` Create .vagrant.d (file -> file), included from `roles/vm_server/tasks/main.yml:10`
- `roles/vm_server/tasks/vagrant_per_user.yml:18` Create .vagrant.d/boxes (file -> file), included from `roles/vm_server/tasks/main.yml:10`
- `roles/vm_server/tasks/vagrant_per_user.yml:26` Create .vagrant.d/data (file -> file), included from `roles/vm_server/tasks/main.yml:10`
- `roles/vm_server/tasks/vagrant_per_user.yml:34` Create .vagrant.d/tmp (file -> file), included from `roles/vm_server/tasks/main.yml:10`
- `roles/golang/tasks/main.yml:7` (include_tasks -> Rust control flow)
- `roles/golang/tasks/godoc.yml:4` Get default shell for '{{ item }}' (command -> sh), included from `roles/golang/tasks/main.yml:7`
- `roles/golang/tasks/godoc.yml:9` Parse default shell for '{{ item }}' (set_fact -> Rust control flow), included from `roles/golang/tasks/main.yml:7`
- `roles/golang/tasks/godoc.yml:13` check for godoc (shell -> sh), included from `roles/golang/tasks/main.yml:7`
- `roles/golang/tasks/godoc.yml:23` install godoc (shell -> sh), included from `roles/golang/tasks/main.yml:7`
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
- `roles/rust_tools/tasks/main.yml:19` (include_tasks -> Rust control flow)
- `roles/rust_tools/tasks/per_user.yml:3` Check if cargo is installed '{{ item }}' (shell -> sh), included from `roles/rust_tools/tasks/main.yml:19`
- `roles/rust_tools/tasks/per_user.yml:13` Fail if cargo is not installed (fail -> Rust control flow), included from `roles/rust_tools/tasks/main.yml:19`
- `roles/rust_tools/tasks/per_user.yml:18` (include_tasks -> Rust control flow), included from `roles/rust_tools/tasks/main.yml:19`
- `roles/rust_tools/tasks/per_app.yml:3` Check if '{{ app_name }}' is installed for '{{ current_user }}' (shell -> sh), included from `roles/rust_tools/tasks/per_user.yml:18`
- `roles/rust_tools/tasks/per_app.yml:14` Install '{{ app_name }}' for '{{ current_user }}' (shell -> sh), included from `roles/rust_tools/tasks/per_user.yml:18`

#### Hand-rolled ensure (15 tasks)

Becomes: `sh!(..).unless(check)` or `.creates(path)`

- `roles/golang/tasks/godoc.yml:13` check for godoc (shell -> sh), included from `roles/golang/tasks/main.yml:7`
- `roles/golang/tasks/godoc.yml:23` install godoc (shell -> sh), included from `roles/golang/tasks/main.yml:7`
- `roles/rust_build/tasks/per_user.yml:13` Check if cargo is installed for '{{ item }}' who uses '{{ user_shell }}'" (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:122` Download rustup script for '{{ item }}' (get_url -> fetch), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:130` Install rust and tools with the rustup script for '{{ item }}' (command -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:137` Check if cargo-deb is installed for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:147` Install cargo-deb (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:154` Check if cargo-generate-rpm is installed for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:164` Install cargo-generate-rpm for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:170` Check if x86_64-unknown-linux-musl is installed for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_build/tasks/per_user.yml:179` Install rustup target x86_64-unknown-linux-musl for '{{ item }}' (shell -> sh), included from `roles/rust_build/tasks/main.yml:17`
- `roles/rust_tools/tasks/per_user.yml:3` Check if cargo is installed '{{ item }}' (shell -> sh), included from `roles/rust_tools/tasks/main.yml:19`
- `roles/rust_tools/tasks/per_user.yml:13` Fail if cargo is not installed (fail -> Rust control flow), included from `roles/rust_tools/tasks/main.yml:19`
- `roles/rust_tools/tasks/per_app.yml:3` Check if '{{ app_name }}' is installed for '{{ current_user }}' (shell -> sh), included from `roles/rust_tools/tasks/per_user.yml:18`
- `roles/rust_tools/tasks/per_app.yml:14` Install '{{ app_name }}' for '{{ current_user }}' (shell -> sh), included from `roles/rust_tools/tasks/per_user.yml:18`

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
| pkg | 18 | apt 7, dnf 7, pacman 2, pip 1, yum 1 | pkg, pkg::pip |
| file | 11 | copy 2, file 6, lineinfile 2, template 1 | file |
| sh | 22 | command 4, shell 18 | sh |
| user | 4 | user 4 | user |
| fetch | 2 | get_url 2 | fetch |
| control | 37 | debug 2, fail 1, include_role 4, include_tasks 21, set_fact 9 | Rust control flow |

### Unclassified

None.

### Skipped: out of scope

- `roles/docker/tasks/debian.yml:11` galaxy_role: geerlingguy.docker: name has a dot, treated as a galaxy role
- `roles/docker/tasks/redhat.yml:19` galaxy_role: geerlingguy.docker: name has a dot, treated as a galaxy role
- `roles/golang/tasks/main.yml:3` galaxy_role: gantsign.golang: name has a dot, treated as a galaxy role
- `roles/nvm_node/tasks/main.yml:3` galaxy_role: stephdewit.nvm: name has a dot, treated as a galaxy role

Regenerate: `tp classify conversion/ansible/playbooks/dev_desktop.yml --roles-path conversion/ansible/roles` (the classifier has no role filter, so it lists the skipped roles too).

## Preserved knowledge

1. `rust_tools` needs the user's cargo and fails loudly without it
   (`roles/rust_tools/tasks/per_user.yml:13-16`). The role relies on
   `rust_build` running earlier in `playbooks/dev_desktop.yml:14-15`. Dropping
   `rust_tools` removes that dependency; nothing else here reads cargo.
2. `rust_tools` builds every crate with `--locked` "because some apps need
   it" (`roles/rust_tools/tasks/per_app.yml:13`) and `RUSTFLAGS='-C
   opt-level=3'`, `--jobs=$(nproc)` (`per_app.yml:15`). Kept as history only,
   since the role is dropped.
3. `ubuntu2204.yml` is included for 22.04 and 24.04 only
   (`roles/rust_tools/tasks/main.yml:10`); the file name still says 2204 for
   both. Dropped with the role.
4. `tmux` has `become: yes` on a play that already runs as root
   (`roles/tmux/tasks/main.yml:2`, `playbooks/dev_desktop.yml:6`); a no-op.
5. `tmux` requests `tmuxp` with `tmux` in one `apt` call
   (`roles/tmux/tasks/main.yml:4-6`). `tmuxp` has no package on Fedora and the
   EL family, see Is the method current; the port decides per family.
6. `nvm_node` is one `include_role` and nothing else; every setting is in
   `inventories/group_vars/all:34-37` (nvm 0.40.4, node `lts`, install path
   `/var/lib/nvm`, init file `/etc/bash.bashrc`). Nothing in the repo reads
   `nvm_install_path` besides the Galaxy role.
7. `full_users` and `vnc_users` exist only for `rust_tools`
   (`roles/rust_tools/tasks/main.yml:19`) and the out-of-scope tigervnc role;
   neither goes into the port's `Vars`.

## Is the method current

Research date: 2026-11-03.

### Node through mise instead of nvm

- mise installs Node from the official archive on nodejs.org and checks it
  against `SHASUMS256.txt` and that file's OpenPGP signature; `mise use -g
  node@26` writes a per-user default, and the page describes no system-wide
  form (the system layer is covered by `src/roles/dev_common.rs` for `just`).
  Version requests: `latest` is the newest release, `lts` the newest release
  of the current LTS line, a numeric prefix selects the newest matching
  release.
  Source: https://mise.jdx.dev/lang/node.html (accessed 2026-11-03)
- `nvm_node_version: lts` (`inventories/group_vars/all:35`) asks for the LTS
  line. `h.mise(["node"])` with no version asks for mise's default request for
  a bare tool name, which the page above does not state to be `lts`. The port
  has to pick: `lts` keeps the Ansible intent, `latest` follows the rest of
  the dev_common tools (Question below).
- Verdict: mise is the current way in this fleet (`just` already installs
  through it); the `stephdewit.nvm` role is unpinned and its code is not
  mirrored, so it cannot be checked.
- Open: `docker run --rm ubuntu:24.04 sh -c 'apt-get update -qq && apt-get install -y -qq curl ca-certificates >/dev/null && curl -fsSL https://mise.run | sh && ~/.local/bin/mise ls-remote node@lts | tail -1'` prints the version `lts` resolves to today.

### tmux and tmuxp per family

- Ubuntu 24.04 serves `tmuxp` 1.38.0-1ubuntu1 and Debian 12 serves
  1.27.0-1 (`apt-cache policy tmuxp`); Arch serves 1.76.0-1 from `extra`
  (`pacman -Si tmuxp`). Fedora 43, Rocky 9, Rocky 10 and Amazon Linux 2023 have
  no `tmuxp` package in their default repositories. Local probes, 2026-11-03,
  throwaway containers (`ubuntu:24.04`, `debian:12`, `archlinux`, `fedora:43`,
  `rockylinux:9`, `rockylinux/rockylinux:10`, `amazonlinux:2023`).
- So `tmuxp` is packaged on the Debian family and Arch; on Fedora, the EL
  family and Amazon Linux 2023 it is not, and tmuxp's own page installs it
  with pip, uv or Homebrew, not with the distro manager. It needs tmux >= 3.2
  and Python >= 3.10.
  Source: https://tmuxp.git-pull.com/quickstart.html (accessed 2026-11-03)
- Verdict: `tmux` is a distro package everywhere; `tmuxp` is a distro package
  on Debian, Ubuntu and Arch only. The Ansible role never worked outside the
  Debian family (apt-only, no guard, observed failing on Rocky 9).
- Open: `docker run --rm rockylinux:9 sh -c 'dnf -y install epel-release >/dev/null && dnf info tmuxp'` shows whether EPEL serves `tmuxp` on EL.

### Rust tools by `cargo install`

- The seven crates are installed from source with `cargo install --locked`
  per user, no version wanted, no update path
  (`roles/rust_tools/tasks/per_app.yml:14-20`). The user decided to drop the
  role ("straight out", 2026-11-04), so no vendor method is researched here.
- Verdict: dropped by the user; nothing to compare.

## Recommendation and decision

### Options

1. Port every row (nvm_node as a Galaxy-free installer, rust_tools as
   `pkg: Cargo` per user, tmux as `pkg`). For: keeps the Ansible
   workstation as it is. Against: three of the rows have no working Ansible
   baseline; `nvm_node` pins nothing, and the seven source builds cost
   minutes per user on every new host.
2. Port tmux, replace nvm_node by mise, drop rust_tools. For: matches the
   user's triage; Node comes from the same mise layer as `just`. Against:
   hosts lose the seven cargo tools until the user asks for them again.
3. Put Node inside `dev_common`. For: one place for all language runtimes.
   Against: `dev_common` runs in all four container playbooks, so Node would
   change four image builds and the docker oracle's intended differences.

### Position

Option 2. The port's playbook gets a one-line `node` role at the position
where `nvm_node` stood, calling `h.mise(["node"])`; it is not in
`dev_common` (option 3's cost). `tmux` is one `pkg` with the per-family rule
below. The consequence in the fleet: the seven cargo tools and the
`ubuntu2204.yml` apt list stop being installed on a workstation configured
from this playbook.

Per-family rule for `tmux`: `tmux` on every family; `tmuxp` only where the
distro packages it (Debian, Ubuntu, Arch); Fedora, EL and Amazon Linux 2023
get `tmux` alone.

Question for the reviewer. Situation: the Ansible role asks for the node LTS
line (`nvm_node_version: lts`, `inventories/group_vars/all:35`); `h.mise(["node"])`
asks mise for a bare tool name. Options: (a) pin the request to `lts`,
which keeps what Ansible installed and costs a one-word pin on the handle;
(b) leave it to mise's default, the same as `just`, which tracks the newest
release and moves ahead of LTS. Position: (a), since a workstation wants a
stable Node. Stakes: with (b) `node --version` moves to a non-LTS line when
mise's `latest` does; with (a) it moves only when the LTS line does. The
Open line under "Node through mise" settles what `lts` resolves to today.

Dropped branches (no image reaches them): not applicable, since this
playbook builds no image; `rust_tools`'s `ubuntu2204.yml` list and the seven
crates are dropped by the user's decision, `nvm_node` is replaced.

Bugs the oracle cannot see (fixed in the port): `tmux` fails on every
non-Debian family because its only task is an unguarded `apt` call
(`roles/tmux/tasks/main.yml:3-6`); the port installs `tmux` through the
distro's own manager everywhere. Also: `tmuxp` is requested where it has no
package. No other bug found in these three roles.

Intended differences (bugs fixed in the port that the oracle sees): none. The
oracle for `tmux` runs on Ubuntu 24.04 (apt), where Ansible and the port
install the same two names.

Primitive gaps: none.

Built-primitive defects: none known.

Decision: tmux keep as one `pkg` (`tmux` everywhere, `tmuxp` on Debian, Ubuntu and Arch); Ansible is apt-only with no guard. Decided by the user 2026-11-04 (triage); levels not yet reviewed.

Decision: nvm_node drop; Node comes from `h.mise(["node"])`, with the mise page above as its dated source. Decided by the user 2026-11-04 (triage); levels not yet reviewed.

Decision: rust_tools drop ("straight out", the user, 2026-11-04). Decided by the user 2026-11-04 (triage); levels not yet reviewed.

Decision: the Node line sits in its own one-line `node` role in the playbook where `nvm_node` stood, not in `dev_common` (A-5b-4). Decided by the user 2026-11-04 (triage); levels not yet reviewed.

## Port notes

(Phase 2.)

## Review

2026-11-04: accepted by the user for the port ("okay go"), all levels, no
comments; the Decision line stands as written. rust_tools is dead: not ported,
not reconsidered.
