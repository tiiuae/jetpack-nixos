{ buildFromDebs
, debs
, lib
}:
let
  # Find the nsight-compute version from available debs
  nsightComputeDebs = lib.filterAttrs (n: v: lib.hasPrefix "nsight-compute-" n && n != "nsight-compute-addon-l4t") debs.common;
  nsightComputeVersion = lib.head (lib.mapAttrsToList (n: v: lib.removePrefix "nsight-compute-" n) nsightComputeDebs);
  
  finalAttrs = {
    pname = "nsight-compute-target";
    version = nsightComputeVersion;
    srcs = debs.common."nsight-compute-${finalAttrs.version}".src;
    postPatch = ''
      # ncu relies on relative folder structure to find sections file so emulate that
      mkdir -p target
      cp -r "opt/nvidia/nsight-compute/${finalAttrs.version}/target/linux-v4l_l4t-t210-a64" target
      cp -r "opt/nvidia/nsight-compute/${finalAttrs.version}/extras" .
      cp -r "opt/nvidia/nsight-compute/${finalAttrs.version}/sections" .
      rm -rf opt usr

      # ncu requires that it remains under its original directory so symlink instead of copying
      # things out
      mkdir -p bin
      ln -sfv ../target/linux-v4l_l4t-t210-a64/ncu ./bin/ncu
    '';
    meta.platforms = [ "aarch64-linux" ];
  };
in
buildFromDebs finalAttrs
