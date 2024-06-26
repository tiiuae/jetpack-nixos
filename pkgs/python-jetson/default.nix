{ buildPythonPackage
, fetchFromGitHub
, fetchPypi
, pyftdi
}:

buildPythonPackage {
  pname = "python-jetson";
  version = "0.0.0";
  src = fetchFromGitHub {
    owner = "NVIDIA";
    repo = "python-jetson";
    rev = "7cf586612820b8c81a17168541eb8bfc45b010de";
    sha256 = "sha256-APlDliwGqlhWChJESyCYyI2N9/yzlRdp1qwvfqlRjKM=";
  };

  propagatedBuildInputs = [ pyftdi ];

  doCheck = false;
}

buildPythonPackage {
  version = "0.1.48";
  pname = "edk2-basetools";
  format = "pyproject";

  src = fetchPypi {
    inherit pname version;
    sha256 = "sha256-8gvv5cEQbdjdyp9govGL9ex9Xwb28JoD+ma65Ud35rs";
  };

  patches = [
  #  (fetchpatch2 {
  #    url = "https://patch-diff.githubusercontent.com/raw/whosaysni/robotframework-seriallibrary/pull/23.diff";
  #    sha256 = "sha256-fuPH+LkCuZBFCWRc1oCsTiqq/i2EsYJwaUh4hrdIJnw=";
  #  })
  ];

  # unit tests are impure
  # doCheck = false;

  #nativeBuildInputs = [
  #  poetry-core
  #];

  #propagatedBuildInputs = [
  #  robotframework
  #  pyserial
  #];

# meta = with pkgs.lib; {
#    description = "Python extension library for edk2 building";
#    homepage = "https://github.com/";
#    license = licenses.asl20;
#  };
}

