#!/bin/bash
set -e

[ ! -d 'u-boot' ] && git clone https://gitlab.denx.de/u-boot/custodians/u-boot-efi -b efi-2020-10 && mv u-boot-efi u-boot 
#[ ! -d 'u-boot' ] && git clone https://github.com/u-boot/u-boot.git -b master
[ ! -d 'edk2-platforms' ] && git clone https://git.linaro.org/people/ilias.apalodimas/edk2-platforms.git -b stmm_rpmb_ffa
[ ! -d 'edk2' ] && git clone https://git.linaro.org/people/ilias.apalodimas/edk2.git -b stmm_ffa
[ ! -d 'optee_os' ] && git clone https://github.com/apalos/optee_os/ -b stmm_pr
[ ! -d 'arm-trusted-firmware' ] && git clone https://github.com/ARM-software/arm-trusted-firmware.git -b master

for i in u-boot edk2 edk2-platforms optee_os; do
	pushd "$i"
	git clean -d -f
	git reset --hard
	git pull --rebase
	popd
done

# Build EDK2
export WORKSPACE=$(pwd)
export PACKAGES_PATH=$WORKSPACE/edk2:$WORKSPACE/edk2-platforms
export ACTIVE_PLATFORM="Platform/StMMRpmb/PlatformStandaloneMm.dsc"
export GCC5_AARCH64_PREFIX=aarch64-linux-gnu-

pushd edk2
git submodule init
git submodule update --init --recursive
popd

source edk2/edksetup.sh
make -C edk2/BaseTools
build -p $ACTIVE_PLATFORM -b RELEASE -a AARCH64 -t GCC5 -n `nproc` -D DO_X86EMU=TRUE

# Build OP-TEE
cp Build/MmStandaloneRpmb/RELEASE_GCC5/FV/BL32_AP_MM.fd optee_os
pushd optee_os
export ARCH=arm
CROSS_COMPILE32=arm-linux-gnueabihf- make -j32 CFG_ARM64_core=y \
	PLATFORM=vexpress-qemu_armv8a CFG_STMM_PATH=BL32_AP_MM.fd CFG_RPMB_FS=y \
	CFG_RPMB_FS_DEV_ID=1 CFG_CORE_HEAP_SIZE=524288 CFG_RPMB_WRITE_KEY=1
popd

# Build U-Boot
export CROSS_COMPILE=aarch64-linux-gnu-
export ARCH=arm64

pushd u-boot
patch -p1 < ../patches/0002-rpmb-emulation-hack.-Breaks-proper-hardware-support.patch
make qemu_tfa_mm_defconfig 
make -j$(nproc)
popd

# Build ATF
pushd arm-trusted-firmware
make PLAT=qemu SPD=opteed
popd

mkdir -p output
cp arm-trusted-firmware/build/qemu/release/*.bin output
cp optee_os/out/arm-plat-vexpress/core/tee-header_v2.bin output/bl32.bin
cp optee_os/out/arm-plat-vexpress/core/tee-pager_v2.bin output/bl32_extra1.bin
cp optee_os/out/arm-plat-vexpress/core/tee-pageable_v2.bin output/bl32_extra2.bin
cp u-boot/u-boot.bin output/bl33.bin

echo 
echo "#################### BUILD DONE ####################"
echo "cd output "
echo "sudo qemu-system-aarch64 -m 1024 -smp 2 -show-cursor -serial stdio -monitor null -nographic -cpu cortex-a57 -bios bl1.bin -machine virt,secure=on -d unimp -semihosting-config enable,target=native -serial tcp::5000,server,nowait -gdb tcp::1234"

echo 
echo "For secure UART debugging"
echo "telnet 0 5000"
