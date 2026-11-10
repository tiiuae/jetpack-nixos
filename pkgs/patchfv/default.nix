{ buildPackages
, fetchFromGitHub
, lib
,
}:

let
  uefi-firmware-parser =
    if lib.versionAtLeast lib.trivial.release "26.05" then
      buildPackages.python3Packages.uefi-firmware-parser
    else
      buildPackages.python3Packages.buildPythonPackage {
        pname = "uefi-firmware-parser";
        version = "1.14";
        pyproject = true;

        src = fetchFromGitHub {
          owner = "theopolis";
          repo = "uefi-firmware-parser";
          tag = "v1.14";
          hash = "sha256-flBnYDVc0ZAG0wW613XUjAdCuHSn7uw2VDMLRFIgaNY=";
        };

        build-system = [
          buildPackages.python3Packages.setuptools
          buildPackages.python3Packages.wheel
        ];

        pythonRemoveDeps = [ "future" ];

        pythonImportsCheck = [ "uefi_firmware" ];

        meta = {
          description = "Tool for parsing, extracting, and recreating UEFI firmware volumes";
          homepage = "https://github.com/theopolis/uefi-firmware-parser";
          license = lib.licenses.mit;
          mainProgram = "uefi-firmware-parser";
          platforms = lib.platforms.unix;
        };
      };
in

buildPackages.writers.writePython3Bin "patchfv"
{
  libraries = [ uefi-firmware-parser ];
  # E501: ignore line length
  flakeIgnore = [ "E501" ];
}
  (builtins.readFile ./patchfv.py)
