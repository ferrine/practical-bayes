# jupyter-ai and the JupyterLab extensions it is built from. None of these are
# in nixpkgs (checked: 144 of its 158 transitive deps already are).
#
# Every package here publishes a pure `py3-none-any` wheel with the JavaScript
# already compiled, so these are wheel installs -- no node, no npm, no
# hatch-jupyter-builder. The wheels unpack their prebuilt assets into
# `share/jupyter/labextensions/` and `etc/jupyter/jupyter_server_config.d/`
# under the env prefix, which JupyterLab already searches (`jupyter --paths`),
# so nothing else has to be wired up.
#
# `agent-client-protocol` is deliberately held at 0.11.1: nixpkgs ships 0.12.0
# and jupyter-ai-acp-client requires >=0.11.0,<0.12.0. It is the single
# constraint violation out of the 42 these packages declare -- re-check it on
# every `npins update`.
#
# jupyter-ai 3.x pins its own sub-packages hard (>=0.3.0,<0.4.0 and friends),
# so this table moves as a set. Bump it all together, never piecemeal.
#
# Used as a python packageOverrides function -- see ../python-env.nix.
final: prev:

let
  # A prebuilt wheel straight off PyPI. `dist`/`python` = "py3" makes fetchPypi
  # build the .../py3/<initial>/<name>/<name>-<version>-py3-none-any.whl URL.
  wheel =
    {
      pname,
      version,
      hash,
      deps ? [ ],
    }:
    prev.buildPythonPackage {
      inherit pname version;
      format = "wheel";

      src = prev.fetchPypi {
        pname = builtins.replaceStrings [ "-" ] [ "_" ] pname;
        inherit version hash;
        format = "wheel";
        dist = "py3";
        python = "py3";
      };

      dependencies = map (d: final.${d}) deps;

      # Wheels carry no tests, and the real check is whether JupyterLab loads
      # the extension -- see the verification steps in lab/README.md.
      doCheck = false;

      meta = {
        description = "${pname} (prebuilt wheel from PyPI)";
        homepage = "https://pypi.org/project/${pname}/";
      };
    };
in
{
  agent-client-protocol = wheel {
    pname = "agent-client-protocol";
    version = "0.11.1";
    hash = "sha256-QnkPCiW4/ST1ybJ7fgw0Ej/BqYACStjvll0dFppeQtQ=";
    deps = [
      "pydantic"
    ];
  };

  jupyterlab-cell-input-footer = wheel {
    pname = "jupyterlab-cell-input-footer";
    version = "0.3.2";
    hash = "sha256-KkX7CUICP0AsuxwuwGacpPvKjVGhuMsmnSMi0+r5YgE=";
    deps = [
      "jupyterlab"
    ];
  };

  jupyterlab-diff = wheel {
    pname = "jupyterlab-diff";
    version = "0.7.1";
    hash = "sha256-B7uHA/YhwEldRrfqJQJQ0K3d+n0mJxP+EiihAkrz4ag=";
    deps = [
      "jupyterlab-cell-input-footer"
    ];
  };

  jupyterlab-ai-commands = wheel {
    pname = "jupyterlab-ai-commands";
    version = "0.4.0";
    hash = "sha256-hUp6pXriG+JvjzWhVHcddi+UVAqYd3eJiZhEVMM2fGg=";
    deps = [
      "jupyterlab-diff"
    ];
  };

  jupyterlab-chat = wheel {
    pname = "jupyterlab-chat";
    version = "0.25.0";
    hash = "sha256-+Q8M9DEu7ROHnYsym2raJhuUO4Sjvaag1VToxnWXOv8=";
    deps = [
      "jupyter-events"
      "jupyter-server"
      "jupyter-ydoc"
      "pycrdt"
    ];
  };

  jupyterlab-commands-toolkit = wheel {
    pname = "jupyterlab-commands-toolkit";
    version = "0.2.0";
    hash = "sha256-31Nkl8XkSBgRsSk961Dl4xsV5dkhltJ1yRfwvzRWsII=";
    deps = [
      "jupyter-server"
    ];
  };

  jupyter-live-content = wheel {
    pname = "jupyter-live-content";
    version = "0.1.1";
    hash = "sha256-8182bdBA6TA95sA6mS411TFybBUb8cv7ZF3YnY7g8oM=";
    deps = [
      "jupyter-server"
      "watchfiles"
    ];
  };

  jupyter-server-mcp = wheel {
    pname = "jupyter-server-mcp";
    version = "0.3.0";
    hash = "sha256-OiDeLPWKWjyBQYOCm24VfdOXw57dPKwT7RbyT1952OU=";
    deps = [
      "fastmcp"
      "jupyter-server"
    ];
  };

  jupyter-ai-router = wheel {
    pname = "jupyter-ai-router";
    version = "0.1.1";
    hash = "sha256-XX8RiTtCUzYbBDYedxj1RAelOJs+hyZtPNUBWRUU25E=";
    deps = [
      "jupyter-server"
      "jupyterlab-chat"
    ];
  };

  jupyter-ai-persona-manager = wheel {
    pname = "jupyter-ai-persona-manager";
    version = "0.2.0";
    hash = "sha256-1Zh6hl2d035Lb/mx2mtKbo4OVWmpUJWaJ5NBPwBPu74=";
    deps = [
      "importlib-metadata"
      "jupyter-ai-router"
      "jupyter-server"
      "jupyterlab-chat"
      "pydantic"
    ];
  };

  jupyter-ai-tools = wheel {
    pname = "jupyter-ai-tools";
    version = "0.7.0";
    hash = "sha256-9qf5Oj02Cm3FU8c2HFwlRO90ZckzTQX6CjlL3R+rE5E=";
    deps = [
      "jupyter-server"
      "jupyter-ydoc"
      "jupyterlab-ai-commands"
      "jupyterlab-commands-toolkit"
      "pycrdt"
    ];
  };

  jupyter-ai-chat-commands = wheel {
    pname = "jupyter-ai-chat-commands";
    version = "0.0.4";
    hash = "sha256-X4ymmuPjwH+RG2QhlnPsKi3f/B6T4E2Mzbebt5JQOrU=";
    deps = [
      "jupyter-ai-persona-manager"
      "jupyter-ai-router"
      "jupyter-server"
      "jupyterlab-chat"
    ];
  };

  jupyter-ai-acp-client = wheel {
    pname = "jupyter-ai-acp-client";
    version = "0.3.0";
    hash = "sha256-VbbUiw0uDWTa6M9jWhh1csPxmSfZsuTK3+p2KBE/yfM=";
    deps = [
      "agent-client-protocol"
      "jupyter-ai-persona-manager"
      "jupyter-server"
      "jupyterlab-chat"
      "pydantic"
    ];
  };

  jupyter-ai = wheel {
    pname = "jupyter-ai";
    version = "3.2.0";
    hash = "sha256-sgcwKzpFL16yRXYm6dVHOsdNr+XqDxyJDyjvdgCbxnU=";
    deps = [
      "jupyter-ai-acp-client"
      "jupyter-ai-chat-commands"
      "jupyter-ai-persona-manager"
      "jupyter-ai-router"
      "jupyter-ai-tools"
      "jupyter-live-content"
      "jupyter-server-mcp"
      "jupyterlab-chat"
      "jupyterlab-commands-toolkit"
    ];
  };

}
