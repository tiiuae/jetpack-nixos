{ optee-config }:
# Builds from optee-config rather than optee-os to avoid an
# optee-os -> fTPM TA -> taDevKit -> optee-os cycle.
optee-config.overrideAttrs (prevAttrs: {
  pname = "optee-ta-dev-kit";
  makeFlags = prevAttrs.makeFlags or [ ] ++ [ "ta_dev_kit" ];
})
