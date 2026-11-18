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
src/playbooks/labtwo.rs      labtwo (the lab servers, by inventory group) and labtwo_<role>, the VM oracle's one-role cases
src/roles/                   dev_common, kernel_build, rust_build, rust_kernel, src_repos,
                             admin_users, docker, vm_server, node, golang, tmux,
                             maasfix, h11ssl_reboot_fix, root_user, hashicorp_packer, systemd_time, cuda
src/vars.rs                  the typed vars every playbook reads (loaded from TOML)
vars/container.toml          vars for image builds: admin_users = ["root"], tool versions
vars/desktop.toml            vars for dev_desktop: admin_users = ["bot", "tpdev"]
vars/labtwo*.toml            vars for labtwo: the real run, the VM runs, and the oracle's one-role cases
scripts/                     the equivalence oracles and the VM harness (below)
conversion/SOURCE            the ansible repo and commit the ports were made from; a role being ported keeps its YAML and understanding doc in conversion/ until it lands
tests/plans.rs               plan snapshots: every playbook on every supported distro
```

Each role carries its understanding as comments: what the playbook is for,
which branches were kept, dropped or fixed, and why. The YAML it replaced is
gone; `conversion/SOURCE` records the ansible commit the ports were made
from, and `just check-conversion` verifies the directory against it (with
no port in progress it holds only that header, as now). The labtwo playbook
came from a second source, `ansible_labtwo_2` (`playbooks/labtwo.yml`, a
working tree of 67988b9); its sha256 is in `src/playbooks/labtwo.rs`, and the
tree hashes that tied that checkout's role dirs to 79d1ca1 are in git history.

## Build and run

Rust stable, `just`, and the `x86_64-unknown-linux-musl` target.

```
just musl                                   # build/tp-basic, static, then `list`
just dist                                   # build/dist/{tp-basic, vars/, PROVENANCE} for ../docker_images (bake context `tp`)
build/tp-basic list
build/tp-basic plan container/rust --distro rockylinux10
build/tp-basic run container/dev_base --local --vars vars/container.toml
build/tp-basic run container/dev_base --host bot@10.0.0.7 --ssh-key ~/.ssh/id_ed25519 --vars vars/container.toml --log run.jsonl
```

### The labtwo playbook

`labtwo` is `ansible_labtwo_2/playbooks/labtwo.yml` as one playbook, chosen per
host by inventory group: `maas_installs` runs `maasfix`; `H11SSL_motherboards`
runs `H11SSL_reboot_fix`; `servers` and `storage_servers` run `admin_users`,
`root_user`, `dev_common`, `src_repos`, `kernel_build`, `docker`, `vm_server`,
`hashicorp_packer`, `rust_build`, `tmux`, `systemd_time` (the YAML's `zsh` is
not ported); `gpu_servers` runs `cuda`. One reboot barrier follows them all
(`h.reboot().if_pending()`). A host in none of these groups gets nothing.

```
build/tp-basic run labtwo --inventory inventories/labtwo.local.toml --vars vars/labtwo.toml
```

`inventories/labtwo.example.toml` has placeholder hosts in the five groups; the
real inventory is `inventories/labtwo.local.toml` (gitignored). `vars/labtwo.toml`
holds the non-secret values the roles read and `default_password` as a
reference into OpenBao (`kv/infra/labtwo/default_password`, field `hash`),
resolved only by a real run; `plan` and the tests never read it. (`tp-basic
plan labtwo` has no inventory, so no groups and an empty plan; the group sets
are traced by `tests/plans.rs`.)
`vars/labtwo_vm.toml` has the same values with no `default_password`, for VM
runs that must not contact OpenBao. The plan snapshots
(`tests/plans/snapshots/labtwo__*`) cover four group sets on ubuntu2404 and
ubuntu2604 and the `servers` set on the other eleven distros.

On a VM (1 GiB, 40 GB disk), `just test-vm ubuntu2404 labtwo` proves the
playbook over SSH. The VM is in `servers`, `maas_installs` and
`H11SSL_motherboards`, with the login user as its admin user. It is pre-seeded
with a MAAS-style `sources.list` and the old `ubuntu-src.sources`. The image's
installer tokens (`autoinstall ds=nocloud-net;s=…`) are taken out of
`/etc/default/grub`, because GRUB reads that `;` as the end of the `linux` line.
The case then checks:
- `--check` lists the expected changes;
- run 1 (`--reboot auto`) crosses one reboot, and afterwards `reboot=efi` is
  in `/proc/cmdline`, the time zone, sources and drop-ins are as wanted,
  `sshd -T` is unchanged, and a fresh login and sudo work;
- run 2 is CHANGED 0, with no reboot.

`just test-vm ubuntu2404 labtwo_gpu` runs the same playbook in `servers` and
`gpu_servers`, with cuda's small lists (`vars/labtwo_gpu_vm.toml`).

What has been proved (Goal 10, closed 2026-11-16), per new role:

| Role | Plan snapshots | VM oracle vs Ansible (ubuntu2404, 1 GiB) | VM run of `labtwo` | Real hosts (run, rerun CHANGED 0) | Reboot crossed on a real host |
|---|---|---|---|---|---|
| maasfix | 13 distros | equal | yes | veritech02, 03, 01 (no change of its own named) | veritech02: one boot crossed after the run, by the user's own recovery, not telepatch's barrier; the rerun after it CHANGED 0. veritech03: one reboot crossed through telepatch's barrier (`reboot_vm`, `--reboot auto`, the user standing by); labtwo rerun after it CHANGED 0 |
| systemd_time | 13 | equal | yes | veritech02, 03, 01 (zone already set) | veritech02: one boot crossed after the run, by the user's own recovery, not telepatch's barrier; the rerun after it CHANGED 0. veritech03: one reboot crossed through telepatch's barrier (`reboot_vm`, `--reboot auto`, the user standing by); labtwo rerun after it CHANGED 0 |
| root_user | 13 | equal but the declared sudoers and sshd lines | yes; `sshd -T` unchanged, fresh login | veritech02, 03, 01; sshd untouched | veritech02: one boot crossed after the run, by the user's own recovery, not telepatch's barrier; the rerun after it CHANGED 0. veritech03: one reboot crossed through telepatch's barrier (`reboot_vm`, `--reboot auto`, the user standing by); labtwo rerun after it CHANGED 0 |
| hashicorp_packer | 13 | equal but the declared apt sources | yes | veritech02, 03, 01 (legacy list and key replaced) | veritech02: one boot crossed after the run, by the user's own recovery, not telepatch's barrier; the rerun after it CHANGED 0. veritech03: one reboot crossed through telepatch's barrier (`reboot_vm`, `--reboot auto`, the user standing by); labtwo rerun after it CHANGED 0 |
| H11SSL_reboot_fix | 13 | equal (no reboot there) | yes; after the reboot `/proc/cmdline` has one `reboot=efi` | veritech02, 03, 01 (already in effect, no reboot marked) | veritech02: one boot crossed after the run, by the user's own recovery, not telepatch's barrier; `/proc/cmdline` has one `reboot=efi` after that boot; the rerun after it CHANGED 0. veritech03: one reboot crossed through telepatch's barrier (`reboot_vm`, `--reboot auto`, the user standing by); `/proc/cmdline` has one `reboot=efi` after that boot; the board was back within telepatch's wait (down 566 s of 600 s); labtwo rerun after it CHANGED 0 |
| cuda | 13 | equal with small lists, but the declared apt sources | `labtwo_gpu`, small lists, no GPU | veritech01 with the full lists, already installed | no |

The eight roles ported earlier ran in the same real-host runs. What is NOT
proved:
- a reboot crossed through labtwo's own barrier on a real host
  (veritech03's crossing went through the `reboot_vm` test playbook's
  barrier, the same engine routine); the GPU after a reboot; any boot on
  veritech01. What is proved instead: veritech03 crossed one reboot
  through telepatch's barrier (2026-11-18, `reboot_vm`, `--reboot auto`,
  the user standing by, down 566 s), and the labtwo rerun after it was
  CHANGED 0; veritech02 booted once after its run (2026-11-18, by
  the user's own recovery, not by telepatch), `/proc/cmdline` then had one
  `reboot=efi`, and the rerun after that boot was CHANGED 0;
- veritech04, at all: it was never run in Goal 10; vt-* VMs were on it, and
  the user dropped it from the goal on 2026-11-18;
- a from-scratch NVIDIA driver and CUDA install on real hardware: veritech01
  already had them, so the real run proved convergence only;
- the H11SSL board's reboot behaviour, under the fault or otherwise: a hang
  was seen on veritech02 after a by-hand reboot with `reboot=efi` in effect,
  cause unknown, and veritech02 came back only by the user's recovery;
- veritech03's state before the port: it was unreachable for the survey, so
  it has none (it answered later, and its real run went through);
- Pop!_OS, which the roles accept but nothing ran.

The same binary builds images (bind-mounted into a `docker build`, see
`../docker_images/Dockerfiles/telepatch.*`), provisions a machine it is copied to, or provisions hosts
over SSH from wherever it runs.

`cargo test` renders every playbook against every supported distro and
compares with the snapshots under `tests/plans/snapshots/`, so a change to a
role shows up as a diff in the plan before anything is applied anywhere.

## Proving the ports

Every ported role is held to the same standard: the original Ansible playbook
and `tp-basic` must leave a machine in the same state. The production
acceptance runners were retired (`test-acceptance`, `test-matrix` and
`test-container` stay retired). What remains, from cheap to thorough, lands
under `build/`, gitignored.

**The gate is `just test-edge`.** The local half runs here: telepatch's
`cargo test --workspace`, this repo's `cargo test --test plans` (the plan
snapshots and `plans_are_byte_identical`), `scripts/test-edge.sh --self-test`
and `just musl`. Then `just docker-vm test-edge-cell ubuntu2404` runs one
cell in a fresh 1 GiB `tp-*` VM. Both sides start from stock `ubuntu:24.04`,
pulled inside the VM, in containers with `sleep` as PID 1. Each side gets the
same bootstrap (`python3`, `python3-apt`, `python3-venv`, which Ansible needs
on the target). The Ansible side then runs `playbooks/edge` once from a
throwaway venv under `/opt/edge-ansible`. uv builds that venv on Python 3.13,
because ansible-core 2.22 needs it and the image ships 3.12. The venv also
gets the `community.general` collection, because the Arch task's
`ansible.builtin.pacman` redirects there and ansible-core resolves every
task's module when the play loads. The venv is removed before the capture. The telepatch side runs `tp-basic run edge
--local` twice. The cell passes when all of these hold:

- the second telepatch run shows `CHANGED 0`;
- `compare_captures` reports the two `image-state.sh` captures identical,
  with no intended-differences file;
- the marker `/usr/local/share/telepatch-edge.txt` has the sha256 of
  `printf 'edge\n'` on both sides;
- `/usr/local/bin/edge-jq` is the checksummed jq 1.7.1 on both sides.

The cell has a 10 minute budget, and going over only prints `budget:
exceeded`. At 30 minutes it removes its containers and fails, and so does an
OOM. Neither limit is widened. `just test-edge` accepts only ubuntu2404.

```
just test-edge
```

**The full edge matrix is manual: Jared starts it.** `just test-edge-matrix`
is not a goal gate. It runs the same cell on every distro of
`tests/plans.rs`, one after another, in one 1 GiB `tp-*` VM, each from its
stock image (`debian:12`, `debian:13`, `ubuntu:24.04`, `ubuntu:26.04`,
`fedora:43`, `fedora:44`, `rockylinux/rockylinux:9`, `rockylinux/rockylinux:10`,
`almalinux:9`, `almalinux:10`, `amazonlinux:2023`, `archlinux:latest`). The
bootstrap is the family's package manager (apt, dnf, pacman). omarchy has no
stock image: the matrix prints `SKIP omarchy`, does not bake
`../docker_images`, and its plan snapshot stays its only check. The matrix
refuses to start when the VM host already lists a `tp-*` VM. One cell by
hand: `just docker-vm test-edge-cell rockylinux10`.

```
just test-edge-matrix
```

**Where the VMs run.** Every `tp-*` VM is made on veritech04 through this
workstation's `~/repos/jaredeh/vmtool` (run from its own directory, so its
`config.yml` and token are used in place) as `veritech04/tp-<name>`; the one
driver is `scripts/lib/vm.sh`. Nothing of ours is installed, built or kept on
veritech04, and nothing ssh-es to it. The base image is vmtool's
`ubuntu2404.qcow2`, uploaded by `vmtool create` on a miss; every VM gets 1 GiB.
One VM at a time is created, then commissioned, then onboarded:

1. `vmtool create veritech04/tp-<name> ubuntu2404.qcow2 --memory 1 --disk-size N`
2. pre-commission check, one ssh call as `packer` through vmtool's tunnel: the
   hostname is not a `vt-*` name, `/proc/uptime` is less than the seconds since
   step 1 began, and the IP `vmtool list veritech04` shows is on no other row
   (`pre-commission check: ok (...)` in the log; a failure deletes the VM and
   stops, and commission is never run)
3. `vmtool playbook ... commission.yml` (its own hostname, machine-id and host
   keys, then a reboot)
4. post-commission check: the hostname is `tp-<name>` and the IP is on no other
   row (`post-commission check: ok (...)`)
5. `vmtool playbook ... setup_bot.yml` (bot, key auth; its key stays under
   vmtool's `.machines/veritech04/tp-<name>/` and is used in place, by path)

The guest is reached through vmtool's tunnel, not `ProxyJump`: the ssh option
is `ProxyCommand=sh -c 'cd <vmtool dir> && exec ./vmtool tunnel
veritech04/tp-<name>'` (the form `./vmtool ssh-config` prints) and the
destination is `bot@tp-<name>`, for `tp-basic run`, the oracle's Ansible
inventory and the docker socket forward alike. The VM is deleted on every exit
unless `--keep`. Verify that vmtool reaches veritech04 with:

```
bash scripts/vm-host.sh check    # read-only: `vmtool hosts` shows veritech04 reachable; docker-vm.sh runs it before every VM
```

The `vt-*` VMs on veritech04 are not ours: nothing here names, stops or deletes
a VM whose name does not start with `tp-`, and `vmtool list veritech04` is read
only to check that our VM's address is on no other row.

`scripts/image-state.sh` still captures a machine (packages by name and
architecture, pip distributions, rustup state, apt sources, `/usr/local/bin`,
mise shims, tools, config and `/etc/profile.d` names). Idempotency and the
svc proof still run inside a `tp-*` VM (`just docker-vm …`):

```
just test-idempotent ubuntu2404 rust        # apply twice in one container; the second run must change nothing
just test-services ubuntu2404               # desktop_services (docker, vm_server) twice in an init-less container; svc prepare lines printed, run 2 CHANGED 0
```

**SSH transport on a VM** (`scripts/test-vm.sh`). Creates a fresh Ubuntu
24.04 VM with [vmtool](https://github.com/jaredeh/vmtool), applies `container/dev_base`
to it over SSH twice, and deletes the VM. Passes when the first run exits 0
and the second reports `STATUS ok`, `CHANGED 0`, and `bot`'s login shell
runs `just --version` through the mise shims. It does not compare that
playbook to a container record.

```
just test-vm ubuntu2404 dev_base
just test-vm ubuntu2404 dev_desktop
```

`dev_desktop` (vars/desktop.toml, admin users `bot` and `tpdev`, a 30 GB
disk) after the second run gates on working
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

**Ansible against telepatch on a VM** (`scripts/test-vm-oracle.sh`). Two fresh
VMs from the same image, one at a time: `ansible-playbook` from this machine
runs the original playbook on one, `tp-basic run --host` runs the port on the
other, and the two states are diffed by `scripts/lib/compare.sh`. Each side runs
twice and both passes are timed, so the run also answers how the two tools
compare on a fresh host and on a converged one.

```
just test-vm-oracle ubuntu2404 dev_base
just test-vm-oracle ubuntu2404 dev_desktop_kept
just test-vm-oracle ubuntu2404 labtwo_<role>
```

`labtwo_<role>` is one role of the labtwo playbook: `maasfix`, `systemd_time`,
`root_user`, `hashicorp_packer`, `h11ssl_reboot_fix` (the Ansible role dir is
`H11SSL_reboot_fix`; the case name is lowercase because VM names allow only
`tp-[a-z0-9-]+`) and `cuda`. The script writes a wrapper playbook into its
export (hosts `all`, the role; `vm_server` first for `hashicorp_packer`), and
the tp side runs the test playbook of the same name (added with each port).
A case may have a pre-seed, `scripts/oracle-preseed/<case>.sh`, run as root on
both VMs before the pre-state capture: `labtwo_maasfix` writes a MAAS-style
`/etc/apt/sources.list` with live entries, `labtwo_cuda` installs `docker.io`
(the Ansible handler restarts docker). `labtwo_src_repos.sh` (an
`ubuntu-src.sources`) is ready for the src_repos case, which is not accepted
yet. `labtwo_cuda` overrides the package lists to a small one on the Ansible
side.

`image-state.sh` captures, besides the packages, seven single-file sections
for every run: `timezone` (the `/etc/localtime` target), `sshd` (`sshd -T`
permitrootlogin and passwordauthentication), `sudoers` (the includedir and
secure_path lines; it used to appear only with `--users`), `units` (sha256 of
each drop-in under `/etc/systemd/system/*.d/`), `grub` (the kernel arguments
on the `linux` lines of `grub.cfg`, without the image path and `root=`),
`groups` (members of kvm, libvirt, docker) and `profile.d` (sha256 of
`cuda.sh`). A missing file gives the header and `(none)`. The self-tests run
them on a fake root (`IMAGE_STATE_ROOT`) with a stub `sshd`. None of the new
sections differs between the two sides of the existing cases (dev_base and
the container cases touch none of those files; `admin_users` touches only
sudoers, already declared), so their intended files are unchanged.

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

The harnesses read, and never write, these neighbours (`../ansible_labtwo_2`
is listed for provenance only):

- `../ansible`: the originals, at the commit in `conversion/SOURCE`.
- `../ansible_labtwo_2`: only `playbooks/labtwo.yml` was taken from it (its
  sha256 is in `src/playbooks/labtwo.rs`); nothing reads it now.
- `../docker_images`: the pinned base images; the Ansible-side Dockerfiles
  (from the pinned commit) and the telepatch Dockerfiles (its working
  tree, run with `build/dist`), which the docker oracle reuses unmodified.
- `~/repos/jaredeh/vmtool`: the libvirt VM tool the VM harnesses drive
  through its CLI; VMs are named `tp-*` and deleted when the run ends.

## License

MIT. See [LICENSE](LICENSE).
