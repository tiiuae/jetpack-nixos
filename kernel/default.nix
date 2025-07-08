{ l4tVersion, l4t-xusb-firmware, kernelVersion, gitRepos, realtime ? false, config, lib, pkgs, kernelPatches ? [ ], ... }:
let
  kernel-file =
    if l4tVersion == "36.4.3" then
      if kernelVersion == "bsp-default" then
        ./5.15-r36-4-3
      else if kernelVersion == "upstream-6-6" then
        ./6.6-upstream
      else
        throw "Not supported kernel verion for 36.4.3 l4tVersion"
    else if l4tVersion == "35.6.1" then
      if kernelVersion == "bsp-default" then
        ./5.10-r35.6
      else
        throw "Not supported kernel verion for 35.6.1 l4tVersion"
    else
      throw "Not supported l4tVersion version";
in
pkgs.callPackage "${kernel-file}" { inherit l4t-xusb-firmware gitRepos realtime kernelPatches; }
