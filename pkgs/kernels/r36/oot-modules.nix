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
    # Add hwpm - needed for conftest and Module.symvers
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

  # Use default buildPhase with makeFlags
  buildFlags = [ "modules" ];

  # Use default install phase
  installTargets = [ "modules_install" ];

  # Remove duplicate hwpm module to prevent collision
  # The hwpm module is built both standalone and as part of nvidia-oot
  postInstall = ''
    echo "=== Looking for hwpm modules to deduplicate ==="
    find $out -name "nvhwpm.ko*" -type f | while read -r f; do
      echo "Found hwpm module: $f"
    done
    
    # The hwpm module gets built twice:
    # 1. As part of nvidia-oot (in .../updates/nvhwpm.ko.xz)
    # 2. As standalone hwpm (in .../updates/drivers/tegra/hwpm/nvhwpm.ko.xz)
    # We remove the standalone one to prevent collision
    standalone_hwpm="$out/lib/modules/${kernel.modDirVersion}/updates/drivers/tegra/hwpm/nvhwpm.ko.xz"
    if [ -f "$standalone_hwpm" ]; then
      echo "Removing duplicate standalone hwpm module: $standalone_hwpm"
      rm -f "$standalone_hwpm"
      # Clean up empty directories
      rmdir "$out/lib/modules/${kernel.modDirVersion}/updates/drivers/tegra/hwpm" 2>/dev/null || true
      rmdir "$out/lib/modules/${kernel.modDirVersion}/updates/drivers/tegra" 2>/dev/null || true
      rmdir "$out/lib/modules/${kernel.modDirVersion}/updates/drivers" 2>/dev/null || true
    fi
  '';

  # # GCC 14.2 seems confused about DRM_MODESET_LOCK_ALL_BEGIN/DRM_MODESET_LOCK_ALL_END in nvdisplay/kernel-open/nvidia-drm/nvidia-drm-drv.c:1344
  # extraMakeFlags = [ "KCFLAGS=-Wno-error=unused-label" ];
})
