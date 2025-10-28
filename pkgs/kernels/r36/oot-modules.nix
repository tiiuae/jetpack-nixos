#
# NOTE! Contains PKVM patches
#
#

# PKVM

#
# NOTE! Contains PKVM patches
#

{ applyPatches
, bspSrc
, buildPackages
, gitRepos
, kernel
, l4tMajorMinorPatchVersion
, lib
, runCommand
, stdenv
, fetchpatch
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
    (gitRepos.hwpm.overrideAttrs { name = "hwpm"; })
    (applyPatches {
      name = "nvidia-oot";
      src = gitRepos.nvidia-oot;
      patches = [
        ./0001-rtl8822ce-Fix-Werror-address.patch
        ./0002-sound-Fix-include-path-for-tegra-virt-alt-include.patch

        #
        # START: PKVM patches
        #
        (fetchpatch {
          name = "nvvrs-pseq-rtc: Fix unbalanced mutex_unlock()";
          url = "https://github.com/tiiuae/nvidia-oot-jetson/commit/17388e6f24bb4b1d8ad5bdf64226ab6286da96e1.patch";
          hash = "sha256-bsgEPHmBCnTZKDSKmIrQg5HdxI5ERDuJS5UscbiXWC0=";
        })

        (fetchpatch {
          name = "tegra23x_perf_uncore: Fix double free bug";
          url = "https://github.com/tiiuae/nvidia-oot-jetson/commit/45a23b4c6eba2e470bf95a3f34fed336c8b5a45d.patch";
          hash = "sha256-qBXbFkqJf6IIR5GrI5UVkJCMTfMY603OoucUV7G8yXE=";
        })

        (fetchpatch {
          name = "tegra23x_perf_uncore: don’t claim PERF_TYPE_HARDWARE";
          url = "https://github.com/tiiuae/nvidia-oot-jetson/commit/9b204daf35f86752c9a135e7d013d1bd0f0f539d.patch";
          hash = "sha256-o4l1wm9kLwPhsL1Dup0ac1XVOryqfCROAY4g59AhXFw=";
        })

        (fetchpatch {
          name = "tegra23x_perf_uncore: enforce CPU0 and expose cpumask in sysfs";
          url = "https://github.com/tiiuae/nvidia-oot-jetson/commit/ea69f9653341f971cdd044541b8370b3b7c14ab1.patch";
          hash = "sha256-RW1aHf0tXxhNYyJ6Z3dH/CmECDCWGkdNadHBE77rA0M=";
        })

        (fetchpatch {
          name = "tegra23x_perf_uncore: reject NV_INT_* pseudo-IDs";
          url = "https://github.com/tiiuae/nvidia-oot-jetson/commit/e63767db5cb0bb5eb56d5d30f6f4ba97ba81412f.patch";
          hash = "sha256-LWd/RCE3ycNw4nBcMgsJeOJHqATFIf9jEMmAyuQ8X8Q=";
        })

        (fetchpatch {
          name = "tegra23x_perf_uncore: only claim events explicitly targeting this PMU type";
          url = "https://github.com/tiiuae/nvidia-oot-jetson/commit/1d18f351e42bcb9dbcc6da858ae55c20f912151d.patch";
          hash = "sha256-e6weQTt1SXwK/sfbRL8XuVWSUm9YbNfmlzYana7iPX4=";
        })
        #
        # END: PKVM patches
        #
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
        ./0004-ANDURIL-override-KERNEL_SOURCES-and-KERNEL_OUTPUT-if.patch
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
      # Kind of hack: Jetson 36.4.4. conftest fails when gcc 14 is used
      + lib.optionals (l4tMajorMinorPatchVersion == "36.4.4") ''
        sed -i '7571s/.*/return register_shrinker(s, \\\"%s\\", name);/' "$out"/nvidia-oot/scripts/conftest/conftest.sh
      ''
    );
in
stdenv.mkDerivation (finalAttrs: {
  __structuredAttrs = true;
  strictDeps = true;

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

  postInstall = ''
    mkdir -p $dev
    cat **/Module.symvers > $dev/Module.symvers
  '';

  outputs = [
    "out"
    "dev"
  ];

  # # GCC 14.2 seems confused about DRM_MODESET_LOCK_ALL_BEGIN/DRM_MODESET_LOCK_ALL_END in nvdisplay/kernel-open/nvidia-drm/nvidia-drm-drv.c:1344
  # extraMakeFlags = [ "KCFLAGS=-Wno-error=unused-label" ];

  buildFlags = [ "modules" ];
  installTargets = [ "modules_install" ];
})
