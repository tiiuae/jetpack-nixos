# SPDX-FileCopyrightText: 2022-2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

let
  agx = {
    dcbDtsi = "generated/agx-p3737-p3701-dcb.dtsi";
    dcbSha256 = "e0d92e6dbf1ffef266cfd2e192847e76f8d88c19c55430f2f5d4aaf69494a2fc";
    dcbBytes = "8407";
  };
in
{
  bpmpPolicies = import ./bpmp-policies.nix;

  boards = {
    inherit agx;
    nx = agx;
  };
}
