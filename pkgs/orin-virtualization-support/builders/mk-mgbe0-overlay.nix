# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{ lib }:
{ pkgs
, hostDtb
, support
,
}:
let
  mgbe0 = support.passthrough.mgbe0;
  policy = support.bpmpPolicies.mgbe0.device;
  ids = values: lib.concatStringsSep " " (map toString values);
  refs = values: lib.concatMapStringsSep ", " (value: "<&bpmp ${toString value}>") values;
  source = pkgs.replaceVars "${support}/device-trees/mgbe0/mgbe0-crosvm-overlay.dts" {
    bpmpClocks = refs policy.clocks;
    bpmpResets = refs policy.resets;
    bpmpPowerDomains = refs policy.powerDomains;
  };
  overlay = pkgs.buildPackages.runCommand "mgbe0-crosvm-overlay.dtbo"
    { nativeBuildInputs = [ pkgs.buildPackages.dtc ]; }
    ''
      check_ids() {
        property="$1"
        expected="$2"
        values="$(fdtget -t i ${lib.escapeShellArg hostDtb} ${lib.escapeShellArg mgbe0.nodePath} "$property")"
        set -- $values
        if [ "$#" -eq 0 ] || [ $(( $# % 2 )) -ne 0 ]; then
          echo "malformed $property in pinned Orin device tree" >&2
          exit 1
        fi
        actual=""
        while [ "$#" -gt 0 ]; do
          shift
          actual="''${actual:+$actual }$1"
          shift
        done
        if [ "$actual" != "$expected" ]; then
          echo "$property BPMP IDs drifted: expected '$expected', got '$actual'" >&2
          exit 1
        fi
      }

      test "$(fdtget -t s ${lib.escapeShellArg hostDtb} ${lib.escapeShellArg mgbe0.nodePath} compatible)" = ${lib.escapeShellArg mgbe0.compatible}
      test "$(fdtget -t s ${lib.escapeShellArg hostDtb} ${lib.escapeShellArg mgbe0.nodePath} phy-mode)" = "10gbase-r"
      check_ids clocks ${lib.escapeShellArg (ids policy.clocks)}
      check_ids resets ${lib.escapeShellArg (ids policy.resets)}
      check_ids power-domains ${lib.escapeShellArg (ids policy.powerDomains)}
      dtc -@ -I dts -O dtb -o "$out" ${source}
    '';
  prepare = pkgs.writeShellApplication {
    name = "prepare-mgbe0-crosvm-overlay";
    runtimeInputs = with pkgs; [
      coreutils
      dtc
      findutils
      gnugrep
    ];
    text = ''
      set -euo pipefail

      live_root=/sys/firmware/devicetree/base
      live_fdt=/sys/firmware/fdt
      output=${lib.escapeShellArg mgbe0.crosvmOverlayPath}
      temporary="$(mktemp --tmpdir=/run .mgbe0-net-vm.dtbo.XXXXXX)"
      trap 'rm -f "$temporary"' EXIT
      mapfile -d "" nodes < <(find "$live_root" -type d -name ${lib.escapeShellArg mgbe0.nodeName} -print0)
      if [ "''${#nodes[@]}" -ne 1 ]; then
        echo "expected one live ${mgbe0.nodeName} node, found ''${#nodes[@]}" >&2
        exit 1
      fi
      node="''${nodes[0]}"
      node_path="/''${node#"$live_root"/}"
      if ! tr '\0' '\n' < "$node/compatible" | grep -Fxq ${lib.escapeShellArg mgbe0.compatible}; then
        echo "live $node_path is not compatible with ${mgbe0.compatible}" >&2
        exit 1
      fi

      check_ids() {
        local property="$1" expected="$2" values actual=""
        values="$(fdtget -t i "$live_fdt" "$node_path" "$property")"
        read -r -a cells <<< "$values"
        if [ "''${#cells[@]}" -eq 0 ] || [ $(( ''${#cells[@]} % 2 )) -ne 0 ]; then
          echo "malformed live $property on $node_path" >&2
          exit 1
        fi
        for ((index = 1; index < ''${#cells[@]}; index += 2)); do
          actual="''${actual:+$actual }''${cells[index]}"
        done
        if [ "$actual" != "$expected" ]; then
          echo "live $property BPMP IDs drifted: expected '$expected', got '$actual'" >&2
          exit 1
        fi
      }

      check_ids clocks ${lib.escapeShellArg (ids policy.clocks)}
      check_ids resets ${lib.escapeShellArg (ids policy.resets)}
      check_ids power-domains ${lib.escapeShellArg (ids policy.powerDomains)}

      install -m 0644 ${overlay} "$temporary"
      if [ -e "$node/mac-address" ]; then
        if [ "$(stat -c %s "$node/mac-address")" -ne 6 ]; then
          echo "live mac-address on $node_path is not six bytes" >&2
          exit 1
        fi
        read -r -a mac_bytes <<< "$(od -An -v -t x1 "$node/mac-address")"
        if [ "''${#mac_bytes[@]}" -ne 6 ]; then
          echo "could not decode live mac-address on $node_path" >&2
          exit 1
        fi
        fdtput -t bx "$temporary" /fragment@0/__overlay__/ethernet mac-address "''${mac_bytes[@]}"
      fi
      mv "$temporary" "$output"
      trap - EXIT
    '';
  };
in
{
  inherit overlay prepare;
}
