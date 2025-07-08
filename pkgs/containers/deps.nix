{ lib
, runCommand
, dpkg
, debs
, l4tVersion
}:
let

  l4t-file =
    if l4tVersion == "36.4.3" then
      ./l4t-r36-4-3.json
    else if l4tVersion == "35.6.0" then
      ./l4t-r35-6.json
    else
      throw "Not supported l4tVersion version";

in

runCommand "container-deps" { nativeBuildInputs = [ dpkg ]; }
  (lib.concatStringsSep "\n"
    (lib.mapAttrsToList
      (deb: debFiles:
      (if builtins.hasAttr deb debs.t234 then ''
        echo Unpacking ${deb}; dpkg -x ${debs.t234.${deb}.src} debs
      '' else ''
        echo Unpacking ${deb}; dpkg -x ${debs.common.${deb}.src} debs
      '') + (lib.concatStringsSep "\n" (map
        (file: ''
          if [[ -f debs${file} ]]; then
            install -D --target-directory=$out${builtins.dirOf file} debs${file}
          else
            echo "WARNING: file ${file} not found in deb ${deb}"
          fi
        '')
        debFiles)))
      (lib.importJSON l4t-file)))
