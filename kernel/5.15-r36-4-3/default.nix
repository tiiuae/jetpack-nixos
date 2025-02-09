{
  pkgs,
  lib,
  fetchFromGitHub,
  fetchpatch,
  l4t-xusb-firmware,
  realtime ? false,
  kernelPatches ? [ ],
  structuredExtraConfig ? { },
  extraMeta ? { },
  argsOverride ? { },
  fetchurl,
  runCommand,
  ...
}@args:
let
  isNative = pkgs.stdenv.isAarch64;
  pkgsAarch64 = if isNative then pkgs else pkgs.pkgsCross.aarch64-multiplatform;

  src = fetchurl {
    url = "https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.3/sources/public_sources.tbz2";
    hash = "sha256-LBd4BGeePtZQ2r7G+pWDiFeYlvFwVwxhcaG2w4ZmkhY=";
  };

  source = runCommand "jetson-bsp-kernel-5-15-source" { } ''
    tar xf ${src}
    cd Linux_for_Tegra/source
    mkdir $out
    tar -C $out -xf kernel_src.tbz2
    mv $out/kernel/kernel-jammy-src $out/bsp-kernel
    cp -vpr $out/bsp-kernel/* $out/
    rm -rf $out/bsp-kernel
  '';

in
pkgsAarch64.buildLinux (
  args
  // {
    version = "5.15.148" + lib.optionalString realtime "-rt70";
    extraMeta.branch = "5.15";

    defconfig = "defconfig";

    # https://github.com/NixOS/nixpkgs/pull/366004
    # introduced a breaking change that if a module is declared but it is not being used it will fail
    # if you try to suppress each of he errors e.g.
    # REISERFS_FS_SECURITY = lib.mkForce unset; within structuredExtraConfig
    # that list runs to a long 100+ modules so we go back to the previous default and ignore them
    ignoreConfigErrors = true;

    # Using applyPatches here since it's not obvious how to append an extra
    # postPatch. This is not very efficient.
    src = source;

    autoModules = false;
    features = { }; # TODO: Why is this needed in nixpkgs master (but not NixOS 22.05)?

    # As of 22.11, only kernel configs supplied through kernelPatches
    # can override configs specified in the platforms
    kernelPatches = [
      # if USB_XHCI_TEGRA is built as module, the kernel won't build
      {
        name = "make-USB_XHCI_TEGRA-builtins";
        patch = null;
        extraConfig = ''
          USB_XHCI_TEGRA y
          EXTRA_FIRMWARE_DIR ${l4t-xusb-firmware}/lib/firmware
          EXTRA_FIRMWARE nvidia/tegra194/xusb.bin
        '';
      }
    ] ++ kernelPatches;

    structuredExtraConfig =
      with lib.kernel;
      {
        # Following modules need for iso_minimal
        ISO9660 = module;
        USB_UAS = yes;

        # Required by IO base b
        USB_ONBOARD_HUB = no;

        # Override the default CMA_SIZE_MBYTES=32M setting in common-config.nix with the default from tegra_defconfig
        # Otherwise, nvidia's driver craps out
        CMA_SIZE_MBYTES = lib.mkForce (freeform "64");

        ### So nat.service and firewall work ###
        NF_TABLES = module; # This one should probably be in common-config.nix
        NFT_NAT = module;
        NFT_MASQ = module;
        NFT_REJECT = module;
        NFT_COMPAT = module;
        NFT_LOG = module;
        NFT_COUNTER = module;
        # IPv6 is enabled by default and without some of these `firewall.service` will explode.
        IP6_NF_MATCH_AH = module;
        IP6_NF_MATCH_EUI64 = module;
        IP6_NF_MATCH_FRAG = module;
        IP6_NF_MATCH_OPTS = module;
        IP6_NF_MATCH_HL = module;
        IP6_NF_MATCH_IPV6HEADER = module;
        IP6_NF_MATCH_MH = module;
        IP6_NF_MATCH_RPFILTER = module;
        IP6_NF_MATCH_RT = module;
        IP6_NF_MATCH_SRH = module;

        # Needed since mdadm stuff is currently unconditionally included in the initrd
        # This will hopefully get changed, see: https://github.com/NixOS/nixpkgs/pull/183314
        MD = yes;
        BLK_DEV_MD = module;
        MD_LINEAR = module;
        MD_RAID0 = module;
        MD_RAID1 = module;
        MD_RAID10 = module;
        MD_RAID456 = module;
      }
      // (lib.optionalAttrs realtime {
        PREEMPT_VOLUNTARY = lib.mkForce no; # Disable the one set in common-config.nix
        # These are the options enabled/disabled by scripts/rt-patch.sh
        PREEMPT_RT = yes;
        DEBUG_PREEMPT = no;
        KVM = no;
        CPU_IDLE_TEGRA18X = no;
        CPU_FREQ_GOV_INTERACTIVE = no;
        CPU_FREQ_TIMES = no;
        FAIR_GROUP_SCHED = no;
      })
      // structuredExtraConfig;

  }
  // argsOverride
)
