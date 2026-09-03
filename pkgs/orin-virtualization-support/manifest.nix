# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

{ lib }:
let
  hex = lib.fromHexString;
  formatAddress = value: "0x${lib.toLower (lib.toHexString value)}";

  agx = {
    dcbDtsi = "generated/agx-p3737-p3701-dcb.dtsi";
    dcbSha256 = "e0d92e6dbf1ffef266cfd2e192847e76f8d88c19c55430f2f5d4aaf69494a2fc";
    dcbBytes = "8407";
  };

  hardware = rec {
    crosvmLayout = rec {
      memoryBase = hex "0x2000000000";
      platformMmio = {
        base = hex "0x60000000";
        size = memoryBase - platformMmio.base;
      };
    };

    reservedMemory = {
      vmHs = {
        dev = "60000000.vm_hs_p";
        base = hex "0x60000000";
        size = hex "0x04000000";
        symbol = "vm_hs_p";
      };
      vmCma = {
        dev = "80000000.vm_cma_p";
        base = hex "0x80000000";
        size = hex "0x30000000";
        symbol = "vm_cma_p";
      };
      scanout = {
        dev = "b0000000.scanout_p";
        base = hex "0xb0000000";
        size = hex "0x08000000";
        symbol = "scanout_p";
      };
      dispRamLow = {
        dev = "b8000000.dispram_lo_p";
        base = hex "0xb8000000";
        size = hex "0x2e000000";
        symbol = "dispram_lo_p";
      };
      dispRamHigh = {
        dev = "200000000.dispram_hi_p";
        base = hex "0x200000000";
        size = hex "0x1a000000";
        symbol = "dispram_hi_p";
      };
    };

    displayCaps = [
      {
        dev = "13830000.disp_caps_pt";
        base = hex "0x66230000";
        size = hex "0x00010000";
        symbol = "disp_caps_pt";
      }
      {
        dev = "13870000.disp_chan_pt";
        base = hex "0x66270000";
        size = hex "0x00010000";
        symbol = "disp_chan_pt";
      }
      {
        dev = "138c8000.disp_cursor_pt";
        base = hex "0x662c8000";
        size = hex "0x00008000";
        symbol = "disp_cursor_pt";
      }
    ];

    engines = {
      gpu = {
        dev = "17000000.gpu";
        symbol = "ga10b";
      };
      host1x = {
        dev = "13e00000.host1x_pt";
        symbol = "host1x";
      };
      vic = {
        dev = "15340000.vic";
        symbol = "vic";
      };
      nvdec = {
        dev = "15480000.nvdec";
        symbol = "nvdec";
      };
      nvjpg = {
        dev = "15540000.nvjpg";
        symbol = "nvjpg";
      };
    };

    mgbe0 = {
      sysfsName = "6800000.ethernet";
      nodeName = "ethernet@6800000";
      nodePath = "/bus@0/ethernet@6800000";
      compatible = "nvidia,tegra234-mgbe";
      dtSymbol = "mgbe0";
      crosvmOverlayPath = "/run/mgbe0-net-vm.dtbo";
    };

    mttcan = {
      compatible = "nvidia,tegra194-mttcan";
      controllers = [
        {
          interfaceName = "can0";
          sysfsName = "c310000.mttcan";
          nodeName = "mttcan@c310000";
          nodePath = "/bus@0/mttcan@c310000";
          dtSymbol = "mttcan0";
          clocks = [
            284 # TEGRA234_CLK_CAN1_CORE
            10 # TEGRA234_CLK_CAN1_HOST
            9 # TEGRA234_CLK_CAN1
            94 # TEGRA234_CLK_PLLAON
          ];
          resets = [ 4 ]; # TEGRA234_RESET_CAN1
        }
        {
          interfaceName = "can1";
          sysfsName = "c320000.mttcan";
          nodeName = "mttcan@c320000";
          nodePath = "/bus@0/mttcan@c320000";
          dtSymbol = "mttcan1";
          clocks = [
            285 # TEGRA234_CLK_CAN2_CORE
            12 # TEGRA234_CLK_CAN2_HOST
            11 # TEGRA234_CLK_CAN2
            94 # TEGRA234_CLK_PLLAON
          ];
          resets = [ 5 ]; # TEGRA234_RESET_CAN2
        }
      ];
    };

    displayCardPath = "/dev/dri/by-path/platform-66200000.display-card";
  };

  mkRole =
    name: capabilities:
    let
      inherit (capabilities) display gpu host1x;
      displayOnly = display && !gpu && !host1x;
      computeWithHost1x = gpu && host1x && !display;
      reservedMemory =
        if displayOnly then
          with hardware.reservedMemory;
          [
            scanout
            dispRamLow
            dispRamHigh
          ]
        else
          lib.optional host1x hardware.reservedMemory.vmHs
          ++ [ hardware.reservedMemory.vmCma ]
          ++ lib.optional (!computeWithHost1x) hardware.reservedMemory.scanout;
      displayCaps = lib.optionals display hardware.displayCaps;
      engines =
        lib.optional gpu hardware.engines.gpu
        ++ lib.optionals host1x [
          hardware.engines.host1x
          hardware.engines.vic
          hardware.engines.nvdec
          hardware.engines.nvjpg
        ];
      hostDevices = map (device: device.dev) (reservedMemory ++ displayCaps ++ engines);
    in
    {
      inherit
        capabilities
        displayCaps
        engines
        hostDevices
        name
        reservedMemory
        ;

      expDtDefines =
        lib.optionalString (!host1x) "-DEXP_DROP_HOST1X "
        + lib.optionalString (!display) "-DEXP_DROP_DISPLAY "
        + lib.optionalString displayOnly "-DEXP_DROP_GPU "
        + lib.optionalString computeWithHost1x "-DEXP_SHRINK_BANK1 ";

      guestDts = if displayOnly then "disp-vm/tegra234-dispvm.dts" else "gpu-vm/tegra234-gpuvm.dts";
      dtbName = if displayOnly then "tegra234-dispvm.dtb" else "tegra234-gpuvm.dtb";
      crosvmOverlayDts =
        if displayOnly then
          "disp-vm/tegra234-dispvm-crosvm-overlay.dts"
        else
          "gpu-vm/tegra234-guivm-crosvm-overlay.dts";
      crosvmOverlayName = "tegra234-${name}-crosvm-overlay";

      vfioArgs =
        lib.concatMap
          (resource: [
            "-device"
            "vfio-platform,host=${resource.dev},mmio-base=${formatAddress resource.base}"
          ])
          (reservedMemory ++ displayCaps)
        ++ lib.concatMap
          (device: [
            "-device"
            "vfio-platform,host=${device.dev}"
          ])
          engines;

      crosvmDevices =
        map
          (resource: {
            path = resource.dev;
            dtSymbol = resource.symbol;
            iommu = "off";
            mmioBase = resource.base;
            mapEarly = true;
          })
          reservedMemory
        ++ map
          (resource: {
            path = resource.dev;
            dtSymbol = resource.symbol;
            iommu = "off";
            mmioBase = resource.base;
          })
          displayCaps
        ++ map
          (device: {
            path = device.dev;
            dtSymbol = device.symbol;
            iommu = "off";
          })
          engines;

      guestKernelModules =
        lib.optionals host1x [
          "nvmap"
          "host1x"
          "nvhost"
          "nvgpu"
        ]
        ++ lib.optionals display [
          "nvmap"
          "tegra-dce"
          "dce-guest-proxy"
          "nvidia-modeset"
          "nvidia-drm"
        ];

      needsDceBridge = display;
      noSyncpointPatch = capabilities.noSyncpointDisplay;
      inherit (hardware) crosvmLayout;
    };

  roles = {
    compute = mkRole "gpuvm" {
      gpu = true;
      host1x = true;
      media = true;
      display = false;
      noSyncpointDisplay = false;
    };
    display = mkRole "dispvm" {
      gpu = false;
      host1x = false;
      media = false;
      display = true;
      noSyncpointDisplay = true;
    };
    combined = mkRole "guivm" {
      gpu = true;
      host1x = true;
      media = true;
      display = true;
      noSyncpointDisplay = false;
    };
  };
in
{
  bpmpPolicies = import ./bpmp-policies.nix;
  passthrough = hardware // { inherit roles; };

  boards = {
    inherit agx;
    nx = agx;
  };
}
