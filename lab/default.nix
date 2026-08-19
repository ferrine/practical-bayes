# The course lab VM: a NixOS guest running JupyterHub, built with plain Nix and
# the repo-level npins pin (same convention as ../default.nix -- no flakes).
#
# Do not call this directly; ./launch.sh passes every knob below as --argstr
# and then runs the resulting VM. Everything is a string so that a single
# --argstr code path works for all of them.
#
#   nix-build lab -A vm      # just build the runner
#   nix-build lab -A bayesEnv --no-out-link   # inspect the student python env
{ sources ? import ../npins
, pkgs ? import sources.nixpkgs { }

  # --- host side ---
, hostAddress ? "127.0.0.1" # which host interface the hub is published on
, hostPort ? "8000"
, memoryMiB ? "262144" # 256 GiB
, cores ? "24"
, rootDiskMiB ? "20480" # disposable OS disk
, sshPort ? "" # "" disables the ssh forward

  # --- guest side ---
, admins ? "admin" # comma-separated JupyterHub admin usernames
, perUserMemory ? "16G" # MemoryMax per student server
, perUserCpus ? "4" # CPUQuota per student server
, idleTimeout ? "7200" # seconds before an idle server is culled
, sshKeys ? "" # newline-separated authorized_keys for root
}:

let
  inherit (pkgs) lib;

  splitNonEmpty = sep: s:
    builtins.filter (x: x != "") (map lib.strings.trim (lib.splitString sep s));

  labCfg = {
    inherit hostAddress perUserMemory perUserCpus;
    hostPort = lib.toInt hostPort;
    memoryMiB = lib.toInt memoryMiB;
    cores = lib.toInt cores;
    rootDiskMiB = lib.toInt rootDiskMiB;
    idleTimeout = lib.toInt idleTimeout;
    sshPort = if sshPort == "" then null else lib.toInt sshPort;

    # Port JupyterHub listens on *inside* the VM. Not configurable: the host
    # side is what varies, and the forward maps hostPort -> hubPort.
    hubPort = 8000;

    admins = splitNonEmpty "," admins;
    sshKeys = splitNonEmpty "\n" sshKeys;
  };

  nixos = import "${sources.nixpkgs}/nixos" {
    system = "x86_64-linux";
    configuration = {
      imports = [
        # `nixos-rebuild build-vm` adds this module implicitly; a plain
        # `import <nixpkgs/nixos>` does not, so pull it in by hand.
        "${sources.nixpkgs}/nixos/modules/virtualisation/qemu-vm.nix"
        ./configuration.nix
        ./vm.nix
      ];
      # Reuse the already-instantiated nixpkgs instead of evaluating a second one.
      nixpkgs.pkgs = pkgs;
      _module.args.labCfg = labCfg;
    };
  };

  pyenv = import ./python-env.nix { inherit pkgs; };
in
{
  # `result/bin/run-practical-bayes-lab-vm` -- what launch.sh executes.
  inherit (nixos) vm system;

  # Host-side tools launch.sh needs, taken from the same pin.
  inherit (pkgs) qemu_kvm e2fsprogs;

  inherit (pyenv) bayesEnv hubEnv;
}
