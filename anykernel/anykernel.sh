# AnyKernel3 - S22 StealthStation
# osm0sis @ xda-developers

properties() { '
kernel.string=S22 StealthStation NetHunter Kernel
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=SM-S901E
device.name2=dm1s
device.name3=s5e9925
supported.versions=13-15
'; }

block=/dev/block/by-name/boot;
is_slot_device=1;
ramdisk_compression=auto;
patch_vbmeta_flag=auto;

. tools/ak3-core.sh;
. tools/boot_patch.sh "$KERNEL";
