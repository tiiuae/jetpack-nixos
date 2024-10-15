set -e
unset PATH

for p in $buildInputs; do
    export PATH=$p/bin${PATH:+:}$PATH
done

tar -vxf $src
cd Linux_for_Tegra/source

tar xf kernel_oot_modules_src.tbz2
tar xf nvidia_kernel_display_driver_source.tbz2

    # Patch nvidia modules source
sed -i '49s/SOURCES=$(KERNEL_HEADERS)/SOURCES=$(KERNEL_HEADERS)\/source/g' Makefile
sed -i '/cp -LR $(KERNEL_HEADERS)\/\* $(NVIDIA_HEADERS)/s/$/ \|\| true;/' Makefile
#Sources are copied from store. They are read only
sed -i '/cp -LR $(KERNEL_HEADERS)\/\* $(NVIDIA_HEADERS)/a \\tchmod -R u+w out/nvidia-linux-header/' Makefile
sed -i '113s/SYSSRC=$(NVIDIA_HEADERS)/SYSSRC=$(NVIDIA_HEADERS)\/source/g' Makefile
# TODO: Remove warning:
#    warning: call to ‘__write_overflow_field’
sed -i '/subdir-ccflags-y += -Werror/d' nvidia-oot/Makefile

export KERNEL_HEADERS=$linux68dev/lib/modules/6.8.12/build
export CROSS_COMPILE=$aarch64LinuxGnu/bin/aarch64-unknown-linux-gnu-
export IGNORE_MISSING_MODULE_SYMVERS=1

make ARCH=arm64 modules

mkdir $out
make ARCH=arm64 INSTALL_MOD_PATH=$out modules_install
