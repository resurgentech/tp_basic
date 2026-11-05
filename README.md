# tp_basic

Playbooks and roles for [telepatch](https://github.com/resurgentech/telepatch):
the development workstation, build container and server configurations that
the [ansible](https://github.com/resurgentech/ansible) repo used to hold.

telepatch is the engine. This repo is what runs on it, the way a playbook
repo relates to Ansible itself. It compiles to one static binary,
`tp-basic`, that knows every playbook here.

## What is in it

```
src/playbooks/container.rs   container/dev_base, container/kernel_build, container/rust, container/latest_kernel_build
src/playbooks/desktop.rs     dev_desktop, dev_desktop_kept (the VM oracle subset: admin_users, tmux), desktop_services (docker, vm_server: the svc proofs)
src/roles/                   dev_common, kernel_build, rust_build, rust_kernel, src_repos,
                             admin_users, docker, vm_server, node, golang, tmux
src/vars.rs                  the typed vars every playbook reads (loaded from TOML)
vars/container.toml          vars for image builds: admin_users = ["root"], tool versions
vars/desktop.toml            vars for dev_desktop: admin_users = ["bot", "tpdev"], default_password = ""
Dockerfiles/telepatch.*      the telepatch twins of docker_images' ansible.* Dockerfiles, one per distro family
scripts/                     the equivalence oracles and the VM harness (below)
conversion/SOURCE            the ansible repo and commit the ports were made from; a role being ported keeps its YAML and understanding doc in conversion/ until it lands
tests/plans.rs               plan snapshots: every playbook on every supported distro
```

Each role carries its understanding as comments: what the playbook is for,
which branches were kept, dropped or fixed, and why. The YAML it replaced is
gone; `conversion/SOURCE` records the ansible commit the ports were made
from, and `just check-conversion` verifies the directory against it (with
no port in progress it holds only that header).

## Build and run

Rust stable, `just`, and the `x86_64-unknown-linux-musl` target.

```
just musl                                   # build/tp-basic, static, then `list`
build/tp-basic list
build/tp-basic plan container/rust --distro rockylinux10
build/tp-basic run container/dev_base --local --vars vars/container.toml
build/tp-basic run container/dev_base --host bot@10.0.0.7 --ssh-key ~/.ssh/id_ed25519 --vars vars/container.toml --log run.jsonl
```

The same binary builds images (bind-mounted into a `docker build`, see
`Dockerfiles/`), provisions a machine it is copied to, or provisions hosts
over SSH from wherever it runs.

`cargo test` renders every playbook against every supported distro and
compares with the snapshots under `tests/plans/snapshots/`, so a change to a
role shows up as a diff in the plan before anything is applied anywhere.

## Proving the ports

Every ported role is held to the same standard: the original Ansible playbook
and `tp-basic` must leave a machine in the same state. Three harnesses check
that, from cheap to thorough. Outputs land under `build/`, gitignored.

**Docker oracle** (`scripts/test-container.sh`). Builds a container's image
chain twice from one pinned base image, once with the Ansible Dockerfiles of
the pinned `../docker_images` commit and once with the telepatch twins,
captures the installed state of each final image with
`scripts/image-state.sh` (packages by name and architecture, pip
distributions, rustup state, apt sources, `/usr/local/bin`, mise shims,
tools, config and `/etc/profile.d` names), and diffs. Any
difference fails.
The Ansible side (docker-bake.hcl, `Dockerfiles/ansible.*`, build context) is
exported with `git archive` from the commit `ported_docker_images` in the
justfile into `build/docker_images/<sha>/`, never read from the sibling's
working tree; `DI_SHA=<sha>` overrides it.

```
just test-container ubuntu2404 dev_base     # one cell
just test-acceptance                        # the gate: 7 cells on ubuntu2404, rockylinux10 and ubuntu2604
just test-idempotent ubuntu2404 rust        # apply twice in one container; the second run must change nothing
just test-services ubuntu2404               # desktop_services (docker, vm_server) twice in an init-less container; svc prepare lines printed, run 2 CHANGED 0
just test-matrix                            # every container on every distro; writes build/matrix.md (not a gate)
```

**SSH transport on a VM** (`scripts/test-vm.sh`). Creates a fresh Ubuntu
24.04 VM with [vmtool](https://github.com/jaredeh/vmtool), applies `container/dev_base`
to it over SSH twice, and deletes the VM. Passes when the first run exits 0
and the second reports `STATUS ok`, `CHANGED 0`, and `bot`'s login shell
runs `just --version` through the mise shims. The package comparison with
the docker oracle's record is printed but not gated: containers and VMs
differ in structure (systemd, kernel, udev, cloud-init), so apt resolves
alternatives differently and the sets cannot match one to one.

```
just test-vm ubuntu2404 dev_base
just test-vm ubuntu2404 dev_desktop
```

`dev_desktop` (vars/desktop.toml, admin users `bot` and `tpdev`, a 30 GB
disk) has no docker oracle record; after the second run it gates on working
checks for each admin user in a login shell (`bot` directly, `tpdev` through
`sudo -n -iu tpdev`): `sudo -n true`, `id -nG` holding `sudo`, `docker` and
`libvirt`, `docker run --rm hello-world`, `go version`, `node --version`,
`just --version`, `tmux -V` and `virsh --version` (`virsh -c qemu:///system
version` is printed, not gated). Go is wanted at latest, so a Go release
between the two passes is the one accepted cause of a nonzero count, and the
script prints it as such.

Runs on 2026-11-04 (Ubuntu 24.04 VM, 4 GiB):

| | First run | Second run | Changed on the second run | Whole script |
|---|---|---|---|---|
| `dev_desktop` | 14m25s | 9s | 0 (all 16 working checks pass) | 15m48s |
| `dev_base` | 5m50s | 1s | 0 | 7m11s |

**Ansible against telepatch on a VM** (`scripts/test-vm-oracle.sh`). The
docker oracle on the base you actually deploy to. Two fresh VMs from the same
image, one at a time: `ansible-playbook` from this machine runs the original
playbook on one, `tp-basic run --host` runs the port on the other, and the
two states are diffed with the docker oracle's own comparison. Each side runs
twice and both passes are timed, so the run also answers how the two tools
compare on a fresh host and on a converged one.

```
just test-vm-oracle ubuntu2404 dev_base
just test-vm-oracle ubuntu2404 dev_desktop_kept
```

`dev_desktop_kept` is the two roles of `dev_desktop` that were ported rather
than rewritten (`admin_users`, `tmux`). The script writes that two-role
playbook into its own export of the ansible commit, and both captures add the
account sections (`image-state.sh --users bot,tpdev`: passwd entry without
secrets, groups, the `passwd -S` letter, the sudoers include and secure_path
lines, the drop-ins, `~/.ssh`). A run on 2026-11-04: identical with the three
declared sudoers differences (admin_users bugs 1 and 2); Ansible 10.6s and
6.3s, telepatch 3.8s and 0.3s, both changing nothing on the second run.

A run on 2026-11-03, `dev_base` on Ubuntu 24.04, states identical down to
versions apart from the six intended mise lines:

| | First run | Second run | Changed on the second run |
|---|---|---|---|
| Ansible | 4m36s | 6.7s | 1 (the original's unguarded uv installer) |
| telepatch | 3m57s | 1.3s | 0 |

Each script has a `--self-test` that checks its comparison logic with no
docker, VM or network; `just test-oracle-selftest` runs both.

**Intended differences.** Both oracles compare through one function,
`compare_captures` in `scripts/lib/compare.sh`. Where telepatch deliberately
differs from Ansible, `tests/oracle/intended/<container>.txt` (used for every
distro of that container; no file means an exact match) lists it, one per
line: `+<section>|<line>` when telepatch adds the line, `-<section>|<line>`
when it lacks it; `#` comments and blank lines are allowed. `<section>` is the
text of a `== section ==` header in the capture. The oracle writes
`ansible.intended.state`, Ansible's capture with each `+` line merged into its
section (in `LC_ALL=C` sort order for the sections `image-state.sh` sorts,
appended otherwise) and each `-` line removed, then runs the usual `diff -u`
against `telepatch.state`. So a `+` line telepatch lacks still fails, as does
a `-` line Ansible never had, an unknown section, or any other difference.
The result line reads `identical (N intended differences applied)` and lists
them. A line may be limited to some distros with a bracketed list right before
the sign, `[rockylinux9,rockylinux10]-pip|pyaml`: on any other distro it is
ignored; a malformed list fails the comparison (see
`tests/oracle/intended/README`).

The first intended difference (goal 5a, 2026-11-03): `dev_common` installs
mise system-wide (`/usr/local/bin/mise`), puts its shims on every login
shell's PATH (`/etc/profile.d/mise.sh`) and installs `just` through mise's
system layer (`/etc/mise/config.toml`, `/usr/local/share/mise`). The Ansible
original has none of it, so the four containers' files list the six lines it
adds. Any user's login shell then runs `just` from
`/usr/local/share/mise/shims/just`; `just test-vm` checks that as `bot`.

## Neighbours

The harnesses read, and never write, three sibling checkouts:

- `../ansible`: the originals, at the commit in `conversion/SOURCE`.
- `../docker_images`: the pinned base images and the Ansible-side
  Dockerfiles, which the docker oracle reuses unmodified.
- `~/repos/jaredeh/vmtool`: the libvirt VM tool the VM harnesses drive
  through its CLI; VMs are named `tp-*` and deleted when the run ends.

## License

MIT. See [LICENSE](LICENSE).
