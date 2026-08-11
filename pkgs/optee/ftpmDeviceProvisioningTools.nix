{ stdenvNoCC
, lib
, makeWrapper
, runtimeShell
, gitRepos
, l4tMajorMinorPatchVersion
, tpm2-tools
, openssl
, diffutils
, ftpmHelperTa
}:
let
  toolSrc = "${gitRepos."tegra/optee-src/nv-optee"}/optee/samples/ftpm-helper/host/tool";
  runtimePath = lib.makeBinPath [ tpm2-tools openssl diffutils ftpmHelperTa ];
in
stdenvNoCC.mkDerivation {
  pname = "ftpm-device-provisioning-tools";
  version = l4tMajorMinorPatchVersion;

  dontUnpack = true;
  nativeBuildInputs = [ makeWrapper ];

  # #!/bin/bash does not resolve on NixOS, so run each script through
  # runtimeShell rather than relying on its own shebang. Each script needs
  # tpm2-tools and diffutils; ftpm_device_provision.sh also needs openssl
  # and calls nvftpm-helper-app (from ftpmHelperTa) internally by name.
  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin

    makeWrapper ${runtimeShell} $out/bin/ftpm-device-provision \
      --add-flags ${toolSrc}/ftpm_device_provision.sh \
      --prefix PATH : ${runtimePath}
    makeWrapper ${runtimeShell} $out/bin/ftpm-offline-verify \
      --add-flags ${toolSrc}/ftpm_offline_provisioning_verify.sh \
      --prefix PATH : ${runtimePath}
    makeWrapper ${runtimeShell} $out/bin/ftpm-test-attestation \
      --add-flags ${toolSrc}/ftpm_test_local_attestation.sh \
      --prefix PATH : ${runtimePath}

    runHook postInstall
  '';

  meta = {
    description = "NVIDIA fTPM on-device provisioning and verification scripts";
    platforms = [ "aarch64-linux" ];
  };
}
