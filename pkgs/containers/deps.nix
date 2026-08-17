{ lib
, runCommand
, dpkg
, debs
, l4tMajorMinorPatchVersion
, l4tAtLeast
, l4t-cuda
, l4t-video-codec-openrm
}:

runCommand "container-deps" { nativeBuildInputs = [ dpkg ]; }
  (
    (lib.concatStringsSep "\n"
      (lib.mapAttrsToList
        (deb: debFiles:
          let
            repo = if l4tAtLeast "38" then "som" else "t234";
          in
          (if builtins.hasAttr deb debs.${repo} then ''
            echo Unpacking ${deb}; dpkg -x ${debs.${repo}.${deb}.src} debs
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
        (lib.importJSON ./r${lib.versions.major l4tMajorMinorPatchVersion}-l4t.json)))
      + lib.optionalString (l4tAtLeast "39") ''
      # Mirror the host libraries added to drivers.csv in l4t-csv.nix.
      mkdir -p $out/usr/lib/aarch64-linux-gnu/nvidia
      ln -s ${l4t-cuda}/lib/libcuda.so.1.1 $out/usr/lib/aarch64-linux-gnu/nvidia/libcuda.so.1.1
      ln -s libcuda.so.1.1 $out/usr/lib/aarch64-linux-gnu/nvidia/libcuda.so.1
      ln -s libcuda.so.1 $out/usr/lib/aarch64-linux-gnu/nvidia/libcuda.so
      ln -s ${l4t-cuda}/lib/libcuda_instrumentation.so $out/usr/lib/aarch64-linux-gnu/nvidia/libcuda_instrumentation.so
      ln -s libcuda_instrumentation.so $out/usr/lib/aarch64-linux-gnu/nvidia/libcuda_instrumentation.so.1
      ln -s ${l4t-video-codec-openrm}/opt/nvidia/l4t-gpu-libs/openrm/libnvcuvid.so $out/usr/lib/aarch64-linux-gnu/nvidia/libnvcuvid.so
      ln -s libnvcuvid.so $out/usr/lib/aarch64-linux-gnu/nvidia/libnvcuvid.so.1
    ''
  )
