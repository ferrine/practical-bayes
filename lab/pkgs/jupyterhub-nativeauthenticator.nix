# NativeAuthenticator -- the signup/approval authenticator used by the lab hub.
# Not in nixpkgs, so it is packaged here from the PyPI sdist. All of its runtime
# dependencies (jupyterhub, bcrypt, onetimepass) already are in nixpkgs.
{ lib
, buildPythonPackage
, fetchPypi
, setuptools
, jupyterhub
, bcrypt
, onetimepass
}:

buildPythonPackage rec {
  pname = "jupyterhub-nativeauthenticator";
  version = "1.3.0";
  pyproject = true;

  src = fetchPypi {
    pname = "jupyterhub_nativeauthenticator";
    inherit version;
    hash = "sha256-Z9SdagRlhJSmWEZtvkxkGLaK5ldzJIVa/l/Iq9+G74k=";
  };

  # 1.3.0 still ships a setup.py-driven sdist (the hatchling migration landed
  # after the release), so the pyproject.toml carries no build-system table.
  build-system = [ setuptools ];

  dependencies = [
    jupyterhub
    bcrypt
    onetimepass # optional 2FA support; imported unconditionally by the module
  ];

  # The test suite needs a live hub; the import check is what matters for us.
  doCheck = false;
  pythonImportsCheck = [ "nativeauthenticator" ];

  meta = with lib; {
    description = "JupyterHub authenticator with a native signup/approval flow";
    homepage = "https://github.com/jupyterhub/nativeauthenticator";
    license = licenses.bsd3;
  };
}
