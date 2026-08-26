# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{ config
, lib
, pkgs
, ...
}:
let
  cfg = config.hardware.nvidia-jetpack.virtualization;
  hostAssignments = cfg.gpuPassthroughHost.assignments;
  support = pkgs.nvidia-jetpack.orinVirtualizationSupport;
  roles = support.passthrough.roles;
  payloads = lib.mapAttrs (_: assignment: roles.${assignment.role}) hostAssignments;
  claimedDevices = lib.concatMap (payload: payload.hostDevices) (lib.attrValues payloads);
  roleEnabled = role: lib.any (assignment: assignment.role == role) (lib.attrValues hostAssignments);
  gpuOwner = roleEnabled "compute" || roleEnabled "combined";
  displayOwner = roleEnabled "display" || roleEnabled "combined";
  guestPayload = roles.${cfg.gpuPassthroughGuest.role};
  displayCard = support.passthrough.displayCardPath;
  hasCompositor = config.services.greetd.enable;
  kmscube-wrapped = pkgs.runCommand "kmscube-nomod" { nativeBuildInputs = [ pkgs.buildPackages.makeWrapper ]; } ''
    mkdir -p $out/bin
    makeWrapper ${pkgs.kmscube}/bin/kmscube $out/bin/kmscube \
      --set LD_PRELOAD ${support.gbmNoModifiersShim}/lib/gbm-nomod-shim.so
  '';
  bindServiceName = name: "bind-${name}-vfio-platform";
  bindService = name: payload: {
    description = "Bind ${name} devices to vfio-platform";
    wantedBy = [ "multi-user.target" ];
    before = [ "microvm@${name}.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "bind-${name}-vfio-platform" ''
        set -eu
        for device in ${lib.escapeShellArgs payload.hostDevices}; do
          echo vfio-platform > "/sys/bus/platform/devices/$device/driver_override"
          current=$(basename "$(readlink -f "/sys/bus/platform/devices/$device/driver" 2>/dev/null)" || true)
          if [ "$current" != vfio-platform ]; then
            echo "$device" > /sys/bus/platform/drivers/vfio-platform/bind
          fi
        done
      '';
    };
  };
in
{
  options.hardware.nvidia-jetpack.virtualization = {
    gpuPassthroughHost.assignments = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.role = lib.mkOption {
            type = lib.types.enum [
              "compute"
              "display"
              "combined"
            ];
            description = "GPU/display resource role assigned to this guest.";
          };
        }
      );
      default = { };
      description = "Orin GPU/display passthrough assignments keyed by guest name.";
    };

    gpuPassthroughGuest = {
      enable = lib.mkEnableOption "Orin GPU/display passthrough guest support";
      kernelPackages = lib.mkOption {
        type = lib.types.raw;
        default = pkgs.linuxPackages_6_12;
        defaultText = lib.literalExpression "pkgs.linuxPackages_6_12";
        description = "Base kernel package set used by an Orin GPU/display guest.";
      };
      role = lib.mkOption {
        type = lib.types.enum [
          "compute"
          "display"
          "combined"
        ];
        default = "combined";
        description = "GPU/display resources owned by this guest.";
      };
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (hostAssignments != { }) {
      assertions = [
        {
          assertion = lib.length claimedDevices == lib.length (lib.unique claimedDevices);
          message = "Orin GPU/display passthrough assignments overlap; every physical resource must have one owner.";
        }
        {
          assertion = !(roleEnabled "compute") || roleEnabled "display";
          message = "The Orin compute role requires a display-role peer.";
        }
        {
          assertion = !(roleEnabled "display") || roleEnabled "compute";
          message = "The Orin display role requires a compute-role peer.";
        }
      ];

      hardware.nvidia-jetpack.virtualization = {
        bpmpHost.consumers = lib.mapAttrs (_: assignment: support.bpmpPolicies.${assignment.role}) hostAssignments;
        dceHost.enable = displayOwner;
      };

      services.udev.extraRules = ''
        SUBSYSTEM=="vfio", GROUP="kvm"
      '';
      systemd.services = lib.mapAttrs'
        (
          name: payload: lib.nameValuePair (bindServiceName name) (bindService name payload)
        )
        payloads;
    })

    (lib.mkIf gpuOwner {
      warnings = [
        "Orin GPU passthrough disables host graphics."
      ];
      hardware.graphics.enable = lib.mkForce false;
      boot.blacklistedKernelModules = [
        "nvgpu"
        "nvidia"
        "nvidia_modeset"
        "nvidia_drm"
        "tegra_drm"
        "host1x"
      ];
      hardware.deviceTree.overlays = [
        {
          name = "gpu_passthrough_overlay";
          dtsFile = "${support}/device-trees/gpu-vm/gpu_passthrough_overlay.dts";
        }
      ];
    })

    (lib.mkIf (roleEnabled "compute") {
      hardware.deviceTree.dtboBuildExtraPreprocessorFlags = [ "-DGHAF_INCLUDE_DISPVM_RAM" ];
    })

    (lib.mkIf cfg.gpuPassthroughGuest.enable {
      environment.systemPackages = [
        pkgs.libdrm
        kmscube-wrapped
        pkgs.mesa-demos
        pkgs.drm_info
      ];

      systemd.services.kms-owner = lib.mkIf (guestPayload.capabilities.display && !hasCompositor) {
        description = "Hold DRM master on the nvdisplay card so the panel stays lit";
        wantedBy = [ "multi-user.target" ];
        after = [ "systemd-udev-settle.service" ];
        wants = [ "systemd-udev-settle.service" ];
        serviceConfig = {
          ExecStartPre = "${pkgs.bash}/bin/bash -c 'for i in $(seq 1 60); do [ -e ${displayCard} ] && exit 0; sleep 1; done; exit 1'";
          ExecStart = "${pkgs.bash}/bin/bash -c '${pkgs.coreutils}/bin/sleep infinity | ${kmscube-wrapped}/bin/kmscube -D ${displayCard}'";
          Restart = "always";
          RestartSec = "2";
        };
      };

      systemd.services.dce-rm-deinit = lib.mkIf guestPayload.needsDceBridge {
        description = "Deinitialize NVIDIA DCE RM before the display guest powers off";
        wantedBy = [ "multi-user.target" ];
        before = lib.optional (!hasCompositor) "kms-owner.service" ++ lib.optional hasCompositor "greetd.service";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = lib.getExe' pkgs.coreutils "true";
          ExecStop = "${lib.getExe' pkgs.kmod "modprobe"} -r nvidia_drm nvidia_modeset nvidia";
          TimeoutStopSec = "30";
        };
      };

      hardware.graphics.enable = true;
      hardware.graphics.extraPackages = [
        (pkgs.symlinkJoin {
          name = "l4t-3d-core-egl-gbm-1.1.3";
          paths = [
            (pkgs.egl-gbm.overrideAttrs (old: {
              patches = (old.patches or [ ]) ++ [ support.eglGbmSingleDevicePatch ];
            }))
            pkgs.egl-wayland
            pkgs.nvidia-jetpack.l4t-3d-core
          ];
          postBuild = ''
            rm -f $out/share/egl/egl_external_platform.d/nvidia_gbm.json
          '';
        })
      ]
      ++ (with pkgs.nvidia-jetpack; [
        l4t-core
        l4t-cuda
        l4t-nvsci
      ])
      ++ [
        (pkgs.symlinkJoin {
          name = "l4t-wayland-sans-egl-wayland";
          paths = [ pkgs.nvidia-jetpack.l4t-wayland ];
          postBuild = ''
            rm -f $out/lib/libnvidia-egl-wayland.so*
            rm -f $out/share/egl/egl_external_platform.d/nvidia_wayland.json
          '';
        })
        (pkgs.symlinkJoin {
          name = "l4t-gbm-sans-egl-gbm";
          paths = [ pkgs.nvidia-jetpack.l4t-gbm ];
          postBuild = ''
            rm -f $out/lib/libnvidia-egl-gbm.so*
            rm -f $out/share/egl/egl_external_platform.d/nvidia_gbm.json
          '';
        })
      ];
      environment.etc."egl/egl_external_platform.d".source =
        "${pkgs.addDriverRunpath.driverLink}/share/egl/egl_external_platform.d/";

      boot.kernelPackages = lib.mkForce (
        (cfg.gpuPassthroughGuest.kernelPackages.extend pkgs.nvidia-jetpack.kernelPackagesOverlay).extend (
          _final: prev: {
            devicetree =
              if lib.versionAtLeast prev.kernel.version "7.1" then
                prev.devicetree.overrideAttrs
                  (old: {
                    postPatch = (old.postPatch or "") + ''
                      sed -i '/-Wno-graph_child_address/d' kernel-devicetree/scripts/Makefile.lib
                    '';
                  })
              else
                prev.devicetree;
            nvidia-oot-modules = prev.nvidia-oot-modules.overrideAttrs (old: {
              patches =
                (old.patches or [ ])
                ++ map (name: "${support}/patches/nvidia-oot/gpu-display/${name}") [
                  "0001-gpu-add-support-for-passthrough.patch"
                  "0002-add-support-for-gpu-display-passthrough.patch"
                  "0003-add-support-for-display-passthrough.patch"
                  "0005-force-niso-display-surfaces-contiguous.patch"
                  "0006-dce-addresses-cpu-phys-high-iova.patch"
                  "0008-fix-dual-mode-honor-rm-connect-state.patch"
                  "0009-core-notifier-plain-write-no-awaken.patch"
                  "0020-synthesize-boot-hotplug-long-pulse.patch"
                  "0011-window-notifier-plain-write.patch"
                  "0024-nvkms-keep-flip-completion-binding.patch"
                  "0025-tegra-fbdev-use-core-allocated-fb-info.patch"
                ]
                ++ lib.optional guestPayload.noSyncpointPatch "${support}/patches/nvidia-oot/gpu-display/0021-nvkms-force-no-syncpt-support.patch";
              postPatch = (old.postPatch or "") + ''
                ${lib.optionalString (lib.versionAtLeast prev.kernel.version "7.1") ''
                  substituteInPlace hwpm/drivers/tegra/hwpm/os/linux/driver.c \
                    --replace-fail '#if defined(NV_CLASS_STRUCT_DEVNODE_HAS_CONST_DEV_ARG)' '#if 1 /* Linux 7.1 */' \
                    --replace-fail '#if defined(NV_PLATFORM_DRIVER_STRUCT_REMOVE_RETURNS_VOID) /* Linux v6.11 */' '#if 1 /* Linux 7.1 */'
                  substituteInPlace hwpm/drivers/tegra/hwpm/os/linux/mem_mgmt_utils.c \
                    --replace-fail 'MODULE_IMPORT_NS(DMA_BUF);' 'MODULE_IMPORT_NS("DMA_BUF");' \
                    --replace-fail '#if defined(NV_GET_USER_PAGES_HAS_ARGS_FLAGS) /* Linux v6.5 */' '#if 1 /* Linux 7.1 */'
                ''}
                patch -p1 -d nvidia-oot < ${support}/patches/nvidia-oot/dce/0001-dce-virt-hooks.patch
                patch -p1 -d nvidia-oot < ${support}/patches/nvidia-oot/dce/0002-dce-client-ipc-inject.patch
                install -D ${support}/sources/nvidia-oot/drivers/platform/tegra/dce-guest-proxy/dce-guest-proxy.c \
                  nvidia-oot/drivers/platform/tegra/dce/dce-guest-proxy.c
                echo 'obj-m += dce-guest-proxy.o' >> nvidia-oot/drivers/platform/tegra/dce/Makefile
              '';
            });
          }
        )
      );
      boot.kernelParams = [
        "clk_ignore_unused"
        "pd_ignore_unused"
        "nvidia-drm.modeset=1"
        "drm.vblankoffdelay=0"
      ];
      boot.extraModulePackages = [ config.boot.kernelPackages.nvidia-oot-modules ];
      boot.kernelModules = guestPayload.guestKernelModules;
      hardware.firmware = [ pkgs.nvidia-jetpack.l4t-firmware ];

      boot.kernelPatches = [
        {
          name = "tegra fixed chip id";
          patch = "${support}/patches/linux/0004-tegra-fixed-chip-id.patch";
        }
        {
          name = "bpmp-virt proxy drivers";
          patch = "${support}/patches/linux/bpmp-sources.patch";
        }
        {
          name = "bpmp-virt core hooks";
          patch =
            if lib.versionAtLeast config.boot.kernelPackages.kernel.version "7.1" then
              "${support}/patches/linux/bpmp/0001-bpmp-virt-hooks.patch"
            else
              "${support}/patches/linux/bpmp/0001-bpmp-virt-hooks-6.12.patch";
        }
        {
          name = "bpmp guest proxy kernel configuration";
          patch = null;
          structuredExtraConfig = with lib.kernel; {
            ARCH_TEGRA = lib.mkForce yes;
            ARCH_TEGRA_234_SOC = yes;
            TEGRA_HSP_MBOX = yes;
            TEGRA_IVC = yes;
            TEGRA_BPMP = yes;
            TEGRA_BPMP_GUEST_PROXY = yes;
            TEGRA_BPMP_HOST_PROXY = no;
            CLK_TEGRA_BPMP = yes;
            RESET_TEGRA_BPMP = yes;
            PM_GENERIC_DOMAINS = yes;
            ARM64_PMEM = yes;
          };
        }
      ];

      assertions = [
        {
          assertion = lib.elem "clk_ignore_unused" config.boot.kernelParams && lib.elem "pd_ignore_unused" config.boot.kernelParams;
          message = "Orin GPU/display guests must preserve shared clocks and power domains.";
        }
      ];
    })
  ];
}
