# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: MIT

{ config, pkgs, lib }:
let
  modules = [ "nvme" "tegra-xudc" "xhci-tegra" "libcomposite" "usb_f_mass_storage" "usb_f_acm" ];
  modulesClosure = pkgs.makeModulesClosure {
    rootModules = modules;
    kernel = config.system.modulesTree;
    firmware = config.hardware.firmware;
    allowMissing = false;
  };
  recoverySource = pkgs.writeText "reboot-recovery.c" ''
    #include <linux/reboot.h>
    #include <sys/syscall.h>
    #include <unistd.h>
    int main(void) {
      sync();
      return syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
                     LINUX_REBOOT_CMD_RESTART2, "forced-recovery");
    }
  '';
  recovery = pkgs.pkgsStatic.stdenv.mkDerivation {
    name = "reboot-recovery";
    dontUnpack = true;
    buildPhase = "$CC -Wall -Wextra -Werror ${recoverySource} -o reboot-recovery";
    installPhase = "install -Dm755 reboot-recovery $out/bin/reboot-recovery";
    meta.mainProgram = "reboot-recovery";
  };
  init = pkgs.writeScript "nvme-flash-init" ''
    #!${pkgs.pkgsStatic.busybox}/bin/sh
    set -eu
    export PATH=${pkgs.pkgsStatic.busybox}/bin
    mount -t proc proc /proc
    mount -t sysfs sysfs /sys
    mount -t devtmpfs devtmpfs /dev
    for module in ${toString modules}; do
      ${lib.getExe' pkgs.pkgsStatic.kmod "modprobe"} "$module"
    done

    flash_id=
    for arg in $(cat /proc/cmdline); do
      case "$arg" in flash-id=*) flash_id=''${arg#flash-id=};; esac
    done
    test -n "$flash_id"
    for attempt in $(seq 1 60); do
      set -- /sys/block/nvme*n1
      test -e "$1" && break
      sleep 1
    done
    # Never select a disk by enumeration order when several SSDs are installed.
    test "$#" -eq 1 && test -e "$1"
    disk=/dev/$(basename "$1")
    mount -t configfs configfs /sys/kernel/config
    gadget=/sys/kernel/config/usb_gadget/nvme-flash
    mkdir "$gadget"
    echo 0x1d6b > "$gadget/idVendor"
    echo 0x0104 > "$gadget/idProduct"
    mkdir "$gadget/strings/0x409" "$gadget/configs/c.1"
    echo NixOS > "$gadget/strings/0x409/manufacturer"
    echo NVMe-flash > "$gadget/strings/0x409/product"
    echo "$flash_id" > "$gadget/strings/0x409/serialnumber"
    mkdir "$gadget/functions/mass_storage.0" "$gadget/functions/acm.usb0"
    echo "$disk" > "$gadget/functions/mass_storage.0/lun.0/file"
    ln -s "$gadget/functions/mass_storage.0" "$gadget/configs/c.1/"
    ln -s "$gadget/functions/acm.usb0" "$gadget/configs/c.1/"
    for attempt in $(seq 1 60); do
      udc=$(ls /sys/class/udc | head -n 1)
      test -n "$udc" && break
      sleep 1
    done
    test -n "$udc"
    echo "$udc" > "$gadget/UDC"
    if test -w /sys/class/usb_role/usb2-0-role-switch/role; then
      echo device > /sys/class/usb_role/usb2-0-role-switch/role
    fi
    echo "NVMe exported over USB: $disk"
    while true; do
      if read -r command < /dev/ttyGS0 && test "$command" = recovery; then
        echo "" > "$gadget/UDC"
        ${lib.getExe recovery}
      fi
      sleep 1
    done
  '';
in
pkgs.makeInitrd {
  contents = [
    { object = init; symlink = "/init"; }
    { object = modulesClosure; symlink = "/lib"; suffix = "/lib"; }
  ];
}
