# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: MIT
{ pkgs }:
pkgs.runCommand "nvme-flash-layout-tests"
{ nativeBuildInputs = [ pkgs.python3 ]; }
  ''
    check_layout() {
      python3 ${../device-pkgs/check-qspi-layout.py} layout.xml
    }
    echo '<partition_layout><device type="spi" instance="0"/></partition_layout>' > layout.xml
    check_layout
    for invalid in \
      '<partition_layout><device type="spi"/><device type="nvme"/></partition_layout>' \
      '<partition_layout><device type="sdmmc_user"/></partition_layout>' \
      '<partition_layout><device/></partition_layout>' \
      '<partition_layout/>' \
      '<other><device type="spi"/></other>' \
      '<partition_layout>'; do
      echo "$invalid" > layout.xml
      if check_layout; then
        echo "Accepted invalid firmware layout: $invalid" >&2
        exit 1
      fi
    done
    touch "$out"
  ''
