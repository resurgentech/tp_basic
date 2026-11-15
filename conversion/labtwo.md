# labtwo.yml: understanding doc (playbook level)

Scope: `playbooks/labtwo.yml` as a playbook: its plays, groups, play
vars and role list. The six roles ported in Goal 10 (T151–T156) each
get their own doc until their oracle passes; those ported, and the
eight ported earlier, carry their understanding as code comments in
`src/roles/`. All file:line citations are relative
to `conversion/ansible/`. `playbooks/labtwo.yml` is a byte copy of the
working tree of `ansible_labtwo_2` at 67988b9 (it modifies the
committed file); the six role dirs are byte copies of the ansible repo
at 79d1ca1, equal to the `ansible_labtwo_2` copies (hashes and the
equality record in `conversion/SOURCE`). Last read against those
copies on 2026-11-15.

Decision: Decided by agent (agent-alone); not yet reviewed by the user.

## Purpose

`labtwo.yml` configures the lab's bare-metal servers ("Configures
servers for lab two", `playbooks/labtwo.yml:2`). It is four plays, each
a role list applied to one or two inventory groups. The hosts are MAAS
deploys of the Ubuntu 24.04 cloud image, so two plays exist only to
undo quirks of those installs (MAAS apt sources, the networkd
wait-online timeout) and of one motherboard (the H11SSL's EFI reboot).

Plays to groups (`playbooks/labtwo.yml`):

| Play | Lines | Groups | Roles |
|---|---|---|---|
| Fix up quirks of the MAAS installs | `:4-7` | `maas_installs` | `maasfix` |
| Bug with H11SSL motherboards not rebooting | `:9-12` | `H11SSL_motherboards` | `H11SSL_reboot_fix` |
| Configures development servers | `:14-37` | `servers`, `storage_servers` | `admin_users`, `root_user`, `dev_common`, `zsh` (dropped), `src_repos`, `kernel_build`, `docker`, `vm_server`, `hashicorp_packer`, `rust_build`, `tmux`, `systemd_time` |
| Configures GPU on servers | `:49-52` | `gpu_servers` | `cuda` |

Group membership (`ansible_labtwo_2/inventories/labtwo.yml`, read
2026-11-15; host names are kept out of this repo): the four lab servers
are each in `servers`, `maas_installs` and `H11SSL_motherboards`; one of
them is also the only member of `gpu_servers`. `storage_servers` holds
one storage host that is not a lab server; no telepatch run reaches it
in this goal. Every host logs in as a non-root user with become.

Play vars (`playbooks/labtwo.yml:16-18`): `vault_addr` and
`vault_token` are `lookup('env', 'VAULT_ADDR')` and
`lookup('env', 'VAULT_TOKEN')`. No in-scope role reads either (a grep
of the eight ported roles' YAML and the six mirrored roles finds no
reader). They map to nothing in `Vars`: `telepatch-openbao` reads
`BAO_*`/`VAULT_*` from the controller's environment itself when a
secret reference needs it, and no role names a store.

Dropped and out-of-scope roles:

- `zsh` (`playbooks/labtwo.yml:23`): not supported, not ported (user
  ruling, 2026-11-14). The telepatch play leaves it out.
- Ubuntu 22.04 is deprecated (user ruling, 2026-11-14): no branch, flag
  or workaround. cuda's `ubuntu2204_based` vars
  (`roles/cuda/vars/main.yml:11-12,18-19`) are dropped in T156.
- Commented out in the play, out of scope: `golang` (`:29`),
  `rust_tools` (`:31`), `cockpit` (`:32`), `aptly_cli` (`:34`),
  `xterm_ghostty` (`:36`), `networkd_wait_fix` (`:37`; maasfix
  carries the same override).
- The commented-out "Client tools" play (`:39-46`, `minio_client`,
  `mc_setup`) is out of scope.

Role docs:

- Ported earlier, understanding in code comments: `admin_users`,
  `dev_common`, `src_repos`, `kernel_build`, `docker`, `vm_server`,
  `rust_build`, `tmux` (`src/roles/<role>.rs`).
- Ported in Goal 10, understanding in code comments: `maasfix` (T151),
  `systemd_time` (T152), `root_user` (T153), `hashicorp_packer` (T154).
  Their mirrors stay, cited here.
- To come, one per port step, `conversion/<role>.md`:
  `H11SSL_reboot_fix` (T155), `cuda` (T156).

## Outcomes

End state per group, after one run. Role-level detail (and every fault
the port fixes) is in the role modules' comments; this lists what a host in each
group holds when the playbook is done. The surveyed state of the lab
servers (T149, 2026-11-15, three of four reachable) is folded in where
it changes what a run does there.

### `maas_installs` (Ubuntu 24.04 and later)

- `/etc/apt/sources.list` holds only the pointer comment to
  `ubuntu.sources`, when `ubuntu.sources` exists
  (`roles/maasfix/tasks/apt_sources_ubuntu2404.yml:3-19`).
- `systemd-networkd-wait-online.service` waits for any one link, 30 s
  at most, through a unit drop-in
  (`roles/maasfix/tasks/networkd_wait_ubuntu2404.yml:3-16`).
- Survey: on every reachable server `sources.list` already has no live
  line and the drop-in already exists, so a run there changes at most
  their exact text.

### `H11SSL_motherboards` (Ubuntu 24.04 and later)

- The kernel command line carries `reboot=efi`; a reboot is needed for
  it to take effect (`roles/H11SSL_reboot_fix/tasks/ubuntu2404.yml:2-15`).
  The port writes it through `h.kernel_args()` (T147), a
  `/etc/default/grub.d/` file that sorts last, instead of editing
  `/etc/default/grub`.
- Survey: `reboot=efi` is already on `/proc/cmdline` of every reachable
  server, and their `50-cloudimg-settings.cfg` is renamed `.disabled`.
  A first run there writes the telepatch file and runs `update-grub`
  once, with no change to the effective command line; its reboot mark
  is then a no-op in effect.

### `servers` and `storage_servers`

In play order:
- `admin_users`, `dev_common`, `src_repos`, `kernel_build`, `docker`,
  `vm_server`, `rust_build`, `tmux`: the ported roles' outcomes, as in
  `src/roles/<role>.rs`. `src_repos` removes the old labtwo
  `ubuntu-src.sources` and sets `deb-src` on `ubuntu.sources` (user
  ruling, 2026-11-14); the survey found `ubuntu-src.sources` on every
  reachable server.
- `root_user`: root exists with `/root/.ssh` at 0700; `/etc/sudoers`
  has the includedir and a `secure_path`; sshd permits root login and
  password authentication (`roles/root_user/tasks/main.yml:1-56`).
  Survey: on every reachable server `sshd -T` gives
  `permitrootlogin yes` and `passwordauthentication no`, the second
  set by the cloud image's `sshd_config.d` drop-in, which wins over the
  YAML's edit. The YAML's stated outcome is therefore not in effect
  today. Ruled 2026-11-15 ("Leave as found"): the port (T153) has no
  sshd op, so what is in effect on each host stays; root_user runs on
  the real hosts like every other role.
- `hashicorp_packer` (after `vm_server`): `packer` installed from the
  HashiCorp apt repo, and each admin user in `kvm` and `libvirt`
  (`roles/hashicorp_packer/tasks/main.yml:1-53`,
  `roles/hashicorp_packer/tasks/per_user.yml:3-10`). Survey: every
  reachable server carries the legacy one-line `hashicorp.list` and
  the dearmored key in `trusted.gpg.d`; the port replaces both.
- `systemd_time`: the time zone is `iana_tz`, `America/Los_Angeles` in
  `ansible_labtwo_2/inventories/group_vars/all`
  (`roles/systemd_time/tasks/main.yml:4-12`). Survey: already set on
  every reachable server.

### `gpu_servers`

- The CUDA apt repo through NVIDIA's `cuda-keyring` package, the
  pinned NVIDIA driver and CUDA package lists, the container toolkit
  from NVIDIA's flat apt repo at its pinned version,
  `/etc/profile.d/cuda.sh` putting the CUDA tools on `PATH`; docker
  restarted after a toolkit change; a reboot after a driver or CUDA
  change (`roles/cuda/tasks/main.yml:1-37`,
  `roles/cuda/vars/main.yml:1-46`).
- Survey: the GPU server already has `cuda-keyring` 1.1-1 and
  `nvidia-container-toolkit` 1.19.0-1 (the pin), and the toolkit's
  shell-written list and key, which the port's repo op will meet.

### Not touched by any role

The survey found one third-party apt source on one server that no
labtwo role writes. No port acts on it.

### Reboot

One reboot barrier at the end of the telepatch playbook
(`h.reboot().if_pending()`): `H11SSL_reboot_fix` and `cuda` mark it;
nothing after the roles needs the rebooted state. The Ansible play
reboots in cuda's handler instead.

## Task intent

No task is rowed here: every role in the playbook is passed with
`--skip-role` (`admin_users`, `root_user`, `dev_common`, `zsh`,
`src_repos`, `kernel_build`, `docker`, `vm_server`,
`hashicorp_packer`, `rust_build`, `tmux`, `systemd_time`, `maasfix`,
`H11SSL_reboot_fix`, `cuda`). Each port step's role doc carries its
role's task intent; the ported roles carry theirs in code comments;
`zsh` is dropped.

Primitive gaps: none at playbook level. The roles' gaps (time zone,
kernel command line, source packages) are built by T146, T147 and
T143.

## Current method

Four plays, each `hosts:` one or two groups and a `roles:` list; the
third play sets two vars from the controller environment. No
`pre_tasks`, `tasks`, `handlers` or `serial` at play level; ordering
is play order, then role order within a play.

## Preserved knowledge

- Group membership decides which roles a host gets; a host in several
  groups gets each play's roles in play order (maasfix, then H11SSL,
  then the server roles, then cuda).
- `hashicorp_packer` follows `vm_server`, which creates the `kvm` and
  `libvirt` groups its per-user task needs.
- The server play's comment on `networkd_wait_fix` asks whether that
  fix is redundant; maasfix already carries the same drop-in.

## Is the method current

The play structure maps one to one onto a telepatch playbook: one
function per play, gated by `in_group`, roles called in order, one
reboot barrier at the end. Nothing in the playbook level is outdated
beyond the dropped and commented-out roles above.

## Recommendation and decision

Port the playbook as `src/playbooks/labtwo.rs` (T157): the four plays
as `in_group` blocks in the same order, `zsh` left out, no vars for
`vault_addr`/`vault_token`, one `h.reboot().if_pending()` at the end.

Decision: Decided by agent (agent-alone); not yet reviewed by the user.

## Port notes

- Inventory: the real one is gitignored (`inventories/labtwo.local.toml`);
  the committed example uses placeholders.
- `storage_servers` stays in the play's group list, so the playbook
  matches the YAML; no run in this goal reaches its host.
- Real-host runs: `--serial 1`, `--reboot never` until reboots are
  allowed. root_user is not excluded: it has no sshd op (ruling of
  2026-11-15, "Leave as found").

## Review

Not yet reviewed by the user.
