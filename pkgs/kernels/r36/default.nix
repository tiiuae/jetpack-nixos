# Kernel version selector for r36 (L4T 36.x)
{ kernelVersion ? "bsp-default", callPackage, ... }@args:
let
  # Remove kernelVersion from args to avoid passing it to the actual kernel package
  kernelArgs = builtins.removeAttrs args [ "kernelVersion" ];
  
  # Select the appropriate kernel package based on kernelVersion
  kernelPackage = 
    if kernelVersion == "bsp-default" then
      ./5.15-bsp.nix
    else if kernelVersion == "upstream-6-6" then
      ./6.6-upstream/default.nix
    else
      throw "Unsupported kernel version '${kernelVersion}' for L4T r36. Supported versions: bsp-default, upstream-6-6";
in
callPackage kernelPackage kernelArgs