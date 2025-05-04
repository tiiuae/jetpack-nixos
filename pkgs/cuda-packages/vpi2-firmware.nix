# Needed for vpi2-samples benchmark w/ pva to work
{ debs
, dpkg
, runCommand
,
}:
runCommand "vpi3-firmware" { nativeBuildInputs = [ dpkg ]; } ''
  dpkg-deb -x ${debs.common.libnvvpi3.src} source
  install -D source/opt/nvidia/vpi3/lib64/priv/vpi3_pva_auth_allowlist $out/lib/firmware/pva_auth_allowlist
''
