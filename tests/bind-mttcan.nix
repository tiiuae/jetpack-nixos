# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{ self, pkgs }:
let
  host = (self.nixosConfigurations.orin-agx-devkit-jp7.extendModules {
    modules = [
      self.nixosModules.orin-virtualization
      { hardware.nvidia-jetpack.virtualization.mttcanHost.enable = true; }
    ];
  }).config;
  bind = host.systemd.services.bindMttcan.serviceConfig.ExecStart;
in
pkgs.runCommand "bind-mttcan-test" { } ''
  root="$TMPDIR/platform"
  mkdir -p "$root/drivers/vfio-platform" "$root/devices"
  for device in c310000.mttcan c320000.mttcan; do
    mkdir "$root/devices/$device"
  done
  # Redirect only sysfs paths; exercise the generated production script.
  sed "s|/sys/bus/platform|$root|g" ${bind} > bind.sh
  bash bind.sh
  test "$(cat "$root/drivers_probe")" = c320000.mttcan
  for device in c310000.mttcan c320000.mttcan; do
    test "$(cat "$root/devices/$device/driver_override")" = vfio-platform
    ln -s "$root/drivers/vfio-platform" "$root/devices/$device/driver"
  done
  : > "$root/drivers_probe"
  bash bind.sh
  test ! -s "$root/drivers_probe"
  mv "$root/devices/c320000.mttcan" "$root/devices/missing"
  if bash bind.sh > missing.log 2>&1; then
    echo 'Missing controller unexpectedly accepted' >&2
    exit 1
  fi
  grep -F 'MTTCAN platform device is missing:' missing.log
  touch "$out"
''
