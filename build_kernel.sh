#!/usr/bin/env bash
#r5q build sh

pack()
{
	rm boot.img boot.tar dtb kernel ramdisk.cpio
	magiskboot unpack boot
	cp Image kernel
	magiskboot repack boot boot.img
	7z a -ttar ./boot.tar ./boot.img
	rm boot.img dtb kernel ramdisk.cpio
}

if [[ ! -d "./toolchain" ]]; then
	echo "The toolchain is missing"
	exit 1
fi

setup()
{
	export ARCH=arm64
	export PROJECT_NAME=r5q

	mkdir -p out

	BUILD_CROSS_COMPILE=$(pwd)/toolchain/gcc-cfp/gcc-cfp-jopp-only/aarch64-linux-android-4.9/bin/aarch64-linux-android-
	KERNEL_LLVM_BIN=$(pwd)/toolchain/clang/host/linux-x86/clang-4639204-cfp-jopp/bin/clang
	CLANG_TRIPLE=aarch64-linux-gnu-
	KERNEL_MAKE_ENV="DTC_EXT=$(pwd)/tools/dtc CONFIG_BUILD_ARM64_DT_OVERLAY=y"

	MAKE=toolchain/make-4.3/bin/make
}

build()
{
	$MAKE -j$(nproc) -C $(pwd) O=$(pwd)/out $KERNEL_MAKE_ENV ARCH=arm64 CROSS_COMPILE=$BUILD_CROSS_COMPILE REAL_CC=$KERNEL_LLVM_BIN CLANG_TRIPLE=$CLANG_TRIPLE r5q_eur_open_defconfig
	$MAKE -j$(nproc) -C $(pwd) O=$(pwd)/out $KERNEL_MAKE_ENV ARCH=arm64 CROSS_COMPILE=$BUILD_CROSS_COMPILE REAL_CC=$KERNEL_LLVM_BIN CLANG_TRIPLE=$CLANG_TRIPLE
}

setup
build

if [[ "$1" == "flash" ]]; then
	cd out/arch/arm64/boot/
	pack
	echo "Waiting for ADB Connection" 
	adb wait-for-device
	adb reboot download
	echo "Waiting for Download Mode connection"
	until lsusb | grep "Samsung" >/dev/null; do
		sleep 0.5
	done
	echo "Device detected"
	odin4 -a boot.tar
	cd ../../../..'
fi

if [[ "$(whoami)" == "filip" ]]; then
	git add .
	read -p "Commit? " usrcommit
	git commit $usrcommit
	git push -u origin main
fi
