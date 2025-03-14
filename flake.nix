{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/4fd304c580d3704b4f3a9955b354148b4f1d73b1";
  };

  outputs = { self, nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;

      allSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs allSystems (system: f {
        pkgs = nixpkgs.legacyPackages.${system};
        inherit system;
      });

      installer_minimal_config = {
        imports = [
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-minimal.nix"
          self.nixosModules.default
        ];
        # Avoids a bunch of extra modules we don't have in the tegra_defconfig, like "ata_piix",
        hardware.enableAllHardware = lib.mkForce false;

        hardware.nvidia-jetpack.enable = true;
      };
    in
    {
      nixosConfigurations = {
        installer_minimal = nixpkgs.legacyPackages.aarch64-linux.nixos installer_minimal_config;
        installer_minimal_cross = nixpkgs.legacyPackages.x86_64-linux.pkgsCross.aarch64-multiplatform.nixos installer_minimal_config;
      };

      nixosModules.default = import ./modules/default.nix;

      overlays.default = import ./overlay.nix;

      packages = {
        x86_64-linux =
          let
            supportedConfigurations = lib.listToAttrs (map
              (c: {
                name = "${c.som}-${c.jetpackVersion}-${c.kernelVersion}-${c.carrierBoard}";
                value = c;
              }) [
              { som = "orin-agx"; jetpackVersion = "jp5-1-4"; kernelVersion = "jpBSPKernel"; carrierBoard = "devkit"; }
              { som = "orin-agx"; jetpackVersion = "jp6-2"; kernelVersion = "jpBSPKernel"; carrierBoard = "devkit"; }
              { som = "orin-agx"; jetpackVersion = "jp6-2"; kernelVersion = "upstreamKernel6-6"; carrierBoard = "devkit"; }
              { som = "orin-agx-industrial"; jetpackVersion = "jp5-1-4"; kernelVersion = "jpBSPKernel"; carrierBoard = "devkit"; }
              { som = "orin-nx"; jetpackVersion = "jp5-1-4"; kernelVersion = "jpBSPKernel"; carrierBoard = "devkit"; }
              { som = "orin-nx"; jetpackVersion = "jp6-2"; kernelVersion = "jpBSPKernel"; carrierBoard = "devkit"; }
              { som = "orin-nx"; jetpackVersion = "jp6-2"; kernelVersion = "upstreamKernel6-6"; carrierBoard = "devkit"; }
              { som = "orin-nx"; jetpackVersion = "jp6-2"; kernelVersion = "jpBSPKernel"; carrierBoard = "io-base-b-devkit"; }
              { som = "orin-nx"; jetpackVersion = "jp6-2"; kernelVersion = "upstreamKernel6-6"; carrierBoard = "io-base-b-devkit"; }
              { som = "orin-nano"; jetpackVersion = "jp5-1-4"; kernelVersion = "jpBSPKernel"; carrierBoard = "devkit"; }
              { som = "xavier-agx"; jetpackVersion = "jp5-1-4"; kernelVersion = "jpBSPKernel"; carrierBoard = "devkit"; }
              { som = "xavier-agx-industrial"; jetpackVersion = "jp5-1-4"; kernelVersion = "jpBSPKernel"; carrierBoard = "devkit"; } # TODO: Entirely untested
              { som = "xavier-nx"; jetpackVersion = "jp5-1-4"; kernelVersion = "jpBSPKernel"; carrierBoard = "devkit"; }
              { som = "xavier-nx-emmc"; jetpackVersion = "jp5-1-4"; kernelVersion = "jpBSPKernel"; carrierBoard = "devkit"; }
            ]);

            supportedNixOSConfigurations = lib.mapAttrs
              (n: c: (nixpkgs.legacyPackages.x86_64-linux.pkgsCross.aarch64-multiplatform.nixos {
                imports = [ self.nixosModules.default ];
                hardware.nvidia-jetpack = { enable = true; } // c;
                networking.hostName = "${c.som}-${c.jetpackVersion}-${c.kernelVersion}-${c.carrierBoard}"; # Just so it sets the flash binary name.
              }).config)
              supportedConfigurations;

            flashScripts = lib.mapAttrs' (n: c: lib.nameValuePair "flash-${n}" c.system.build.flashScript) supportedNixOSConfigurations;
            initrdFlashScripts = lib.mapAttrs' (n: c: lib.nameValuePair "initrd-flash-${n}" c.system.build.initrdFlashScript) supportedNixOSConfigurations;
            uefiCapsuleUpdates = lib.mapAttrs' (n: c: lib.nameValuePair "uefi-capsule-update-${n}" c.system.build.uefiCapsuleUpdate) supportedNixOSConfigurations;
          in
          {
            # TODO: Untested
            iso_minimal = self.nixosConfigurations.installer_minimal_cross.config.system.build.isoImage;

            inherit (self.legacyPackages.x86_64-linux)
              board-automation python-jetson;
            inherit (self.legacyPackages.x86_64-linux.cudaPackages)
              nsight_systems_host nsight_compute_host;
          }
          # Flashing and board automation scripts _only_ work on x86_64-linux
          // flashScripts
          // initrdFlashScripts
          // uefiCapsuleUpdates;

        aarch64-linux = {
          iso_minimal = self.nixosConfigurations.installer_minimal.config.system.build.isoImage;
        };
      };

      checks = forAllSystems ({ pkgs, ... }: {
        formatting = pkgs.runCommand "repo-formatting" { nativeBuildInputs = with pkgs; [ nixpkgs-fmt ]; } ''
          nixpkgs-fmt --check ${self} && touch $out
        '';
      });

      formatter = forAllSystems ({ pkgs, ... }: pkgs.nixpkgs-fmt);

      legacyPackages = forAllSystems ({ system, ... }:
        (import nixpkgs { inherit system; overlays = [ self.overlays.default ]; }).nvidia-jetpack
      );
    };
}
