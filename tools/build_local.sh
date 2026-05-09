#!/data/data/com.termux/files/usr/bin/bash
# Mirror CI build locally inside proot Kali/Ubuntu
set -e
KDIR=${1:-"$HOME/kernel_src"}
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export PLATFORM_VERSION=13
export ANDROID_MAJOR_VERSION=t
cd "$KDIR"
make O=out stealth_defconfig
make O=out -j$(nproc) KCFLAGS="-w" Image
echo ""
echo "Image: $KDIR/out/arch/arm64/boot/Image"
