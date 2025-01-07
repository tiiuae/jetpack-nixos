{
  stdenv,
  kernel,
  runCommand,
  fetchurl,
  fetchgit,
  lib,
  buildPackages,
  dtc,
}:
let

  # TODO: update to jetson_36.5 when available
  l4tTag = "rel-36_eng_2024-10-24";

  jetsonLinux = fetchurl {
    url = "https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.0/release/Jetson_Linux_R36.4.0_aarch64.tbz2";
    sha256 = "sha256-ftl/Yg4+/HztzpB2EuTHOuNl+IeOjzX9vwWWAZmrAB4=";
  };

  nvgpuSrc = fetchgit {
    url = "https://nv-tegra.nvidia.com/r/linux-nvgpu";
    rev = "${l4tTag}";
    hash = "sha256-dleWf4vymh9xDmW+JfJQrG7bXF4xiXeblZBQrHlzibc=";
  };

  nvidiaOotSrc = fetchgit {
    url = "https://nv-tegra.nvidia.com/r/linux-nv-oot";
    rev = "${l4tTag}";
    hash = "sha256-+un39i6DveTMdx+RIndJPsduCjVixN09qeERZLdZ7m4=";
  };

  nvidiaOotSrcPatched = stdenv.mkDerivation {
    name = "nvidia-oot-patched-source";
    src = nvidiaOotSrc;
    patches = [ 
      ./patches/0001-nvidia-oot-Fix-build-for-Linux-v6.12.patch 
    ];
    phases = [ "unpackPhase" "patchPhase" "installPhase" ];
    installPhase = ''
      cp -r . $out
    '';
  };

  nvdisplaySrc = fetchgit {
    url = "https://nv-tegra.nvidia.com/r/tegra/kernel-src/nv-kernel-display-driver";
    rev = "${l4tTag}";
    hash = "sha256-Xx41BQ1Nv/67z5OdPVEVOrnIB6FZYxu+nd7Ryn9t//0=";
  };

  nvdisplaySrcPatched = stdenv.mkDerivation {
    name = "nvdisplay-patched-source";
    src = nvdisplaySrc;
    patches = [       
      ./patches/0001-nvdisplay-Fix-build-for-Linux-v6.12.patch
    ];
    phases = [ "unpackPhase" "patchPhase" "installPhase" ];
    installPhase = ''
      cp -r . $out
    '';
  };

  hwpmSrc = fetchgit {
    url = "https://nv-tegra.nvidia.com/r/linux-hwpm";
    rev = "${l4tTag}";
    hash = "sha256-otOVFeF+8XKORWMXTRTcXQUXvojdwInVC3jPXTgrk3A=";
  };

  nvethernetrmSrc = fetchgit {
    url = "https://nv-tegra.nvidia.com/r/kernel/nvethernetrm";
    rev = "${l4tTag}";
    hash = "sha256-cTJagcO7TYG0eT0dgZn67hX/EKT04OrTYvwBwWEe1YU=";
  };

  kernelDeviceTreeSrc = fetchgit {
    url = "https://nv-tegra.nvidia.com/linux/kernel-devicetree";
    rev = "${l4tTag}";
    hash = "sha256-mFmxO7rg1DWnYK+HDFQnc9XLpS4lwXfSXGOibKC4FPY=";
  };

  t23xDtsSrc = fetchgit {
    url = "https://nv-tegra.nvidia.com/r/device/hardware/nvidia/t23x-public-dts";
    rev = "${l4tTag}";
    hash = "sha256-6feN3Sau1GD60CmCww2RpwDQNJeLC3x6BcCV7PAHG7k=";
  };

  tegraPublicDtsSrc = fetchgit {
    url = "https://nv-tegra.nvidia.com/r/device/hardware/nvidia/tegra-public-dts";
    rev = "${l4tTag}";
    hash = "sha256-NMp7UY0OlH2ddBSrUzCUSLkvnWrELhz8xH/dkV86ids=";
  };


  # TODO: check if  cp -r ${kerlel.src} kernel  is needed
  source = runCommand "source" { } ''
    echo
    echo Extract Jetson Linux
    tar -xf ${jetsonLinux}

    echo
    echo Copy modules sources
    cd Linux_for_Tegra/source/

    cp -r ${nvgpuSrc} nvgpu
    cp -r ${nvidiaOotSrcPatched} nvidia-oot
    cp -r ${hwpmSrc} hwpm
    cp -r ${nvethernetrmSrc} nvethernetrm
    cp -r ${kernelDeviceTreeSrc} kernel-devicetree
    mkdir -p hardware/nvidia/t23x/nv-public
    cp -r ${t23xDtsSrc}/* hardware/nvidia/t23x/nv-public/
    mkdir -p hardware/nvidia/tegra/nv-public
    cp -r ${tegraPublicDtsSrc}/* hardware/nvidia/tegra/nv-public/
    cp -r ${nvdisplaySrcPatched} nvdisplay
 
    mkdir $out
 
    cp -r ./* $out
  '';

  # unclear why we need this, but some part of nvidia's conftest doesn't pick up the headers otherwise
  kernelIncludes = x: [
    "${kernel.dev}/lib/modules/${kernel.modDirVersion}/source/include"
    "${kernel.dev}/lib/modules/${kernel.modDirVersion}/source/arch/${stdenv.hostPlatform.linuxArch}/include"
    "${kernel.dev}/lib/modules/${kernel.modDirVersion}/source/include/uapi/"
    "${kernel.dev}/lib/modules/${kernel.modDirVersion}/source/arch/${stdenv.hostPlatform.linuxArch}/include/uapi/"
  ];
in
stdenv.mkDerivation {
  pname = "nvidia-oot";
  inherit (kernel) version;

  src = source;
  patches = [ ];

  postUnpack = ''
    # make kernel headers readable for the nvidia build system.
    cp -r ${kernel.dev} linux-dev
    cp -r ${kernel.src} linux-src
    chmod -R u+w linux-dev
    chmod -R u+w linux-src
    export KERNEL_HEADERS=$(pwd)/linux-src
    export KERNEL_OUTPUT=$(pwd)/linux-dev/lib/modules/${kernel.modDirVersion}/build

    ln -sf ../../../../../../nvethernetrm source/nvidia-oot/drivers/net/ethernet/nvidia/nvethernet/nvethernetrm

  '';

  nativeBuildInputs = kernel.moduleBuildDependencies ++ [ dtc ];

  # some calls still go to `gcc` in the build
  depsBuildBuild = [ buildPackages.stdenv.cc ];

  makeFlags =
    [
      "ARCH=${stdenv.hostPlatform.linuxArch}"
      "INSTALL_MOD_PATH=${placeholder "out"}"
    ]
    ++ lib.optionals (stdenv.hostPlatform != stdenv.buildPlatform) [
      "CROSS_COMPILE=${stdenv.cc}/bin/${stdenv.cc.targetPrefix}"
    ];

  CROSS_COMPILE = lib.optionalString (
    stdenv.hostPlatform != stdenv.buildPlatform
  ) "${stdenv.cc}/bin/${stdenv.cc.targetPrefix}";

  hardeningDisable = [ "pic" ];

  # unclear why we need to add nvidia-oot/sound/soc/tegra-virt-alt/include
  # this only happens in the nix-sandbox and not in the nix-shell
  NIX_CFLAGS_COMPILE = "-fno-stack-protector -Wno-error=attribute-warning -I ${source}/nvidia-oot/sound/soc/tegra-virt-alt/include ${
    lib.concatMapStrings (x: "-isystem ${x} ") (kernelIncludes kernel.dev)
  }";

  buildPhase = ''
    make $makeFlags modules
    make $makeFlags dtbs
  '';

  installTargets = [ "modules_install" ];
}
