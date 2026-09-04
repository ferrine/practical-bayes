# `lab/` — the course JupyterHub VM

A NixOS guest, run under QEMU/KVM straight from this repo, serving JupyterHub
with the full PyMC/pydata stack. Students register themselves, an admin approves
them, and their home directories live on a disk image that survives every
rebuild of the machine.

Built with plain Nix and the repo-level npins pin (`../npins`) — same convention
as the lecture toolchain, no flakes, no system-wide install.

## Quick start

```sh
./lab/launch.sh --admin ferrine
```

That is the whole thing. It builds the VM, creates the disk images if they do
not exist yet, prints the URLs and boots the machine with its console attached
to your terminal. Defaults: **256 GiB RAM / 24 vCPU** for the guest, **16 GiB /
4 CPU** per student (comfortable for ~15 concurrent), published on
`127.0.0.1:8000`.

```sh
./lab/launch.sh --help          # every knob
./lab/launch.sh --host 0.0.0.0 --port 8000 --admin ferrine
./lab/launch.sh --build-only    # build without starting
./lab/launch.sh --detach        # run in the background
```

In the foreground the guest console is attached to your terminal and `poweroff`
there stops it cleanly — but the VM dies with the terminal.

### Running it detached

`--detach` disowns the VM from the shell that started it and leaves three files
in `lab/state/`:

| file | |
|---|---|
| `lab-vm.pid` | QEMU's own pid (`-pidfile`), removed when it exits |
| `lab-vm.log` | the guest console |
| `qemu-monitor.sock` | QEMU monitor — how you stop it without a console |

```sh
echo system_powerdown | socat - UNIX-CONNECT:lab/state/qemu-monitor.sock  # graceful
kill "$(cat lab/state/lab-vm.pid)"                                        # power cord
```

Launching again from the same state directory refuses to start while that pid
is alive, so you cannot accidentally run two VMs on one data disk.

Detached means no console, so pass `--ssh-port N --ssh-key ~/.ssh/id_ed25519.pub`
if you want a way in for the admin operations below.

Every option is also an environment variable (`LAB_HOST`, `LAB_PORT`,
`LAB_MEM`, `LAB_CPUS`, `LAB_ADMINS`, …). All of them are passed through to
`nix-build`, so there is one source of truth and no drift between the built
system and the running one. The price is a NixOS evaluation (~30 s) on each
launch; the closure itself is cached after the first build.

## Accounts

`NativeAuthenticator`, so:

1. A student opens `/hub/signup` and picks a username and password.
2. An admin approves them at `/hub/authorize` (linked from `/hub/admin`).
3. They log in and get their own JupyterLab.

The approval queue **is** the whitelist — nobody can log in until you click
approve, even if the hub is exposed to the network. Admin accounts (from
`--admin`) are auto-approved on signup; sign yours up first.

### Hard roster (optional)

If you would rather work from a class list, put one username per line in
`/var/lib/jupyterhub/students.txt` inside the VM (see `students.txt.example`)
and `systemctl restart jupyterhub`. Only those names — plus the admins — can
log in. That file lives on the persistent disk, so editing it needs no rebuild;
delete it and restart to go back to approval-only mode.

Two things worth knowing:

- Turning the roster on **also locks out accounts that already exist** and are
  not listed. That is deliberate (`Authenticator.allow_existing_users` is forced
  off; JupyterHub would otherwise keep admitting every account already in its
  database, and the roster could only ever add people). Their home directories
  are untouched — put the name back in the file to restore access.
- Signup itself is not blocked: an unlisted person can still create an account,
  they just cannot log in with it.

## Persistence

Two disk images under `lab/state/`:

| file | contents | disposable? |
|---|---|---|
| `root.qcow2` | `/etc`, `/var/log`, …; the Nix store comes from the host over 9p | **yes** — delete it and relaunch to reset the machine |
| `data.qcow2` | mounted at `/var/lib` | **no** — this is the one that matters |

`data.qcow2` holds everything worth keeping:

- `/var/lib/jupyterhub/jupyterhub.sqlite` — accounts, password hashes, approvals
- `/var/lib/private/<student>/` — every student's home directory, including
  their notebooks, `~/.venvs` and the uv cache

Home directories work without any declarative Unix users: `SystemdSpawner` runs
each server under a systemd `DynamicUser` with a persistent `StateDirectory`.
That is also where the isolation comes from — `ProtectSystem=strict`,
`PrivateTmp`, no sudo.

**Backup** = stop the VM and copy `lab/state/data.qcow2` somewhere. Restore by
copying it back. Nothing else is stateful.

## Course materials

The seminars, homework and lecture PDFs are baked into the guest from this repo
at build time and exposed read-only at `/srv/course` (also symlinked as
`~/course-materials`). `seminars/solved/` is **excluded** — students get the
blank notebooks.

On first login each student gets their own writable copy of `seminars/` and
`ha/` in their home. Re-running `launch.sh` after editing the notebooks updates
`/srv/course` for everyone, but does not touch the copies students already have.

## Extending the environment with uv

The kernel is a Nix environment (see `python-env.nix`), so it cannot be
`pip install`-ed into. To add anything from PyPI, make a venv that inherits the
whole Nix stack and register it as its own kernel:

```sh
lab-venv extras                                   # creates ~/.venvs/extras + a kernel
uv pip install --python ~/.venvs/extras/bin/python some-package
```

Then pick **Python 3 (extras)** in JupyterLab. `--system-site-packages` means
PyMC, ArviZ, JAX and friends are still there; you only download what is new.
`programs.nix-ld` is enabled in the guest, so manylinux wheels run unmodified.
The venv and the uv cache live in `$HOME`, i.e. on the persistent disk.

`UV_PYTHON_DOWNLOADS=never` is set on purpose: a uv-managed interpreter would
not see the Nix site-packages.

## Admin operations

Everything below is run on the VM console (autologin as root) or over ssh if
you launched with `--ssh-port 2222 --ssh-key ~/.ssh/id_ed25519.pub`:

```sh
systemctl status jupyterhub
journalctl -u jupyterhub -f
systemctl restart jupyterhub                       # picks up students.txt

systemctl status jupyter-<name>-singleuser         # one student's server
systemctl show jupyter-<name>-singleuser -p MemoryMax -p CPUQuota

du -sh /var/lib/private/*                          # who is using the disk
```

Idle servers are culled after 2 h by default (`--idle-timeout`), which is what
makes 16 GiB per student affordable.

## Tuning

```sh
./lab/launch.sh --mem 128 --cpus 16 \
                --per-user-mem 8G --per-user-cpus 2 \
                --idle-timeout 3600
```

Rough rule: `per-user-mem × concurrent students ≲ guest RAM`. CPU can be
oversubscribed — `CPUQuota` is a ceiling, not a reservation.

The persistent disk size (`--data-size`, default 200 G) only applies when
`data.qcow2` is first created; changing it later does nothing.

## Caveats

- **Notebook drift.** Nixpkgs currently gives **PyMC 6.3**, **ArviZ 1.3** and
  **pandas 3.0**, while the seminars were written against PyMC 5.x / ArviZ 0.x
  and `environment.yaml` pins `pandas<2.0`. ArviZ 1.x and pandas 3.x are both
  breaking, so expect some notebooks to need porting. Escape hatch until then:
  `lab-venv legacy && uv pip install --python ~/.venvs/legacy/bin/python "pymc<6" "arviz<1" "pandas<2"`.
- **Plain HTTP.** With `--host 0.0.0.0` passwords cross the network in the
  clear. Keep the default `127.0.0.1` and put a TLS-terminating reverse proxy
  in front of it for anything beyond a trusted LAN.
- **First build is big** (PyMC, JAX, JupyterLab). On the teaching machine the
  configured extra substituters (`nix-community.cachix.org`, `cache.numtide.com`,
  `cache.nixos-cuda.org`) are unreachable and even `cache.nixos.org` answers
  slower than Nix's 5 s default `connect-timeout`, which makes the build look
  hung. Fix it with Nix's own `NIX_CONFIG` (it handles the empty value that a
  command-line `--option` cannot):

  ```sh
  export NIX_CONFIG='substituters = https://cache.nixos.org
  extra-substituters =
  connect-timeout = 60
  stalled-download-timeout = 600'
  ./lab/launch.sh --admin ferrine
  ```

  `LAB_NIX_OPTS` is also passed through to every `nix-build` for anything else
  (`--max-jobs`, `-j`, …). Do **not** add `--builders ""` — that forces QEMU and
  its whole graphics stack to be compiled locally, which is where the naive
  version of this workaround falls over.
- KVM is required; `launch.sh` refuses to start without `/dev/kvm`.

## Layout

```
launch.sh                       entry point: flags -> nix-build -> run the VM
default.nix                     wires the arguments into a NixOS evaluation
configuration.nix               the guest: JupyterHub, auth, kernels, uv, materials
vm.nix                          QEMU: RAM, vCPUs, disks, port forwarding
python-env.nix                  hubEnv (JupyterHub) and bayesEnv (student kernel)
pkgs/                           the two JupyterHub plugins missing from nixpkgs
students.txt.example            optional hard roster
state/                          disk images + built runner (gitignored)
```
