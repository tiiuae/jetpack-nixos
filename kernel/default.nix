{ l4tVersion, kernelVersion, l4t-xusb-firmware, realtime ? false, config, lib, pkgs, kernelPatches ? [], ... }:
let
  kernel-file = if l4tVersion == "36.4.3" then
      if kernelVersion == "upstreamKernel6-6" then
        ./6.6-upstream
      else if kernelVersion == "jpBSPKernel" then
        ./5.15-r36-4-3
      else
        throw "Not supported kernelVersion"
  else if l4tVersion == "35.6.0" then
      ./5.10-r35.6
  else
    throw "Not supported l4tVersion version";
in
pkgs.callPackage "${kernel-file}" { inherit l4t-xusb-firmware realtime kernelPatches; }
