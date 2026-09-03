# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{ config
, lib
, pkgs
, ...
}:
let
  cfg = config.hardware.nvidia-jetpack.virtualization;
  consumers = cfg.bpmpHost.consumers;
  bpmpEnabled = consumers != { };
  bpmpGuestEnabled = cfg.mgbe0Guest.enable || cfg.mttcanGuest.enable;
  ids = values: lib.concatStringsSep " " (map toString values);
  support = pkgs.nvidia-jetpack.orinVirtualizationSupport.override {
    bpmpAllowAllDomains = cfg.bpmpHost.allowAllDomains;
  };
  mgbe0 = support.passthrough.mgbe0;
  mgbe0DevicePath = "/sys/bus/platform/devices/${mgbe0.sysfsName}";
  mgbe0Artifacts = support.mkMgbe0Overlay {
    inherit pkgs support;
    hostDtb = "${config.hardware.deviceTree.package}/${config.hardware.deviceTree.name}";
  };
  hostNvidiaOotMakefile = pkgs.writeText "nvidia-oot-host-Makefile" ''
    # SPDX-License-Identifier: GPL-2.0

    LINUXINCLUDE += -I$(srctree.nvconftest)
    LINUXINCLUDE += -I$(srctree.nvidia-oot)/include

    subdir-ccflags-y += -Werror
    subdir-ccflags-y += -Wmissing-prototypes
    obj-m += drivers/platform/tegra/dce/
  '';
  mttcan = support.passthrough.mttcan;
  mttcanDevices = map (controller: controller.sysfsName) mttcan.controllers;
  mttcanModules = config.boot.kernelPackages.nvidia-oot-modules.overrideAttrs (old: {
    pname = "l4t-mttcan-modules";
    postPatch = (old.postPatch or "") + ''
      substituteInPlace Makefile \
        --replace-fail 'modules: hwpm nvidia-oot nvgpu nvidia-display' 'modules: nvidia-oot' \
        --replace-fail 'modules_install: hwpm nvidia-oot nvgpu nvidia-display-install' 'modules_install: nvidia-oot' \
        --replace-fail 'nvidia-oot: conftest hwpm' 'nvidia-oot: conftest' \
        --replace-fail '$(MAKEFILE_DIR)/hwpm/drivers/tegra/hwpm/Module.symvers' ""

      # NetVM needs only the NVIDIA PPS provider and the native MTTCAN
      # driver. Avoid compiling unrelated display, GPU, camera, and network
      # modules against its upstream guest kernel.
      cp nvidia-oot/Makefile nvidia-oot/Makefile.all
      cat > nvidia-oot/Makefile <<'EOF'
      # SPDX-License-Identifier: GPL-2.0-only
      # SPDX-FileCopyrightText: Copyright (c) 2022-2024 NVIDIA CORPORATION. All rights reserved.
      LINUXINCLUDE += -I$(srctree.nvconftest)
      LINUXINCLUDE += -I$(srctree.nvidia-oot)/include
      subdir-ccflags-y += -Werror
      subdir-ccflags-y += -Wmissing-prototypes
      ifeq ($(CONFIG_TEGRA_VIRTUALIZATION),y)
      subdir-ccflags-y += -DCONFIG_TEGRA_VIRTUALIZATION
      endif
      ifeq ($(CONFIG_TEGRA_SYSTEM_TYPE_ACK),y)
      subdir-ccflags-y += -DCONFIG_TEGRA_SYSTEM_TYPE_ACK
      subdir-ccflags-y += -Wno-sometimes-uninitialized
      subdir-ccflags-y += -Wno-parentheses-equality
      subdir-ccflags-y += -Wno-enum-conversion
      subdir-ccflags-y += -Wno-implicit-fallthrough
      endif
      obj-m += drivers/
      EOF

      cp nvidia-oot/drivers/Makefile nvidia-oot/drivers/Makefile.all
      cat > nvidia-oot/drivers/Makefile <<'EOF'
      # SPDX-License-Identifier: GPL-2.0-only
      # SPDX-FileCopyrightText: Copyright (c) 2022-2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
      LINUXINCLUDE += -I$(srctree.nvidia-oot)/include
      obj-m += net/can/
      obj-m += nvpps/
      EOF
    '';
  });
  bindMttcan = pkgs.writeShellApplication {
    name = "bind-mttcan-vfio-platform";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.iproute2
    ];
    text = ''
      set -eu

      for device in ${lib.escapeShellArgs mttcanDevices}; do
        device_path="/sys/bus/platform/devices/$device"
        if [ ! -d "$device_path" ]; then
          echo "MTTCAN platform device is missing: $device_path" >&2
          exit 1
        fi

        if [ -d "$device_path/net" ]; then
          for interface_path in "$device_path"/net/*; do
            [ -e "$interface_path" ] || continue
            ip link set dev "''${interface_path##*/}" down
          done
        fi

        current="$(basename "$(readlink -f "$device_path/driver" 2>/dev/null)" || true)"
        if [ -n "$current" ] && [ "$current" != vfio-platform ]; then
          echo "$device" > "$device_path/driver/unbind"
        fi

        echo vfio-platform > "$device_path/driver_override"
        current="$(basename "$(readlink -f "$device_path/driver" 2>/dev/null)" || true)"
        if [ "$current" != vfio-platform ]; then
          echo "$device" > /sys/bus/platform/drivers/vfio-platform/bind
        fi
      done
    '';
  };
  bpmpHostOverlay = pkgs.writeText "bpmp-host-overlay.dts" ''
    /dts-v1/;
    /plugin/;
    / {
        overlay-name = "BPMP host proxy allow-list";
        compatible = "nvidia,tegra234";
        fragment@0 {
            target-path = "/";
            __overlay__ {
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: policy: ''
        bpmp-host-proxy-${name} {
            compatible = "nvidia,bpmp-host-proxy";
            device-name = "bpmp-host-${name}";
            allowed-clocks = <${ids policy.clocks}>;
            allowed-resets = <${ids policy.resets}>;
            allowed-power-domains = <${ids policy.powerDomains}>;
            status = "okay";
        };
      '') consumers
    )}
            };
        };
    };
  '';
in
{
  imports = [ ./orin-gpu-virtualization.nix ];

  options.hardware.nvidia-jetpack.virtualization = {
    bpmpHost = {
      allowAllDomains = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Let BPMP host proxies service every clock, reset, and power-domain
          request instead of enforcing their device-tree allow-lists.

          This is dangerous and intended only for temporary policy discovery.
          A guest must also use `clk_ignore_unused` and `pd_ignore_unused` so it
          cannot disable host-owned resources during late initialization.
        '';
      };

      consumers = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              clocks = lib.mkOption {
                type = lib.types.listOf lib.types.int;
                default = [ ];
                apply = lib.unique;
                description = "Raw BPMP clock IDs this proxy forwards.";
              };
              resets = lib.mkOption {
                type = lib.types.listOf lib.types.int;
                default = [ ];
                apply = lib.unique;
                description = "Raw BPMP reset IDs this proxy forwards.";
              };
              powerDomains = lib.mkOption {
                type = lib.types.listOf lib.types.int;
                default = [ ];
                apply = lib.unique;
                description = "Raw BPMP power-domain IDs this proxy forwards.";
              };
            };
          }
        );
        default = { };
        description = ''
          Per-consumer BPMP host-proxy policies. A character device named
          `/dev/bpmp-host-NAME` is created for each attribute.
        '';
      };
    };

    dceHost = {
      enable = lib.mkEnableOption "the Orin DCE display host proxy";
      kernelPackages = lib.mkOption {
        type = lib.types.raw;
        default = pkgs.nvidia-jetpack.kernelPackages;
        defaultText = lib.literalExpression "pkgs.nvidia-jetpack.kernelPackages";
        description = "Base kernel package set used by the Orin DCE host.";
      };
    };
    mgbe0Host.enable = lib.mkEnableOption "host support for passing Orin MGBE0 through to a guest";
    mgbe0Guest = {
      enable = lib.mkEnableOption "Orin MGBE0 support in a passthrough guest";
      kernelPackages = lib.mkOption {
        type = lib.types.raw;
        default = pkgs.linuxPackages_6_12;
        defaultText = lib.literalExpression "pkgs.linuxPackages_6_12";
        description = "Base kernel package set used by the Orin MGBE0 guest.";
      };
    };
    mttcanHost.enable = lib.mkEnableOption "host support for passing both Orin MTTCAN controllers through to a guest";
    mttcanGuest = {
      enable = lib.mkEnableOption "both Orin MTTCAN controllers in a passthrough guest";
      kernelPackages = lib.mkOption {
        type = lib.types.raw;
        default = pkgs.linuxPackages_6_12.extend pkgs.nvidia-jetpack.kernelPackagesOverlay;
        defaultText = lib.literalExpression "pkgs.linuxPackages_6_12.extend pkgs.nvidia-jetpack.kernelPackagesOverlay";
        description = "Kernel package set, including NVIDIA OOT modules, used by the Orin MTTCAN guest.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf bpmpEnabled {
      assertions = [
        {
          assertion = config.hardware.nvidia-jetpack.enable && lib.hasPrefix "orin" config.hardware.nvidia-jetpack.som;
          message = "Orin BPMP virtualization requires hardware.nvidia-jetpack on an Orin SoM.";
        }
        {
          assertion = lib.versionAtLeast config.boot.kernelPackages.kernel.version "6.6";
          message = "Orin BPMP virtualization requires Linux 6.6 or newer.";
        }
      ];

      boot.kernelPatches = [
        {
          name = "Orin virtualization kernel configuration";
          patch = null;
          structuredExtraConfig = with lib.kernel; {
            PCI_STUB = lib.mkDefault yes;
            VFIO = lib.mkDefault yes;
            VIRTIO_PCI = lib.mkDefault yes;
            VIRTIO_MMIO = lib.mkDefault yes;
            HOTPLUG_PCI = lib.mkDefault yes;
            PCI_DEBUG = lib.mkDefault yes;
            PCI_HOST_GENERIC = lib.mkDefault yes;
            VFIO_IOMMU_TYPE1 = lib.mkDefault yes;
            HOTPLUG_PCI_ACPI = lib.mkDefault yes;
            PCI_HOST_COMMON = lib.mkDefault yes;
            VFIO_PLATFORM = yes;
            TEGRA_BPMP_GUEST_PROXY = lib.mkDefault no;
            TEGRA_BPMP_HOST_PROXY = yes;
          }
          // lib.optionalAttrs (lib.versionAtLeast config.boot.kernelPackages.kernel.version "7.1") {
            IOMMUFD = yes;
          };
        }
        {
          name = "vfio-platform optional reset";
          patch = "${support}/patches/linux/bpmp/0002-vfio_platform-reset-required-false.patch";
        }
        {
          name = "BPMP virtualization proxy drivers";
          patch = "${support}/patches/linux/bpmp-sources.patch";
        }
        {
          name = "BPMP virtualization core hooks";
          patch = "${support}/patches/linux/bpmp/0001-bpmp-virt-hooks.patch";
        }
      ];

      boot.kernelParams = [
        "vfio_iommu_type1.allow_unsafe_interrupts=1"
        "arm-smmu.disable_bypass=0"
      ];

      hardware.deviceTree = {
        enable = true;
        overlays = [
          {
            name = "bpmp_host_overlay";
            dtsFile = bpmpHostOverlay;
          }
        ];
      };

      services.udev.extraRules = lib.concatStringsSep "\n" (
        map (name: ''KERNEL=="bpmp-host-${name}", GROUP="kvm", MODE="0660"'') (lib.attrNames consumers)
      );
    })

    (lib.mkIf cfg.dceHost.enable {
      assertions = [
        {
          assertion = config.hardware.nvidia-jetpack.enable && lib.hasPrefix "orin" config.hardware.nvidia-jetpack.som;
          message = "The DCE host proxy requires hardware.nvidia-jetpack on an Orin SoM.";
        }
      ];

      boot.kernelParams = [
        "clk_ignore_unused"
        "pd_ignore_unused"
      ];

      boot.kernelPackages = lib.mkForce (
        (cfg.dceHost.kernelPackages.extend pkgs.nvidia-jetpack.kernelPackagesOverlay).extend (
          _final: prev: {
            devicetree =
              if lib.versionAtLeast prev.kernel.version "7.1" then
                prev.devicetree.overrideAttrs
                  (old: {
                    postPatch = (old.postPatch or "") + ''
                      sed -i '/-Wno-graph_child_address/d' kernel-devicetree/scripts/Makefile.lib
                    '';
                  })
              else
                prev.devicetree;
            nvidia-oot-modules = prev.nvidia-oot-modules.overrideAttrs (old: {
              nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
                pkgs.buildPackages.dtc
                pkgs.buildPackages.unixtools.xxd
              ];
              postPatch = (old.postPatch or "") + ''
                ${lib.optionalString (lib.versionAtLeast prev.kernel.version "7.1") ''
                  substituteInPlace Makefile \
                    --replace-fail 'modules: hwpm nvidia-oot nvgpu nvidia-display' 'modules: nvidia-oot' \
                    --replace-fail 'modules_install: hwpm nvidia-oot nvgpu nvidia-display-install' 'modules_install: nvidia-oot' \
                    --replace-fail 'nvidia-oot: conftest hwpm' 'nvidia-oot: conftest'
                  sed -i '/KBUILD_EXTRA_SYMBOLS=.*hwpm.*Module.symvers/d' Makefile
                  install -m 0644 ${hostNvidiaOotMakefile} nvidia-oot/Makefile

                  substituteInPlace nvidia-oot/drivers/platform/tegra/dce/dce-ipc.c \
                    --replace-fail '#if defined(NV_TEGRA_IVC_STRUCT_HAS_IOSYS_MAP)' '#if 1 /* Linux 7.1 iosys_map IVC */'
                  substituteInPlace nvidia-oot/drivers/platform/tegra/dce/include/dce-ipc.h \
                    --replace-fail '#if defined(NV_TEGRA_IVC_STRUCT_HAS_IOSYS_MAP)' '#if 1 /* Linux 7.1 iosys_map IVC */'
                  substituteInPlace nvidia-oot/drivers/platform/tegra/dce/dce-module.c \
                    --replace-fail '#if defined(NV_PLATFORM_DRIVER_STRUCT_REMOVE_RETURNS_VOID) /* Linux v6.11 */' '#if 1 /* Linux 7.1 */'
                ''}
                install -D ${support}/sources/nvidia-oot/drivers/platform/tegra/dce-host-proxy/dce-host-proxy.c \
                  nvidia-oot/drivers/platform/tegra/dce/dce-host-proxy.c
                install -D ${support}/sources/nvidia-oot/drivers/platform/tegra/dce-host-proxy/dce-host-proxy.h \
                  nvidia-oot/drivers/platform/tegra/dce/dce-host-proxy.h
                echo 'obj-m += dce-host-proxy.o' >> nvidia-oot/drivers/platform/tegra/dce/Makefile

                install -D ${support}/sources/nvidia-oot/drivers/platform/tegra/dce-iso-anchor/dce-iso-anchor.c \
                  nvidia-oot/drivers/platform/tegra/dce/dce-iso-anchor.c
                dtc -@ -I dts -O dtb -o dce-iso-anchor.dtbo \
                  ${support}/sources/nvidia-oot/drivers/platform/tegra/dce-iso-anchor/dce-iso-anchor.dts
                xxd -i -n dce_iso_anchor_dtbo dce-iso-anchor.dtbo \
                  > nvidia-oot/drivers/platform/tegra/dce/dce-iso-anchor-dtbo.h
                echo 'obj-m += dce-iso-anchor.o' >> nvidia-oot/drivers/platform/tegra/dce/Makefile
              '';
            });
          }
        )
      );

      boot.blacklistedKernelModules = [
        "nvidia"
        "nvidia_modeset"
        "nvidia_drm"
        "tegra_drm"
      ];
      boot.kernelModules = [
        "tegra-dce"
        "dce-host-proxy"
        "dce-iso-anchor"
      ];

      services.udev.extraRules = ''
        KERNEL=="dce-host", GROUP="kvm", MODE="0660"
      '';

      hardware.deviceTree = {
        enable = true;
        overlays = [
          {
            name = "dce_host_overlay";
            dtsFile = "${support}/device-trees/host/dce-host-proxy-overlay.dts";
          }
        ];
      };
    })

    (lib.mkIf cfg.mgbe0Host.enable {
      assertions = [
        {
          assertion = config.hardware.nvidia-jetpack.enable && lib.hasPrefix "orin" config.hardware.nvidia-jetpack.som;
          message = "Orin MGBE0 host passthrough requires hardware.nvidia-jetpack on an Orin SoM.";
        }
      ];

      services.udev.extraRules = ''
        SUBSYSTEM=="vfio", GROUP="kvm"
      '';

      boot.blacklistedKernelModules = [
        "nvethernet"
        "dwmac-tegra"
      ];

      systemd.services.bindMgbe0 = {
        description = "Bind MGBE0 (${mgbe0.sysfsName}) to the vfio-platform driver";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStartPre = "${pkgs.bash}/bin/bash -c \"echo vfio-platform > ${mgbe0DevicePath}/driver_override\"";
          ExecStart = "${pkgs.bash}/bin/bash -c \"echo ${mgbe0.sysfsName} > /sys/bus/platform/drivers/vfio-platform/bind\"";
        };
      };

      systemd.services.prepareMgbe0CrosvmOverlay = {
        description = "Prepare the live MGBE0 device-tree overlay for Crosvm";
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe mgbe0Artifacts.prepare;
        };
      };
    })

    (lib.mkIf cfg.mttcanHost.enable {
      assertions = [
        {
          assertion = config.hardware.nvidia-jetpack.enable && lib.hasPrefix "orin" config.hardware.nvidia-jetpack.som;
          message = "Orin MTTCAN host passthrough requires hardware.nvidia-jetpack on an Orin SoM.";
        }
      ];

      services.udev.extraRules = ''
        SUBSYSTEM=="vfio", GROUP="kvm"
      '';

      hardware.deviceTree = {
        enable = true;
        overlays = [
          {
            name = "mttcan_host_overlay";
            # NVIDIA's BSP supplies both upstream-style and `-nv` Orin DTBs,
            # but only the latter contain the two mttcan nodes.  The root
            # compatible strings are identical, so compatibility matching
            # alone would also try this overlay on node-less DTBs and fail.
            filter = "-nv";
            dtsFile = "${support}/device-trees/mttcan/mttcan-host-overlay.dts";
          }
        ];
      };

      systemd.services.bindMttcan = {
        description = "Bind both Orin MTTCAN controllers to the vfio-platform driver";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = lib.getExe bindMttcan;
        };
      };
    })

    (lib.mkIf bpmpGuestEnabled {
      boot.kernelPackages = lib.mkForce (
        if cfg.mttcanGuest.enable then cfg.mttcanGuest.kernelPackages else cfg.mgbe0Guest.kernelPackages
      );
      boot.kernelParams = [
        "clk_ignore_unused"
        "pd_ignore_unused"
      ];
      boot.kernelPatches = [
        {
          name = "BPMP virtualization proxy drivers";
          patch = "${support}/patches/linux/bpmp-sources.patch";
        }
        {
          name = "BPMP virtualization core hooks";
          patch =
            if lib.versionAtLeast config.boot.kernelPackages.kernel.version "7.1" then
              "${support}/patches/linux/bpmp/0001-bpmp-virt-hooks.patch"
            else if lib.versionAtLeast config.boot.kernelPackages.kernel.version "6.12" then
              "${support}/patches/linux/bpmp/0001-bpmp-virt-hooks-6.12.patch"
            else
              "${support}/patches/linux/bpmp/0001-bpmp-virt-hooks.patch";
        }
        {
          name = "BPMP guest proxy kernel configuration";
          patch = null;
          structuredExtraConfig = with lib.kernel; {
            ARCH_TEGRA = yes;
            ARCH_TEGRA_234_SOC = yes;
            TEGRA_HSP_MBOX = yes;
            TEGRA_IVC = yes;
            TEGRA_BPMP = yes;
            TEGRA_BPMP_GUEST_PROXY = yes;
            TEGRA_BPMP_HOST_PROXY = no;
            CLK_TEGRA_BPMP = yes;
            RESET_TEGRA_BPMP = yes;
            PM_GENERIC_DOMAINS = yes;
          };
        }
      ];
    })

    (lib.mkIf cfg.mgbe0Guest.enable {
      boot.kernelPatches = [
        {
          name = "dwmac-tegra fixed stream id";
          patch = "${support}/patches/linux/0001-dwmac-tegra-fixed-stream-id.patch";
        }
        {
          name = "MGBE0 guest kernel configuration";
          patch = null;
          structuredExtraConfig = with lib.kernel; {
            STMMAC_ETH = yes;
            STMMAC_PLATFORM = yes;
            DWMAC_TEGRA = yes;
            AQUANTIA_PHY = yes;
          };
        }
      ];
    })

    (lib.mkIf cfg.mttcanGuest.enable {
      boot.extraModulePackages = [ mttcanModules ];
      boot.kernelModules = [
        "nvpps"
        "mttcan"
      ];
      boot.kernelPatches = [
        {
          name = "MTTCAN guest kernel configuration";
          patch = null;
          structuredExtraConfig = with lib.kernel; {
            CAN = yes;
            CAN_DEV = module;
            CAN_RAW = module;
            PTP_1588_CLOCK = module;
          };
        }
      ];
    })
  ];
}
