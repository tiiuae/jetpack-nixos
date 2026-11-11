# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{ lib }:
{ pkgs
, hostDtb
, support
,
}:
let
  mttcan = support.passthrough.mttcan;
  controllers = mttcan.controllers;
  refs = values: lib.concatMapStringsSep ", " (value: "<&bpmp ${toString value}>") values;
  source = pkgs.replaceVars "${support}/device-trees/mttcan/mttcan-crosvm-overlay.dts" {
    bpmpCan0Clocks = refs (builtins.elemAt controllers 0).clocks;
    bpmpCan0Resets = refs (builtins.elemAt controllers 0).resets;
    bpmpCan1Clocks = refs (builtins.elemAt controllers 1).clocks;
    bpmpCan1Resets = refs (builtins.elemAt controllers 1).resets;
  };
  checkController = controller: ''
    node=${lib.escapeShellArg controller.nodePath}
    test "$(fdtget -t s ${lib.escapeShellArg hostDtb} "$node" compatible)" = ${lib.escapeShellArg mttcan.compatible}
    test "$(fdtget -t s ${lib.escapeShellArg hostDtb} "$node" reg-names)" = "can-regs glue-regs msg-ram"
    test "$(fdtget -t s ${lib.escapeShellArg hostDtb} "$node" pll_source)" = "pllaon"
    test "$(fdtget -t s ${lib.escapeShellArg hostDtb} "$node" clock-names)" = "can_core can_host can pllaon"
    test "$(fdtget -t s ${lib.escapeShellArg hostDtb} "$node" reset-names)" = "can"
    check_ids "$node" clocks ${lib.escapeShellArg (lib.concatStringsSep " " (map toString controller.clocks))}
    check_ids "$node" resets ${lib.escapeShellArg (lib.concatStringsSep " " (map toString controller.resets))}
  '';
in
pkgs.buildPackages.runCommand "mttcan-crosvm-overlay.dtbo"
{ nativeBuildInputs = [ pkgs.buildPackages.dtc ]; }
  ''
    check_ids() {
      node="$1"
      property="$2"
      expected="$3"
      values="$(fdtget -t i ${lib.escapeShellArg hostDtb} "$node" "$property")"
      set -- $values
      if [ "$#" -eq 0 ] || [ $(( $# % 2 )) -ne 0 ]; then
        echo "malformed $property on $node in pinned Orin device tree" >&2
        exit 1
      fi
      actual=""
      while [ "$#" -gt 0 ]; do
        shift
        actual="''${actual:+$actual }$1"
        shift
      done
      if [ "$actual" != "$expected" ]; then
        echo "$property BPMP IDs on $node drifted: expected '$expected', got '$actual'" >&2
        exit 1
      fi
    }

    ${lib.concatMapStringsSep "\n" checkController controllers}
    dtc -@ -I dts -O dtb -o "$out" ${source}
  ''
