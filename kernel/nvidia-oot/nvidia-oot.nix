{ stdenv
, kernel
, runCommand
, fetchurl
, lib
, buildPackages
, gitRepos
, l4tVersion
}:
let
  src =
    if l4tVersion == "36.4.3" then
      fetchurl
        {
          url = "https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.3/sources/public_sources.tbz2";
          hash = "sha256-LBd4BGeePtZQ2r7G+pWDiFeYlvFwVwxhcaG2w4ZmkhY=";
        }
    else
      throw "Not supported l4tVersion version";

  source = runCommand "nvidia-oot-source" { } ''
    tar xf ${src}
    cd Linux_for_Tegra/source
    mkdir $out
    tar -C $out -xf kernel_oot_modules_src.tbz2
    tar -C $out -xf nvidia_kernel_display_driver_source.tbz2

    rm $out/nvidia-oot/drivers/net/wireless/realtek/rtl8822ce/include/linux/wireless.h
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
  # Patch created like that:
  # nix-build ./packages.nix -A nvidia-oot-cross.src
  # mkdir source
  # cp -r result/* source
  # chmod -R +w source
  # cd source
  # git init .
  # git add .
  # git commit -m "Initial commit"
  # <make changes>
  # git diff > ../0001-build-fixes.patch
  patches = [
    ./0001-nix-build-fixes.patch
    ./0002-downgrade-gcc-14-err-to-warn.patch
  ] ++ (lib.optional (kernel.modDirVersion == "6.6.75") [ ./0003-linux-6-6-build-fixes.patch ]);

  postUnpack = ''
    # make kernel headers readable for the nvidia build system.
    cp -r ${kernel.dev} linux-dev
    chmod -R u+w linux-dev
    export KERNEL_HEADERS=$(pwd)/linux-dev/lib/modules/${kernel.modDirVersion}/build

  '';

  nativeBuildInputs = kernel.moduleBuildDependencies ++ [ ];

  # some calls still go to `gcc` in the build
  depsBuildBuild = [ buildPackages.stdenv.cc ];

  makeFlags =
    [
      "ARCH=${stdenv.hostPlatform.linuxArch}"
      "INSTALL_MOD_PATH=${placeholder "out"}"
      "modules"
    ]
    ++ lib.optionals (stdenv.hostPlatform != stdenv.buildPlatform) [
      "CROSS_COMPILE=${stdenv.cc}/bin/${stdenv.cc.targetPrefix}"
    ];

  CROSS_COMPILE = lib.optionalString
    (
      stdenv.hostPlatform != stdenv.buildPlatform
    ) "${stdenv.cc}/bin/${stdenv.cc.targetPrefix}";

  hardeningDisable = [ "pic" ];

  # unclear why we need to add nvidia-oot/sound/soc/tegra-virt-alt/include
  # this only happens in the nix-sandbox and not in the nix-shell
  NIX_CFLAGS_COMPILE = "-fno-stack-protector -Wno-error=attribute-warning -Wno-address
    -I ${source}/nvidia-oot/sound/soc/tegra-virt-alt/include ${
        lib.concatMapStrings (x: "-isystem ${x} ") (kernelIncludes kernel.dev)
      }";

  installTargets = [ "modules_install" ];
}
