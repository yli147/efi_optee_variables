#!/bin/bash
set -e

[ ! -d 'u-boot' ] && git clone https://github.com/u-boot/u-boot.git -b master
[ ! -d 'edk2-platforms' ] && git clone https://git.linaro.org/people/ilias.apalodimas/edk2-platforms.git -b stmm
[ ! -d 'edk2' ] && git clone https://git.linaro.org/people/sughosh.ganu/edk2.git -b ffa_svc_optional_on_upstream
[ ! -d 'optee_os' ] && git clone https://github.com/OP-TEE/optee_os.git -b master
[ ! -d 'arm-trusted-firmware' ] && git clone https://github.com/ARM-software/arm-trusted-firmware.git -b master
[ ! -d 'MSRSec' ] && git clone https://github.com/microsoft/MSRSec.git

clean_dirs='u-boot edk2 edk2-platforms optee_os arm-trusted-firmware MSRSec'
for i in $clean_dirs; do
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
cp Build/MmStandaloneRpmb/RELEASE_GCC5/FV/BL32_AP_MM.fd optee_os

# Build OP-TEE for the devkit
if [ ! -d 'optee_os/out/arm-plat-vexpress/export-ta_arm64' ]; then
	pushd optee_os
	export ARCH=arm
	CROSS_COMPILE32=arm-linux-gnueabihf- make -j32 CFG_ARM64_core=y \
		PLATFORM=vexpress-qemu_armv8a CFG_STMM_PATH=BL32_AP_MM.fd CFG_RPMB_FS=y \
		CFG_RPMB_FS_DEV_ID=0 CFG_CORE_HEAP_SIZE=524288 CFG_RPMB_WRITE_KEY=1 \
		CFG_CORE_HEAP_SIZE=524288 CFG_CORE_DYN_SHM=y CFG_RPMB_TESTKEY=y \
		CFG_RPMB_WRITE_KEY=1 \
		CFG_REE_FS=n CFG_CORE_ARM64_PA_BITS=48  \
		CFG_TEE_CORE_LOG_LEVEL=1 CFG_TEE_TA_LOG_LEVEL=1 \
		CFG_SCTLR_ALIGNMENT_CHECK=n 
	popd
fi

# Build fTPM
pushd MSRSec
git submodule update --init
popd
pushd MSRSec/TAs/optee_ta
TA_CPU=cortex-a53 TA_CROSS_COMPILE=aarch64-linux-gnu- \
	TA_DEV_KIT_DIR=../../../../optee_os/out/arm-plat-vexpress/export-ta_arm64 \
	CFG_TEE_TA_LOG_LEVEL=1 CFG_ARM64_ta_arm64=y CFG_FTPM_USE_WOLF=y make -j1 ftpm
popd

# Build OP-TEE with fTPM + StMM
cp Build/MmStandaloneRpmb/RELEASE_GCC5/FV/BL32_AP_MM.fd optee_os
pushd optee_os
export ARCH=arm
CROSS_COMPILE32=arm-linux-gnueabihf- make -j32 CFG_ARM64_core=y \
	PLATFORM=vexpress-qemu_armv8a CFG_STMM_PATH=BL32_AP_MM.fd CFG_RPMB_FS=y \
	CFG_RPMB_FS_DEV_ID=0 CFG_CORE_HEAP_SIZE=524288 CFG_RPMB_WRITE_KEY=1 \
	CFG_CORE_HEAP_SIZE=524288 CFG_CORE_DYN_SHM=y CFG_RPMB_TESTKEY=y \
	CFG_RPMB_WRITE_KEY=1 \
	CFG_REE_FS=n CFG_CORE_ARM64_PA_BITS=48  \
	CFG_SCTLR_ALIGNMENT_CHECK=n \
	CFG_TEE_CORE_LOG_LEVEL=1 CFG_TEE_TA_LOG_LEVEL=1 \
	EARLY_TA_PATHS=../MSRSec/TAs/optee_ta/out/fTPM/bc50d971-d4c9-42c4-82cb-343fb7f37896.stripped.elf
popd

# Build U-Boot
export CROSS_COMPILE=aarch64-linux-gnu-
export ARCH=arm64

pushd u-boot
for i in `ls ../patches`; do
patch -p1 < ../patches/$i
done
cp ../qemu_tfa_mm_defconfig configs
make qemu_tfa_mm_defconfig 
make -j$(nproc)
popd

# Build ATF
pushd arm-trusted-firmware
make PLAT=qemu BL32=../optee_os/out/arm-plat-vexpress/core/tee-header_v2.bin \
	BL32_EXTRA1=../optee_os/out/arm-plat-vexpress/core/tee-pager_v2.bin \
	BL32_EXTRA2=../optee_os/out/arm-plat-vexpress/core/tee-pageable_v2.bin \
	BL33=../u-boot/u-boot.bin \
	BL32_RAM_LOCATION=tdram SPD=opteed all fip

	dd if=build/qemu/release/bl1.bin of=flash.bin bs=4096 conv=notrunc
	dd if=build/qemu/release/fip.bin of=flash.bin seek=64 bs=4096 conv=notrunc
popd

mkdir -p output
cp arm-trusted-firmware/flash.bin output
cp arm-trusted-firmware/build/qemu/release/*.bin output
cp optee_os/out/arm-plat-vexpress/core/tee-header_v2.bin output/bl32.bin
cp optee_os/out/arm-plat-vexpress/core/tee-pager_v2.bin output/bl32_extra1.bin
cp optee_os/out/arm-plat-vexpress/core/tee-pageable_v2.bin output/bl32_extra2.bin
cp u-boot/u-boot.bin output/bl33.bin

echo 
echo "#################### BUILD DONE ####################"
echo "cd output "
echo "SEMI-HOSTING:  "
echo  "sudo qemu-system-aarch64 -m 1024 -smp 2 -show-cursor -serial stdio -monitor null -nographic -cpu cortex-a57 -bios bl1.bin -machine virt,secure=on -d unimp -semihosting-config enable,target=native -serial tcp::5000,server,nowait -gdb tcp::1234 -dtb virt.dtb"
echo "FIP: "
echo -e "sudo qemu-system-aarch64 -m 1024 -smp 2 -show-cursor -serial stdio -monitor null -nographic -cpu cortex-a57 -bios flash.bin -machine virt,secure=on -d unimp -serial tcp::5000,server,nowait -gdb tcp::1234 -dtb virt.dtb"

echo 
echo "For secure UART debugging"
echo "telnet 0 5000"
