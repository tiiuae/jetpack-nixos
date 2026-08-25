# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{ lib
, runCommand
, runCommandCC
, writeShellApplication
, iproute2
, bpmpAllowAllDomains ? false
,
}:
let
  gbmNoModifiersShim = runCommandCC "orin-gbm-no-modifiers-shim" { } ''
    mkdir -p "$out/lib"
    $CC -O2 -fPIC -shared -o "$out/lib/gbm-nomod-shim.so" \
      ${./sources/userspace/gbm-nomod-shim.c} -ldl
  '';
  quiesceMgbe0 = writeShellApplication {
    name = "quiesce-mgbe0";
    runtimeInputs = [ iproute2 ];
    text = ''
      set -eu

      driver_path=/sys/bus/platform/drivers/tegra-mgbe
      if [ ! -d "$driver_path" ]; then
        echo "MGBE0 driver path is missing: $driver_path" >&2
        exit 1
      fi

      found=0
      for device in "$driver_path"/*; do
        [ -d "$device/net" ] || continue
        for path in "$device/net"/*; do
          [ -e "$path" ] || continue
          found=1
          interface="''${path##*/}"
          echo "Quiescing MGBE0 interface $interface from ''${device##*/}"
          ip link set dev "$interface" down
        done
      done

      if [ "$found" -eq 0 ]; then
        echo "No MGBE0 network interface found under $driver_path" >&2
        exit 1
      fi
    '';
  };
in
runCommand "orin-virtualization-support"
{
  preferLocalBuild = true;
  passthru = import ./manifest.nix { inherit lib; } // {
    inherit gbmNoModifiersShim quiesceMgbe0;
    eglGbmSingleDevicePatch = ./patches/userspace/egl-gbm-single-device-fallback.patch;
    mkGuestDtb = import ./builders/mk-guest-dtb.nix { inherit lib; };
    mkCrosvmOverlay = import ./builders/mk-crosvm-overlay.nix { inherit lib; };
    mkMgbe0Overlay = import ./builders/mk-mgbe0-overlay.nix { inherit lib; };
  };
}
  ''
    mkdir -p "$out"
    cp -r ${./sources} "$out/sources"
    cp -r ${./patches} "$out/patches"
    cp -r ${./device-trees} "$out/device-trees"
    chmod -R u+w "$out"

    ${lib.optionalString bpmpAllowAllDomains ''
      substituteInPlace \
        "$out/sources/linux/drivers/firmware/tegra/bpmp-host-proxy/bpmp-host-proxy.c" \
        --replace-fail '#define BPMP_HOST_ALLOWS_ALL   0' \
                       '#define BPMP_HOST_ALLOWS_ALL   1'
    ''}

    mkdir source-empty source-tree
    cp -r "$out/sources/linux"/. source-tree/
    find source-empty source-tree -exec touch -h -d @0 {} +
    diff -Naur source-empty source-tree > "$out/patches/linux/bpmp-sources.patch" || true
    test -s "$out/patches/linux/bpmp-sources.patch"
  ''
