{ stdenvNoCC
, makeWrapper
, runtimeShell
, gitRepos
, l4tMajorMinorPatchVersion
}:
let
  toolSrc = "${gitRepos."tegra/optee-src/nv-optee"}/optee/samples/ftpm-helper/host/tool";
in
stdenvNoCC.mkDerivation {
  pname = "ftpm-device-provisioning";
  version = l4tMajorMinorPatchVersion;

  dontUnpack = true;
  nativeBuildInputs = [ makeWrapper ];

  # #!/bin/bash does not resolve on NixOS, so run each script through
  # runtimeShell rather than relying on its own shebang.
  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin

    makeWrapper ${runtimeShell} $out/bin/ftpm-device-provision \
      --add-flags ${toolSrc}/ftpm_device_provision.sh
    makeWrapper ${runtimeShell} $out/bin/ftpm-offline-verify \
      --add-flags ${toolSrc}/ftpm_offline_provisioning_verify.sh
    makeWrapper ${runtimeShell} $out/bin/ftpm-test-attestation \
      --add-flags ${toolSrc}/ftpm_test_local_attestation.sh

    runHook postInstall
  '';

  meta = {
    description = "NVIDIA fTPM on-device provisioning and verification scripts";
    platforms = [ "aarch64-linux" ];
  };
}
