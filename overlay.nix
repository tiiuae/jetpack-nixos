# TODO(jared): Get rid of usage of `callPackages` where possible so we can take
# advantage of scope's `self.callPackage` (callPackages does not exist under
# `self`).

final: prev:
let
  inherit (prev) lib;
  jetpackVersion = "6.2";
  l4tVersion = "36.4.3";
  cudaVersion = "12.6";

  sourceInfo = import ./sourceinfo {
    l4tMajorMinorPatchVersion = l4tVersion;
    inherit lib;
    inherit (prev) fetchurl fetchgit;
  };

  uefi-firmware-file =
    if l4tVersion == "36.4.3" then
      ./pkgs/uefi-firmware/r36
    else if l4tVersion == "35.6.0" then
      ./pkgs/uefi-firmware/r35
    else
      throw "Not supported l4tVersion version";

in
{
  nvidia-jetpack = prev.lib.makeScope prev.newScope (self: ({
    inherit jetpackVersion l4tVersion cudaVersion;
    l4tMajorMinorPatchVersion = l4tVersion;

    inherit (sourceInfo) debs gitRepos;

    kernelVersion = final.kernelVersion or "bsp-default";

    bspSrc = prev.runCommand "l4t-unpacked"
      {
        # https://developer.nvidia.com/embedded/jetson-linux-archive
        # https://repo.download.nvidia.com/jetson/
        src = prev.fetchurl {
          url = with prev.lib.versions; "https://developer.download.nvidia.com/embedded/L4T/r${major l4tVersion}_Release_v${minor l4tVersion}.${patch l4tVersion}/release/Jetson_Linux_R${l4tVersion}_aarch64.tbz2";
          hash = "sha256-lJpEBJxM5qjv31cuoIIMh09u5dQco+STW58OONEYc9I=";
        };
        # We use a more recent version of bzip2 here because we hit this bug
        # extracting nvidia's archives:
        # https://bugs.launchpad.net/ubuntu/+source/bzip2/+bug/1834494
        nativeBuildInputs = [ prev.buildPackages.bzip2_1_1 ];
      } ''
      bzip2 -d -c $src | tar xf -
      mv Linux_for_Tegra $out
    '';

    # Here for convenience, to see what is in upstream Jetpack
    unpackedDebs = prev.runCommand "unpackedDebs-${l4tVersion}" { nativeBuildInputs = [ prev.buildPackages.dpkg ]; } ''
      mkdir -p $out
      ${prev.lib.concatStringsSep "\n" (prev.lib.mapAttrsToList (n: p: "echo Unpacking ${n}; dpkg -x ${p.src} $out/${n}") self.debs.common)}
      ${prev.lib.concatStringsSep "\n" (prev.lib.mapAttrsToList (n: p: "echo Unpacking ${n}; dpkg -x ${p.src} $out/${n}") self.debs.t234)}
    '';

    # Also just for convenience,
    unpackedDebsFilenames = prev.runCommand "unpackedDebsFilenames-${l4tVersion}" { nativeBuildInputs = [ prev.buildPackages.dpkg ]; } ''
      mkdir -p $out
      ${prev.lib.concatStringsSep "\n" (prev.lib.mapAttrsToList (n: p: "echo Extracting file list from ${n}; dpkg --fsys-tarfile ${p.src} | tar --list > $out/${n}") self.debs.common)}
      ${prev.lib.concatStringsSep "\n" (prev.lib.mapAttrsToList (n: p: "echo Extracting file list from ${n}; dpkg --fsys-tarfile ${p.src} | tar --list > $out/${n}") self.debs.t234)}
    '';

    unpackedGitRepos = prev.runCommand "unpackedGitRepos-${l4tVersion}" { } (
      prev.lib.mapAttrsToList
        (relpath: repo: ''
          mkdir -p $out/${relpath}
          cp --no-preserve=all -r ${repo}/. $out/${relpath}
        '')
        self.gitRepos
    );

    inherit (prev.callPackages "${uefi-firmware-file}" { inherit (self) l4tMajorMinorPatchVersion; })
      edk2-jetson uefi-firmware;

    inherit (prev.callPackages ./pkgs/optee {
      # Nvidia's recommended toolchain is gcc9:
      # https://nv-tegra.nvidia.com/r/gitweb?p=tegra/optee-src/nv-optee.git;a=blob;f=optee/atf_and_optee_README.txt;h=591edda3d4ec96997e054ebd21fc8326983d3464;hb=5ac2ab218ba9116f1df4a0bb5092b1f6d810e8f7#l33
      stdenv = prev.gcc9Stdenv;
      inherit (self) bspSrc gitRepos l4tVersion;
    }) buildTOS buildOpteeTaDevKit opteeClient;
    genEkb = self.callPackage ./pkgs/optee/gen-ekb.nix { };

    flash-tools = self.callPackage ./pkgs/flash-tools { };

    # Allows automation of Orin AGX devkit
    board-automation = self.callPackage ./pkgs/board-automation { };

    # Allows automation of Xavier AGX devkit
    python-jetson = prev.python3.pkgs.callPackage ./pkgs/python-jetson { };

    tegra-eeprom-tool = prev.callPackage ./pkgs/tegra-eeprom-tool { };
    tegra-eeprom-tool-static = prev.pkgsStatic.callPackage ./pkgs/tegra-eeprom-tool { };

    cudaPackages = prev.lib.makeScope prev.newScope (finalCudaPackages: {
      # Versions
      inherit cudaVersion l4tVersion;
      cudaMajorMinorPatchVersion = cudaVersion;
      cudaMajorMinorVersion = prev.lib.versions.majorMinor cudaVersion;
      cudaMajorVersion = prev.lib.versions.major cudaVersion;
      cudaVersionDashes = prev.lib.replaceStrings [ "." ] [ "-" ] (prev.lib.versions.majorMinor cudaVersion);

      # Utilities
      callPackages = prev.lib.callPackagesWith (self // finalCudaPackages);
      cudaAtLeast = prev.lib.versionAtLeast cudaVersion;
      cudaOlder = prev.lib.versionOlder cudaVersion;
      inherit (self) debs;
      debsForSourcePackage = srcPackageName: prev.lib.filter (pkg: (pkg.source or "") == srcPackageName) (prev.lib.attrValues finalCudaPackages.debs.common);

      # L4T packages needed by cuda packages
      inherit (self) l4t-3d-core l4t-core l4t-cuda l4t-cupva l4t-multimedia;
      l4tMajorMinorPatchVersion = l4tVersion;
      inherit (prev) autoAddDriverRunpath;
    }
    # Add the packages built from cuda-packages directory
    // prev.lib.packagesFromDirectoryRecursive {
      directory = ./pkgs/cuda-packages;
      inherit (finalCudaPackages) callPackage;
    });

    samples = prev.callPackages ./pkgs/samples {
      inherit (self) debs cudaVersion cudaPackages l4t-cuda l4t-multimedia l4t-camera;
      inherit (prev) autoAddDriverRunpath;
    };

    tests = prev.callPackages ./pkgs/tests { inherit l4tVersion; };

    kernelPackagesOverlay = final: _:
      if lib.versionAtLeast l4tVersion "36" then {
        nvidia-oot = final.callPackage ./pkgs/kernels/r36/oot-modules.nix {
          inherit (self) bspSrc gitRepos;
          inherit (final) kernel;
          l4tMajorMinorPatchVersion = l4tVersion;
        };
      } else {
        nvidia-display-driver = self.callPackage ./kernel/display-driver.nix {
          inherit (self) gitRepos;
          inherit (final) kernel;
          l4tMajorMinorPatchVersion = l4tVersion;
        };
      };

    kernel = self.callPackage (if lib.versionAtLeast l4tVersion "36" then ./pkgs/kernels/r36 else ./kernel) {
      inherit (self) l4tVersion l4t-xusb-firmware kernelVersion gitRepos;
      l4tMajorMinorPatchVersion = l4tVersion;
      kernelPatches = [ ];
    };
    kernelPackages = (prev.linuxPackagesFor self.kernel).extend self.kernelPackagesOverlay;

    rtkernel = self.callPackage (if lib.versionAtLeast l4tVersion "36" then ./pkgs/kernels/r36 else ./kernel) {
      inherit (self) l4tVersion l4t-xusb-firmware kernelVersion gitRepos;
      l4tMajorMinorPatchVersion = l4tVersion;
      kernelPatches = [ ];
      realtime = true;
    };
    rtkernelPackages = (prev.linuxPackagesFor self.rtkernel).extend self.kernelPackagesOverlay;

    nxJetsonBenchmarks = self.callPackage ./pkgs/jetson-benchmarks {
      targetSom = "nx";
    };
    xavierAgxJetsonBenchmarks = self.callPackage ./pkgs/jetson-benchmarks {
      targetSom = "xavier-agx";
    };
    orinAgxJetsonBenchmarks = self.callPackage ./pkgs/jetson-benchmarks {
      targetSom = "orin-agx";
    };

    flashFromDevice = self.callPackage ./pkgs/flash-from-device { };

    otaUtils = self.callPackage ./pkgs/ota-utils { };

    l4tCsv = self.callPackage ./pkgs/containers/l4t-csv.nix { inherit l4tVersion; };
    genL4tJson = prev.runCommand "l4t.json" { nativeBuildInputs = [ prev.buildPackages.python3 ]; } ''
      python3 ${./pkgs/containers/gen_l4t_json.py} ${self.l4tCsv} ${self.unpackedDebsFilenames} > $out
    '';
    containerDeps = self.callPackage ./pkgs/containers/deps.nix { inherit l4tVersion; };
    nvidia-ctk = self.callPackage ./pkgs/containers/nvidia-ctk.nix { };

    # TODO(jared): deprecate this
    devicePkgsFromNixosConfig = config: config.system.build.jetsonDevicePkgs;
  } // (prev.callPackages ./pkgs/l4t {
    l4tMajorMinorPatchVersion = l4tVersion;
    l4tAtLeast = prev.lib.versionAtLeast l4tVersion;
    l4tOlder = prev.lib.versionOlder l4tVersion;
    inherit (self) cudaPackages;
    cudaDriverMajorMinorVersion = with prev.lib.versions; "${major cudaVersion}.${minor cudaVersion}";
    inherit (sourceInfo) debs;
  })));
}
