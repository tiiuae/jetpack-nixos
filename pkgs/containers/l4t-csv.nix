{ bspSrc, runCommand }:
runCommand "l4t.csv" { } ''
  tar -xf "${bspSrc}/nv_tegra/config.tbz2"
  # Jetpack 5 to 6 split l4t.csv into devices.csv and drivers.csv
  cat etc/nvidia-container-runtime/host-files-for-container.d/devices.csv > \
    etc/nvidia-container-runtime/host-files-for-container.d/l4t.csv
  cat etc/nvidia-container-runtime/host-files-for-container.d/drivers.csv > \
    etc/nvidia-container-runtime/host-files-for-container.d/l4t.csv
  install etc/nvidia-container-runtime/host-files-for-container.d/l4t.csv $out
''
