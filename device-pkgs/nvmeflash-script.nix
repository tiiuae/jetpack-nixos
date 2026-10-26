# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: MIT

{ config
, pkgs
, lib
, mkRcmBootScript
, qspiFlashScript
, l4tMajorMinorPatchVersion
, writeText
, deviceTree
}:
let
  cfg = config.hardware.nvidia-jetpack;
  initrd = import ./nvme-flash-initrd.nix { inherit config pkgs lib; };
  peripheralDtbo = import ./force-xusb-peripheral.nix {
    inherit config lib l4tMajorMinorPatchVersion writeText deviceTree;
  };
  rcmScript = mkRcmBootScript {
    kernelPath = "${config.system.build.kernel}/${config.system.boot.loader.kernelFile}";
    initrdPath = "${initrd}/initrd";
    kernelCmdline = lib.concatStringsSep " " ([ "clk_ignore_unused" "flash-id=$flash_id" ] ++ cfg.console.args);
    additionalDtbOverlays = (lib.filter (path: (path.name or "") != "DefaultBootOrder.dtbo") cfg.flashScriptOverrides.additionalDtbOverlays) ++ [ peripheralDtbo ];
  };
in
''
  # MB2 in JetPack 7 cannot write NVMe. Boot Linux to export the SSD, then
  # use the existing QSPI-only flash path for platform firmware.
  for arg in "$@"; do
    case "$arg" in
      --no-flash|--help|-h) exec ${lib.getExe qspiFlashScript} "$@" ;;
    esac
  done
  if [[ -z ''${SIGNED_SD_IMAGE_DIR:-} ]]; then
    echo "NVMe flashing requires -s <sd-image-result>." >&2
    exit 1
  fi
  shopt -s nullglob
  images=("$SIGNED_SD_IMAGE_DIR"/sd-image/*.img.zst "$SIGNED_SD_IMAGE_DIR"/*.img.zst)
  if [[ ''${#images[@]} -ne 1 ]]; then
    echo "Expected exactly one compressed disk image in $SIGNED_SD_IMAGE_DIR." >&2
    exit 1
  fi
  image=''${images[0]}
  image_bytes=$(zstd -dc "$image" | wc -c)
  flash_id=$(cat /proc/sys/kernel/random/uuid)
  export flash_id
  # shellcheck disable=SC2329 # on_exit is invoked by the RCM script's EXIT trap.
  (
    unset WORKDIR
    ${rcmScript}
  )
  disk=/dev/disk/by-id/usb-Linux_File-Stor_Gadget_''${flash_id}-0:0
  for ((attempt=0; attempt<120; attempt++)); do
    [[ -b "$disk" ]] && break
    sleep 1
  done
  if [[ ! -b "$disk" ]]; then
    echo "The recovery kernel did not expose the NVMe disk." >&2
    exit 1
  fi
  if [[ $(blockdev --getsize64 "$disk") -lt $image_bytes ]]; then
    echo "The disk image does not fit on the NVMe disk." >&2
    exit 1
  fi
  # The random USB serial ties this path to this recovery invocation, even
  # when other Jetsons or USB storage devices are attached to the workstation.
  echo "Writing $image to $disk"
  wipefs --all "$disk"
  zstd -dc "$image" | dd of="$disk" bs=4M iflag=fullblock conv=fsync status=progress
  blockdev --flushbufs "$disk"
  control=(/dev/serial/by-id/usb-NixOS_NVMe-flash_"$flash_id"-if*)
  [[ ''${#control[@]} -eq 1 ]]
  printf 'recovery\n' > "''${control[0]}"
  for ((attempt=0; attempt<30; attempt++)); do
    [[ ! -e "$disk" ]] && break
    sleep 1
  done
  sleep 3
  ${lib.getExe qspiFlashScript} "$@"
''
