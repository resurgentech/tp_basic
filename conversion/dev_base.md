# dev_base.yml: understanding doc

Scope: `playbooks/container/dev_base.yml` and the `dev_common` role it applies.
All file:line citations are relative to `conversion/ansible/` (byte copies of
the ansible repo at 79d1ca1). Last read against those copies on 2026-10-30.

## Purpose

`dev_base.yml` installs the common development toolchain into every image
that sits above a distro's `base` image. It runs against all hosts as root
(`playbooks/container/dev_base.yml:5-6`) and applies one role,
`dev_common` (`playbooks/container/dev_base.yml:7-8`). The role dispatches on
distro flags to one task file per family (`roles/dev_common/tasks/main.yml:4-22`),
then adds Python libraries by pip where the distro allows it
(`roles/dev_common/tasks/main.yml:26-32`) and installs `uv`
(`roles/dev_common/tasks/main.yml:34-37`).

Who runs it:

- `docker_images` runs it as the `dev_base` container, parent `base`, for
  all 13 distros (`../docker_images/docker-bake.hcl`, `CONTAINERS` and
  `DISTROS`): debian12, debian13, ubuntu2404, ubuntu2604, fedora43, fedora44,
  rockylinux9, rockylinux10, almalinux9, almalinux10, amazonlinux2023, arch,
  omarchy.
- `kernel_build.yml:8`, `rust.yml:8` and `latest_kernel_build.yml:8` apply
  `dev_common` again on top of `dev_base`, so every later image re-runs this
  role.
- Workstations (including Pop!_OS) run it through the same flags
  (`inventories/group_vars/all:6`).

The ansible side of each image build is `Dockerfiles/ansible.{debian,redhat,arch}`
in `docker_images`. Each does a full package upgrade, clones the ansible repo,
runs `./run targets <playbook> inventories/localhost.yml` with
`ansible_user=root`, then cleans caches. The upgrade and the cleanup belong to
the Dockerfile, not to this playbook.

## Outcomes

The observable end state. This is the oracle's checklist (T18): per image the
oracle compares package names and arch, system pip names, rustup state,
`/etc/apt/sources.list*` paths and content, and `/usr/local/bin` names. The
state below is what this playbook adds on top of the `base` image; the base
image's own packages (git, ansible, and so on) are identical before and after
the port.

### Debian family (debian12, debian13, ubuntu2404, ubuntu2604; Pop!_OS on workstations)

Selected by `debian_based` (`inventories/group_vars/all:6`). Tasks:
`roles/dev_common/tasks/debian.yml:1-50`.

- Packages installed by apt: `python3-apt`, `python3-pip` (`debian.yml:4`);
  `build-essential`, `cmake`, `clang`, `llvm`, `lld`, `git`, `rsync`, `gcc`,
  `gnupg`, `rpm`, `cppcheck`, `autoconf`, `asciidoc`, `bc`, `cpio`, `bison`,
  `flex`, `gawk`, `gettext`, `gzip`, `hostname`, `m4`, `net-tools`,
  `openssl`, `xmlto`, `zstd`, `diffstat`, `sshpass`, `btop`, `acl`, `curl`
  (`debian.yml:9-41`); `python3-jinja2`, `python3-git`, `python3-yaml`,
  `python3-hvac` (`debian.yml:46-50`).
- pip: no pip installs (`main.yml:32` skips Debian). The Python libraries
  arrive as the apt packages above.
- apt sources: no change to `/etc/apt/sources.list*`. The role adds no
  repository.
- rustup: absent. This role installs no Rust.
- `/usr/local/bin`: gains `uv` and `uvx`.

### RedHat family (fedora43, fedora44, rockylinux9, rockylinux10, almalinux9, almalinux10)

Selected by `redhat_based` (`inventories/group_vars/all:4`). Tasks:
`roles/dev_common/tasks/redhat.yml:1-31`.

- Packages installed by dnf: the group `@Development Tools`
  (`redhat.yml:6`) plus `cmake`, `clang`, `llvm`, `lld`, `bison`, `flex`,
  `git`, `rsync`, `gcc`, `zlib-devel`, `gnupg`, `bc`, `newt`, `slang`,
  `xmlto`, `net-tools`, `rpm-build`, `dpkg-devel`, `dpkg`, `dpkg-dev`,
  `zstd`, `python3`, `python3-devel`, `python3-docutils`, `python3-pip`
  (`redhat.yml:7-30`). Requested names resolve through package provides, so
  the installed rpm name can differ from the requested name (`gnupg`); the
  oracle records installed names. `base.el` enables EPEL and CRB before this
  playbook runs (outside this repo); the EL images need them for packages
  such as `dpkg-dev` and `*-devel`. Observed 2026-10-30 (see Local probes):
  `dpkg`, `dpkg-dev`, `dpkg-devel` are served by `epel` on Rocky 9.
- pip: `jinja2`, `GitPython`, `pyaml` (`main.yml:27-31`) installed to the
  system interpreter, with their dependencies (PyYAML, MarkupSafe, gitdb,
  smmap). pip leaves an already-installed distro copy of an unpinned
  requirement in place, so the pip names the oracle sees depend on what the
  base image installed. Observed 2026-10-30 (see Local probes): no RedHat or
  Amazon base image has pip, `git` (GitPython) or `pyaml` importable, so those
  two always arrive by pip; Jinja2 and PyYAML are already importable
  (rpm-provided) on fedora43, fedora44 and rockylinux10, and absent on
  rockylinux9 and amazonlinux2023, where pip installs them. Open: almalinux9
  and almalinux10 were not probed for Jinja2/PyYAML; the `pip list` capture
  settles them.
- Repos: none added by this role.
- rustup: absent.
- `/usr/local/bin`: gains `uv` and `uvx`.

### Amazon Linux 2023 (amazonlinux2023)

Selected by `amazonlinux2023_based` (`inventories/group_vars/all:10`); Amazon
is not in `redhat_based` (`inventories/group_vars/all:4`), so `redhat.yml`
never runs here. Tasks: `roles/dev_common/tasks/amazonlinux2023.yml:1-25`.

- Packages installed by dnf: `@Development Tools` (`amazonlinux2023.yml:5`)
  plus `cmake`, `clang`, `llvm`, `lld`, `git`, `rsync`, `gcc`, `zlib-devel`,
  `bc`, `newt`, `slang`, `xmlto`, `net-tools`, `rpm-build`, `zstd`, `wget`,
  `python3`, `python3-devel`, `python3-pip` (`amazonlinux2023.yml:6-24`). It
  differs from the RedHat list: no `gnupg`, `bison`, `flex`, `dpkg*`,
  `python3-docutils`; adds `wget`.
- pip: `jinja2`, `GitPython`, `pyaml` (`main.yml:27-31`), as in the RedHat
  family.
- rustup: absent. `/usr/local/bin`: gains `uv` and `uvx`.

### Arch family (arch, omarchy)

Selected by `arch_based`, which tests `ansible_os_family`, not the
distribution name (`inventories/group_vars/all:5`). Tasks:
`roles/dev_common/tasks/archlinux.yml:1-24`.

- Packages installed by pacman: `base-devel`, `cmake`, `clang`, `llvm`,
  `lld`, `git`, `rsync`, `gnupg`, `bc`, `cpio`, `xmlto`, `zstd`, `wget`,
  `python`, `python-pip`, `python-yaml`, `python-jinja`, `python-gitpython`,
  `python-pytest` (`archlinux.yml:5-23`).
- pip: no pip installs (`main.yml:32` skips Arch).
- Repos: none added by this role (the Omarchy repo comes from
  `docker_images/Dockerfiles/base.omarchy`).
- rustup: absent. `/usr/local/bin`: gains `uv` and `uvx`.

### Every image

- `/usr/local/bin/uv` and `/usr/local/bin/uvx` exist and run
  (`main.yml:35`; the installer's binary list is `uv uvx`, see
  Is the method current).
- No other new name in `/usr/local/bin`.
- Shell profiles are not edited: the installer skips profile edits when its
  install directory is already on `PATH`, and `/usr/local/bin` is. Observed
  2026-10-30 in ubuntu:24.04: `~/.profile` and `~/.bashrc` hold no uv lines
  after the install; the installer does create `~/.config/uv`.
- The uv version is whatever the installer script carries on the day of the
  build. The oracle compares names, not versions, so this is not an
  equivalence point.

### Mapping to the oracle checklist

| Oracle item | Debian family | RedHat family | Amazon 2023 | Arch family |
|---|---|---|---|---|
| package names + arch | apt list above | dnf list above | dnf list above | pacman list above |
| system pip names | distro-packaged Jinja2, GitPython, PyYAML, hvac | + pip Jinja2, GitPython, pyaml | same as RedHat | distro-packaged only |
| rustup state | absent | absent | absent | absent |
| /etc/apt/sources.list* | unchanged | n/a | n/a | n/a |
| /usr/local/bin names | uv, uvx | uv, uvx | uv, uvx | uv, uvx |

## Current method

_Generated by `tp classify playbooks/container/dev_base.yml`._

14 tasks in scope; 8 match no pattern and are plain module calls. A task is listed under every pattern it matches, so pattern counts overlap and do not sum to the task total.

### By pattern

| Pattern | Tasks | Proposed telepatch primitive |
|---|---|---|
| Distro dispatch | 6 | typed `os` fact and a `match`, or a per-family table on `pkg` |
| Per-user loop | 0 | `for u in users { let s = h.as_user(u); ... }`; the login shell is a fact of the user |
| Hand-rolled ensure | 0 | `sh!(..).unless(check)` or `.creates(path)` |
| Version pinning | 0 | `bin_version` fact plus the ensure combinator |
| Repo setup | 0 | `repo` primitive; one cache update per window |
| Shell for a primitive | 0 | the matching primitive (`svc`, `file`, `pkg`, `user`), not `sh` |
| Controller-side gather | 0 | `secret`, `fetch`, `local` (prepare phase) |
| Handler | 0 | a guard on the restart op; identical guarded ops merge |

#### Distro dispatch (6 tasks)

Becomes: typed `os` fact and a `match`, or a per-family table on `pkg`

- `roles/dev_common/tasks/main.yml:4` dev_common_debian (include_tasks -> Rust control flow)
- `roles/dev_common/tasks/main.yml:8` dev_common_redhat (include_tasks -> Rust control flow)
- `roles/dev_common/tasks/main.yml:12` dev_common_amazonlinux2 (include_tasks -> Rust control flow)
- `roles/dev_common/tasks/main.yml:16` dev_common_amazonlinux2023 (include_tasks -> Rust control flow)
- `roles/dev_common/tasks/main.yml:20` dev_common_archlinux (include_tasks -> Rust control flow)
- `roles/dev_common/tasks/main.yml:26` Various python dependancies (pip -> pkg::pip)

### By module category

| Category | Tasks | Modules | Proposed telepatch primitive |
|---|---|---|---|
| pkg | 8 | apt 3, dnf 2, pacman 1, pip 1, yum 1 | pkg, pkg::pip |
| sh | 1 | shell 1 | sh |
| control | 5 | include_tasks 5 | Rust control flow |

### Unclassified

None.

### Skipped: out of scope

None.

Regeneration: from the telepatch checkout run
`cargo run -q -p tp -- classify ../tp_basic/conversion/ansible/playbooks/container/dev_base.yml`
and paste its output over this section unedited (from `## Current method`
through `### Skipped: out of scope`). Regenerate whenever the YAML changes.

## Preserved knowledge

Each item is something the YAML knows that a port must keep. Citations are
file:line against `conversion/ansible/`.

1. Amazon Linux is not in `redhat_based`. The list at
   `inventories/group_vars/all:4` omits `Amazon`, so Amazon never takes the
   `redhat.yml` branch and has its own task file per release
   (`roles/dev_common/tasks/main.yml:12-18`). `docker-bake.hcl` maps
   amazonlinux2023 to the `redhat` Dockerfile, which only chooses `dnf`; the
   playbook still sees `ansible_distribution == Amazon`. A port's `os` fact
   must keep Amazon apart from the RedHat family.
2. PEP 668: Debian and Arch Python is externally managed, so the role skips
   pip there and installs the libraries as distro packages
   (`main.yml:24-25`, `main.yml:32`, `debian.yml:44-50`,
   `archlinux.yml:20-23`). The port keeps this split: pip for the RedHat
   family and Amazon, distro packages for Debian and Arch.
3. The task named "Ubuntu2404 python deps" (`debian.yml:44`) has no `when`,
   so it runs on every Debian-family host: Debian 12 and 13, Ubuntu 24.04 and
   26.04, Pop!_OS. The name is wrong; the behaviour is the Debian-wide one.
   `ubuntu2404_based` (`inventories/group_vars/all:13`) is not consulted.
   Keep the behaviour, drop the name.
4. `python3-hvac` and `python3-apt` are there for Ansible itself.
   `python3-hvac` is commented "for vault/openbao in ansible"
   (`debian.yml:50`). `python3-apt` is what Ansible's `apt` module imports on
   the target (`debian.yml:4`). Neither serves a developer. They stay until
   equivalence passes (see Recommendation).
5. The uv installer re-runs on every play. The task has no `creates`, no
   guard and no `changed_when` (`main.yml:34-37`), so it downloads and
   replaces `uv` and `uvx` each time and always reports changed. Because
   `kernel_build.yml:8`, `rust.yml:8` and `latest_kernel_build.yml:8` re-apply
   the role, every later image re-installs uv. The script is unpinned and
   piped from the network without a checksum.
6. Only the Debian branch installs `curl` (`debian.yml:41`). The uv step
   needs `curl` (`main.yml:35`); on RedHat, Amazon and Arch it relies on the
   base image shipping one (observed 2026-10-30: those bases have it, the
   Debian and Ubuntu bases do not; see Local probes). A port that drops the dependency on the base
   image must add `curl` to those branches.
7. `pyaml` is not `PyYAML`. The pip list installs `pyaml` (`main.yml:31`),
   while Debian and Arch install `python3-yaml`/`python-yaml`
   (`debian.yml:49`, `archlinux.yml:20`), which is PyYAML. Keep both names as
   written; `pyaml` pulls PyYAML as a dependency on the pip branch.
8. The `apt` calls never refresh the cache (`debian.yml:2-5`; the module's
   default is no refresh). The Dockerfile does `apt-get update` first
   (`../docker_images/Dockerfiles/ansible.debian`). A port must refresh the
   cache once before the first install.
9. The Dockerfiles run a full upgrade before the playbook
   (`ansible.debian`: `apt-get upgrade -y`; `ansible.redhat`: `dnf update -y`;
   `ansible.arch`: `pacman -Syu`). The arch Dockerfile says why: no partial
   upgrade. The playbook does not upgrade. Keep the upgrade in the Dockerfile.
10. `@Development Tools` is a quoted group name on RedHat and Amazon 2023
    (`redhat.yml:6`, `amazonlinux2023.yml:5`). Group names differ between dnf
    versions (see Is the method current). The explicit `gcc` beside the group
    (`redhat.yml:14`, `amazonlinux2023.yml:12`) keeps a compiler present
    whatever the group holds.
11. `arch_based` tests `ansible_os_family`, the other flags test
    `ansible_distribution` (`inventories/group_vars/all:5` against `:4`,
    `:6`). Omarchy reaches the Arch branch only through `os_family`.
12. `dpkg-devel`, `dpkg`, `dpkg-dev` exist on the RedHat branch
    (`redhat.yml:22-25`) and not on Amazon (`amazonlinux2023.yml`); the Amazon
    2 file says `dpkg-dev` was lost (`amazonlinux2.yml:18`). EL gets them from
    repos enabled in `base.el`, not from this repo.
13. Harmless redundancy: `rsync` is listed twice (`debian.yml:16`,
    `debian.yml:34`); `gcc` sits beside `build-essential` (`debian.yml:10`,
    `debian.yml:17`) and `base-devel`. A package set deduplicates; the port may
    list each name once.
14. Pop!_OS belongs to `debian_based` and `ubuntu_based`
    (`inventories/group_vars/all:6`, `:8`). Workstations use it, so `os` keeps
    Pop!_OS as a Debian-family member even though no image builds it.

## Is the method current

Research date for every line below: 2026-10-30. Quotes and summaries are of
the pages as fetched that day.

### uv installer

- The documented way to choose the install directory is `UV_INSTALL_DIR`;
  `UV_NO_MODIFY_PATH` disables shell profile edits; `UV_UNMANAGED_INSTALL`
  installs to a fixed path, prevents profile edits and disables self-update.
  Source: https://docs.astral.sh/uv/reference/installer/ (accessed 2026-10-30)
- The installer script itself (`APP_VERSION="0.13.6"` in the copy fetched):
  installs the binaries `uv uvx`, moves them into the install directory every
  run, and skips profile edits when the install directory is already on
  `PATH`. Source: https://astral.sh/uv/install.sh (accessed 2026-10-30)
- Verdict: the `curl ... install.sh | UV_INSTALL_DIR=... sh` form
  is still the documented method. `UV_INSTALL_DIR=/usr/local/bin` is valid
  and produces the `uv` and `uvx` the Outcomes require. `UV_UNMANAGED_INSTALL`
  is the stricter option for a system install. The reference page does not say
  whether a re-run skips an existing install; the script moves over it.
- Observed 2026-10-30 (see Local probes): a second run on an installed,
  identical version reinstalls both binaries (new inodes) and prints
  "everything's installed!" again, so the task is not a no-op on re-run.

### `@Development Tools` under dnf5

- Fedora 41 and later use dnf5. A Fedora forum report states the display name
  fails to install ("No match") while the group ID `development-tools` works.
  Source: https://discussion.fedoraproject.org/t/cant-install-development-tools-on-fedora-linux-silverblue-41/134864 (accessed 2026-10-30)
- A secondary guide reports `dnf group install` matches IDs only on dnf5 and
  that on Fedora the group of that name holds no compiler, while on Rocky 10
  it carries gcc, g++, make and gdb. It is not an official document.
  Source: https://computingforgeeks.com/install-development-tools-fedora/ (accessed 2026-10-30)
- Ansible's `dnf` module documents the `'@Development tools'` form and
  selects a `dnf5` backend by `use_backend`.
  Source: https://docs.ansible.com/ansible/latest/collections/ansible/builtin/dnf_module.html (accessed 2026-10-30)
- Verdict: the display-name form in `redhat.yml:6` is the fragile part on
  fedora43 and fedora44. The explicit `gcc`, `clang`, `bison`, `flex` in the
  same list (`redhat.yml:7-14`) cover the compiler gap if the group content
  differs. A telepatch `pkg` table should name the group per family, because
  the ID is not the same everywhere (next bullet).
- Observed 2026-10-30 (see Local probes): fedora43 and fedora44 run dnf5
  (5.2.18 and 5.4.6). On both, `dnf group info` resolves "Development Tools"
  to id `development-tools`, but `dnf install "@Development Tools"` fails with
  "No match for argument: Development Tools". Rocky 9 and 10 and Amazon 2023
  run dnf 4 (4.14.0, 4.20.0, 4.14.0); on them the ID `development-tools` does
  not exist ("Group development-tools does not exist") and the name
  "Development Tools" is the group. So the ID form is Fedora-only.
- Open: whether the Ansible `dnf` module (rather than the dnf5 CLI) resolves
  `@Development Tools` on fedora43 and fedora44. Settled by the oracle's
  package capture from the existing dev_base images (T18).

### PEP 668

- PEP 668 is Final. A distro marks an interpreter by placing an
  `EXTERNALLY-MANAGED` file in the standard library directory; pip then
  refuses installs outside a virtual environment unless told otherwise. The
  PEP's worked example is Debian.
  Source: https://peps.python.org/pep-0668/ (accessed 2026-10-30)
- Fedora does not ship the marker: the change proposal targeted Fedora 38 and
  a maintainer stated on 2023-11-09 that it was never submitted.
  Sources: https://fedoraproject.org/wiki/Changes/PythonMarkExternallyManaged (accessed 2026-10-30)
  and https://discussion.fedoraproject.org/t/status-of-marking-the-base-python-environment-as-externally-managed-pep-668/95164 (accessed 2026-10-30)
- Verdict: the Debian/Arch-versus-rest split at `main.yml:24-32` matches the
  state of Fedora (pip works as root) and the PEP's Debian example. The role's
  claim for Arch rests on the in-repo comment alone.
- Observed 2026-10-30 (see Local probes): the marker exists on debian12,
  debian13, ubuntu2404, ubuntu2604, arch and omarchy; it is absent on
  fedora43, fedora44, rockylinux9/10, almalinux9/10 and amazonlinux2023. This
  confirms the split at `main.yml:32` on all 13 images.

### Ansible `apt` module needs python3-apt

- The module lists `python3-apt` as a requirement on the executing host and
  does not refresh the cache unless asked.
  Source: https://docs.ansible.com/ansible/latest/collections/ansible/builtin/apt_module.html (accessed 2026-10-30)
- Verdict: `python3-apt` (`debian.yml:4`) serves Ansible and stays for as long
  as Ansible applies the role.

### Local probes

Read-only probes run on 2026-10-30 against the pinned local base images (all
`resurgentech/base-<distro>:latest`; image id prefixes: debian12 f2a7c8935977,
debian13 eb20f9fa4b92, ubuntu2404 19733c3865dd, ubuntu2604 db4dea6389df,
fedora43 5c79697e7c5d, fedora44 2b99cad1c4a8, rockylinux9 1ddbb63701bc,
rockylinux10 7accaf98f669, almalinux9 37b1370908ce, almalinux10 5c6804d3afdf,
amazonlinux2023 8928b8d1d3bd, arch 8d5b4bf2baf6, omarchy 2ba09cd5f063).
Command form: `docker run --rm --entrypoint sh <image> -c '<probe>'`.

| Probe | Result (2026-10-30) |
|---|---|
| `ls /usr/lib*/python3*/EXTERNALLY-MANAGED` | present: debian12 (python3.11), debian13 (3.13), ubuntu2404 (3.12), ubuntu2604 (3.14), arch and omarchy (3.14); absent: fedora43/44, rockylinux9/10, almalinux9/10, amazonlinux2023 |
| `python3 -m pip --version` | "No module named pip" on all 13 bases |
| `command -v curl` | empty on debian12/13 and ubuntu2404/2604; present on every other base |
| `dnf --version` | dnf5 5.2.18.0 (fedora43), 5.4.6.0 (fedora44); dnf 4.14.0 (rockylinux9, almalinux9, amazonlinux2023), 4.20.0 (rockylinux10, almalinux10) |
| `dnf group info "Development Tools"` and `dnf group info development-tools` | fedora43/44: both resolve, `Id : development-tools`; rockylinux9/10, amazonlinux2023: the name resolves, the ID gives "Group development-tools does not exist" |
| `dnf install -y --setopt=tsflags=test "@Development Tools"` | fedora43/44: "No match for argument: Development Tools"; rockylinux9/10, amazonlinux2023: "Complete!" |
| `python3 -c "import jinja2, yaml"` | ok on fedora43, fedora44, rockylinux10; ModuleNotFoundError on rockylinux9 and amazonlinux2023 |
| `python3 -c "import git"`, `python3 -c "import pyaml"` | ModuleNotFoundError on fedora43, rockylinux9, rockylinux10, amazonlinux2023 |
| `dnf -q repoquery --qf "%{name} %{repoid}" dpkg-dev dpkg-devel dpkg` | `epel` for all three (rockylinux9) |
| uv installer twice in `ubuntu:24.04` (id 33ceb71981b6), `UV_INSTALL_DIR=/usr/local/bin`, script `https://astral.sh/uv/install.sh` saved 2026-10-30 as 0.13.6 | second run reinstalled `uv` and `uvx` (inodes 57762299/57762300 became 57762310/57762311, mtime unchanged); `uv --version` is 0.13.6; `/usr/local/bin` holds only `uv` and `uvx`; no uv lines in `~/.profile` or `~/.bashrc`; `~/.config/uv` created |

Not probed: the Python-module rows and the group-info and install rows for
almalinux9/10, debian and ubuntu; the group rows ran on fedora43/44,
rockylinux9/10 and amazonlinux2023 only.

## Recommendation and decision

### Options

1. Port 1:1 to telepatch. One `os` match, a per-family `pkg` table with the
   exact names above, `pkg::pip` for the RedHat family and Amazon, one `sh`
   for uv. Equivalence is exact; every known fragility is carried over.
   For: the oracle (T18) passes with no argument. Against: carries the
   re-running installer and the display-name group.
2. Port and tidy in the same step: guard the uv install, drop `python3-hvac`,
   pin the group by ID. For: a cleaner port. Against: removing a package
   and guarding the installer change what the oracle sees (package list,
   `/usr/local/bin` timestamps), so a diff cannot separate a port bug from a
   chosen change.
3. Leave it in ansible. For: no work. Against: the corpus is the migration
   target and this role is shared by four playbooks.

### Position

Option 1 now, with the tidy items recorded as "after equivalence" per Open
question 3 and made only once the 13-image oracle is green.

Port now (these do not show in the oracle diff):

- `os` fact with Debian family (including Pop!_OS), RedHat family, Amazon 2023
  and Arch family as separate variants; Amazon stays outside RedHat; Arch
  matches by `os_family`.
- Per-family package tables exactly as in Outcomes. Request names as the YAML
  does. Fix the misleading task name; run the Debian Python-libraries step on
  the whole Debian family.
- Refresh the apt cache once before the first apt install (item 8). Keep the
  full upgrade in the Dockerfile.
- Install `curl` on every branch before the uv step only if the oracle shows
  the base image lacks it (item 6); otherwise leave the base image to provide
  it.
- Deduplicate the package lists (`rsync`) (item 13). No effect on the
  installed set.

Dropped branches (no image reaches them; recorded here, not ported):

- Amazon Linux 2: `amazonlinux2.yml`, `main.yml:12-14`, flag
  `inventories/group_vars/all:9`. No image builds it.
- Debian 10: flag `inventories/group_vars/all:7`. `dev_common` does not read
  it.
- Ubuntu 20.04 and 22.04: flags `inventories/group_vars/all:11-12`.
  `dev_common` does not read them.
- Dropping affects only the `dev_common` port. The flags stay in `group_vars`
  for other roles until those are ported.

Bugs the oracle cannot see: none found in `dev_common`. The roadmap's
examples (a root looped twice, `/home/root`) belong to other roles. The
duplicate `rsync` and the "Ubuntu2404" task name are the only defects here
and are covered above.

After equivalence (change what the oracle sees; not made yet):

- Remove `python3-hvac` and `python3-apt` from Debian-family images once the
  playbook no longer depends on Ansible there (changes the package list).
- Make the uv install idempotent (guard on `/usr/local/bin/uv`) and pin its
  version (`/usr/local/bin` metadata and later images' uv version change).
  Prefer `UV_UNMANAGED_INSTALL` for a system install.
- Name the dnf group per family (ID `development-tools` on Fedora, the name
  "Development Tools" on EL and Amazon; see the probes), and decide
  whether the RedHat group content is still wanted (changes the package list
  on Fedora if the group content differs).
- Decide whether `pyaml` is wanted at all, or only PyYAML (pip list changes).
- Decide whether `python-pytest` on Arch (`archlinux.yml:23`) belongs to a
  development base (package list changes).

Open: nothing blocks the port; the Open lines under Is the method current
are checks the oracle runs anyway.

Decision: take Option 1 with the "after equivalence" list above. Decided by
agent (agent-alone); not yet reviewed by the user.

## Port notes

Port of Option 1 (1:1). Code: `src/roles/dev_common.rs` (role),
`src/playbooks/container.rs` (`container/dev_base`, registered in
`src/lib.rs`). Plan snapshots for all 13 images: `tests/plans.rs`, files in
`tests/plans/snapshots/`. Citations are against `conversion/ansible/`.

What each task became:

- `playbooks/container/dev_base.yml:5-8` (all hosts, root, role `dev_common`):
  the playbook fn `dev_base` calls `dev_common`. Root is the run's user.
- `main.yml:4-22` (five `include_tasks` on flags): one if/else chain in the
  role. The flags are small fns reproducing `group_vars/all:4-6,10`.
  `redhat_based` is distro Fedora/Rocky/Alma (or ID `centos`/`rhel`, which
  telepatch parses as `Distro::Other`). `debian_based` is distro
  Debian/Ubuntu/Pop!_OS (a Debian-family distro outside that list, such as
  Mint, gets no branch, as in the YAML). `arch_based` is family Arch (omarchy
  parses as Arch). `amazonlinux2023_based` is distro Amazon with major 2023.
  Amazon is family RedHat in telepatch but stays out of `redhat_based`.
- `debian.yml:1-5` (`apt` python3-apt, python3-pip), `:7-41` (tools),
  `:43-50` (python libs): three `h.pkg([..])` calls in YAML order. The
  optimizer merges them into one apt install ("merged from dev_common #1, #2,
  #3" in the snapshots), which also does the one apt cache refresh (item 8).
  The duplicate `rsync` (`debian.yml:34`) is not repeated (item 13). The
  third task runs on the whole Debian family, as before; its misleading name
  is gone.
- `redhat.yml:1-31`: one `h.pkg`, names and order as written, including
  `"@Development Tools"`.
- `amazonlinux2023.yml:1-25`: one `h.pkg`, names as written, in its own
  branch (Amazon 2023 only).
- `archlinux.yml:1-24`: one `h.pkg` (pacman), names as written.
- `main.yml:26-32` (pip, `when: not (debian_based or arch_based)`):
  `h.pip(["jinja2", "GitPython", "pyaml"])` under the same condition, so a
  host no flag matches also gets it, as in the YAML. pip comes from
  `python3-pip` in the RedHat and Amazon package lists; the plan orders the
  pip op after the dnf op (snapshots rockylinux10, amazonlinux2023).
- `main.yml:34-37` (uv installer): left as `sh!`. telepatch has no
  installer primitive and the decision keeps it unguarded, so it runs every
  time. The command is wrapped in `( ... )` so `set -o pipefail` does not
  leak into the persistent shell later ops share; Ansible ran it in its own
  `/bin/bash`. The op declares `writes [*]`, so on Debian it runs after the
  merged apt op that installs `curl` (snapshot ubuntu2404). Other bases ship
  curl (probes).

Dropped (as decided): `amazonlinux2.yml` and `main.yml:12-14` (Amazon Linux
2); the Debian 10 and Ubuntu 20.04/22.04 flags. Consequence: an Amazon Linux
2 host gets no package branch but would still take the pip step (the YAML's
flags say pip runs there). No image reaches it.

Left as the YAML has it, for after equivalence: `python3-hvac` and
`python3-apt`, the unguarded and unpinned uv installer, `@Development Tools`
by display name. On fedora43 and fedora44 the probes show the dnf5 CLI
rejects `Development Tools` ("No match for argument"), so the port may fail
there where the Ansible `dnf` module may not. Fedora is not in the oracle's
acceptance set; T18 settles it. telepatch's own installed-group check
(`dnf group list --installed | grep`) is also not the module's.

Equivalence result (T18): not yet run.

## Review

2026-10-30: second pass, re-read against the YAML and the Dockerfiles line
by line, with package counts rechecked by command (`grep -c` over each task
file's list). What changed in the pass:

- Counts confirmed: Debian 2 + 32 apt entries (31 distinct, `rsync` twice) and
  4 Python entries; RedHat the group plus 24; Amazon 2023 the group plus 19;
  Arch 19 (including `base-devel`). No list changed.
- File:line citations were spot-checked against the files and none changed.
- Removed an unsupported claim from the RedHat pip bullet that `ansible-core`
  already supplies Jinja2 and PyYAML; it is now an Open line settled by
  `pip list`.
- Removed a claim that `dpkg-dev` comes from EPEL or CRB specifically; the doc
  now says `base.el` enables both and leaves the serving repo as an Open line.
- Moved the regeneration command to the end of Current method so the section
  starts with the classifier's own heading, unedited.
- Grepped the doc for hedge words; none remain.

2026-10-30, third pass: settled Open lines with local probes of the pinned
base images (new Local probes subsection). Changed: dpkg repo (EPEL), pip
names per RedHat image, uv re-run behaviour, PEP 668 marker per image, dnf
group naming. The probe corrected an earlier verdict: the ID
`development-tools` exists only on Fedora, not on EL or Amazon, so the
"name the group by its ID" recommendation was rewritten as per-family naming.
Still Open: the Ansible `dnf` module on fedora43/44, and almalinux Python
modules.


## skill-feedback

Input for T15 (the `ansible-port` skill, v1). Each item is adoptable or
rejectable on its own.

1. Level order. Writing Outcomes before Current method worked: the oracle
   checklist forced concrete package names, and reading the YAML afterwards
   showed every branch. Adopt: Outcomes comes first and is written from the
   YAML, then the classifier output is pasted.
2. The classifier output says what the YAML does (14 tasks, 6 dispatch), not
   what it installs. Outcomes had to be hand-built from five task files. Adopt:
   a `tp classify --packages` listing per task file (module, state, names)
   would make Outcomes a copy-and-check instead of a transcription.
3. `tp classify` counted `pip` under "Distro dispatch" because of its `when`.
   That is a real dispatch, but the conditional is the PEP 668 split and the
   table gives no hint of it. Adopt: print the `when` expression next to each
   dispatch task.
4. The classifier does not show cross-file flag definitions. Every flag
   (`redhat_based` and the others) lives in `group_vars/all`, a file the
   playbook never names. Adopt: the skill tells the author to open
   `inventories/group_vars/all` first and cite the flag lines; reject if the
   classifier learns to resolve flags.
5. Citing file:line was easy for task files and hard for facts defined by
   absence (Amazon missing from a list, no `update_cache`, no `creates`).
   Adopt: a convention for citing an absence: cite the line that would
   contain it, and say "omits" or "no X".
6. Outcomes needs an installed-name versus requested-name rule. `gnupg` on
   RedHat resolves through provides, so the oracle's name may differ from the
   YAML's name. Adopt: the skill states that Outcomes lists requested names
   and the oracle compares installed names.
7. Shared roles. `dev_common` runs again in three later playbooks; the
   per-playbook doc misses that unless the author greps for the role. Adopt:
   a step "grep who else applies this role" in Purpose.
8. Web research. The search tool returned summaries, not pages; the fetch
   tool returned model summaries of pages and failed on a 404 and a 429.
   Two claims (dnf5 group IDs, Fedora PEP 668) needed a second primary page
   to hold up; the first source was a blog or a forum. Adopt: prefer
   vendor docs and issue threads, mark secondary sources as secondary in the
   doc, record a failed fetch instead of retrying the same URL.
9. The date rule is easiest when the access date sits on the same line as the
   URL. Long URLs make a line unwieldy; the checker only needs the date on
   that line. Adopt: `Source: <url> (accessed YYYY-MM-DD)` as the one form.
10. The Open lines stayed useful. Four checks (marker presence, dnf group
    resolution, installer re-run, curl in base) are all image captures that
    T18 makes anyway. Adopt: the skill tells the author to phrase each
    Open line as a command whose output settles it.
11. Reject: a template for "bugs the oracle cannot see". This role had none;
    forcing the section to have content invites invented findings.
12. The heading is `## skill-feedback` (the step's spelling, lower-case
    with a hyphen) so `grep -n '^## skill-feedback'` finds it; the other
    headings are sentence case.
