{ l4tVersion, l4t-xusb-firmware, realtime ? false, config, lib, pkgs, kernelPatches ? [], ... }:
let
  kernel-file = if l4tVersion == "36.4.3" then
      #./5.15-r36-4-3
      ./6.6-upstream
  else if l4tVersion == "35.6.1" then
      ./5.10-r35.6
  else
      throw "Not supported l4tVersion version";
in
pkgs.callPackage "${kernel-file}" { inherit l4t-xusb-firmware realtime kernelPatches; }
