# Dynamic overlay that uses mk-overlay.nix with version selection
# This provides a migration path from the static overlay.nix to the dynamic mk-overlay.nix

final: prev:
let
  inherit (prev.lib) makeScope;
  
  # Version mapping for JetPack major versions
  versionMap = {
    "5" = {
      jetpack = "5.1.5";
      l4t = "35.6.0";  # Based on uefi-firmware check in overlay.nix
      cuda = "11.4.298";
      cudaDriver = "11.4";
      bspHash = "sha256-1pALDC0vYDBFpO9XA39vbA3dvlFD4dJuQxLSBQW/GSo=";
    };
    "6" = {
      jetpack = "6.2";
      l4t = "36.4.3";
      cuda = "12.6.10";
      cudaDriver = "12.6";
      bspHash = "sha256-lJpEBJxM5qjv31cuoIIMh09u5dQco+STW58OONEYc9I=";
    };
  };

  # Try to detect majorVersion from different sources
  # Default to "6" for Orin support
  majorVersion = "6";

  # Get version info based on major version
  versionInfo = versionMap.${majorVersion} or (throw "Unknown JetPack major version: ${majorVersion}");

  # Import mk-overlay to get the overlay function
  mkOverlay = import ./mk-overlay.nix {
    jetpackMajorMinorPatchVersion = versionInfo.jetpack;
    l4tMajorMinorPatchVersion = versionInfo.l4t;
    cudaMajorMinorPatchVersion = versionInfo.cuda;
    cudaDriverMajorMinorVersion = versionInfo.cudaDriver;
    bspHash = versionInfo.bspHash;
  };

  # Call the overlay function to get the jetpack scope content
  jetpackScopeContent = mkOverlay final prev;

in
{
  # Wrap the scope content in nvidia-jetpack attribute
  nvidia-jetpack = makeScope prev.newScope (self: jetpackScopeContent);
}