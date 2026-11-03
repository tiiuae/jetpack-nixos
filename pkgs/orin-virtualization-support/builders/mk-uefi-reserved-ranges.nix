# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{ lib }:
{ pkgs, support, includeDispVmRam }:
let
  inherit (support.passthrough.reservedMemory) vmCma scanout dispRamLow dispRamHigh;
  # vmHs is the host1x register aperture, not DRAM.
  ranges = [ vmCma scanout ] ++ lib.optionals includeDispVmRam [ dispRamLow dispRamHigh ];
  cell = value: "0x${lib.toLower (lib.toHexString value)}";
  cells = value: "${cell (value / 4294967296)} ${cell (lib.mod value 4294967296)}";
  reg = lib.concatMapStringsSep " " (range: "${cells range.base} ${cells range.size}") ranges;
  source = pkgs.writeText "uefi-reserved-ranges.dts" ''
    /dts-v1/;
    /plugin/;
    / {
      overlay-name = "UEFI VM reserved ranges";
      fragment@0 {
        target-path = "/";
        board_config {
          sw-modules = "uefi";
        };
        __overlay__ {
          firmware {
            uefi {
              reserved-ranges {
                compatible = "ghaf,uefi-reserved-ranges";
                #address-cells = <2>;
                #size-cells = <2>;
                reg = <${reg}>;
              };
            };
          };
        };
      };
    };
  '';
in
pkgs.buildPackages.runCommand "UefiReservedRanges.dtbo"
{ nativeBuildInputs = [ pkgs.buildPackages.dtc ]; }
  ''
    dtc -@ -W no-unit_address_vs_reg -W no-reg_format -W no-avoid_default_addr_size \
      -I dts -O dtb ${source} -o $out
  ''
