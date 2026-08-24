# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{ lib
, runCommand
, bpmpAllowAllDomains ? false
,
}:
runCommand "orin-virtualization-support"
{
  preferLocalBuild = true;
}
  ''
    mkdir -p "$out"
    cp -r ${./sources} "$out/sources"
    cp -r ${./patches} "$out/patches"
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
