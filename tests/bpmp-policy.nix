# SPDX-FileCopyrightText: 2026 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{ pkgs }:
pkgs.runCommandCC "bpmp-policy-test" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  tar -xOf ${pkgs.linux_6_12.src} --wildcards '*/include/soc/tegra/bpmp-abi.h' > bpmp-abi.h
  cp ${../pkgs/orin-virtualization-support/sources/linux/drivers/firmware/tegra/bpmp-host-proxy/bpmp-host-proxy.h} bpmp-host-proxy.h
  mkdir linux
  printf '#include <stdbool.h>\n#include <stdint.h>\n' > linux/types.h
  # Compile the actual policy functions with a userspace message wrapper.
  python3 - <<'PY'
  from pathlib import Path
  source = Path("${../pkgs/orin-virtualization-support/sources/linux/drivers/firmware/tegra/bpmp-host-proxy/bpmp-host-proxy.c}").read_text()
  start = source.index("static const uint32_t protected_clk_roots[]")
  end = source.index("\n}\n", source.index("static bool check_if_allowed", start)) + 3
  Path("policy-under-test.h").write_text(source[start:end])
  PY
  $CC -std=gnu11 -Wall -Wextra -Werror -Wno-sign-compare -I. ${./bpmp-policy.c} -o policy-test
  ./policy-test
  touch "$out"
''
