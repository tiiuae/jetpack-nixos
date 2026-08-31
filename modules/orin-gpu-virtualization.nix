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
  guestNvidiaOotDriversMakefile = pkgs.writeText "nvidia-oot-guest-drivers-Makefile" ''
    LINUXINCLUDE += -I$(srctree.nvidia-oot)/include
    LINUXINCLUDE += -I$(srctree.nvidia-oot)/drivers/gpu/host1x/hw/
    LINUXINCLUDE += -I$(srctree.nvidia-oot)/drivers/video/tegra/host/
    LINUXINCLUDE += -I$(srctree.nvidia-oot)/drivers/gpu/host1x/include
    LINUXINCLUDE += -I$(srctree.hwpm)/include

    obj-m += devfreq/
    obj-m += gpu/host1x-fence/
    obj-m += gpu/host1x-nvhost/
    obj-m += platform/tegra/dce/
    obj-m += platform/tegra/mc-utils/
    obj-m += video/tegra/nvmap/
  '';
  nvmapLinux71Compat = pkgs.writeText "nvmap-linux-7.1-compat.h" ''
    #ifndef NVMAP_LINUX_7_1_COMPAT_H
    #define NVMAP_LINUX_7_1_COMPAT_H

    #include <linux/mm.h>

    #ifndef nth_page
    #define nth_page(page, n) \
      folio_page(page_folio(page), \
                 folio_page_idx(page_folio(page), page) + (n))
    #endif

    #endif
  '';
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
                  "0026-nvgpu-map-syncpoint-aperture-as-resource.patch"
                  "0027-nvgpu-honor-ga10b-iommu-bypass.patch"
                ]
                ++ lib.optional guestPayload.noSyncpointPatch "${support}/patches/nvidia-oot/gpu-display/0021-nvkms-force-no-syncpt-support.patch";
              postPatch = (old.postPatch or "") + ''
                ${lib.optionalString (lib.versionAtLeast prev.kernel.version "7.1") ''
                  # The accelerated guest only consumes the GPU/display module
                  # closure below.  Avoid compiling unrelated BSP drivers whose
                  # private APIs have no bearing on this VM.
                  substituteInPlace nvidia-oot/Makefile \
                    --replace-fail $'ifdef CONFIG_SND_SOC\nobj-m += sound/soc/tegra/\nobj-m += sound/tegra-safety-audio/\nobj-m += sound/soc/tegra-virt-alt/\nendif' '# Audio is outside the GPU/display guest closure.'
                  install -m 0644 ${guestNvidiaOotDriversMakefile} nvidia-oot/drivers/Makefile
                  install -m 0644 ${nvmapLinux71Compat} nvidia-oot/include/linux/nvmap-linux-7.1-compat.h
                  sed -i '/#include <linux\/version.h>/a #include <linux/nvmap-linux-7.1-compat.h>' \
                    nvidia-oot/drivers/video/tegra/nvmap/nvmap_priv.h
                  substituteInPlace nvidia-oot/drivers/video/tegra/nvmap/Makefile.memory.configs \
                    --replace-fail 'NVMAP_CONFIG_SCIIPC := y' 'NVMAP_CONFIG_SCIIPC := n # Not used by the GPU/display guest.'
                  substituteInPlace nvgpu/drivers/gpu/nvgpu/Makefile.linux.configs \
                    --replace-fail 'CONFIG_NVGPU_PCI_IGPU := y' 'CONFIG_NVGPU_PCI_IGPU := n # Platform GPU guest only.'
                  substituteInPlace nvgpu/drivers/gpu/nvgpu/os/linux/scale.c \
                    --replace-fail $'#ifdef CONFIG_DEVFREQ_THERMAL\n\t\tcooling = of_devfreq_cooling_register(dev->of_node, devfreq);\n\t\tif (IS_ERR(cooling))\n\t\t\tdev_info(dev, "Failed to register cooling device\\n");\n\t\telse\n\t\t\tl->cooling = cooling;\n#endif' $'#ifdef CONFIG_DEVFREQ_THERMAL\n\t\tif (devfreq != NULL) {\n\t\t\tcooling = of_devfreq_cooling_register(dev->of_node, devfreq);\n\t\t\tif (IS_ERR(cooling))\n\t\t\t\tdev_info(dev, "Failed to register cooling device\\n");\n\t\t\telse\n\t\t\t\tl->cooling = cooling;\n\t\t}\n#endif'

                  # R36.5 carries conftests for these API transitions, but its
                  # conftest probes predate Linux 7.1.  Select the known 7.1
                  # sides explicitly for the guest module closure.
                  for source in \
                    nvidia-oot/drivers/gpu/host1x/dev.c \
                    nvidia-oot/drivers/gpu/host1x/mipi.c \
                    nvidia-oot/drivers/platform/tegra/dce/dce-module.c \
                    nvidia-oot/drivers/video/tegra/nvmap/nvmap_init.c; do
                    substituteInPlace "$source" \
                      --replace-fail '#if defined(NV_PLATFORM_DRIVER_STRUCT_REMOVE_RETURNS_VOID) /* Linux v6.11 */' '#if 1 /* Linux 7.1 */'
                  done
                  substituteInPlace nvidia-oot/drivers/gpu/host1x/cdma.c \
                    --replace-fail '#if defined(NV_IOMMU_MAP_HAS_GFP_ARG) /* Linux v6.3 */' '#if 1 /* Linux 7.1 */'
                  substituteInPlace nvidia-oot/drivers/gpu/host1x-nvhost/nvhost.c \
                    --replace-fail '#if defined(NV_CLASS_CREATE_HAS_NO_OWNER_ARG) /* Linux v6.4 */' '#if 1 /* Linux 7.1 */'
                  substituteInPlace nvidia-oot/drivers/gpu/host1x-fence/dev.c \
                    --replace-fail '#if defined(NV_CLASS_STRUCT_DEVNODE_HAS_CONST_DEV_ARG) /* Linux v6.2 */' '#if 1 /* Linux 7.1 */' \
                    --replace-fail '#if defined(NV_CLASS_CREATE_HAS_NO_OWNER_ARG) /* Linux v6.4 */' '#if 1 /* Linux 7.1 */' \
                    --replace-fail 'spin_lock(pfd_fence->fence->lock);' 'spin_lock(dma_fence_spinlock(pfd_fence->fence));' \
                    --replace-fail 'spin_unlock(pfd_fence->fence->lock);' 'spin_unlock(dma_fence_spinlock(pfd_fence->fence));'
                  substituteInPlace nvidia-oot/drivers/platform/tegra/dce/dce-ipc.c \
                    --replace-fail '#if defined(NV_TEGRA_IVC_STRUCT_HAS_IOSYS_MAP) /* Linux v6.2 */' '#if 1 /* Linux 7.1 */'
                  substituteInPlace nvidia-oot/drivers/platform/tegra/dce/include/dce-ipc.h \
                    --replace-fail '#if defined(NV_TEGRA_IVC_STRUCT_HAS_IOSYS_MAP)' '#if 1 /* Linux 7.1 */'

                  substituteInPlace nvidia-oot/drivers/video/tegra/nvmap/nvmap_priv.h \
                    --replace-fail '#if defined(NV_GET_USER_PAGES_HAS_ARGS_FLAGS) /* Linux v6.5 */' '#if 1 /* Linux 7.1 */' \
                    --replace-fail '__weak int nvmap_sci_ipc_init(void)' 'static inline int nvmap_sci_ipc_init(void)' \
                    --replace-fail '__weak void nvmap_sci_ipc_exit(void)' 'static inline void nvmap_sci_ipc_exit(void)'
                  substituteInPlace nvidia-oot/drivers/video/tegra/nvmap/nvmap_dmabuf.c \
                    --replace-fail '#if defined(NV_VM_AREA_STRUCT_HAS_CONST_VM_FLAGS) /* Linux v6.3 */' '#if 1 /* Linux 7.1 */' \
                    --replace-fail $'\t.cache_sgt_mapping = true,\n' ""
                  for source in \
                    nvidia-oot/drivers/video/tegra/nvmap/nvmap_handle.c \
                    nvidia-oot/drivers/video/tegra/nvmap/nvmap_sci_ipc.c; do
                    substituteInPlace "$source" \
                      --replace-fail '#if defined(NV_GET_FILE_RCU_HAS_DOUBLE_PTR_FILE_ARG) /* Linux 6.7 */' '#if 1 /* Linux 7.1 */'
                  done
                  substituteInPlace nvidia-oot/drivers/video/tegra/nvmap/nvmap_handle.c \
                    --replace-fail 'atomic_long_inc_not_zero(&h->dmabuf->file->f_count) == 0' '!file_ref_get(&h->dmabuf->file->f_ref)'
                  for source in nvidia-oot/drivers/video/tegra/nvmap/*.c; do
                    sed -E -i 's/atomic_long_read\(&([^)]*)->f_count\)/file_count(\1)/g' "$source"
                  done
                  sed -E -i 's/__assign_str\(([^,]+), [^;]+\);/__assign_str(\1);/' \
                    nvidia-oot/include/trace/events/nvmap.h
                  substituteInPlace hwpm/drivers/tegra/hwpm/os/linux/driver.c \
                    --replace-fail '#if defined(NV_CLASS_STRUCT_DEVNODE_HAS_CONST_DEV_ARG)' '#if 1 /* Linux 7.1 */' \
                    --replace-fail '#if defined(NV_PLATFORM_DRIVER_STRUCT_REMOVE_RETURNS_VOID) /* Linux v6.11 */' '#if 1 /* Linux 7.1 */'
                  substituteInPlace hwpm/drivers/tegra/hwpm/os/linux/mem_mgmt_utils.c \
                    --replace-fail 'MODULE_IMPORT_NS(DMA_BUF);' 'MODULE_IMPORT_NS("DMA_BUF");' \
                    --replace-fail '#if defined(NV_GET_USER_PAGES_HAS_ARGS_FLAGS) /* Linux v6.5 */' '#if 1 /* Linux 7.1 */'
                  substituteInPlace nvgpu/drivers/gpu/nvgpu/os/linux/pci_power.c \
                    --replace-fail '#include <linux/of_gpio.h>' $'#include <linux/gpio.h>\n#define of_get_named_gpio(np, propname, index) ((void)(np), (void)(propname), (void)(index), -EOPNOTSUPP)'
                  substituteInPlace nvgpu/drivers/gpu/nvgpu/os/linux/dmabuf_nvs.c \
                    --replace-fail '#if defined(NV_VM_AREA_STRUCT_HAS_CONST_VM_FLAGS) /* Linux v6.3 */' '#if 1 /* Linux 7.1 */' \
                    --replace-fail 'zap_vma_ptes(vma, vma->vm_start, vma->vm_end - vma->vm_start);' 'zap_special_vma_range(vma, vma->vm_start, vma->vm_end - vma->vm_start);'
                  substituteInPlace nvgpu/drivers/gpu/nvgpu/os/linux/ioctl.c \
                    --replace-fail '#if defined(NV_CLASS_STRUCT_DEVNODE_HAS_CONST_DEV_ARG) /* Linux v6.2 */' '#if 1 /* Linux 7.1 */' \
                    --replace-fail '#if defined(NV_CLASS_CREATE_HAS_NO_OWNER_ARG) /* Linux v6.4 */' '#if 1 /* Linux 7.1 */'
                  for source in \
                    nvgpu/drivers/gpu/nvgpu/os/linux/ioctl_ctrl.c \
                    nvgpu/drivers/gpu/nvgpu/os/linux/debug_gr.c; do
                    substituteInPlace "$source" \
                      --replace-fail '#if defined(NV_VM_AREA_STRUCT_HAS_CONST_VM_FLAGS) /* Linux v6.3 */' '#if 1 /* Linux 7.1 */'
                  done
                  substituteInPlace nvgpu/drivers/gpu/nvgpu/os/linux/ioctl_ctrl.c \
                    --replace-fail 'zap_vma_ptes(vma, vma->vm_start, vma->vm_end - vma->vm_start);' 'zap_special_vma_range(vma, vma->vm_start, vma->vm_end - vma->vm_start);'
                  substituteInPlace nvgpu/drivers/gpu/nvgpu/os/linux/module.c \
                    --replace-fail '#include <linux/of_gpio.h>' $'#include <linux/gpio.h>\n#define of_get_named_gpio(np, propname, index) ((void)(np), (void)(propname), (void)(index), -EOPNOTSUPP)' \
                    --replace-fail '#if defined(NV_PLATFORM_DRIVER_STRUCT_REMOVE_RETURNS_VOID) /* Linux v6.11 */' '#if 1 /* Linux 7.1 */' \
                    --replace-fail 'MODULE_IMPORT_NS(DMA_BUF);' 'MODULE_IMPORT_NS("DMA_BUF");'
                  substituteInPlace nvgpu/drivers/gpu/nvgpu/os/linux/periodic_timer.c \
                    --replace-fail $'\thrtimer_init(&timer->timer, CLOCK_MONOTONIC, HRTIMER_MODE_REL);\n\ttimer->timer.function = timer_callback;' $'\thrtimer_setup(&timer->timer, timer_callback, CLOCK_MONOTONIC, HRTIMER_MODE_REL);'
                  substituteInPlace nvgpu/drivers/gpu/nvgpu/os/linux/platform_gk20a_tegra.c \
                    --replace-fail $'static long gm20b_round_rate_ops(struct clk_hw *hw, unsigned long rate,\n\t\t\t     unsigned long *parent_rate)\n{\n\tstruct clk_gk20a *clk = clk_gk20a_from_hw(hw);\n\treturn gm20b_round_rate(clk, rate, parent_rate);\n}' $'static int gm20b_determine_rate_ops(struct clk_hw *hw,\n\t\t\t    struct clk_rate_request *req)\n{\n\tstruct clk_gk20a *clk = clk_gk20a_from_hw(hw);\n\tlong rate = gm20b_round_rate(clk, req->rate, &req->best_parent_rate);\n\n\tif (rate < 0)\n\t\treturn rate;\n\treq->rate = rate;\n\treturn 0;\n}' \
                    --replace-fail '.round_rate = gm20b_round_rate_ops,' '.determine_rate = gm20b_determine_rate_ops,'
                  substituteInPlace nvdisplay/kernel-open/Kbuild \
                    --replace-fail $'# Detect SGI UV systems and apply system-specific optimizations.' $'# Linux 7.1 no longer folds the deprecated EXTRA_CFLAGS into ccflags-y.\nccflags-y += $(EXTRA_CFLAGS)\n\n# Detect SGI UV systems and apply system-specific optimizations.'
                  for source in \
                    nvdisplay/kernel-open/nvidia/nvidia.Kbuild \
                    nvdisplay/kernel-open/nvidia-modeset/nvidia-modeset.Kbuild; do
                    substituteInPlace "$source" \
                      --replace-fail 'cmd_symlink = ln -sf $< $@' 'cmd_symlink = ln -sf $(abspath $<) $@'
                  done
                  substituteInPlace nvdisplay/kernel-open/conftest.sh \
                    --replace-fail '-std=gnu11 -fshort-wchar' '-std=gnu11 -fms-extensions -fshort-wchar' \
                    --replace-fail '-Wno-implicit-function-declaration -Wno-strict-prototypes"' '-Wno-implicit-function-declaration -Wno-strict-prototypes -include $SOURCES/include/linux/kconfig.h"'

                  # Linux 7.1 API adaptations which are newer than the R36.5
                  # display driver's conftest vocabulary.
                  substituteInPlace nvdisplay/kernel-open/common/inc/nv-mm.h \
                    --replace-fail '#if defined(NV_VM_AREA_STRUCT_HAS_CONST_VM_FLAGS)' '#if 1 /* Linux 7.1 */'
                  substituteInPlace nvdisplay/kernel-open/common/inc/nv-time.h \
                    --replace-fail 'if (in_irq() && (us > NV_MAX_ISR_DELAY_US))' 'if (in_hardirq() && (us > NV_MAX_ISR_DELAY_US))'
                  sed -i 's/in_irq()/in_hardirq()/g' nvdisplay/kernel-open/common/inc/nv-time.h
                  substituteInPlace nvdisplay/kernel-open/nvidia-drm/nvidia-dma-fence-helper.h \
                    --replace-fail 'return dma_fence_signal(fence);' $'dma_fence_signal(fence);\n    return 0;' \
                    --replace-fail 'return dma_fence_signal_locked(fence);' $'dma_fence_signal_locked(fence);\n    return 0;'
                  substituteInPlace nvdisplay/kernel-open/nvidia-drm/nvidia-drm-connector.c \
                    --replace-fail $'static int nv_drm_connector_mode_valid(struct drm_connector    *connector,\n                                       struct drm_display_mode *mode)' $'static enum drm_mode_status nv_drm_connector_mode_valid(\n    struct drm_connector *connector,\n    const struct drm_display_mode *mode)'
                  substituteInPlace nvdisplay/kernel-open/nvidia-drm/nvidia-drm-drv.c \
                    --replace-fail $'    struct drm_file *file,\n    #if defined(NV_DRM_HELPER_MODE_FILL_FB_STRUCT_HAS_CONST_MODE_CMD_ARG)' $'    struct drm_file *file,\n    const struct drm_format_info *format,\n    #if defined(NV_DRM_HELPER_MODE_FILL_FB_STRUCT_HAS_CONST_MODE_CMD_ARG)' \
                    --replace-fail $'            dev,\n            file,\n            &local_cmd);' $'            dev,\n            file,\n            format,\n            &local_cmd);' \
                    --replace-fail $'    .desc                   = "NVIDIA DRM driver",\n    .date                   = "20160202",' $'    .desc                   = "NVIDIA DRM driver",' \
                    --replace-fail '    DRM_DEBUG(' '    pr_debug('
                  substituteInPlace nvdisplay/kernel-open/nvidia-drm/nvidia-drm-fb.c \
                    --replace-fail $'    struct drm_file *file,\n    struct drm_mode_fb_cmd2 *cmd)' $'    struct drm_file *file,\n    const struct drm_format_info *format_info,\n    struct drm_mode_fb_cmd2 *cmd)' \
                    --replace-fail 'nv_drm_framebuffer_alloc(dev, file, cmd)' 'nv_drm_framebuffer_alloc(dev, file, format_info, cmd)' \
                    --replace-fail $'        &nv_fb->base,\n        cmd);' $'        &nv_fb->base,\n        format_info,\n        cmd);'
                  substituteInPlace nvdisplay/kernel-open/nvidia-drm/nvidia-drm-fb.h \
                    --replace-fail $'    struct drm_file *file,\n    struct drm_mode_fb_cmd2 *cmd);' $'    struct drm_file *file,\n    const struct drm_format_info *format_info,\n    struct drm_mode_fb_cmd2 *cmd);'
                  substituteInPlace nvdisplay/kernel-open/nvidia-drm/nvidia-drm-gem-nvkms-memory.h \
                    --replace-fail 'int nv_drm_dumb_create(' $'struct drm_file;\nstruct drm_device;\nstruct drm_mode_create_dumb;\n\nint nv_drm_dumb_create('
                  substituteInPlace nvdisplay/kernel-open/nvidia-drm/nvidia-drm-helper.h \
                    --replace-fail '(__state)->connectors[__i].state' '(__state)->connectors[__i].state_to_destroy' \
                    --replace-fail '(__state)->crtcs[__i].state' '(__state)->crtcs[__i].state_to_destroy' \
                    --replace-fail '(__state)->planes[__i].state' '(__state)->planes[__i].state_to_destroy'
                  substituteInPlace nvdisplay/kernel-open/nvidia-drm/nvidia-drm-linux.c \
                    --replace-fail 'del_timer_sync(&timer->kernel_timer)' 'timer_delete_sync(&timer->kernel_timer)'
                  substituteInPlace nvdisplay/kernel-open/nvidia-modeset/nvidia-modeset-linux.c \
                    --replace-fail 'del_timer_sync(&timer->kernel_timer)' 'timer_delete_sync(&timer->kernel_timer)'
                  substituteInPlace nvdisplay/kernel-open/nvidia/nv.c \
                    --replace-fail 'del_timer_sync(&nvl->rc_timer.kernel_timer)' 'timer_delete_sync(&nvl->rc_timer.kernel_timer)' \
                    --replace-fail 'del_timer_sync(&nvl->snapshot_timer.kernel_timer)' 'timer_delete_sync(&nvl->snapshot_timer.kernel_timer)'
                  substituteInPlace nvdisplay/kernel-open/nvidia/nv-frontend.c \
                    --replace-fail 'MODULE_IMPORT_NS(DMA_BUF);' 'MODULE_IMPORT_NS("DMA_BUF");'
                  substituteInPlace nvdisplay/kernel-open/nvidia/nv-nano-timer.c \
                    --replace-fail $'    hrtimer_init(&nv_nstimer->hr_timer, CLOCK_MONOTONIC, HRTIMER_MODE_REL);\n    nv_nstimer->hr_timer.function = nv_nano_timer_callback_typed_data;' $'    hrtimer_setup(&nv_nstimer->hr_timer,\n                  nv_nano_timer_callback_typed_data,\n                  CLOCK_MONOTONIC, HRTIMER_MODE_REL);'
                  substituteInPlace nvdisplay/kernel-open/nvidia/nv-platform-pm.c \
                    --replace-fail $'    ret = pm_runtime_put(nvl->dev);\n\n    if (ret == 0)' $'    pm_runtime_put(nvl->dev);\n    ret = 0;\n\n    if (ret == 0)'
                  substituteInPlace nvdisplay/kernel-open/nvidia/nv-dmabuf.c \
                    --replace-fail 'dma_buf_attachment_is_dynamic(attachment)' 'attachment->importer_ops != NULL'
                  substituteInPlace nvdisplay/kernel-open/nvidia/nv-dma.c \
                    --replace-fail 'return (ops->map_resource != NULL);' 'return NV_TRUE; /* dma_map_resource() uses map_phys on Linux 7.1. */'
                  substituteInPlace nvdisplay/kernel-open/nvidia/os-interface.c \
                    --replace-fail 'return (in_irq());' 'return (in_hardirq());'
                  substituteInPlace nvdisplay/kernel-open/nvidia-drm/nvidia-drm-priv.h \
                    --replace-fail 'DRM_ERROR(' 'pr_err(' \
                    --replace-fail 'DRM_INFO(' 'pr_info(' \
                    --replace-fail 'DRM_DEBUG_DRIVER(' 'pr_debug('
                  substituteInPlace nvdisplay/kernel-open/nvidia/libspdm_ecc.c \
                    --replace-fail '#include <crypto/akcipher.h>' '#include <crypto/sig.h>' \
                    --replace-fail $'    struct akcipher_request *req = NULL;\n    struct crypto_akcipher *tfm = NULL;\n    struct scatterlist sg;\n    DECLARE_CRYPTO_WAIT(wait);' '    struct crypto_sig *tfm = NULL;' \
                    --replace-fail 'crypto_alloc_akcipher(ctx->name, CRYPTO_ALG_TYPE_AKCIPHER, 0)' 'crypto_alloc_sig(ctx->name, 0, 0)' \
                    --replace-fail 'crypto_akcipher_set_pub_key(tfm, pub_key, ctx->size + 1)' 'crypto_sig_set_pubkey(tfm, pub_key, ctx->size + 1)' \
                    --replace-fail $'    req = akcipher_request_alloc(tfm, GFP_KERNEL);\n    if (IS_ERR(req)) {\n        pr_info("REQUEST ALLOC FAILED\\n");\n        goto failTfm;\n    }\n\n' "" \
                    --replace-fail '        goto failReq;' '        goto failTfm;' \
                    --replace-fail $'    // Just append hash, for scatterlists it can\'t be on stack anyway\n    memcpy(ber + ber_len, message_hash, hash_size);\n\n    sg_init_one(&sg, ber, ber_len + hash_size);\n    akcipher_request_set_callback(req, CRYPTO_TFM_REQ_MAY_BACKLOG |\n                                  CRYPTO_TFM_REQ_MAY_SLEEP, crypto_req_done, &wait);\n    akcipher_request_set_crypt(req, &sg, NULL, ber_len, hash_size);\n    err = crypto_wait_req(crypto_akcipher_verify(req), &wait);' $'    err = crypto_sig_verify(tfm, ber, ber_len,\n                            message_hash, hash_size);' \
                    --replace-fail $'failReq:\n    akcipher_request_free(req);\nfailTfm:\n    crypto_free_akcipher(tfm);' $'failTfm:\n    crypto_free_sig(tfm);'
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

      boot.kernelPatches = lib.optional (lib.versionAtLeast config.boot.kernelPackages.kernel.version "7.1")
        {
          name = "host1x fence identity for NVIDIA R36.5";
          patch = "${support}/patches/linux/0005-host1x-export-fence-identity.patch";
        } ++ [
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
