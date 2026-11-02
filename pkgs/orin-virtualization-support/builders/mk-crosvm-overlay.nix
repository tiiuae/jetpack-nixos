# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

{ lib }:
{ pkgs
, kernel
, board
, role
, dtsRoot
,
}:
let
  inherit (role) capabilities;
  overlayDts = "${dtsRoot}/${role.crosvmOverlayDts}";
  gpuDtsDir = "${dtsRoot}/gpu-vm";
  dispDtsDir = "${dtsRoot}/disp-vm";
  mainInc = "${kernel.dev}/lib/modules/${kernel.modDirVersion}/source/include";
  findReserved = symbol: lib.findFirst (resource: resource.symbol == symbol) null role.reservedMemory;
  cell64 =
    value:
    let
      high = builtins.div value 4294967296;
      low = value - high * 4294967296;
    in
    "${lib.toLower (lib.toHexString high)} ${lib.toLower (lib.toHexString low)}";
  reg64 = resource: "${cell64 resource.base} ${cell64 resource.size}";
  unitAddress = resource: lib.toLower (lib.toHexString resource.base);
  vmCma = findReserved "vm_cma_p";
  dispRamLow = findReserved "dispram_lo_p";
  dispRamHigh = findReserved "dispram_hi_p";
in
pkgs.stdenv.mkDerivation {
  name = role.crosvmOverlayName;
  dontUnpack = true;
  nativeBuildInputs = [
    pkgs.buildPackages.dtc
    pkgs.buildPackages.gcc
    pkgs.buildPackages.xxd
  ];
  buildPhase = ''
    $CC -E -nostdinc -undef -D__DTS__ ${role.expDtDefines}-DGHAF_DCB_DTSI='"${board.dcbDtsi}"' \
      -x assembler-with-cpp \
      -I${mainInc} \
      -I${gpuDtsDir}/nv-dt-bindings \
      -I${gpuDtsDir} \
      -I${dispDtsDir} \
      ${overlayDts} > preprocessed.dts
    dtc -@ -I dts -O dtb -o ${role.crosvmOverlayName}.dtbo preprocessed.dts
  ''
  + lib.optionalString capabilities.display ''
    fdtget -t bx ${role.crosvmOverlayName}.dtbo \
      /fragment@30/__overlay__/display@13800000 nvidia,dcb-image \
      | tr -s ' \n' '\n' | grep . | sed 's/^\(.\)$/0\1/' | xxd -r -p > dcb.bin
    dcbLen=$(wc -c < dcb.bin)
    dcbHash=$(sha256sum dcb.bin | cut -d' ' -f1)
    if [ "$dcbLen" != "${board.dcbBytes}" ] || [ "$dcbHash" != "${board.dcbSha256}" ]; then
      echo "DCB payload drifted: $dcbLen bytes, sha256 $dcbHash" >&2
      echo "expected ${board.dcbBytes} bytes, sha256 ${board.dcbSha256}" >&2
      exit 1
    fi
  ''
  + ''
    for symbol in ${lib.escapeShellArgs (map (device: device.dtSymbol) role.crosvmDevices)}; do
      fdtget ${role.crosvmOverlayName}.dtbo /__symbols__ "$symbol" >/dev/null
    done
  ''
  + lib.optionalString (!capabilities.display || capabilities.gpu) ''
    test "$(fdtget -t s ${role.crosvmOverlayName}.dtbo \
      /fragment@10/__overlay__/memory@${unitAddress vmCma} device_type)" = memory
    test "$(fdtget -t x ${role.crosvmOverlayName}.dtbo \
      /fragment@10/__overlay__/memory@${unitAddress vmCma} reg)" = "${reg64 vmCma}"
  ''
  + lib.optionalString (capabilities.display && !capabilities.gpu) ''
    test "$(fdtget -t s ${role.crosvmOverlayName}.dtbo \
      /fragment@10/__overlay__/memory@${unitAddress dispRamLow} device_type)" = memory
    test "$(fdtget -t x ${role.crosvmOverlayName}.dtbo \
      /fragment@10/__overlay__/memory@${unitAddress dispRamLow} reg)" = \
      "${reg64 dispRamLow} ${reg64 dispRamHigh}"
  ''
  + lib.optionalString capabilities.host1x ''
    fdtget ${role.crosvmOverlayName}.dtbo \
      /fragment@20/__overlay__/host1x@13e00000 ranges >/dev/null
  '';
  installPhase = ''
    mkdir -p "$out"
    cp ${role.crosvmOverlayName}.dtbo "$out/"
  '';

  passthru.fileName = "${role.crosvmOverlayName}.dtbo";
}
