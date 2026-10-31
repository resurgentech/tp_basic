# kernel_build.yml: understanding doc

Scope: `playbooks/container/kernel_build.yml` and the roles it applies:
`dev_common`, `src_repos`, `kernel_build`. All file:line citations are
relative to `conversion/ansible/` (byte copies of the ansible repo at
79d1ca1). Last read against those copies on 2026-10-30.

`dev_common` already has its understanding in `dev_base.md`; this doc covers
what the role does when applied a second time and does not repeat its
package lists. `src_repos` and `kernel_build` have no role docs of their own;
this doc holds them. `latest_kernel_build.md` covers the playbook that applies
the same two roles on top of `rust_build`.

## Purpose

`kernel_build.yml` turns a `dev_base` image into one that can build the
distro's own kernel packages. It runs against all hosts as root
(`playbooks/container/kernel_build.yml:5-6`) and applies three roles in order
(`playbooks/container/kernel_build.yml:7-10`):

1. `dev_common`, again (see `dev_base.md`).
2. `src_repos`: on the Debian family, turns on `deb-src` source repositories
   (`roles/src_repos/tasks/main.yml:4-15`).
3. `kernel_build`: installs the kernel build dependencies of each family
   (`roles/kernel_build/tasks/main.yml:4-30`).

Who runs it:

- `docker_images` runs it as the `kernel_build` container, parent `dev_base`,
  for all 13 distros (`../docker_images/docker-bake.hcl`, `CONTAINERS` line 29
  and `DISTROS`): debian12, debian13, ubuntu2404, ubuntu2604, fedora43,
  fedora44, rockylinux9, rockylinux10, almalinux9, almalinux10,
  amazonlinux2023, arch, omarchy. The bake file comments that `kernel_build`
  uses the distro's own kernel toolchain, Rust included, and deliberately
  does not build on `rust_build`'s rustup toolchain.
- Workstations run the roles through the same flags
  (`inventories/group_vars/all:4-13`).

Who else applies these roles (`grep -rn "src_repos\|kernel_build" playbooks/`
over the mirrored playbooks, excluding the role directories):

- `src_repos` and `kernel_build`: `playbooks/container/latest_kernel_build.yml:9-10`
  (listed after `dev_common` at `:8`, then `rust_build` and `rust_kernel` at
  `:11-12`). That image's parent is `rust_build`
  (`../docker_images/docker-bake.hcl:31`), so the roles run on an image that
  already holds rustup. The port is reviewed against both playbooks.
- `dev_common`: also `dev_base.yml`, `rust.yml` and `latest_kernel_build.yml`
  (see `dev_base.md`).

Flags the roles read, all defined in `inventories/group_vars/all`, a file the
playbook never names:

- `debian_based` (`:6`: Ubuntu, Pop!_OS, Debian), `ubuntu_based` (`:8`:
  Ubuntu, Pop!_OS), `debian10_based` (`:7`), `redhat_based` (`:4`: CentOS,
  RedHat, Fedora, Rocky, AlmaLinux; omits Amazon), `arch_based` (`:5`, tests
  `ansible_os_family`), `amazonlinux2_based` (`:9`), `amazonlinux2023_based`
  (`:10`).
- `ubuntu2004_based`, `ubuntu2204_based`, `ubuntu2404_based` (`:11-13`) are
  not read by `src_repos` or `kernel_build`: no `when` in
  `roles/kernel_build/tasks/main.yml:4-30` or `roles/src_repos/tasks/main.yml:4-15`
  names them.

The Dockerfiles do work this playbook relies on: `ansible.debian` runs
`apt-get update` and a full upgrade before the playbook, then deletes
`/var/lib/apt/lists/*` afterwards (`../docker_images/Dockerfiles/ansible.debian`).
`ansible.arch` runs `pacman -Syu` first. `ansible.redhat` upgrades first
(see `dev_base.md`, Preserved knowledge 9).

## Outcomes

The observable end state. This is the oracle's checklist (T18): per image the
oracle compares package names and arch, system pip names, rustup state,
`/etc/apt/sources.list*` paths and content, and `/usr/local/bin` names. The
state below is what this playbook adds on top of the `dev_base` image. The
second `dev_common` run adds nothing new (every package and pip name is
already present from the first run; `uv` and `uvx` are replaced in place, see
`dev_base.md`). Requested names are listed; the oracle compares installed
names, which differ where noted.

### Debian family, Ubuntu (ubuntu2404, ubuntu2604; Pop!_OS on workstations)

Selected by `ubuntu_based` (`roles/kernel_build/tasks/main.yml:6`). Tasks:
`roles/kernel_build/tasks/ubuntu.yml:1-24`.

- Source repositories: every `Types: deb` line in
  `/etc/apt/sources.list.d/*.sources` becomes `Types: deb deb-src`
  (`roles/src_repos/tasks/apt_sources_deb822.yml:12`), unless any file already
  carries a `deb-src` type (`:9-11`). Both images use deb822 (Local probes).
  `/etc/apt/sources.list` is untouched on these images.
- apt, in this order: first the build dependencies of the source package
  `linux` (`state: build-dep`, `ubuntu.yml:2-5`); then `libperl-dev`,
  `libzstd-dev`, `libpython3-dev`, `binutils-dev`, `equivs`, `dwarves`,
  `systemtap-sdt-dev`, `libbabeltrace-dev`, `libbabeltrace-ctf-dev`,
  `python3-pip`, `python3-jinja2`, `python3-yaml`, `python3-git`,
  `python3-lxml` (`ubuntu.yml:7-24`; 14 names). `libbabeltrace-ctf-dev` is a
  provided name: the installed package is `libbabeltrace-dev`, whose dpkg
  status carries `Provides: libbabeltrace-ctf-dev` (Local probes). The
  build-dep list is whatever the archive's `linux` source package declares
  that day, so the oracle sees its names, not the YAML.
- pip: no pip installs on this branch.
- rustup: absent.
- `/usr/local/bin`: unchanged (`uv`, `uvx`).

### Debian family, Debian (debian12, debian13)

Selected by `debian_based and not ubuntu_based`
(`roles/kernel_build/tasks/main.yml:14`). Tasks:
`roles/kernel_build/tasks/debian.yml:1-19`.

- Source repositories: as on Ubuntu, in `debian.sources`.
- apt, in this order: first `libncurses-dev`, `libssl-dev`, `libelf-dev`,
  `libudev-dev`, `libpci-dev`, `libiberty-dev`, `equivs`, `dwarves`, `dkms`
  (`debian.yml:2-14`; 9 names); then the build dependencies of `linux`
  (`debian.yml:16-19`). The order is the reverse of Ubuntu's.
- pip, rustup, `/usr/local/bin`: as on Ubuntu.

### RedHat family (fedora43, fedora44, rockylinux9, rockylinux10, almalinux9, almalinux10)

Selected by `redhat_based` (`roles/kernel_build/tasks/main.yml:18`). Tasks:
`roles/kernel_build/tasks/redhat.yml:1-48`.

- pip: `pip` itself at its latest version (`state: latest`,
  `redhat.yml:2-5`), before any dnf work. This installs a second `pip` under
  `/usr/local/lib/python3.N/site-packages` that shadows the rpm one, and adds
  `pip`, `pip3` and `pip3.N` to `/usr/local/bin` (Local probes).
- dnf: `rpmdevtools`, `rpm-build`, `redhat-rpm-config`, `audit-libs-devel`,
  `binutils-devel`, `elfutils-devel`, `elfutils-libelf-devel`, `java-devel`,
  `libcap-devel`, `ncurses-devel`, `newt-devel`, `numactl-devel`,
  `openssl-devel`, `pciutils-devel`, `libnl3-devel`, `xz-devel`, `zlib-devel`,
  `perl-interpreter`, `perl-devel`, `perl-generators`, `perl-Carp`,
  `perl(ExtUtils::Embed)`, `python3-sphinx`, `dwarves`, `kabi-dw`,
  `libbabeltrace-devel`, `libbpf-devel`, `libcap-ng-devel`, `libmnl-devel`,
  `bpftool` (`redhat.yml:7-40`; 30 names). Provided names resolve to other
  installed names: `java-devel` to `java-25-openjdk-devel` (Fedora),
  `java-17-openjdk-devel` (EL9) or `java-21-openjdk-devel` (EL10);
  `zlib-devel` to `zlib-ng-compat-devel` on Fedora and EL10;
  `perl(ExtUtils::Embed)` to `perl-ExtUtils-Embed` (Local probes).
- pip: `jinja2`, `GitPython`, `pyaml` again (`redhat.yml:43-48`), a repeat of
  `roles/dev_common/tasks/main.yml:26-31`; already satisfied, so no change.
- Repos: none added. rustup: absent.
- `/usr/local/bin`: gains `pip`, `pip3`, `pip3.N` beside `uv`, `uvx`, and the
  `pyaml` entry point the first `dev_common` run left.

### Amazon Linux 2023 (amazonlinux2023)

Selected by `amazonlinux2023_based`
(`roles/kernel_build/tasks/main.yml:26`); Amazon is outside `redhat_based`
(`inventories/group_vars/all:4`). Tasks:
`roles/kernel_build/tasks/amazonlinux2023.yml:1-38`.

- dnf: `rpmdevtools`, `rpm-build`, `audit-libs-devel`, `binutils-devel`,
  `elfutils-devel`, `elfutils-libelf-devel`, `libcap-devel`, `ncurses-devel`,
  `newt-devel`, `numactl-devel`, `openssl-devel`, `pciutils-devel`,
  `xz-devel`, `zlib-devel`, `perl-interpreter`, `perl-devel`,
  `perl-generators`, `perl-Carp`, `perl(ExtUtils::Embed)`, `python3-sphinx`,
  `dwarves`, `libbpf-devel`, `libcap-ng-devel`, `libmnl-devel`, `bpftool`
  (`amazonlinux2023.yml:2-30`; 25 names). It omits `redhat-rpm-config`,
  `java-devel`, `libnl3-devel`, `kabi-dw` and `libbabeltrace-devel`, which the
  RedHat list has (`redhat.yml:12`, `:17`, `:24`, `:34`, `:35`); on the
  Amazon image `amazon-rpm-config` provides the first and the other four are
  not installed (Local probes).
- pip: no `pip` upgrade: the file has no pip-latest task
  (`amazonlinux2023.yml:1-38`). `jinja2`, `GitPython`, `pyaml` again
  (`amazonlinux2023.yml:33-38`), already satisfied.
- `/usr/local/bin`: unchanged (`uv`, `uvx`, `pyaml`). The system pip stays the
  rpm one (Local probes).

### Arch family (arch, omarchy)

Selected by `arch_based` (`roles/kernel_build/tasks/main.yml:30`), which tests
`ansible_os_family` (`inventories/group_vars/all:5`). Tasks:
`roles/kernel_build/tasks/archlinux.yml:1-14`.

- pacman: `devtools`, `pacman-contrib`, `bc`, `pahole`, `rust`,
  `rust-bindgen`, `rust-src` (`archlinux.yml:4-14`; 7 names; `bc` is already
  there from `dev_common`).
- pip: none. rustup: absent; `rust` installs `rustc` and `cargo` from the
  distro, not rustup (Local probes).
- `/usr/local/bin`: unchanged.

### Every image

- `src_repos` does nothing outside the Debian family: its three tasks carry
  `when: debian_based|bool` (`roles/src_repos/tasks/main.yml:9`, `:12`, `:15`).
- No new repository file other than the edited `*.sources` on Debian and
  Ubuntu; no other change to `/etc/apt/sources.list*`.
- Not selected on any image: `debian10.yml`, `amazonlinux2.yml`
  (flags `debian10_based`, `amazonlinux2_based`, no image of those releases),
  `debian_long.yml` (no `include_tasks` names it:
  `roles/kernel_build/tasks/main.yml:4-30`), and the legacy
  `apt_sources_list.yml` (reached only when no `*.sources` file exists,
  `roles/src_repos/tasks/main.yml:14-15`).
- Counts rechecked by command: Ubuntu 14 plus build-dep, Debian 9 plus
  build-dep, RedHat 30 dnf plus 3 pip, Amazon 2023 25 dnf plus 3 pip, Arch 7.

### Mapping to the oracle checklist

| Oracle item | Ubuntu | Debian | RedHat family | Amazon 2023 | Arch family |
|---|---|---|---|---|---|
| package names + arch | build-dep of `linux` (archive-dependent) + 14 listed | 9 listed + build-dep of `linux` | 30 listed (installed names differ for 3) | 25 listed | 7 listed |
| system pip names | no change | no change | no new name (a second `pip` copy under `/usr/local`) | no change | no change |
| rustup state | absent | absent | absent | absent | absent (distro `rust`) |
| /etc/apt/sources.list* | `ubuntu.sources`: `Types: deb deb-src` | `debian.sources`: `Types: deb deb-src` | n/a | n/a | n/a |
| /usr/local/bin names | uv, uvx | uv, uvx | + pip, pip3, pip3.N | uv, uvx | uv, uvx |

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
`cargo run -q -p tp -- classify ../tp_basic/conversion/ansible/playbooks/container/kernel_build.yml`
and paste its output over this section unedited (from `## Current method`
through `### Skipped: out of scope`). Regenerate whenever the YAML changes.

## Preserved knowledge

Each item is something the YAML knows that a port must keep (or consciously
drop). Citations are file:line against `conversion/ansible/`.

1. deb822 versus `sources.list`: `src_repos` chooses its branch from the file
   layout, not from the distro or its version. It looks for
   `/etc/apt/sources.list.d/*.sources` (`roles/src_repos/tasks/main.yml:4-9`),
   takes the deb822 branch when any match (`main.yml:12`) and the one-line
   branch when none does (`main.yml:15`). Both branches also require
   `debian_based`. The distro-version flags (`ubuntu2204_based` and others)
   play no part. The port dispatches on the presence of `*.sources` files the
   same way, so a Pop!_OS or Debian host with either layout takes the right
   branch. All four Debian-family images take the deb822 branch (Local probes).
2. The legacy branch never created its `.ansible-src` file
   (`roles/src_repos/tasks/apt_sources_list.yml:8-10`). Line 6 copies
   `sources.list` to `sources.list.ansible`; line 8 then runs `sed -i` on
   `sources.list.ansible-src`, and lines 9-10 read and remove that file. Nothing
   creates it. The script has no `set -e`, so the errors scroll past and the
   shell's exit status is that of the last command, which succeeds. Observed
   on a stand-in file (Local probes): with no `deb-src` line in the file, the
   branch prints three errors, exits 0 and leaves the file unchanged; the
   deb-src lines are never added. Only the other path works: when `deb-src`
   lines exist but are commented (`# deb-src`), line 13 uncomments them and
   the task reports `SOURCES_LIST_CHANGED`. The sed at line 8 would also turn
   `deb` lines into `deb-src` lines instead of adding them, so the intent was
   to build the `-src` copy first. The branch is dropped (no image reaches it),
   and this fact is kept here so nobody ports line 8 as if it worked.
3. The legacy branch has no apt cache update (`apt_sources_list.yml:1-22`
   holds one `shell` task and no `apt` task), unlike the deb822 branch
   (`apt_sources_deb822.yml:17-22`). A host that took it and had its
   `deb-src` lines uncommented would run `build-dep` against lists that lack
   the source indexes. The port refreshes the cache after any change to the
   sources, whichever branch made it.
4. The deb822 edit is guarded and exact. It exits 0 without changing anything
   if any `*.sources` file already has a `Types:` line mentioning `deb-src`
   (`apt_sources_deb822.yml:9-11`; one file with it skips all files). It
   rewrites only lines that are exactly `Types: deb`
   (`apt_sources_deb822.yml:12`); a stanza that reads `Types: deb` followed by
   other text, or lists the types in another order, is left alone. It
   prints `SOURCES_CHANGED` only after a change (`:13`), and that is the only
   thing the later cache update waits for (`:22`). Both images' files carry two
   `Types: deb` stanzas (main and security) and both are edited (Local
   probes). The port edits the same lines and leaves no backup file.
5. The cache update is conditional and, when it runs, refreshes always.
   `update_cache: yes` with `cache_valid_time: 1` (`apt_sources_deb822.yml:18-20`)
   refreshes unless the cache is under one second old; `when:
   apt_deb822_changed.changed` (`:22`) is what decides. The task after it,
   `build-dep`, needs the new lists: source indexes exist only after the
   refresh. The Dockerfile's own `apt-get update` ran before the playbook
   against the old sources, and the layer that built `dev_base` deleted the
   lists afterwards (`ansible.debian`; the `kernel_build` layer starts with its
   own update). Roadmap assumption: this is the apt cache rule of T6. The port
   must order the `build-dep` after the sources change and its cache update,
   and merging installs across roles (Open question 4) must not hoist the
   `build-dep` above them. If a diff traces to a merge, the role gets a
   `barrier()`.
6. Ubuntu runs `build-dep` before its extra packages, Debian after
   (`roles/kernel_build/tasks/ubuntu.yml:2-24` against
   `roles/kernel_build/tasks/debian.yml:2-19`). The YAML gives no reason for
   either order. Order is observable only through which package satisfies a
   dependency, but the Ubuntu extras do include a provided name
   (`libbabeltrace-ctf-dev`, provided by `libbabeltrace-dev`), so the port
   keeps each family's order rather than normalising. A `build-dep` is not
   mergeable with the plain installs around it: it reads the source package's
   dependency list, not a list of names.
7. The RedHat `pip` is `latest` (`roles/kernel_build/tasks/redhat.yml:2-5`) and
   only on the RedHat family: `amazonlinux2023.yml:1-38` has no such task and
   the Debian and Arch files install no pip packages. It runs first in the
   RedHat file, before dnf. `dev_common` supplies the rpm `python3-pip` just
   before (`dev_base.md`, Outcomes), so pip exists; no base image has it
   (`dev_base.md`, Local probes). The task names no interpreter or virtualenv,
   so Ansible's own system `python3` is the target. The result is visible to
   the oracle: a second pip tree under `/usr/local/lib/python3.N/site-packages`
   and three new names in `/usr/local/bin` (`pip`, `pip3`, `pip3.N`) (Local
   probes). The pip version is whatever PyPI holds on the build day; the
   oracle compares names. The port keeps the upgrade, installs into the same
   place (the system interpreter, as root), and does not add the PEP 668 flag
   the Debian and Arch branches would need (`dev_base.md`, Preserved
   knowledge 2).
8. Requested names resolve to other installed names on the RedHat family and
   Ubuntu: `java-devel` (to `java-25-openjdk-devel`, `java-17-openjdk-devel`,
   `java-21-openjdk-devel`), `zlib-devel` (to `zlib-ng-compat-devel` on Fedora
   and EL10), `perl(ExtUtils::Embed)` (to `perl-ExtUtils-Embed`),
   `libbabeltrace-ctf-dev` (to `libbabeltrace-dev`). The port requests the
   same names. The JDK major version differs per release (17 on EL9, 21 on
   EL10, 25 on Fedora); the oracle sees the installed names.
9. Amazon Linux 2023 has its own list and is not RedHat
   (`roles/kernel_build/tasks/main.yml:24-26`; `inventories/group_vars/all:4`
   omits Amazon). The list omits `redhat-rpm-config`, `java-devel`,
   `libnl3-devel`, `kabi-dw` and `libbabeltrace-devel` against the RedHat list
   (`amazonlinux2023.yml:2-30` against `redhat.yml:7-40`). A port must not
   merge the two lists into one table.
10. Rust arrives differently per family and no `kernel_build` file installs
    rustup. Arch installs the distro `rust`, `rust-bindgen` and `rust-src`
    (`archlinux.yml:4-14`), with a comment that says the rest are kernel
    makedeps that `makepkg --syncdeps` would otherwise download on every build
    (`archlinux.yml:2-3`). Ubuntu gets `rustc` only as a dependency of the
    `linux` source package (Local probes: `rustc` appears on kernel_build-ubuntu2404
    and -ubuntu2604 and not on dev_base). Debian and the RedHat family get none.
    The rustup state is "absent" on all 13 images. `rust_build`/`rust_kernel`
    are the roles that add rustup, and `latest_kernel_build.yml` applies
    them after `kernel_build` (`playbooks/container/latest_kernel_build.yml:10-12`).
11. The second `dev_common` run repeats work harmlessly. `uv` and `uvx` are
    replaced in place (`dev_base.md`, Preserved knowledge 5). The Python
    libraries are installed again by the kernel roles: `jinja2`, `GitPython`,
    `pyaml` on the RedHat family and Amazon (`redhat.yml:42-48`,
    `amazonlinux2023.yml:32-38`; the comment at `amazonlinux2023.yml:32` says
    "required for the our build scripts"), and `python3-pip`,
    `python3-jinja2`, `python3-yaml`, `python3-git` on Ubuntu
    (`ubuntu.yml:19-22`), all already present from `dev_common`. The only new
    Python name is `python3-lxml` (`ubuntu.yml:23`). Deduplicating changes no
    installed name. The reason these are there at all is the build scripts the
    images run; the repository that holds them is outside this playbook.
12. Dead and unreachable material. `debian_long.yml` is included by nothing
    (`roles/kernel_build/tasks/main.yml:4-30` names no such file). `debian10.yml`
    is the same list as `debian.yml` and a Debian 10 host would run both:
    `debian10_based` (`main.yml:10`) is true and so is `debian_based and not
    ubuntu_based` (`main.yml:14`). `amazonlinux2.yml` installs EPEL 7
    (`:2-6`), runs `yumdownloader --source kernel` with no `creates`
    (`:36-37`, re-downloading the source rpm in the working directory on every
    play) and pip-installs by `shell` (`:39-40`). `ubuntu.yml:26-29` is a
    commented hack. No image of Debian 10, Amazon Linux 2, Ubuntu 20.04 or
    22.04 exists in `docker_images`. These are dropped (Recommendation).
13. The apt calls here never refresh the cache (`ubuntu.yml:1-24`,
    `debian.yml:1-19`: no `update_cache`); in the whole play the only refresh
    is the one after a sources change (item 5). The port needs the cache
    refreshed before the first apt operation (`dev_base.md`, Preserved
    knowledge 8) and again after the sources change.
14. Pop!_OS is `debian_based` and `ubuntu_based`
    (`inventories/group_vars/all:6`, `:8`), so a Pop!_OS workstation takes
    `ubuntu.yml` and the file-layout dispatch of item 1. No image builds it;
    `os` keeps it in the Debian family.

## Is the method current

Research date for every line below: 2026-10-30. Quotes and summaries are of
the pages as fetched that day. Failed fetches, not retried: the Fedora
quick-docs kernel page, the ArchWiki "Building in a clean chroot" page and the
Arch packaging GitLab PKGBUILD page (Anubis access-denied pages), the Ubuntu
wiki GitKernelBuild page (HTTP 404). The first fetch of the Ansible `apt` page
returned HTTP 429 and succeeded on the next call. No claim below rests on a
page that failed.

### deb822 sources and `deb-src`

- apt's manual page for `sources.list` describes the deb822 `.sources` format
  as intended to become the default, and says the one-line format "is
  deprecated and may eventually be removed, but not before 2029". In deb822,
  `Types: deb deb-src` stands for a `deb` and a `deb-src` line, and "A deb-src
  line is required to fetch source indexes."
  Source: https://manpages.debian.org/trixie/apt/sources.list.5.en.html (accessed 2026-10-30)
- Ubuntu's spec makes deb822 sources the default in 24.04 and moves the default
  list from `/etc/apt/sources.list` to `/etc/apt/sources.list.d/ubuntu.sources`.
  Source: https://discourse.ubuntu.com/t/spec-apt-deb822-sources-by-default/29333 (accessed 2026-10-30)
- Ubuntu's kernel team documents the same edit this role makes: for 24.04 and
  newer, add `deb-src` to the `Types:` line of `ubuntu.sources`, then
  `apt update`, then `apt build-dep`.
  Source: https://documentation.ubuntu.com/kteam-docs/public/how-to/build-kernel.html (accessed 2026-10-30)
- Verdict: the deb822 branch is current and is what Debian 12 and 13 and
  Ubuntu 24.04 and 26.04 need. The one-line branch serves layouts older than
  24.04 (Ubuntu) and 12 (Debian); the manual page keeps the format supported
  until at least 2029, but no image in the fleet uses it.
- Observed 2026-10-30 (see Local probes): all four Debian-family images ship
  deb822 files with two `Types: deb` stanzas.
- Open: whether a Pop!_OS workstation uses deb822 files:
  `ls /etc/apt/sources.list.d/*.sources` on a Pop!_OS host. If it prints
  nothing, the host takes the dropped legacy branch.

### `apt build-dep`

- The Ansible `apt` module documents `build-dep` as "ensures the package build
  dependencies are installed", does not refresh the cache unless asked
  (`update_cache`), and treats an explicit `cache_valid_time` as implying
  `update_cache=yes`. Both `ubuntu.yml:2-5` and `debian.yml:16-19` give no
  `update_cache`, which matches Preserved knowledge 13.
  Source: https://docs.ansible.com/ansible/latest/collections/ansible/builtin/apt_module.html (accessed 2026-10-30)
- Debian's kernel handbook, section 4.5.1 (Preparation), runs `apt-get
  build-dep linux` after installing `build-essential`, and says it installs
  the packages the kernel build needs. The page does not mention `deb-src`.
  Source: https://kernel-team.pages.debian.net/kernel-handbook/ch-common-tasks.html (accessed 2026-10-30)
- The Ubuntu kernel guide runs `apt build-dep -y linux
  linux-image-unsigned-<running kernel version>` and then installs `fakeroot
  llvm libncurses-dev dwarves`; the role passes only `linux` and installs
  `llvm` and `build-essential` through `dev_common` (`fakeroot` comes with
  `build-essential`'s dependencies; not checked against the image).
  Source: https://documentation.ubuntu.com/kteam-docs/public/how-to/build-kernel.html (accessed 2026-10-30)
- Verdict: `build-dep linux` is the documented method on both families. The
  role's extra libraries (`debian.yml:2-14`) are the YAML's own list; the
  handbook does not name them. The Ubuntu page's second argument targets the
  running kernel's source package, which has no meaning inside a container.
- Open: the build-dep package set is archive-dependent. The oracle's package
  capture of a fresh kernel_build-ubuntu2404 against its dev_base parent
  settles whether two builds on different days differ.

### RedHat family kernel build dependencies

- The Fedora wiki lists `fedpkg fedora-packager rpmdevtools ncurses-devel
  pesign grubby` as build tools and installs the build dependencies with
  `dnf builddep kernel.spec` from the source tree, not from a fixed list.
  Source: https://fedoraproject.org/wiki/Building_a_custom_kernel (accessed 2026-10-30)
- Verdict: `redhat.yml:7-40` is a fixed approximation of what `dnf builddep`
  computes from the spec. It works as a list of names; it does not follow the
  spec when the spec changes. No fetched vendor page names `kabi-dw` or
  `libbabeltrace-devel`.
- Observed 2026-10-30 (see Local probes): all 30 requested names are installed
  on the six RedHat-family kernel_build images, so every name resolves in the
  repositories as they were at build time.
- Open: whether the spec-derived set differs: `dnf builddep --assumeno
  kernel.spec` against the same image. Not needed for equivalence.

### pip upgrade on the RedHat family

- pip's documentation gives `python -m pip install --upgrade pip` as the way
  to upgrade, and says a pip installed by a Linux package manager may have been
  modified by its redistributor.
  Source: https://pip.pypa.io/en/stable/installation/ (accessed 2026-10-30)
- PEP 668 puts the `EXTERNALLY-MANAGED` marker in the standard library
  directory, and recommends distros keep locally installed packages under
  `/usr/local` and distro packages under `/usr`, with the local path first on
  `sys.path`. This is the layout the upgrade produces on the RedHat family,
  where no marker exists (`dev_base.md`, Is the method current).
  Source: https://peps.python.org/pep-0668/ (accessed 2026-10-30)
- Verdict: current. The `pip` module's `state: latest` upgrades the one
  requirement and writes to `/usr/local` as root on the RedHat family, as
  observed.
- Observed 2026-10-30 (see Local probes): after the playbook, `pip` runs from
  `/usr/local/lib/python3.N/site-packages` at 26.0.1 or 26.2.2 on the six
  RedHat-family images while the rpm copy stays at 21.3.1, 23.3.2, 25.1.1 or
  26.0.1 in `/usr/lib`.

### Arch kernel build tools

- `pkgctl repo clone` clones "Git packaging repositories from the canonical
  namespace", which is how `devtools` (the `pkgctl` provider) gets the kernel
  PKGBUILD; `--protocol https` selects HTTPS. A search summary of the ArchWiki
  Arch Build System page agrees (secondary; the wiki pages themselves failed
  to fetch).
  Source: https://man.archlinux.org/man/pkgctl-repo-clone.1.en (accessed 2026-10-30)
- The kernel documentation's Rust quick-start gives `pacman -S rust rust-src
  rust-bindgen` for Arch, which are three of the seven names in
  `archlinux.yml:5-14`, and says the standard library source is required
  because the build cross-compiles `core`.
  Source: https://www.kernel.org/doc/html/latest/rust/quick-start.html (accessed 2026-10-30)
- Verdict: current. `pahole`, `pacman-contrib`, `bc` and `devtools` are the
  role's own choices for `makepkg`; no fetched page lists them.
- Open: what `makepkg --syncdeps` installs on a fresh arch image:
  `pkgctl repo clone linux` and `makepkg --printsrcinfo` in the clone, then
  compare its `makedepends` to the seven names.

### Local probes

Read-only probes run on 2026-10-30 against the local images. Command form:
`docker run --rm --entrypoint sh resurgentech/<image>:latest -c '<probe>'`.
Image ids (prefix) of `dev_base-*`: debian12 e239d7815186, debian13
19e74579ec9a, ubuntu2404 fe460532b3f5, ubuntu2604 0f14538424d0, fedora43
f36a855cdbcf, fedora44 dae87e249269, rockylinux9 fe337172380d, rockylinux10
89c355246bfe, almalinux9 d7534e4fc515, almalinux10 cd0a1d6bff2e, amazonlinux2023
ccf51e94e708, arch 7f22abfc5927, omarchy f0182b1584c2. Image ids of
`kernel_build-*`: debian12 3331db9d2cd3, debian13 a6debf75afcc, ubuntu2404
1ae89290fc4b, ubuntu2604 df386815b022, fedora43 b6fd520f641c, fedora44
0c43019b6cd2, rockylinux9 916239c96699, rockylinux10 003835161d64, almalinux9
ca1bf28a47b7, almalinux10 be3c8b83a095, amazonlinux2023 2c6c4e1048f8, arch
147f680520de, omarchy 0db790480044. The `kernel_build-*` images are existing
builds of this playbook; their state is the oracle's reference.

| Probe | Result (2026-10-30) |
|---|---|
| `ls /etc/apt/sources.list /etc/apt/sources.list.d; grep -H "^Types:" /etc/apt/sources.list.d/*.sources` on `dev_base-` and `kernel_build-` debian12, debian13, ubuntu2404, ubuntu2604 | dev_base: `debian.sources` (debian12, debian13) or `ubuntu.sources` (ubuntu2404, ubuntu2604) with two `Types: deb` stanzas; kernel_build: the same file with two `Types: deb deb-src` stanzas. No `sources.list` on debian12/13; on ubuntu2404 and ubuntu2604 a `sources.list` with 0 `^deb-src` lines (270 bytes on ubuntu2404, the comment stub). No `sources.list.ansible*` file left anywhere |
| `ls /var/lib/apt/lists \| wc -l` on `dev_base-debian12` and `kernel_build-debian12` | 0 and 0: the apt lists are deleted at the end of each image layer |
| `/tmp/t/run.sh`: the body of `apt_sources_list.yml:5-20` with its paths pointed at `/tmp/t/sources.list`, run in `dev_base-debian12` on a file holding one `deb` line | stderr: `sed: can't read ...ansible-src: No such file or directory`, `cat: ...: No such file or directory`, `rm: cannot remove ...`; exit status 0; the file is unchanged and `SOURCES_LIST_CHANGED` is not printed |
| same script, file holding a `deb` line and a `# deb-src` line | prints `SOURCES_LIST_CHANGED`; the second line becomes `deb-src ...` |
| `python3 -m pip --version; python3 -m pip list -v \| grep -i "^pip "; ls /usr/local/bin` on `dev_base-` and `kernel_build-` fedora43, fedora44, rockylinux9, rockylinux10, almalinux9, almalinux10 | dev_base: pip from `/usr/lib/python3.N/site-packages` (rpm) at 25.1.1, 26.0.1, 21.3.1, 23.3.2, 21.3.1, 23.3.2; `/usr/local/bin` holds `pyaml uv uvx`. kernel_build: pip from `/usr/local/lib/python3.N/site-packages` at 26.2.2 (fedora43, fedora44, rockylinux10, almalinux10) or 26.0.1 (rockylinux9, almalinux9); `/usr/local/bin` holds `pip pip3 pip3.N pyaml uv uvx` (N = 14, 14, 9, 12, 9, 12) |
| same on `dev_base-` and `kernel_build-amazonlinux2023` | pip 21.3.1 from `/usr/lib/python3.9` (rpm) in both; `/usr/local/bin` holds `pyaml uv uvx` in both |
| same on arch, omarchy, debian12, ubuntu2404 | pip 26.2.2 (arch, omarchy) from `/usr/lib/python3.14/site-packages`, 23.0.1 (debian12) and 24.0 (ubuntu2404) from `/usr/lib/python3/dist-packages`, identical in dev_base and kernel_build; `/usr/local/bin` holds `uv uvx`, except kernel_build-ubuntu2404 which also holds `just` (6.5 MB, owner uid 1001, mtime Oct 15, older than `uv` at Oct 27) |
| `rpm -q --whatprovides <name>` for each name of `redhat.yml:7-40` on the six RedHat-family `kernel_build-` images | every name resolves; differing installed names: `java-devel` to `java-25-openjdk-devel` (fedora43, fedora44), `java-17-openjdk-devel` (rockylinux9, almalinux9), `java-21-openjdk-devel` (rockylinux10, almalinux10); `zlib-devel` to `zlib-ng-compat-devel` (fedora43, fedora44, rockylinux10, almalinux10); `perl(ExtUtils::Embed)` to `perl-ExtUtils-Embed` (all six) |
| same for the names of `redhat.yml:7-40` on `kernel_build-amazonlinux2023` | `redhat-rpm-config` is provided by `amazon-rpm-config`; `java-devel`, `libnl3-devel`, `kabi-dw`, `libbabeltrace-devel` are not installed (none is in `amazonlinux2023.yml:2-30`); `perl(ExtUtils::Embed)` to `perl-ExtUtils-Embed` |
| `dpkg -s <name>` for each name of `ubuntu.yml:10-23` on `kernel_build-ubuntu2404` and `-ubuntu2604` | all installed except `libbabeltrace-ctf-dev` (dpkg state `un`); `/var/lib/dpkg/status` has `libbabeltrace-dev` with `Provides: libbabeltrace-ctf-dev (= 1.5.11-3build3)` on ubuntu2404 |
| `dpkg -s <name>` for each name of `debian.yml:4-13` on `kernel_build-debian12` and `-debian13` | all installed |
| `dpkg -l \| grep -c ^ii` | dev_base-ubuntu2404 769, kernel_build-ubuntu2404 857; dev_base-ubuntu2604 773, kernel_build-ubuntu2604 876; kernel_build-debian12 939; kernel_build-debian13 943 |
| `command -v rustc bindgen rustup` on all 13 `dev_base-` and `kernel_build-` images | no output on any dev_base; kernel_build: `rustc` on ubuntu2404 and ubuntu2604 only; `rustc` and `bindgen` on arch and omarchy; nothing else; `rustup` nowhere |
| `pacman -Q <name>` for each name of `archlinux.yml:5-13` on `kernel_build-arch` and `-omarchy` | all installed; `rust` and `rustup` are not installed on dev_base-arch, `rustup` is not installed on kernel_build |

Open: `just` in `kernel_build-ubuntu2404` is installed by no role of this
playbook. `docker history --no-trunc resurgentech/kernel_build-ubuntu2404:latest`
names the layer that added it; the oracle needs both sides built from the same
base, so rebuild the chain before it runs.

Not probed: `apt-get -s build-dep linux` (the package set that `linux`
declares; needs a network refresh, so not read-only) and the package lists of
almalinux and rockylinux beyond the names above.

## Recommendation and decision

### Options

1. Port 1:1, with no-op duplicates removed. `src_repos` becomes an edit of the
   `*.sources` files plus a cache refresh, dispatched on the file layout;
   `kernel_build` becomes per-family package tables with each family's order
   kept (Ubuntu `build-dep` first, Debian last), the RedHat `pip` upgrade
   kept, and the build-dep after the sources change and its refresh.
   For: the oracle passes with no argument; every quirk is kept and recorded.
   Against: carries the unpinned pip upgrade and the archive-dependent
   build-dep set.
2. Port and tidy in the same step: drop the RedHat `pip` upgrade, normalise
   the Ubuntu and Debian order, derive the RedHat list from
   `dnf builddep`. For: a smaller, self-explanatory role. Against: the pip
   upgrade shows in `/usr/local/bin` and the package set, so a diff cannot be
   told from a port bug.
3. Keep the legacy sources.list branch as well. For: nothing breaks on a host
   with a one-line layout. Against: no image reaches it; the branch is broken
   as written (Preserved knowledge 2), so porting it means porting a fix the
   oracle cannot check.

### Position

Option 1 now, with the tidy items recorded as "after equivalence" per Open
question 3 and made only once the 13-image oracle is green.

Port now (these do not show in the oracle diff):

- Dispatch `src_repos` on the presence of `/etc/apt/sources.list.d/*.sources`
  (Preserved knowledge 1). Edit exactly the lines `Types: deb`, skip if any
  `*.sources` has `deb-src`, then refresh the apt cache only when something
  changed (items 4 and 5).
- Run `build-dep linux` after the sources change and its cache refresh, on
  both Ubuntu and Debian; Ubuntu places it before its extra packages and
  Debian after (item 6). If a merge moves it, the role gets a `barrier()`.
- Keep the RedHat-only `pip` latest, before the dnf install (item 7), using
  the system `python3`.
- Per-family package tables exactly as in Outcomes; Amazon 2023 stays a
  separate table from RedHat (item 9); Arch matches by `os_family`.
- Drop the repeated Python-library installs that `dev_common` already did
  (item 11); the only new Python name is `python3-lxml`.
- The second `dev_common` run is `dev_common`'s port, reviewed in
  `dev_base.md`; nothing here ports its `uv` step again.

Dropped branches (no image reaches them; recorded here, not ported):

- Debian 10: `debian10.yml`, `main.yml:8-10`, flag
  `inventories/group_vars/all:7`.
- Amazon Linux 2: `amazonlinux2.yml`, `main.yml:20-22`, flag
  `inventories/group_vars/all:9`.
- `debian_long.yml`: included by nothing.
- The legacy `sources.list` branch, `apt_sources_list.yml`, reached only when
  no `*.sources` file exists (`main.yml:14-15`). Consequence: on a host with a
  one-line layout (an older Debian or Ubuntu workstation, or a Pop!_OS host
  with no `*.sources` file) the port does nothing for sources and `build-dep`
  fails for lack of `deb-src` lines. The YAML failed there too, except for the
  commented `# deb-src` case (item 2).
- Ubuntu 20.04 and 22.04 flags (`inventories/group_vars/all:11-12`): neither
  role reads them.
- The flags stay in `group_vars` for other roles until those are ported.

Bugs the oracle cannot see: the legacy branch's `.ansible-src` file
(`apt_sources_list.yml:8-10`) is one, and it is dropped with the branch. None
other found in the branches an image reaches.

After equivalence (change what the oracle sees; not made yet):

- Remove the RedHat `pip` latest (`redhat.yml:2-5`) or pin pip; removing it
  removes `pip`, `pip3` and `pip3.N` from `/usr/local/bin` and the second pip
  tree. Decide whether the build scripts need a newer pip than the rpm copy.
- Replace the fixed RedHat package list with the output of `dnf builddep` on
  the spec (package list changes).
- Decide whether `python3-lxml` and the Python libraries belong to the
  kernel image or to `dev_common` (package list changes on Ubuntu).
- Name the Ubuntu build-dep source packages instead of the archive default
  (package list changes).

Open: nothing blocks the port; the Open lines under Is the method current
are checks the oracle runs anyway, except the Pop!_OS source layout.

Decision: take Option 1 with the "after equivalence" list above. Decided by
agent (agent-alone); not yet reviewed by the user.

## Port notes

Port of Option 1 (1:1). Code: `src/roles/src_repos.rs`,
`src/roles/kernel_build.rs` (roles), `src/playbooks/container.rs`
(`container/kernel_build`). `dev_common` is reused from `dev_base`. Plan
snapshots for all 13 images: `tests/plans.rs` (`kernel_build_plans`), files
`tests/plans/snapshots/plans__kernel_build__*.snap`. Citations are against
`conversion/ansible/`. The equivalence run is not recorded here yet.

What each task became:

- `playbooks/container/kernel_build.yml:5-10` (all hosts, root, roles
  `dev_common`, `src_repos`, `kernel_build`): the playbook fn
  `kernel_build_playbook` calls the three roles in that order. `dev_common`
  appears once, as in the YAML; the "second run" in this doc is the one
  after the `dev_base` image's own run.
- `src_repos/tasks/main.yml:4-9` (find `*.sources`) and `:11-15` (the two
  `include_tasks`): no glob fact exists, so the dispatch is a guard on the
  op that ports `apt_sources_deb822.yml:7-15`. The role returns early
  outside Debian, Ubuntu and Pop!_OS (`debian_based`, `group_vars/all:6`).
- `apt_sources_deb822.yml:7-15` (shell, `SOURCES_CHANGED`): kept as `sh!`,
  because no primitive edits a set of files by pattern. `unless` skips when
  no `*.sources` file exists (the YAML's other branch) or when any file has
  a `deb-src` type (`:9-11`). The sed line is the YAML's, exact `Types: deb`
  only (`:12`). `changed_if = "SOURCES_CHANGED"` is the YAML's
  `changed_when`. The op's `writes` is narrowed from `*` to
  `file:/etc/apt/sources.list.d/*.sources`: that still marks the apt cache
  stale for the next apt op and does not fence the unrelated installs
  around it.
- `apt_sources_deb822.yml:17-22` (cache update when changed): the apt cache
  rule of T6. The plan runs `apt-get update` in the first apt op after the
  sources op: the `build-dep` on ubuntu2404 and ubuntu2604, the extras
  install that precedes the `build-dep` on debian12 and debian13. One
  difference: the rule is static, so the refresh runs on every play, not
  only when the sed changed the files (an oracle-invisible cost of one
  `apt-get update`).
- `apt_sources_list.yml:1-22` and `main.yml:14-15`: dropped (legacy
  branch, Preserved knowledge 2 and 3). The never-created `.ansible-src`
  file at `:8-10` is not ported.
- `kernel_build/tasks/main.yml:4-30`: one if/else chain; the flag fns
  repeat `group_vars/all:4-6,8,10` (copies of `dev_common`'s private fns).
  `debian10`, `amazonlinux2` and `debian_long.yml` are not ported.
- `ubuntu.yml:1-5`: `h.pkg(["linux"]).build_dep()`, first. `:7-24`: one
  `h.pkg` of the extras without the four names `dev_common` already
  installed (`python3-pip`, `python3-jinja2`, `python3-yaml`,
  `python3-git`); `python3-lxml` stays.
- `debian.yml:2-14`: one `h.pkg` of the nine extras, then `:16-19`
  `build_dep()` last. The plan keeps that order: the build-dep op writes
  `*`, so no later install merges above it.
- `redhat.yml:2-5`: `h.pip(["pip"]).latest()`, before the dnf op
  (snapshots fedora43, rockylinux10: the pip op precedes the dnf op).
  `:7-40`: one `h.pkg`, 30 names as written. `:42-48` (python libs again):
  dropped, `dev_common` installs them.
- `amazonlinux2023.yml:2-30`: one `h.pkg`, 25 names, its own branch (not
  RedHat's list). `:32-38`: dropped as above. No pip upgrade, as in the
  YAML.
- `archlinux.yml:4-14`: one `h.pkg`, 7 names (`bc` repeats `dev_common` and
  is requested again, as written).

Snapshots read against Outcomes: ubuntu2404 (`build-dep linux`, then the 10
extras, `apt-get update` before the build-dep), debian12 (9 extras with the
refresh, then `build-dep`), rockylinux10 and fedora43 (pip latest, then 30
dnf names), amazonlinux2023 (25 names, no pip), arch (7 names). omarchy
matches arch, debian13 matches debian12, ubuntu2604 matches ubuntu2404.

`sh!` kept: only the sources edit (above); `repo` would replace it when
built. Dropped: the branches under Dropped branches and the repeated Python
library installs (item 11). "After equivalence" items are not made.

## Review

2026-10-30: first pass, agent-alone. Read against the mirrored originals at
79d1ca1; probed the local images; counted package names by command. Grepped
the doc for hedge words.

## skill-feedback

Input for T15 (the `ansible-port` skill, v1), from the second trial doc
(this one). Each item is adoptable or rejectable on its own.

1. The skill's levels assume one playbook with one role. Here three roles
   apply, one already documented in `dev_base.md`. The skill says a role gets
   its own doc only in two cases; neither fits a role documented in another
   playbook's doc. Adopt: say how a doc points at an existing doc for a
   shared role and what it must still say about the second application.
2. The oracle checklist has no row for "a second tool tree". The RedHat `pip`
   upgrade adds a second pip under `/usr/local/lib`, visible only through new
   `/usr/local/bin` names. Adopt: the template's mapping table notes that a
   tool upgrading itself shows in `/usr/local/bin`.
3. The best source for Outcomes was the already built images of the playbook.
   The skill lists web research and local probes of base images but not "read
   the playbook's own output image when one exists", which gave installed
   names, the pip result and the absence of a legacy branch in minutes.
   Adopt: a step in UNDERSTAND.md to probe the playbook's output image.
4. A bug inside a dropped branch needs a home. The `.ansible-src` fact is a
   finding, a preserved fact and a dropped branch at once, and the template
   offers "Bugs the oracle cannot see" and "Dropped branches" as separate
   lists. Adopt: a bug inside a dropped branch goes in Preserved knowledge
   and is named in both lists.
5. The hedge-word check is word-based, so a hedge word inside a longer word is a
   trap; it helped by forcing `Open:` lines phrased as commands. Reject
   nothing.
6. Four fetches failed (Anubis access-denied pages, a 404, a 429). The skill
   says to record a failed fetch but not where. Adopt: a line in the template
   under the research date.
7. When a task matches two classifier patterns ("Repo setup" and "Shell for a
   primitive" for the two sources tasks, "file (was `sh`)"), the table does
   not say which proposal wins. Adopt: the classifier says which to read first.
8. Citing absence worked (omits, no X), but "file included by no task"
   (`debian_long.yml`) has no convention. Adopt: cite the include list that
   would name it.
9. The doc runs long because the template wants every list per family and the
   dev_common lists are already in another doc. Adopt: allow Outcomes to say
   "no change" for a role already documented, as this doc does.
