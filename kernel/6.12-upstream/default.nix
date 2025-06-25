{ pkgs
, applyPatches
, lib
, fetchFromGitHub
, fetchpatch
, fetchurl
, fetchgit
, l4t-xusb-firmware
, realtime ? false
, kernelPatches ? [ ]
, structuredExtraConfig ? { }
, argsOverride ? { }
, buildLinux
, ...
}@args:
let
  isNative = pkgs.stdenv.isAarch64;
  pkgsAarch64 = if isNative then pkgs else pkgs.pkgsCross.aarch64-multiplatform;
in
pkgsAarch64.buildLinux (args // {
  version = "6.12.32" + lib.optionalString realtime "-rt96";
  extraMeta.branch = "6.12";

  ignoreConfigErrors = true;

  defconfig = "defconfig";

  # Using applyPatches here since it's not obvious how to append an extra
  # postPatch. This is not very efficient.
  src = applyPatches {
    src = fetchgit {
      url = "https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git";
      hash = "sha256-uuP0CjK8lOgXrwZifY4RsXsQRVZuKf/RTyoaKdZgdNs=";
      rev = "ba9210b8c96355a16b78e1b890dce78f284d6f31";
    };

    patches = [
      ./0001-Revert-pwm-Don-t-export-pwm_capture.patch
    ];
  };
  autoModules = false;
  features = { }; # TODO: Why is this needed in nixpkgs master (but not NixOS 22.05)?

  # As of 22.11, only kernel configs supplied through kernelPatches
  # can override configs specified in the platforms
  kernelPatches = [
    # TODO Still needed?
    # if USB_XHCI_TEGRA is built as module, the kernel won't build
    {
      name = "make-USB_XHCI_TEGRA-builtins with firmware";
      patch = null;
      extraConfig = ''
        USB_XHCI_TEGRA y
        EXTRA_FIRMWARE_DIR ${l4t-xusb-firmware}/lib/firmware
        EXTRA_FIRMWARE nvidia/tegra194/xusb.bin
  '';
    }
] ++ kernelPatches;

  structuredExtraConfig = with lib.kernel; {

    # Platform-dependent options for mainline kernel
    ARM64_PMEM = yes;
    PCIE_TEGRA194 = yes;
    PCIE_TEGRA194_HOST = yes;
    BLK_DEV_NVME = yes;
    NVME_CORE = yes;
    FB_SIMPLE = yes;

    # Following modules need for iso_minimal
    ISO9660 = module;
    USB_UAS = yes;

    # Required by IO base b
    USB_ONBOARD_HUB = no;

    # Orin-agx requires usb hub drivers if rootfs is boot from USB.
    TYPEC = yes;
    TYPEC_UCSI = yes;
    UCSI_CCG = yes;

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
    # Allow matching by class and corresponding ip4 config (RPFILTER)
    NETFILTER_XT_MATCH_PKTTYPE = module;
    IP_NF_MATCH_RPFILTER = module;

    # Needed since mdadm stuff is currently unconditionally included in the initrd
    # This will hopefully get changed, see: https://github.com/NixOS/nixpkgs/pull/183314
    MD = yes;
    BLK_DEV_MD = module;
    MD_LINEAR = module;
    MD_RAID0 = module;
    MD_RAID1 = module;
    MD_RAID10 = module;
    MD_RAID456 = module;
    # Re-enable DMI (revert https://github.com/OE4T/linux-tegra-5.10/commit/bc94634fcddd594735aa9c5ca5f68b4df1cb5f8b)
    DMI = yes;

  } // (lib.optionalAttrs realtime {
    PREEMPT_VOLUNTARY = lib.mkForce no; # Disable the one set in common-config.nix
    # These are the options enabled/disabled by scripts/rt-patch.sh
    PREEMPT_RT = yes;
    DEBUG_PREEMPT = no;
    KVM = no;
    CPU_IDLE_TEGRA18X = no;
    CPU_FREQ_GOV_INTERACTIVE = no;
    CPU_FREQ_TIMES = no;
    FAIR_GROUP_SCHED = no;
  }) // structuredExtraConfig;

} // argsOverride)
