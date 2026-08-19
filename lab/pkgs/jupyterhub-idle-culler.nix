# jupyterhub-idle-culler -- shuts down student servers that have been idle for a
# while, so a forgotten notebook does not sit on 16 GiB of RAM all week.
# Not in nixpkgs; packaged here from the PyPI sdist.
{ lib
, buildPythonPackage
, fetchPypi
, hatchling
, packaging
, python-dateutil
, tornado
, traitlets
}:

buildPythonPackage rec {
  pname = "jupyterhub-idle-culler";
  version = "2.0.0";
  pyproject = true;

  src = fetchPypi {
    pname = "jupyterhub_idle_culler";
    inherit version;
    hash = "sha256-o3dFShFesE2pvuxfjpsgAj+U8CWcEvGlkMRBItS+vQs=";
  };

  build-system = [ hatchling ];

  dependencies = [
    packaging
    python-dateutil
    tornado
    traitlets
  ];

  # Tests spin up a real JupyterHub.
  doCheck = false;
  pythonImportsCheck = [ "jupyterhub_idle_culler" ];

  meta = with lib; {
    description = "JupyterHub service that culls idle single-user servers";
    homepage = "https://github.com/jupyterhub/jupyterhub-idle-culler";
    license = licenses.bsd3;
    mainProgram = "jupyterhub-idle-culler";
  };
}
