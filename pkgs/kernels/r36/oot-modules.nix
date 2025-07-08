{ applyPatches
, bspSrc
, buildPackages
, gitRepos
, kernel
, l4tMajorMinorPatchVersion
, lib
, runCommand
, stdenv
, ...
}:
let
  patchedBsp = applyPatches {
    name = "patchedBsp";
    src = bspSrc;
    patches = [
      ./Makefile.diff
    ];
  };

  mkCopyProjectCommand = project: ''
    mkdir -p "$out/${project.name}"
    cp --no-preserve=all -vr "${project}"/. "$out/${project.name}"
  '';

  l4t-oot-projects = [
    (applyPatches {
      name = "nvidia-oot";
      src = gitRepos.nvidia-oot;
      patches = [
        ./0002-sound-Fix-include-path-for-tegra-virt-alt-include.patch
      ] ++ lib.optionals (lib.versionAtLeast kernel.version "6.6") [
        ./0003-linux-6-6-build-fixes.patch
      ];
    })
    (gitRepos.nvgpu.overrideAttrs { name = "nvgpu"; })
    (applyPatches {
      name = "nvdisplay";
      src = gitRepos.nvdisplay;
      patches = [
        ./0001-nvidia-drm-Guard-nv_dev-in-nv_drm_suspend_resume.patch
        ./0002-ANDURIL-Add-some-missing-BASE_CFLAGS.patch
        ./0003-ANDURIL-Update-drm_gem_object_vmap_has_map_arg-test.patch
      ];
    })
    (applyPatches {
      name = "nvethernetrm";
      src = gitRepos.nvethernetrm;
      # Some directories in the git repo are RO.
      # This works for L4T b/c they use different output directory
      postPatch = ''
        chmod -R u+w osi
      '';
    })
    # Add hwpm for headers only - we don't build it separately
    (gitRepos.hwpm.overrideAttrs { name = "hwpm"; })
  ];

  l4t-oot-modules-sources = runCommand "l4t-oot-sources" { }
    (
      # Copy the Makefile
      ''
        mkdir -p "$out"
        cp "${patchedBsp}/source/Makefile" "$out/Makefile"
      ''
      # copy the projects
      + lib.strings.concatMapStringsSep "\n" mkCopyProjectCommand l4t-oot-projects
      # See bspSrc/source/source_sync.sh symlink at end of file
      + ''
        ln -vsrf "$out/nvethernetrm" "$out/nvidia-oot/drivers/net/ethernet/nvidia/nvethernet/nvethernetrm"
      ''
    );
in
stdenv.mkDerivation (finalAttrs: {
  pname = "l4t-oot-modules";
  version = "${l4tMajorMinorPatchVersion}";
  src = l4t-oot-modules-sources;

  inherit kernel;

  nativeBuildInputs = finalAttrs.kernel.moduleBuildDependencies;
  depsBuildBuild = [ buildPackages.stdenv.cc ];

  # See bspSrc/source/Makefile
  makeFlags = finalAttrs.kernel.makeFlags ++ [
    "KERNEL_HEADERS=${finalAttrs.kernel.dev}/lib/modules/${finalAttrs.kernel.modDirVersion}/source"
    "KERNEL_OUTPUT=${finalAttrs.kernel.dev}/lib/modules/${finalAttrs.kernel.modDirVersion}/build"
    "INSTALL_MOD_PATH=$(out)"
  ];

  # Build hwpm first to generate Module.symvers, then build nvidia-oot
  buildPhase = ''
    runHook preBuild
    
    # Use the cross-compiler
    export CC="${stdenv.cc.targetPrefix}cc"
    export LD="${stdenv.cc.targetPrefix}ld"
    export AR="${stdenv.cc.targetPrefix}ar"
    export OBJCOPY="${stdenv.cc.targetPrefix}objcopy"
    
    # First, run conftest to prepare the build environment
    echo "Running conftest..."
    make -f Makefile conftest \
      KERNEL_HEADERS=${finalAttrs.kernel.dev}/lib/modules/${finalAttrs.kernel.modDirVersion}/source \
      KERNEL_OUTPUT=${finalAttrs.kernel.dev}/lib/modules/${finalAttrs.kernel.modDirVersion}/build \
      CROSS_COMPILE=${stdenv.cc.targetPrefix}
    
    # First build hwpm to generate Module.symvers
    echo "Building hwpm to generate Module.symvers..."
    make -j $NIX_BUILD_CORES \
      ARCH=arm64 \
      CROSS_COMPILE=${stdenv.cc.targetPrefix} \
      CC="${stdenv.cc.targetPrefix}cc" \
      -C ${finalAttrs.kernel.dev}/lib/modules/${finalAttrs.kernel.modDirVersion}/build \
      M=$PWD/hwpm/drivers/tegra/hwpm \
      CONFIG_TEGRA_OOT_MODULE=m \
      srctree.hwpm=$PWD/hwpm \
      srctree.nvconftest=$PWD/out/nvidia-conftest \
      modules
    
    # Check if Module.symvers was generated
    if [ -f hwpm/drivers/tegra/hwpm/Module.symvers ]; then
      echo "HWPM Module.symvers generated successfully"
    else
      echo "Warning: HWPM Module.symvers not found, checking other locations..."
      find hwpm -name "Module.symvers" -type f
    fi
    
    # Now build the rest using the Makefile
    echo "Building nvidia-oot and other modules..."
    make -j $NIX_BUILD_CORES modules \
      ARCH=arm64 \
      CROSS_COMPILE=${stdenv.cc.targetPrefix} \
      CC="${stdenv.cc.targetPrefix}cc" \
      LD="${stdenv.cc.targetPrefix}ld" \
      AR="${stdenv.cc.targetPrefix}ar" \
      OBJCOPY="${stdenv.cc.targetPrefix}objcopy" \
      KERNEL_HEADERS=${finalAttrs.kernel.dev}/lib/modules/${finalAttrs.kernel.modDirVersion}/source \
      KERNEL_OUTPUT=${finalAttrs.kernel.dev}/lib/modules/${finalAttrs.kernel.modDirVersion}/build
    
    runHook postBuild
  '';

  # Custom install phase to avoid installing duplicate hwpm module
  installPhase = ''
    runHook preInstall
    
    # Install modules using make modules_install
    make modules_install \
      ARCH=arm64 \
      CROSS_COMPILE=${stdenv.cc.targetPrefix} \
      KERNEL_HEADERS=${finalAttrs.kernel.dev}/lib/modules/${finalAttrs.kernel.modDirVersion}/source \
      KERNEL_OUTPUT=${finalAttrs.kernel.dev}/lib/modules/${finalAttrs.kernel.modDirVersion}/build \
      INSTALL_MOD_PATH=$out
    
    # Remove duplicate hwpm module to prevent collision
    echo "Removing duplicate hwpm module to prevent collision..."
    find $out -name "nvhwpm.ko*" | while read hwpm_module; do
      echo "Found hwpm module at: $hwpm_module"
      # Keep only one copy - prefer the one in nvidia-oot
      if [[ "$hwpm_module" =~ "hwpm/drivers/tegra/hwpm" ]]; then
        echo "Removing standalone hwpm module: $hwpm_module"
        rm -f "$hwpm_module"
      fi
    done
    
    runHook postInstall
  '';

  # # GCC 14.2 seems confused about DRM_MODESET_LOCK_ALL_BEGIN/DRM_MODESET_LOCK_ALL_END in nvdisplay/kernel-open/nvidia-drm/nvidia-drm-drv.c:1344
  # extraMakeFlags = [ "KCFLAGS=-Wno-error=unused-label" ];
})
