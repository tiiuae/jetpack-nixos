{ lib, bspSrc, runCommand, l4tVersion }: let

  l4t-csv = if l4tVersion == "36.4.3" then
    "cat etc/nvidia-container-runtime/host-files-for-container.d/devices.csv > etc/nvidia-container-runtime/host-files-for-container.d/l4t.csv \
     cat etc/nvidia-container-runtime/host-files-for-container.d/drivers.csv > etc/nvidia-container-runtime/host-files-for-container.d/l4t.csv"
  else if l4tVersion == "35.6.0" then
    ""
  else
    throw "Not supported l4tVersion";
in

  runCommand "l4t.csv" { } (lib.strings.concatLines [
    "tar -xf ${bspSrc}/nv_tegra/config.tbz2"
    l4t-csv
    "install etc/nvidia-container-runtime/host-files-for-container.d/l4t.csv $out"
  ])
