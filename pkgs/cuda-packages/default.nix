# Temporary compatibility file for the old overlay structure
# The actual cuda packages are defined individually in this directory
# In the newer structure, this would use packagesFromDirectoryRecursive
{ callPackage, ... }:
rec {
  # Import cudaConfig which many packages need
  cudaConfig = callPackage ./cudaConfig.nix { };
  
  # Core hooks that l4t packages need
  markForCudatoolkitRootHook = callPackage ./markForCudatoolkitRootHook/package.nix { inherit cudaConfig; };
  setupCudaHook = callPackage ./setupCudaHook/package.nix { };
}