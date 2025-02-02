{
  buildPythonPackage,
  fetchFromGitHub,
  setuptools,
  setuptools-scm,
  python3Packages,
  pyyaml,
  edk2-pytool-library,
  pefile,
  gitpython,
  openpyxl,
  xlsxwriter,
}:

buildPythonPackage rec {
  pname = "edk2-pytool-extensions";
  version = "0.28.0";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "tianocore";
    repo = "edk2-pytool-extensions";
    rev = "refs/tags/v${version}";
    hash = "sha256-NuAuXmdcRjROV+az4Oji+PpZDawMt2LSwubJ7ldgYiI=";
  };

  patches = [
    ./0001-Remove-nuget-download-and-execute-it-without-Mono.patch
  ];

  SETUPTOOLS_SCM_PRETEND_VERSION = version;
  doCheck = false;

  buildInputs = [
    setuptools
    setuptools-scm
  ];

  dependencies = [
    edk2-pytool-library
    pefile
    gitpython
    openpyxl
    xlsxwriter
  ];

  propagatedBuildInputs = [
    pyyaml
    setuptools
    python3Packages.semantic-version
  ];
}
