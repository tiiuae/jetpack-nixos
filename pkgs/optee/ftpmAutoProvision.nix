{ writeShellApplication
, tpm2-tools
, ftpmHelperTa
, ftpmDeviceProvisioning
}:
writeShellApplication {
  name = "ftpm-auto-provision";
  runtimeInputs = [ tpm2-tools ftpmHelperTa ftpmDeviceProvisioning ];
  text = ''
    # Commit marker; NVIDIA's cert handles are written midway so can't serve this role.
    PROVISIONED_HANDLE="0x01800100"
    OWNER_PW="owner"

    on_failure() {
      echo "[ftpm-provision] FAILED — clearing TPM so the next boot retries cleanly" >&2
      tpm2_clear || \
        echo "[ftpm-provision] WARNING: tpm2_clear failed; TPM may need manual recovery" >&2
    }
    trap on_failure ERR

    if tpm2_nvreadpublic "$PROVISIONED_HANDLE" &>/dev/null; then
      echo "[ftpm-provision] Already provisioned. Skipping."
      exit 0
    fi

    echo "[ftpm-provision] First boot — running fTPM provisioning..."

    WORKDIR=$(mktemp -d)

    # r38.4's ms-tpm-20-ref update made RSA keygen constant-time, so
    # tpm2_createek (invoked by ftpm-device-provision below) now takes
    # ~12s with the CPU stuck in secure world -- past the 10s hard
    # lockup default. Raise the threshold for the duration of this
    # service and restore it on exit, rather than system-wide.
    WATCHDOG_THRESH_FILE="/proc/sys/kernel/watchdog_thresh"
    ORIG_WATCHDOG_THRESH="$(cat "$WATCHDOG_THRESH_FILE")"
    echo 30 > "$WATCHDOG_THRESH_FILE"

    cleanup() {
      echo "$ORIG_WATCHDOG_THRESH" > "$WATCHDOG_THRESH_FILE"
      rm -rf "$WORKDIR"
    }
    trap cleanup EXIT

    RSA_CERT="$WORKDIR/rsa_ek_cert.der"
    EC_CERT="$WORKDIR/ec_ek_cert.der"

    nvftpm-helper-app -a "$RSA_CERT" -b "$EC_CERT"
    ftpm-device-provision -r "$RSA_CERT" -e "$EC_CERT" -p "$OWNER_PW"

    # systemd's TPM2 SRK setup and tpm2-tools expect no auth set.
    tpm2_changeauth -c o -p "$OWNER_PW"
    tpm2_changeauth -c e -p "$OWNER_PW"

    tpm2_nvdefine "$PROVISIONED_HANDLE" -C o -s 1 -a "ownerread|ownerwrite"

    echo "[ftpm-provision] Done."
  '';

  meta = {
    description = "Provision fTPM EK certificates from the EKB into TPM NV memory on first boot";
    platforms = [ "aarch64-linux" ];
  };
}
