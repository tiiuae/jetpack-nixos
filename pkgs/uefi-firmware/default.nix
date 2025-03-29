{ l4tVersion, config, lib, pkgs, ... }:
let
  uefi-firmware-file = if l4tVersion == "36.4.3" then
      ./r36.4.3
  else if l4tVersion == "35.6.1" then
      ./r35.6
  else
      throw "Not supported l4tVersion version";
in

  pkgs.callPackages "${uefi-firmware-file}" { inherit l4tVersion; }
