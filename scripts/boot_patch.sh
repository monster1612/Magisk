#!/system/bin/sh
##########################################################################################
#
# Magisk Boot Image Patcher
# by topjohnwu
#
# Usage: sh boot_patch.sh <bootimage>
#
# The following additional flags can be set in environment variables:
# KEEPVERITY, KEEPFORCEENCRYPT, HIGHCOMP
#
# This script should be placed in a directory with the following files:
#
# File name          Type      Description
#
# boot_patch.sh      script    A script to patch boot. Expect path to boot image as parameter.
#                  (this file) The script will use binaries and files in its same directory
#                              to complete the patching process
# util_functions.sh  script    A script which hosts all functions requires for this script
#                              to work properly
# magiskinit         binary    The binary to replace /init, which has the magisk binary embedded
# magiskboot         binary    A tool to unpack boot image, decompress ramdisk, extract ramdisk,
#                              and patch the ramdisk for Magisk support
# chromeos           folder    This folder should store all the utilities and keys to sign
#                  (optional)  a chromeos device. Used for Pixel C
# amazon             folder    A folder containing the device-specific tools needed to 'resign'
#                              a boot image after patching so it will work on an Amazon device
#                              (currently only good for patching the 2nd gen HD 7" or 8.9")
#
# If the script is not running as root, then the input boot image should be a stock image
# or have a backup included in ramdisk internally, since we cannot access the stock boot
# image placed under /data we've created when previously installed
#
##########################################################################################
##########################################################################################
# Functions
##########################################################################################

# Pure bash dirname implementation
getdir() {
  case "$1" in
    */*) dir=${1%/*}; [ -z $dir ] && echo "/" || echo $dir ;;
    *) echo "." ;;
  esac
}

##########################################################################################
# Initialization
##########################################################################################

if [ -z $SOURCEDMODE ]; then
  # Switch to the location of the script file
  cd "`getdir "${BASH_SOURCE:-$0}"`"
  # Load utility functions
  . ./util_functions.sh
fi

BOOTIMAGE="$1"
[ -e "$BOOTIMAGE" ] || abort "$BOOTIMAGE does not exist!"

# Flags
[ -z $KEEPVERITY ] && KEEPVERITY=false
[ -z $KEEPFORCEENCRYPT ] && KEEPFORCEENCRYPT=false
[ -z $HIGHCOMP ] && HIGHCOMP=false

chmod -R 755 .

# Extract magisk if doesn't exist
[ -e magisk ] || ./magiskinit -x magisk magisk

##########################################################################################
# Unpack
##########################################################################################

CHROMEOS=false

ui_print "- Unpacking boot image"
./magiskboot --unpack "$BOOTIMAGE"

case $? in
  1 )
    abort "! Unable to unpack boot image"
    ;;
  2 )
    HIGHCOMP=true
    ;;
  3 )
    ui_print "- ChromeOS boot image detected"
    CHROMEOS=true
    ;;
  4 )
    ui_print "! Sony ELF32 format detected"
    abort "! Please use BootBridge from @AdrianDC to flash Magisk"
    ;;
  5 )
    ui_print "! Sony ELF64 format detected"
    abort "! Stock kernel cannot be patched, please use a custom kernel"
esac

##########################################################################################
# Ramdisk restores
##########################################################################################

# Test patch status and do restore, after this section, ramdisk.cpio.orig is guaranteed to exist
ui_print "- Checking ramdisk status"
MAGISK_PATCHED=false
./magiskboot --cpio ramdisk.cpio test
case $? in
  0 )  # Stock boot
    ui_print "- Stock boot image detected"
    ui_print "- Backing up stock boot image"
    SHA1=`./magiskboot --sha1 "$BOOTIMAGE" 2>/dev/null`
    STOCKDUMP=stock_boot_${SHA1}.img.gz
    ./magiskboot --compress "$BOOTIMAGE" $STOCKDUMP
    cp -af ramdisk.cpio ramdisk.cpio.orig
    ;;
  1 )  # Magisk patched
    MAGISK_PATCHED=true
    HIGHCOMP=false
    ;;
  2 ) # High compression mode
    MAGISK_PATCHED=true
    HIGHCOMP=true
    ;;
  3 ) # Other patched
    ui_print "! Boot image patched by other programs"
    abort "! Please restore stock boot image"
    ;;
esac

if $MAGISK_PATCHED; then
  ui_print "- Magisk patched image detected"
  # Find SHA1 of stock boot image
  [ -z $SHA1 ] && SHA1=`./magiskboot --cpio ramdisk.cpio sha1 2>/dev/null`
  ./magiskboot --cpio ramdisk.cpio restore
  cp -af ramdisk.cpio ramdisk.cpio.orig
fi

if $HIGHCOMP; then
  ui_print "! Insufficient boot partition size detected"
  ui_print "- Enable high compression mode"
fi

##########################################################################################
# Ramdisk patches
##########################################################################################

ui_print "- Patching ramdisk"

./magiskboot --cpio ramdisk.cpio \
"add 750 init magiskinit" \
"magisk ramdisk.cpio.orig $HIGHCOMP $KEEPVERITY $KEEPFORCEENCRYPT $SHA1"

rm -f ramdisk.cpio.orig

##########################################################################################
# Binary patches
##########################################################################################

if ! $KEEPVERITY; then
  [ -f dtb ] && ./magiskboot --dtb-patch dtb && ui_print "- Removing dm(avb)-verity from fstab in dtb"
  [ -f extra ] && ./magiskboot --dtb-patch extra && ui_print "- Removing dm(avb)-verity from fstab in extra-dtb"
fi

if [ -f kernel ]; then
  # Remove Samsung RKP in stock kernel
  ./magiskboot --hexpatch kernel \
  49010054011440B93FA00F71E9000054010840B93FA00F7189000054001840B91FA00F7188010054 \
  A1020054011440B93FA00F7140020054010840B93FA00F71E0010054001840B91FA00F7181010054

  # skip_initramfs -> want_initramfs
  ./magiskboot --hexpatch kernel \
  736B69705F696E697472616D6673 \
  77616E745F696E697472616D6673
fi

##########################################################################################
# Repack and flash
##########################################################################################

ui_print "- Repacking boot image"
./magiskboot --repack "$BOOTIMAGE" || abort "! Unable to repack boot image!"

# Sign chromeos boot
$CHROMEOS && sign_chromeos

./magiskboot --cleanup
