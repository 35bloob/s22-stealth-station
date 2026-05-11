#!/bin/bash
# ============================================================
# S22 StealthStation - Local Kernel Build Script
# Run inside proot-distro Ubuntu on Termux
# Usage: bash local_build.sh
# ============================================================
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════╗"
echo "║  S22 StealthStation Kernel Builder       ║"
echo "║  NetHunter + KernelSU Local Build        ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"

WORKDIR="$HOME/kernel-build"
REPO_URL="https://github.com/35bloob/s22-stealth-station"

# ── Step 1: Install dependencies ──
echo -e "${YELLOW}[1/9] Installing build dependencies...${NC}"
apt-get update -qq
apt-get install -y build-essential bc flex bison libssl-dev \
  libelf-dev git curl wget zip unzip python3 device-tree-compiler \
  gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu libncurses-dev \
  jq rsync 2>&1 | tail -3
echo -e "${GREEN}✓ Dependencies installed${NC}"

# ── Step 2: Set up workspace ──
echo -e "${YELLOW}[2/9] Setting up workspace...${NC}"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

# Clone repo for configs
if [ -d repo ]; then
  echo "Repo already cloned, pulling latest..."
  cd repo && git pull --ff-only && cd ..
else
  git clone --depth=1 "$REPO_URL" repo
fi
echo -e "${GREEN}✓ Repo ready${NC}"

# ── Step 3: Install GCC wrapper ──
echo -e "${YELLOW}[3/9] Installing GCC warning-suppression wrapper...${NC}"
REAL_GCC=$(which aarch64-linux-gnu-gcc)
if [ ! -f "${REAL_GCC}.real" ]; then
  cp "$REAL_GCC" "${REAL_GCC}.real"
fi
cat > "$REAL_GCC" << 'GCCEOF'
#!/bin/bash
exec "${0}.real" "$@" -w -Wno-error
GCCEOF
chmod +x "$REAL_GCC"
echo -e "${GREEN}✓ GCC wrapper installed${NC}"

# ── Step 4: Download kernel source ──
echo -e "${YELLOW}[4/9] Downloading Samsung kernel source...${NC}"
mkdir -p kernel_src
cd kernel_src

# Download from GitHub release
if [ ! -f ".downloaded" ]; then
  RELEASE_URL=$(curl -sL "https://api.github.com/repos/35bloob/s22-stealth-station/releases/tags/kernel-source" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for a in data.get('assets', []):
    print(a['browser_download_url'])
    break
")
  if [ -z "$RELEASE_URL" ]; then
    echo -e "${RED}ERROR: Could not find kernel-source release${NC}"
    echo "Make sure the 'kernel-source' release exists on your repo"
    exit 1
  fi
  FNAME=$(basename "$RELEASE_URL")
  echo "Downloading $FNAME ..."
  wget -q --show-progress "$RELEASE_URL" -O "$FNAME"

  echo "Extracting..."
  if echo "$FNAME" | grep -qi '\.zip$'; then
    unzip -o "$FNAME"
  else
    tar xf "$FNAME"
  fi

  # Extract any nested archives
  for f in *.tar.gz; do
    [ -f "$f" ] && echo "Extracting $f" && tar xzf "$f" || true
  done

  chmod -R u+w .
  touch .downloaded
  echo -e "${GREEN}✓ Kernel source downloaded${NC}"
else
  echo "Source already downloaded, skipping"
fi

# Find kernel directory
KDIR=$(find . -maxdepth 5 -type d -name "arch" -exec test -d "{}/arm64/configs" \; -print 2>/dev/null | head -1 | sed 's|/arch$||')
if [ -z "$KDIR" ]; then
  echo -e "${RED}ERROR: Could not find kernel source directory${NC}"
  exit 1
fi
KERNEL_DIR=$(cd "$KDIR" && pwd)
echo "Kernel at: $KERNEL_DIR"
cd "$KERNEL_DIR"

# ── Step 5: Patch source ──
echo -e "${YELLOW}[5/9] Patching kernel source...${NC}"
chmod -R u+w .
python3 << 'PATCHEOF'
import os, re

print('--- Patching cred.c ---')
for root, dirs, files in os.walk('.'):
    for fname in files:
        fpath = os.path.join(root, fname)
        if fname == 'cred.c':
            t = open(fpath, 'rb').read().decode('utf-8', errors='replace')
            if '0x%lx' in t:
                t = t.replace('0x%lx', '%p')
                open(fpath, 'wb').write(t.encode('utf-8'))
                print(f'  PATCHED {fpath}')
        elif fname == 'kernel.h' and 'include/linux' in root:
            t = open(fpath).read()
            if 'TRACING_MARK_TYPE_END, ""' in t:
                t = t.replace('TRACING_MARK_TYPE_END, ""', 'TRACING_MARK_TYPE_END, " "')
                open(fpath, 'w').write(t)
                print(f'  PATCHED {fpath} (tracing)')
        elif fname == 'psi.c' and 'kernel/sched' in root:
            t = open(fpath).read()
            if '%lu' in t:
                t = t.replace('%lu', '%llu')
                open(fpath, 'w').write(t)
                print(f'  PATCHED {fpath}')

print('--- Patching f2fs ---')
for root, dirs, files in os.walk('fs/f2fs'):
    for fname in files:
        if fname == 'data.c':
            fpath = os.path.join(root, fname)
            t = open(fpath).read()
            if 'flush_group' in t:
                t = t.replace('in_group_p(F2FS_OPTION(sbi).flush_group)', '0')
                open(fpath, 'w').write(t)
                print(f'  PATCHED {fpath}')

print('--- Patching bluetooth hci_sock.c ---')
hci = 'net/bluetooth/hci_sock.c'
if os.path.exists(hci):
    hlines = open(hci).readlines()
    ioctl_start = -1
    ioctl_brace = -1
    for i, hl in enumerate(hlines):
        if 'hci_sock_ioctl' in hl and ('static' in hl or 'int' in hl):
            ioctl_start = i
        if ioctl_start >= 0 and ioctl_brace < 0 and '{' in hl:
            ioctl_brace = i
            break
    if ioctl_brace >= 0:
        decls = '\tstruct sock *sk = sock->sk;\n\tvoid __user *argp = (void __user *)arg;\n\tint err = 0;\n'
        hlines.insert(ioctl_brace+1, decls)
        fixed_count = 0
        for i in range(ioctl_brace+4, min(ioctl_brace+400, len(hlines))):
            if hlines[i].rstrip() == '}' and not hlines[i].startswith('\t\t'):
                break
            if hlines[i].strip() == '*/':
                hlines[i] = '/* (patched) */\n'
                fixed_count += 1
        open(hci, 'w').writelines(hlines)
        print(f'  PATCHED {hci} ({fixed_count} fixes)')

print('--- Patching selinux services.c ---')
sef = 'security/selinux/ss/services.c'
if os.path.exists(sef):
    slines = open(sef).readlines()
    in_func = False
    goto_found = False
    for i, sl in enumerate(slines):
        if 'security_get_user_sids' in sl and '(' in sl:
            in_func = True
        if in_func and 'goto out;' in sl:
            goto_found = True
        if in_func and goto_found and sl.rstrip() == '}':
            slines.insert(i, 'out:\n')
            open(sef, 'w').writelines(slines)
            print(f'  PATCHED {sef}')
            break

print('--- Replacing cc-wrapper.c ---')
for root, dirs, files in os.walk('scripts'):
    for fname in files:
        if fname == 'cc-wrapper.c':
            fpath = os.path.join(root, fname)
            code = '#include <stdio.h>\n#include <stdlib.h>\n#include <unistd.h>\n\nint main(int argc, char **argv) {\n    if (argc < 2) return 1;\n    execvp(argv[1], argv + 1);\n    return 1;\n}\n'
            open(fpath, 'w').write(code)
            print(f'  REPLACED {fpath}')

print('--- Stripping -Werror ---')
for root, dirs, files in os.walk('.'):
    for fname in files:
        if 'Makefile' in fname or fname.endswith('.mk'):
            fpath = os.path.join(root, fname)
            try:
                t = open(fpath).read()
                if '-Werror' in t:
                    t = re.sub(r'-Werror[=\w.-]*', '', t)
                    open(fpath, 'w').write(t)
                    print(f'  CLEANED {fpath}')
            except: pass

print('--- Stripping u/U/UL/ULL suffixes from ALL source files ---')
count = 0
for root, dirs, files in os.walk('.'):
    skip = ['.git', 'out', '.tmp']
    dirs[:] = [d for d in dirs if d not in skip]
    for fname in files:
        if fname.endswith(('.h', '.c', '.S')):
            fpath = os.path.join(root, fname)
            try:
                t = open(fpath).read()
                t2 = re.sub(r'(0x[0-9a-fA-F]+)[uU](?:LL|L|ll|l)?\b', r'\1', t)
                t2 = re.sub(r'(\b[0-9]+)[uU](?:LL|L|ll|l)?\b', r'\1', t2)
                t2 = re.sub(r'(0x[0-9a-fA-F]+)(?:ULL|UL|LL|ul|ull)\b', r'\1', t2)
                t2 = re.sub(r'(\b[0-9]+)(?:ULL|UL|LL|ul|ull)\b', r'\1', t2)
                if t != t2:
                    open(fpath, 'w').write(t2)
                    count += 1
            except: pass
print(f'  Stripped suffixes from {count} files')

print('--- Deleting GCC plugins ---')
for root, dirs, files in os.walk('scripts'):
    for fname in files:
        if fname.endswith('.so'):
            p = os.path.join(root, fname)
            os.remove(p)
            print(f'  DELETED {p}')

print('--- All patches applied ---')
PATCHEOF
echo -e "${GREEN}✓ Source patched${NC}"

# ── Step 6: Add RTL8188FTV driver ──
echo -e "${YELLOW}[6/9] Adding RTL8188FTV WiFi driver...${NC}"
if [ ! -d drivers/net/wireless/rtl8188fu ]; then
  git clone --depth=1 https://github.com/kelebek333/rtl8188fu /tmp/rtl8188fu 2>/dev/null || true
  if [ -d /tmp/rtl8188fu ]; then
    mkdir -p drivers/net/wireless/rtl8188fu
    cp -r /tmp/rtl8188fu/* drivers/net/wireless/rtl8188fu/
    printf 'config RTL8188FU\n  tristate "Realtek RTL8188FU USB WiFi"\n  depends on USB && CFG80211\n  help\n    Enable support for Realtek RTL8188FU/FTV USB WiFi adapters.\n' > drivers/net/wireless/rtl8188fu/Kconfig
    grep -q "rtl8188fu" drivers/net/wireless/Makefile 2>/dev/null || \
      echo 'obj-$(CONFIG_RTL8188FU) += rtl8188fu/' >> drivers/net/wireless/Makefile
    grep -q "rtl8188fu" drivers/net/wireless/Kconfig 2>/dev/null || \
      echo 'source "drivers/net/wireless/rtl8188fu/Kconfig"' >> drivers/net/wireless/Kconfig
    cat > drivers/net/wireless/rtl8188fu/Kbuild << 'KBEOF'
ccflags-y += -I$(srctree)/$(src)/include
ccflags-y += -I$(srctree)/$(src)/hal/phydm
include $(srctree)/$(src)/Makefile
KBEOF
    echo -e "${GREEN}✓ RTL8188FU driver added${NC}"
  fi
else
  echo "Driver already present, skipping"
fi

# ── Step 7: Apply NetHunter config ──
echo -e "${YELLOW}[7/9] Applying NetHunter + stealth config...${NC}"
DC=""
for p in "*s5e9925*" "*dm1s*" "*dm1*" "*s901*" "*exynos*" "*samsung*"; do
  DC=$(find arch/arm64/configs -type f -name "$p" 2>/dev/null | head -1)
  [ -n "$DC" ] && break
done
if [ -z "$DC" ]; then
  if [ -f arch/arm64/configs/gki_defconfig ]; then
    DC=arch/arm64/configs/gki_defconfig
  else
    DC=$(find arch/arm64/configs -maxdepth 1 -type f -name '*defconfig' | head -1)
  fi
fi
echo "Base defconfig: $DC"
cp "$DC" arch/arm64/configs/stealth_defconfig
if [ -d arch/arm64/configs/vendor ]; then
  find arch/arm64/configs/vendor -type f | while read frag; do
    cat "$frag" >> arch/arm64/configs/stealth_defconfig
  done
fi
cat "$WORKDIR/repo/configs/nethunter_fragment.config" >> arch/arm64/configs/stealth_defconfig
cat "$WORKDIR/repo/configs/extra_features.config" >> arch/arm64/configs/stealth_defconfig
printf 'CONFIG_WERROR=n\n# CONFIG_GCC_PLUGINS is not set\n' >> arch/arm64/configs/stealth_defconfig
echo -e "${GREEN}✓ Config applied${NC}"

# ── Step 8: Patch KernelSU ──
echo -e "${YELLOW}[8/9] Patching KernelSU...${NC}"
curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -
printf 'CONFIG_KPROBES=y\nCONFIG_HAVE_KPROBES=y\nCONFIG_KPROBE_EVENTS=y\n' >> arch/arm64/configs/stealth_defconfig
echo -e "${GREEN}✓ KernelSU patched${NC}"

# ── Step 9: BUILD ──
echo -e "${YELLOW}[9/9] Building kernel...${NC}"
echo -e "${CYAN}This will take a while on a phone. Go grab coffee ☕${NC}"
echo ""

export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export PLATFORM_VERSION=13
export ANDROID_MAJOR_VERSION=t

# Last-resort cred.c fix
python3 -c "
p='kernel/cred.c'
t=open(p).read()
t=t.replace('0x%lx', '%p')
open(p,'w').write(t)
"

make O=out stealth_defconfig
sed -i 's/CONFIG_WERROR=y/CONFIG_WERROR=n/' out/.config
sed -i 's/CONFIG_GCC_PLUGINS=y/# CONFIG_GCC_PLUGINS is not set/' out/.config

NPROC=4
echo -e "Building with ${CYAN}$NPROC${NC} cores (limited to avoid overheating)..."
make O=out -j"$NPROC" KCFLAGS="-w" Image 2>&1 | tee build.log

if [ -f out/arch/arm64/boot/Image ]; then
  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║         BUILD SUCCESSFUL! 🎉             ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
  echo ""

  # Package with AnyKernel3
  echo "Packaging with AnyKernel3..."
  git clone --depth=1 https://github.com/osm0sis/AnyKernel3 /tmp/AnyKernel3 2>/dev/null || true
  rm -f /tmp/AnyKernel3/anykernel.sh
  cp "$WORKDIR/repo/anykernel/anykernel.sh" /tmp/AnyKernel3/anykernel.sh
  cp out/arch/arm64/boot/Image /tmp/AnyKernel3/Image
  cd /tmp/AnyKernel3
  rm -f *.md patch/sample* ramdisk/placeholder 2>/dev/null || true
  BUILD_DATE=$(date +%Y%m%d-%H%M)
  ZIP_NAME="S22-StealthStation-${BUILD_DATE}.zip"
  zip -r9 "$ZIP_NAME" . -x ".git/*"

  mkdir -p "$WORKDIR/output"
  cp "$ZIP_NAME" "$WORKDIR/output/"
  cp "$KERNEL_DIR/out/arch/arm64/boot/Image" "$WORKDIR/output/"

  echo ""
  echo -e "${GREEN}Output:${NC}"
  echo -e "  ZIP: ${CYAN}$WORKDIR/output/$ZIP_NAME${NC}"
  echo -e "  Image: ${CYAN}$WORKDIR/output/Image${NC}"
  echo ""
  echo -e "${YELLOW}Flash with TWRP/KernelFlasher or copy to phone storage${NC}"
else
  echo ""
  echo -e "${RED}╔══════════════════════════════════════════╗${NC}"
  echo -e "${RED}║         BUILD FAILED ❌                  ║${NC}"
  echo -e "${RED}╚══════════════════════════════════════════╝${NC}"
  echo ""
  echo "Check build.log for errors:"
  echo "  grep -i error build.log | tail -20"
  exit 1
fi
