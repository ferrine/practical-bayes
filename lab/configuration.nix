# Guest system for the course lab: JupyterHub with self-signup, a PyMC/pydata
# kernel, per-student resource caps and persistent home directories.
#
# See ./vm.nix for the QEMU side (RAM, vCPUs, disks, port forwarding) and
# ./launch.sh for the entry point.
{ config, lib, pkgs, labCfg, ... }:

let
  pyenv = import ./python-env.nix { inherit pkgs; };
  inherit (pyenv) hubEnv bayesEnv python;

  # --- course materials -------------------------------------------------
  # Copied into the store from the repo so the VM carries a snapshot of the
  # notebooks. `solved/` is deliberately excluded -- students get the blank
  # seminars, not the solutions.
  keep = base:
    base != "solved"
    && base != ".ipynb_checkpoints"
    && base != "__pycache__"
    && !(lib.hasSuffix "~" base);

  seminars = builtins.path {
    path = ../seminars;
    name = "practical-bayes-seminars";
    filter = path: _type: keep (baseNameOf path);
  };

  ha = builtins.path {
    path = ../ha;
    name = "practical-bayes-ha";
    filter = path: _type: keep (baseNameOf path);
  };

  # Top-level PDFs only -- no .tex sources, no img/.
  lecturePdfs = builtins.path {
    path = ../lectures;
    name = "practical-bayes-lectures";
    filter = path: type: type == "regular" && lib.hasSuffix ".pdf" path;
  };

  courseMaterials = pkgs.runCommand "practical-bayes-materials" { } ''
    mkdir -p $out
    cp -r ${seminars} $out/seminars
    cp -r ${ha} $out/ha
    cp -r ${lecturePdfs} $out/lectures
  '';

  # --- single-user server wrapper --------------------------------------
  # Runs *inside* the student's systemd unit, so $HOME is the (already
  # created and chowned) persistent StateDirectory. Doing the seeding here
  # rather than from the hub avoids having to guess the dynamic UID.
  singleuserCmd = pkgs.writeShellScript "lab-singleuser" ''
    set -eu

    export UV_CACHE_DIR="$HOME/.cache/uv"
    export UV_PYTHON="${bayesEnv}/bin/python3"
    # A uv-managed interpreter would not see the Nix site-packages.
    export UV_PYTHON_DOWNLOADS=never

    # Read-only view of the current course materials, always up to date.
    ln -sfn /srv/course "$HOME/course-materials"

    if [ ! -e "$HOME/.lab-seeded" ]; then
      echo "seeding $HOME from /srv/course"
      cp -rL --no-preserve=mode,ownership /srv/course/seminars "$HOME/seminars"
      cp -rL --no-preserve=mode,ownership /srv/course/ha "$HOME/ha"
      chmod -R u+rwX "$HOME/seminars" "$HOME/ha"
      touch "$HOME/.lab-seeded"
    fi

    exec ${bayesEnv}/bin/jupyterhub-singleuser "$@"
  '';

  # --- student-facing helper -------------------------------------------
  # Extend the Nix environment with anything from PyPI, in a venv that
  # inherits the whole Bayes stack, and expose it as its own kernel.
  labVenv = pkgs.writeShellApplication {
    name = "lab-venv";
    runtimeInputs = [ pkgs.uv ];
    text = ''
      name="''${1:-extras}"
      venv="$HOME/.venvs/$name"

      if [ ! -d "$venv" ]; then
        uv venv --system-site-packages --python ${bayesEnv}/bin/python3 "$venv"
      fi
      "$venv/bin/python" -m ipykernel install --user \
        --name "$name" --display-name "Python 3 ($name)"

      cat <<EOF

      Ready. Install into it with:

          uv pip install --python $venv/bin/python <package>

      then pick the "Python 3 ($name)" kernel in JupyterLab.
      EOF
    '';
  };

  # Python set literal; `{}` would be an empty *dict*, hence the special case.
  adminSet =
    if labCfg.admins == [ ] then
      "set()"
    else
      "{${lib.concatMapStringsSep ", " (u: ''"${u}"'') labCfg.admins}}";
in
{
  # ---------------------------------------------------------------- system
  system.stateVersion = "25.11";
  networking.hostName = "practical-bayes-lab";
  networking.firewall.allowedTCPPorts = [ 22 labCfg.hubPort ];

  time.timeZone = "Europe/Moscow";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.supportedLocales = [ "en_US.UTF-8/UTF-8" "ru_RU.UTF-8/UTF-8" ];

  # The launcher attaches the VM console to the terminal it was started from;
  # whoever can see that console already controls the VM, so no password dance.
  services.getty.autologinUser = "root";

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };
  users.users.root.openssh.authorizedKeys.keys = labCfg.sshKeys;

  environment.systemPackages = with pkgs; [
    bayesEnv
    labVenv
    uv
    git
    graphviz # `pm.model_to_graphviz()` shells out to `dot`
    curl
    htop
    tmux
    vim
    less
    file
    unzip
  ];

  # manylinux wheels installed by uv link against a plain FHS loader.
  programs.nix-ld.enable = true;

  # Read-only snapshot of the course materials, seeded into homes on first login.
  systemd.tmpfiles.rules = [
    "L+ /srv/course - - - - ${courseMaterials}"
  ];

  # ------------------------------------------------------------- jupyterhub
  services.jupyterhub = {
    enable = true;
    host = "0.0.0.0"; # inside the VM; exposure is controlled by the port forward
    port = labCfg.hubPort;

    authentication = "nativeauthenticator.NativeAuthenticator";
    jupyterhubEnv = hubEnv;
    jupyterlabEnv = bayesEnv;

    kernels.python3 = {
      displayName = "Python 3 (Bayes)";
      language = "python";
      argv = [
        "${bayesEnv}/bin/python3"
        "-m"
        "ipykernel_launcher"
        "-f"
        "{connection_file}"
      ];
      logo32 = "${bayesEnv}/${python.sitePackages}/ipykernel/resources/logo-32x32.png";
      logo64 = "${bayesEnv}/${python.sitePackages}/ipykernel/resources/logo-64x64.png";
    };

    # Appended after the module's own defaults, so anything here wins.
    extraConfig = ''
      import os

      # ---------------------------------------------------------- accounts
      # Students register themselves at /hub/signup; an admin approves them at
      # /hub/admin. The approval queue is the whitelist.
      c.JupyterHub.template_paths = ["${pyenv.nativeauthenticatorTemplates}"]

      c.Authenticator.admin_users = ${adminSet}

      # JupyterHub >= 5 rejects everyone unless some allow rule matches, and
      # NativeAuthenticator does not override check_allowed -- it gates on its
      # own approval flag inside authenticate() instead. So hand authorization
      # over to it wholesale; the roster below flips this back off.
      c.Authenticator.allow_all = True

      c.NativeAuthenticator.open_signup = False
      c.NativeAuthenticator.enable_signup = True
      c.NativeAuthenticator.check_common_password = True
      c.NativeAuthenticator.minimum_password_length = 10
      c.NativeAuthenticator.allowed_failed_logins = 5
      c.NativeAuthenticator.seconds_before_next_try = 60
      c.NativeAuthenticator.ask_email_on_signup = True

      # Optional hard roster. Drop one username per line into this file on the
      # persistent disk and restart the hub -- only those names may log in.
      # No rebuild needed; delete the file to go back to approval-only mode.
      _roster_path = "/var/lib/jupyterhub/students.txt"
      if os.path.exists(_roster_path):
          with open(_roster_path) as _fh:
              _roster = {
                  line.strip()
                  for line in _fh
                  if line.strip() and not line.lstrip().startswith("#")
              }
          if _roster:
              c.Authenticator.allow_all = False
              c.Authenticator.allowed_users = _roster | set(c.Authenticator.admin_users)
              # Without this, JupyterHub keeps letting in every account that
              # already exists in its database (allow_existing_users defaults
              # to True as soon as allowed_users is set), and the roster would
              # only ever *add* people.
              c.Authenticator.allow_existing_users = False

      # ---------------------------------------------------------- spawning
      # Dynamic users: systemd mints a UID per student on spawn and keeps a
      # persistent StateDirectory at /var/lib/private/<name> (= their $HOME),
      # which lives on the data disk. No declarative Unix users needed, and
      # DynamicUser gives us ProtectSystem=strict/PrivateTmp for free.
      c.SystemdSpawner.dynamic_users = True
      c.SystemdSpawner.cmd = "${singleuserCmd}"
      c.SystemdSpawner.default_shell = "${pkgs.bashInteractive}/bin/bash"
      c.SystemdSpawner.disable_user_sudo = True
      c.SystemdSpawner.isolate_tmp = True
      c.SystemdSpawner.mem_limit = "${labCfg.perUserMemory}"
      c.SystemdSpawner.cpu_limit = ${toString labCfg.perUserCpus}
      c.SystemdSpawner.extra_paths = [
          "${bayesEnv}/bin",
          "${labVenv}/bin",
          "/run/current-system/sw/bin",
      ]

      # First spawn copies the course materials into the home directory.
      c.Spawner.start_timeout = 180
      c.Spawner.http_timeout = 120

      # ------------------------------------------------------- idle culling
      # 16 GiB per student is only affordable if forgotten servers go away.
      c.JupyterHub.services = [
          {
              "name": "idle-culler",
              "command": [
                  "${hubEnv}/bin/python3",
                  "-m",
                  "jupyterhub_idle_culler",
                  "--timeout=${toString labCfg.idleTimeout}",
                  "--cull-every=600",
              ],
          }
      ]
      c.JupyterHub.load_roles = [
          {
              "name": "idle-culler",
              "scopes": [
                  "list:users",
                  "read:users:activity",
                  "read:servers",
                  "delete:servers",
              ],
              "services": ["idle-culler"],
          }
      ]
    '';
  };
}
