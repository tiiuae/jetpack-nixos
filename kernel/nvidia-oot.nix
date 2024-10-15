# TODO: Should try to merge with upstream nixpkgs's open.nix nvidia driver
{ stdenv
, lib
, kernel
, gitRepos
, l4tVersion
, pkgs
}:

stdenv.mkDerivation rec {
  pname = "nvidia-oot";
  version = "jetson_${l4tVersion}";

  src = gitRepos."nvidia-oot";

  #setSourceRoot = "sourceRoot=$(echo /build/linux-nv-oot-*)";
  # sourceRoot="linux-nv-oot-564ce2a";

  nativeBuildInputs = kernel.moduleBuildDependencies ++ [
    pkgs.breakpointHook
  ];

  # makeFlags = kernel.makeFlags ++ [
  makeFlags = [
    "SYSSRC=${kernel.dev}/lib/modules/${kernel.modDirVersion}/source"
    "SYSOUT=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build"
    "MODLIB=$(out)/lib/modules/${kernel.modDirVersion}"
    "O=${kernel.dev}/lib/modules/${kernel.modDirVersion}/source"
  ] ++ lib.optionals ((stdenv.buildPlatform != stdenv.hostPlatform) && stdenv.hostPlatform.isAarch64) [
    "TARGET_ARCH=aarch64"
  ];

  # KERNEL_HEADERS="${kernel.dev}/lib/modules/6.8.12/source/";

  # Avoid an error in modpost: "__stack_chk_guard" [.../nvidia.ko] undefined
  # NIX_CFLAGS_COMPILE = "-fno-stack-protector";
  installTargets = [ "modules_install" ];
  enableParallelBuilding = true;

  passthru.meta = {
    license = with lib.licenses; [ mit /* OR */ gpl2Only ];
  };
}
