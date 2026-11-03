# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{ self, lib, pkgs }:
let
  base = self.nixosConfigurations.orin-agx-devkit-jp7;
  evaluate = module: (base.extendModules {
    modules = [
      self.nixosModules.orin-virtualization
      # Keep the package set available while testing a disabled Jetpack module.
      {
        nixpkgs.pkgs = base.pkgs;
        nixpkgs.config = lib.mkForce { };
      }
      module
    ];
  }).config;
  valid = config: lib.all (a: a.assertion) config.assertions;
  rejects = message: config:
    lib.any (a: a.message == message && !a.assertion) config.assertions;
  split = { compute.role = "compute"; display.role = "display"; };
  combined = { gui.role = "combined"; };
  gpuConfig = assignments: allowAllDomains: evaluate {
    hardware.nvidia-jetpack.virtualization = {
      gpuPassthroughHost.assignments = assignments;
      bpmpHost.allowAllDomains = allowAllDomains;
    };
  };
  allowListMessage = "Orin GPU/display passthrough requires closed BPMP allow-lists; hardware.nvidia-jetpack.virtualization.bpmpHost.allowAllDomains must stay false.";
  hosts = {
    bpmp = {
      config.bpmpHost.consumers.probe = { };
      message = "Orin BPMP virtualization requires hardware.nvidia-jetpack on an Orin SoM.";
    };
    dce = {
      config.dceHost.enable = true;
      message = "The DCE host proxy requires hardware.nvidia-jetpack on an Orin SoM.";
    };
    mgbe0 = {
      config.mgbe0Host.enable = true;
      message = "Orin MGBE0 host passthrough requires hardware.nvidia-jetpack on an Orin SoM.";
    };
    gpu = {
      config.gpuPassthroughHost.assignments = combined;
      message = "Orin GPU/display host passthrough requires hardware.nvidia-jetpack on an Orin SoM.";
    };
  };
  results = {
    guestDoesNotStartDisplayWorkloads = !((evaluate {
      hardware.nvidia-jetpack.virtualization.gpuPassthroughGuest.enable = true;
    }).systemd.services ? kms-owner);
    hostDoesNotAssumeMicrovmUnits = !(lib.elem "microvm@gui.service"
      (gpuConfig combined false).systemd.services.bind-gui-vfio-platform.before);
    splitAllowed = valid (gpuConfig split false);
    combinedAllowed = valid (gpuConfig combined false);
    splitRejectsUnrestrictedBpmp = rejects allowListMessage (gpuConfig split true);
    combinedRejectsUnrestrictedBpmp = rejects allowListMessage (gpuConfig combined true);
    policyDiscoveryWithoutGpu = valid (evaluate {
      hardware.nvidia-jetpack.virtualization.bpmpHost = {
        allowAllDomains = true;
        consumers.probe = { };
      };
    });
  } // lib.mapAttrs
    (_: host:
      lib.all
        (platform: rejects host.message (evaluate {
          hardware.nvidia-jetpack = platform // { virtualization = host.config; };
        })) [
        { enable = lib.mkForce false; }
        { som = lib.mkForce "xavier-agx"; }
      ]
    )
    hosts;
  failed = lib.attrNames (lib.filterAttrs (_: passed: !passed) results);
in
assert lib.assertMsg (failed == [ ]) "Orin virtualization regression failures: ${lib.concatStringsSep ", " failed}";
pkgs.runCommand "orin-virtualization-assertions" { } ''
  touch "$out"
''
