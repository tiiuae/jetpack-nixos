{ optee-os }:
# `taDevKit` builds from `optee-os` rather than `new-optee-os` so it
# doesn't depend on the fTPM TA derivations (which themselves depend on
# `taDevKit`) — depending on `new-optee-os` would recreate the
# optee-os → fTPM TA → taDevKit → new-optee-os cycle.
optee-os.overrideAttrs (prevAttrs: {
  pname = "optee-ta-dev-kit";
  makeFlags = prevAttrs.makeFlags or [ ] ++ [ "ta_dev_kit" ];
})
