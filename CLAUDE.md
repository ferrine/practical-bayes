# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Course materials for "Practical Bayesian Methods" (Прикладные байесовские методы), taught at MSU by Maxim Kochurov (PyMC core dev). Four kinds of content:

- `lectures/` — LaTeX **beamer** slide decks, maintained in **two languages**.
- `seminars/` — Jupyter notebooks (PyMC) used live in class, with worked solutions under `seminars/solved/`.
- `ha/` — homework notebooks (`ha-N.ipynb`) plus their data files.
- `lab/` — the JupyterHub VM students actually work in (see below).

## Version control: git

Plain **git**. `main` tracks `origin/main` (`git@github.com:ferrine/practical-bayes.git`); other branches are `master` and `year-2025`.

Note the repo tracks the **built lecture PDFs** (`lectures/*.pdf`) alongside their `.tex` sources — regenerate and commit them when a deck changes (see the build section below). LaTeX intermediates (`.aux`, `.log`, `.nav`, …) and the conda/editor noise are covered by `.gitignore`.

## Lectures: the bilingual convention

Each lecture exists as a pair of `.tex` files in `lectures/`:

- `lecture-N.ru.tex` — **Russian** (the original source).
- `lecture-N.tex` — **English** (translation of the `.ru` version).

The active work in this repo is **translating the Russian decks into English** (see recent commits like "translate HSGP part"). When translating, mirror the structure of the `.ru.tex` file frame-by-frame; only the natural-language text and `\title`/`\section` strings change — keep math, `\includegraphics`, and layout identical. `teaser.tex` / `teaser.ru.tex` follow the same pairing.

Shared across all decks:
- `ferres.sty` — the custom beamer package (theme AnnArbor/crane, `minted` for code, tikz, custom macros like `\cond`).
- `math_commands.tex` — shared math macros, `\input` at the top of every deck.
- `references.bib` — bibliography for all lectures.
- `img/` — figures referenced by `\includegraphics`.

### Building a deck

The toolchain (TeX Live + `latexmk` + `pygmentize`) is defined in **`default.nix`**, with nixpkgs pinned via **npins** (`npins/sources.json`) — no flakes, no system TeX install needed. Enter the shell, then use `make`:

```sh
nix-shell                       # from repo root; provides texlive, latexmk, pygmentize
cd lectures
make                            # build every deck (English + .ru + teaser)
make lecture-5.pdf              # build one deck
make clean                      # remove intermediates incl. _minted-* (keeps PDFs)
make cleanall                   # also remove the PDFs
```

`nix-build` realises just the TeX Live bundle (`default.nix`'s `tex` attribute) into `./result`. To bump nixpkgs: `npins update` (then rebuild).

The build is driven by **`latexmk`** (config in `lectures/.latexmkrc`): it reruns `pdflatex`/`bibtex` until cross-references, the TOC, and the bibliography converge, so the output is consistent regardless of how many passes a deck needs. `minted` needs `-shell-escape` + `pygmentize`; both are handled by `.latexmkrc` and `default.nix` respectively (this is why a bare system `pdflatex` historically failed on decks with code listings).

**Two gotchas on this machine:**

1. A `zsh` plugin wraps `nix-shell` and breaks `--run` non-interactively (`/scripts/buildShellShim: No such file or directory`). Bypass it with `command nix-shell --run '...'`.
2. Nix offloads builds to a remote builder that can't reach `nix-community.cachix.org` / `cache.numtide.com`, so the `texlive.combine` step can hang then fail at <1 B/s. If a build stalls on cache downloads, force a **local** build off the official cache:

```sh
command nix-shell --builders "" \
  --option substituters "https://cache.nixos.org" \
  --option extra-substituters "" \
  --run 'cd lectures && make'
```

The individual TeX packages still come from `cache.nixos.org`; only the final combine needs to run locally.

## Notebooks (seminars & homework)

Run against the conda environment defined in `environment.yaml` (`conda env create -f environment.yaml`, env name `practical-bayes-env`). Core stack: **PyMC ≥5.8**, PyTensor, ArviZ, NumPy, `pandas<2.0`, matplotlib/seaborn, scikit-learn. The `pandas<2.0` pin is intentional.

`seminars/N-*.ipynb` are the in-class (often blank-to-fill) versions; `seminars/solved/` holds the completed counterparts. Keep the two in sync when editing a seminar.

## The lab VM (`lab/`)

A NixOS guest run under QEMU/KVM that serves JupyterHub to the class. Same plain-Nix + npins convention as the lectures (it reuses `../npins`), no flakes. `lab/README.md` is the operator-facing doc; the short version:

```sh
./lab/launch.sh --admin ferrine       # build + boot; 127.0.0.1:8000 by default
./lab/launch.sh --help                # every knob (host/port/RAM/CPU/caps/roster)
```

Structure: `launch.sh` (flags → `nix-build` → run) → `default.nix` (arguments → NixOS eval) → `configuration.nix` (the guest) + `vm.nix` (QEMU) + `python-env.nix` (the two Python envs) + `pkgs/` (two JupyterHub plugins missing from nixpkgs).

Things that are easy to get wrong when editing this:

- **Every knob goes through `nix-build` as an `--argstr`**, so all of `default.nix`'s arguments are strings and get converted in `labCfg`. Keep it that way — one code path, no build-time/runtime drift.
- `import <nixpkgs/nixos>` does **not** pull in `virtualisation/qemu-vm.nix` (only `nixos-rebuild build-vm` does); `lab/default.nix` imports it explicitly.
- `services.jupyterhub.extraConfig` is appended *after* the module's own settings, so anything set there wins — including `c.SystemdSpawner.cmd`, which is overridden with a wrapper that seeds `$HOME` from `/srv/course` on first spawn.
- Students are **not** declarative Unix users. `SystemdSpawner.dynamic_users = True` gives each one a systemd `DynamicUser` whose `StateDirectory` (`/var/lib/private/<name>`) is their `$HOME`.
- Persistence is one disk image, `lab/state/data.qcow2`, mounted at `/var/lib`: hub database (accounts, approvals) plus every home. `root.qcow2` is disposable. `lab/state/` is gitignored — **`data.qcow2` is the backup target**.
- The kernel comes from nixpkgs and cannot be `pip install`-ed into; the supported way to extend it is `lab-venv <name>` (a `uv venv --system-site-packages` on top of the Nix env, registered as its own kernel). `programs.nix-ld` is enabled so manylinux wheels work.
- Nixpkgs gives PyMC 6 / ArviZ 1 / pandas 3, which is **ahead** of what the seminars were written against (see the pin note above) — expect notebook porting work, not a config fix.
- `python-env.nix` pins `pkgs.python313` rather than following `pkgs.python3`. After nixpkgs moved its default to 3.14, `nutpie`/`numpyro`/`bambi` stopped evaluating there (`tensorflow-bin` has no 3.14 build). Re-check the whole stack before raising it.

## Housekeeping

Editor backup/undo artifacts (`*~`, `*.~undo-tree~`, `..gitignore.~undo-tree~`) and LaTeX build leftovers (`.aux`, `.log`, `.nav`, etc.) are scattered in the tree — ignore them; do not edit or "clean up" `*~` files as if they were source.
