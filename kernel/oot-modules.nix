{ pkgs
, stdenv
, lib
, kernel
, gitRepos
, l4tVersion
, fetchgit
, fetchurl
, buildLinux
, system
}:
let

#   nvidia-oot = fetchgit {
#     name = "nvidia-oot";
#     rev = "564ce2a709cfb300aa2cb092a708452d2ce2c274";
#     sha256 = "sha256-l97Dq/WFOlxJVjoH63oUS5d1E+ax+aAz5CKTO678KnI=";
#     url = "git://nv-tegra.nvidia.com/linux-nv-oot.git";
#   };

#   display-driver = fetchgit {
#     name = "display-driver";
#     rev = "64c5e81e487a24fce852316a6b377a9e91e03418";
#     sha256 = "sha256-NZGzhJCXWdogatBAsIkldJ/kP1S3DaLHhR8nDyNsmNY=";
#     url ="git://nv-tegra.nvidia.com/tegra/kernel-src/nv-kernel-display-driver.git";
#   };

  # isNative = pkgs.stdenv.isAarch64;
  # pkgsAarch64 = if isNative then pkgs else pkgs.pkgsCross.aarch64-multiplatform;

    # Replicates Jetpack-nixos kernel
  linux68_pkg = { lib, fetchurl, buildLinux, ... } @ args:

    buildLinux (args // rec {
      pname = "linux68";
      version = "6.8.12";
      extraMeta.branch = "6.8";

      defconfig = "defconfig";
      autoModules = false;

      src = fetchurl {
        url = "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/snapshot/linux-6.8.y.tar.gz";
        hash = "sha256-AvGkgpMPUcZ953eoU/joJT5AvPYA4heEP7gpewzdjy8";
      };
      kernelPatches = [];

      structuredExtraConfig = with lib.kernel; {
        ARM64_PMEM = yes;
        PCIE_TEGRA194 = yes;
        PCIE_TEGRA194_HOST = yes;
        BLK_DEV_NVME = yes;
        NVME_CORE = yes;
        FB_SIMPLE = yes;
      };

    } // (args.argsOverride or {}));

  linux68 = pkgs.callPackage linux68_pkg{};

in

# stdenv.mkDerivation rec {
#   pname = "oot-modules";
#   version = "jetson_${l4tVersion}";

# #  src = gitRepos."tegra/kernel-src/nv-kernel-display-driver";
#   # srcs = [
#   #   nvidia-oot
#   #   display-driver
#   # ];
#   # sourceRoot = nvidia-oot.name;

#   src = fetchurl {
#     url = "https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v3.0/sources/public_sources.tbz2";
#     hash = "sha256-6U2+ACWuMT7rYDBhaXr+13uWQdKgbfAiiIV0Vi3R9sU=";
#   };

#   nativeBuildInputs = kernel.moduleBuildDependencies ++ [
#     # pkgs.breakpointHook
#   ];


#   configurePhase = ''
#     runHook preConfigure

#     cd source

#     tar xf kernel_oot_modules_src.tbz2
#     tar xf nvidia_kernel_display_driver_source.tbz2

#     export CROSS_COMPILE=${pkgs.stdenv.cc}/bin/${pkgs.stdenv.cc.targetPrefix}
#     export KERNEL_HEADERS=${linux68.dev}/lib/modules/${linux68.modDirVersion}/build
#     export IGNORE_MISSING_MODULE_SYMVERS=1

#     # Patch nvidia modules source
#     sed -i '49s/SOURCES=$(KERNEL_HEADERS)/SOURCES=$(KERNEL_HEADERS)\/source/g' Makefile
#     sed -i '/cp -LR $(KERNEL_HEADERS)\/\* $(NVIDIA_HEADERS)/s/$/ \|\| true;/' Makefile
#     #Sources are copied from store. They are read only
#     sed -i '/cp -LR $(KERNEL_HEADERS)\/\* $(NVIDIA_HEADERS)/a \\tchmod -R u+w out/nvidia-linux-header/' Makefile
#     sed -i '113s/SYSSRC=$(NVIDIA_HEADERS)/SYSSRC=$(NVIDIA_HEADERS)\/source/g' Makefile
#     # TODO: Remove warning:
#     #    warning: call to ‘__write_overflow_field’
#     sed -i '/subdir-ccflags-y += -Werror/d' nvidia-oot/Makefile

#     runHook postConfigure
#   '';

#   buildPhase = ''
#     runHook preBuild

#     make modules

#     runHook postBuild
#   '';

#   # Avoid an error in modpost: "__stack_chk_guard" [.../nvidia.ko] undefined
#   NIX_CFLAGS_COMPILE = "-fno-stack-protector";

#   installTargets = [ "modules_install" ];
#   enableParallelBuilding = true;

#   passthru.meta = {
#     license = with lib.licenses; [ mit /* OR */ gpl2Only ];
#   };
# }

derivation {
    name = "nvidia-oot-raw";
    builder = "${pkgs.bash}/bin/bash";
    linux68dev =  "${kernel.dev}";
    aarch64LinuxGnu = "${pkgs.stdenv.cc}";
    system = system;
    args = [ ./nvidia-oot-builder.sh ];
    src = pkgs.fetchurl {
      url = "https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v3.0/sources/public_sources.tbz2";
      hash = "sha256-6U2+ACWuMT7rYDBhaXr+13uWQdKgbfAiiIV0Vi3R9sU=";
    };

    buildInputs = with pkgs; [
      bzip2
      which
      gnutar
      gnumake
      coreutils
      gnused
      binutils.bintools
      findutils
      bash
      gawk
      gcc
      gnugrep
      xz
      # TODO: Remove, but if removed then not compiling
      breakpointHook
    ];
  }
