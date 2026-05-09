#!/data/data/com.termux/files/usr/bin/bash
set -e
AK3_ZIP=$(ls ~/s22-stealth-station/output/*.zip 2>/dev/null | tail -1)
if [ -z "$AK3_ZIP" ]; then
  echo "ERROR: No zip in output/ — download from GitHub Actions first"
  exit 1
fi
echo "Pushing: $AK3_ZIP"
adb push "$AK3_ZIP" /sdcard/Download/
echo ""
echo "Flash in TWRP, or via adb:"
echo "  adb shell su -c 'twrp install /sdcard/Download/$(basename $AK3_ZIP)'"
