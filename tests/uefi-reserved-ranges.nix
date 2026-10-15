# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{ lib, pkgs }:
let
  support = import ../pkgs/orin-virtualization-support/manifest.nix { inherit lib; };
  overlay = includeDispVmRam: (import ../pkgs/orin-virtualization-support/builders/mk-uefi-reserved-ranges.nix { inherit lib; }) {
    inherit pkgs support includeDispVmRam;
  };
in
pkgs.runCommandCC "uefi-reserved-ranges-tests"
{ nativeBuildInputs = [ pkgs.dtc ]; }
  ''
    $CC -Wall -Wextra -Werror -I${../pkgs/uefi-firmware} ${./uefi-reserved-ranges.c} -o test-ranges
    ./test-ranges
    node=/fragment@0/__overlay__/firmware/uefi/reserved-ranges
    test "$(fdtget -t x ${overlay false} $node reg)" = "0 80000000 0 30000000 0 b0000000 0 8000000"
    test "$(fdtget -t x ${overlay true} $node reg)" = "0 80000000 0 30000000 0 b0000000 0 8000000 0 b8000000 0 2e000000 2 0 0 1a000000"
    test "$(fdtget -t s ${overlay true} /fragment@0/board_config sw-modules)" = uefi
    touch "$out"
  ''
