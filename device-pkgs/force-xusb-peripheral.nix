# SPDX-FileCopyrightText: 2022-2024 Anduril Industries
# SPDX-License-Identifier: MIT

{ config, lib, l4tMajorMinorPatchVersion, writeText, deviceTree }:
let
  cfg = config.hardware.nvidia-jetpack;
  forceXusbPeripheralDts =
    let
      overridePaths = {
        "39" = {
          thor = {
            xudcPadctlPath = "bus@0/padctl@a808680000";
            xudcPath = "bus@0/usb@a808670000";
          };
          orin = {
            xudcPadctlPath = "bus@0/padctl@3520000";
            xudcPath = "bus@0/usb@3550000";
          };
        };
        "36" = {
          orin = {
            xudcPadctlPath = "bus@0/padctl@3520000";
            xudcPath = "bus@0/usb@3550000";
          };
        };
        "35" = {
          orin = {
            xudcPadctlPath = "xusb_padctl@3520000";
            xudcPath = "xudc@3550000";
          };
          xavier = {
            xudcPadctlPath = "xusb_padctl@3520000";
            xudcPath = "xudc@3550000";
          };
        };
      };
      l4tMajor = lib.versions.major l4tMajorMinorPatchVersion;
      soc = builtins.elemAt (lib.strings.split "-" cfg.som) 0;
      inherit (overridePaths.${l4tMajor}.${soc}) xudcPadctlPath xudcPath;
    in
    writeText "dts" ''
      /dts-v1/;

      / {
        fragment@0 {
          target-path = "/${xudcPadctlPath}/ports/usb2-0";

          board_config {
            sw-modules = "kernel", "uefi";
          };

          __overlay__ {
            mode = "peripheral";
            /* usb-role-switch and connector are required
              * use a dummy connector that claims USB is connected at boot
              */
            usb-role-switch;
            connector {
              compatible = "usb-b-connector", "gpio-usb-b-connector";
              label = "usb-recovery";
              cable-connected-on-boot = <2>;
            };
          };
        };

        fragment@1 {
          target-path = "/${xudcPath}";

          board_config {
            sw-modules = "kernel", "uefi";
          };

          __overlay__ {
            status = "okay";
          };
        };
      };
    '';
  forceXusbPeripheralDtbo = deviceTree.compileDTS {
    # We force USB port to peripheral mode, in case the carrier board doesn't support OTG
    # Fortunately, the USB controller is all in the SoC, so we can override it directly here
    name = "force-xusb-peripheral.dtbo";
    dtsFile = forceXusbPeripheralDts;
  };

in
forceXusbPeripheralDtbo
