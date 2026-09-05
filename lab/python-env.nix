# The two Python environments the lab VM needs.
#
#   hubEnv    -- JupyterHub itself plus the spawner/authenticator/culler plugins.
#   bayesEnv  -- what students actually get: the JupyterLab server *and* the
#                default kernel. One env for both keeps the closure small and
#                means `uv venv --system-site-packages` on top of it inherits
#                everything (see the `lab-venv` helper in configuration.nix).
{ pkgs }:

let
  # Pinned deliberately rather than following pkgs.python3. When nixpkgs moved
  # its default to 3.14, nutpie / numpyro / bambi stopped evaluating there
  # (tensorflow-bin has no 3.14 build). A teaching environment should not
  # follow that bump by accident -- raise this on purpose, after checking the
  # whole stack still builds.
  python = pkgs.python313.override {
    # jupyter-ai and its JupyterLab extensions, none of which nixpkgs carries.
    packageOverrides = import ./pkgs/jupyter-ai.nix;
  };
  callPackage = python.pkgs.callPackage;
in
rec {
  inherit python;

  nativeauthenticator = callPackage ./pkgs/jupyterhub-nativeauthenticator.nix { };
  idle-culler = callPackage ./pkgs/jupyterhub-idle-culler.nix { };

  hubEnv = python.withPackages (ps: [
    ps.jupyterhub
    ps.jupyterhub-systemdspawner
    nativeauthenticator
    idle-culler
  ]);

  bayesEnv = python.withPackages (ps: with ps; [
    # --- the hub side of a single-user server ---
    jupyterhub # provides jupyterhub-singleuser
    jupyterlab
    notebook
    jupytext
    jupyterlab-git
    ipykernel
    ipywidgets

    # AI assistant: chat panel, /commands, and agent support over ACP + MCP.
    # Students supply their own provider credentials in the JupyterLab UI;
    # those land in their own Jupyter config dir on the persistent disk.
    jupyter-ai

    # --- Bayes ---
    pymc
    pytensor
    nutpie
    arviz
    numpyro
    bambi
    blackjax
    jax
    jaxlib

    # --- array / dataframe / IO ---
    numpy
    scipy
    pandas
    polars
    xarray
    xarray-einstats
    h5netcdf
    netcdf4
    numba

    # --- ML & stats ---
    scikit-learn
    statsmodels

    # --- plotting & misc ---
    matplotlib
    seaborn
    graphviz
    watermark
    requests
  ]);

  # NativeAuthenticator ships its signup/authorize templates as package data;
  # JupyterHub needs to be pointed at them explicitly.
  nativeauthenticatorTemplates =
    "${hubEnv}/${python.sitePackages}/nativeauthenticator/templates";
}
