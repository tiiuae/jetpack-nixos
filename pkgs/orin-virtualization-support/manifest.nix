# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

{ lib }:
let
  hex = lib.fromHexString;
  agx = {
    dcbDtsi = "generated/agx-p3737-p3701-dcb.dtsi";
    dcbSha256 = "e0d92e6dbf1ffef266cfd2e192847e76f8d88c19c55430f2f5d4aaf69494a2fc";
    dcbBytes = "8407";
  };
in
{
  bpmpPolicies = import ./bpmp-policies.nix;

  passthrough = {
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
  };

  boards = {
    inherit agx;
    nx = agx;
  };
}
