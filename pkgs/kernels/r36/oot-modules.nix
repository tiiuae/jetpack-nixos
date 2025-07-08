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
      ./0001-fix-kernel-source-paths.patch
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
        ./0004-downgrade-gcc-14-errors.patch
      ] ++ lib.optionals (lib.versionAtLeast kernel.version "6.6") [
        ./0003-linux-6-6-build-fixes.patch
      ];
    })
    (applyPatches {
      name = "nvgpu";
      src = gitRepos.nvgpu;
      patches = [
        ./0004-downgrade-gcc-14-errors.patch
      ];
    })
    (applyPatches {
      name = "nvdisplay";
      src = gitRepos.nvdisplay;
      patches = [
        ./0001-nvidia-drm-Guard-nv_dev-in-nv_drm_suspend_resume.patch
        ./0002-ANDURIL-Add-some-missing-BASE_CFLAGS.patch
        ./0003-ANDURIL-Update-drm_gem_object_vmap_has_map_arg-test.patch
        ./0004-downgrade-gcc-14-errors.patch
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
    # Add hwpm - will be built for Module.symvers
    (applyPatches {
      name = "hwpm";
      src = gitRepos.hwpm;
      patches = [
        ./0004-downgrade-gcc-14-errors.patch
      ];
    })
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

  # Use default buildPhase with makeFlags
  buildFlags = [ "modules" ];

  # Use default install phase
  installTargets = [ "modules_install" ];

  # Remove duplicate hwpm module to prevent collision
  postInstall = ''
    # Find all nvhwpm.ko* files
    hwpm_files=$(find $out -name "nvhwpm.ko*" -type f || true)
    hwpm_count=$(echo "$hwpm_files" | grep -c . || echo 0)
    
    if [ "$hwpm_count" -gt 1 ]; then
      echo "Found $hwpm_count hwpm modules, removing duplicates..."
      # Keep the one in nvidia-oot, remove standalone
      echo "$hwpm_files" | while read -r hwpm_module; do
        if [[ "$hwpm_module" =~ "/hwpm/drivers/tegra/hwpm/" ]]; then
          echo "Removing standalone hwpm module: $hwpm_module"
          rm -f "$hwpm_module"
        fi
      done
    fi
  '';

  # # GCC 14.2 seems confused about DRM_MODESET_LOCK_ALL_BEGIN/DRM_MODESET_LOCK_ALL_END in nvdisplay/kernel-open/nvidia-drm/nvidia-drm-drv.c:1344
  # extraMakeFlags = [ "KCFLAGS=-Wno-error=unused-label" ];
})
