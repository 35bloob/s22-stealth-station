
name: Build S22 NetHunter Kernel

on:
  push:
    branches:
      - main
  workflow_dispatch:
    inputs:
      kernelsu:
        description: 'Enable KernelSU'
        required: true
        default: 'true'
        type: choice
        options:
          - 'true'
          - 'false'
      extra_features:
        description: 'Enable extra stealth features'
        required: true
        default: 'true'
        type: choice
        options:
          - 'true'
          - 'false'
      create_release:
        description: 'Create GitHub release'
        required: true
        default: 'true'
        type: choice
        options:
          - 'true'
          - 'false'

jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 120
    permissions:
      contents: write

    steps:
      - name: Checkout repo
        uses: actions/checkout@v4

      - name: Install build dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y build-essential bc flex bison libssl-dev \
            libelf-dev git curl wget zip unzip python3 device-tree-compiler \
            gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu libncurses-dev \
            jq rsync python-is-python3

      - name: Replace system GCC with warning-suppressing wrapper
        run: |
          REAL_GCC=$(which aarch64-linux-gnu-gcc)
          sudo cp "$REAL_GCC" "${REAL_GCC}.real"
          printf '#!/bin/bash\nexec "${0}.real" -w -Wno-error "$@"\n' | sudo tee "$REAL_GCC" > /dev/null
          sudo chmod +x "$REAL_GCC"

      - name: Download kernel source
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release download kernel-source --dir . || echo "No release found"
          ARCHIVE=$(ls *.zip *.tar.gz 2>/dev/null | head -1)
          mkdir -p kernel_src && cd kernel_src
          if [[ "$ARCHIVE" == *.zip ]]; then unzip "../$ARCHIVE"; else tar xf "../$ARCHIVE"; fi
          KDIR=$(find . -maxdepth 5 -type d -name "arch" -exec test -d "{}/arm64/configs" \; -print | head -1 | sed 's|/arch$||')
          if [ -z "$KDIR" ]; then KDIR="."; fi
          echo "KERNEL_DIR=$(realpath $KDIR)" >> $GITHUB_ENV

      - name: Patch source and disable forbidden-warning system
        run: |
          cd ${{ env.KERNEL_DIR }}
          chmod -R u+w .
          python3 << 'EOF'
          import os, re
          print('=== PATCHING SOURCE FILES ===')
          for root, dirs, files in os.walk('.'):
              for fname in files:
                  fpath = os.path.join(root, fname)
                  if fname == 'cred.c':
                      with open(fpath, 'rb') as f: raw = f.read()
                      text = raw.decode('utf-8', errors='replace')
                      if '0x%lx' in text:
                          text = text.replace('0x%lx', '%p')
                          with open(fpath, 'wb') as f: f.write(text.encode('utf-8'))
                          print(f'PATCHED {fpath}')
                  elif fname == 'kernel.h' and 'include/linux' in root:
                      t = open(fpath).read()
                      if 'TRACING_MARK_TYPE_END, ""' in t:
                          open(fpath, 'w').write(t.replace('TRACING_MARK_TYPE_END, ""', 'TRACING_MARK_TYPE_END, " "'))
                  elif fname == 'psi.c' and 'kernel/sched' in root:
                      t = open(fpath).read()
                      if '%lu' in t: open(fpath, 'w').write(t.replace('%lu', '%llu'))

          # Patch Bluetooth hci_sock.c
          hci = 'net/bluetooth/hci_sock.c'
          if os.path.exists(hci):
              with open(hci, 'r') as f: lines = f.readlines()
              new_lines = []
              for line in lines:
                  if 'hci_sock_ioctl' in line and '{' in line:
                      new_lines.append(line)
                      new_lines.append('\tstruct sock *sk = sock->sk;\n\tvoid __user *argp = (void __user *)arg;\n\tint err = 0;\n')
                  else:
                      new_lines.append(line)
              with open(hci, 'w') as f: f.writelines(new_lines)
              print("PATCHED hci_sock.c")

          # Remove Werror and fix cc-wrapper
          for root, _, files in os.walk('.'):
              for f in files:
                  if f == 'Makefile' or f.endswith('.mk') or f == 'cc-wrapper.c':
                      fp = os.path.join(root, f)
                      try:
                          with open(fp, 'r') as file: content = file.read()
                          content = re.sub(r'-Werror[=w.-]*', '', content)
                          if f == 'cc-wrapper.c':
                              content = '#include <unistd.h>\nint main(int argc, char **av){return execvp(av[1], av+1);}'
                          with open(fp, 'w') as file: file.write(content)
                      except: pass
          EOF

      - name: Add RTL8188FTV driver
        run: |
          cd ${{ env.KERNEL_DIR }}
          git clone --depth=1 https://github.com/kelebek333/rtl8188fu drivers/net/wireless/rtl8188fu || true
          echo 'obj-$(CONFIG_RTL8188FU) += rtl8188fu/' >> drivers/net/wireless/Makefile
          echo 'source "drivers/net/wireless/rtl8188fu/Kconfig"' >> drivers/net/wireless/Kconfig

      - name: Apply NetHunter config
        run: |
          cd ${{ env.KERNEL_DIR }}
          DC=$(find arch/arm64/configs -name "*defconfig" | grep -E "s5e9925|dm1|gki" | head -1)
          cp "$DC" arch/arm64/configs/stealth_defconfig
          # Merge custom configs if they exist
          [ -f "${{ github.workspace }}/configs/nethunter_fragment.config" ] && cat ${{ github.workspace }}/configs/nethunter_fragment.config >> arch/arm64/configs/stealth_defconfig
          echo "CONFIG_WERROR=n" >> arch/arm64/configs/stealth_defconfig

      - name: Patch KernelSU
        if: inputs.kernelsu == 'true'
        run: |
          cd ${{ env.KERNEL_DIR }}
          curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -
          echo "CONFIG_KPROBES=y" >> arch/arm64/configs/stealth_defconfig
          echo "CONFIG_KPROBE_EVENTS=y" >> arch/arm64/configs/stealth_defconfig

      - name: Build kernel
        run: |
          cd ${{ env.KERNEL_DIR }}
          export ARCH=arm64
          export CROSS_COMPILE=aarch64-linux-gnu-
          make O=out stealth_defconfig
          sed -i 's/CONFIG_WERROR=y/CONFIG_WERROR=n/g' out/.config
          make O=out -j$(nproc) KCFLAGS="-w" Image
          if [ -f out/arch/arm64/boot/Image ]; then echo "BUILD_SUCCESS=true" >> $GITHUB_ENV; fi

      - name: Package with AnyKernel3
        if: env.BUILD_SUCCESS == 'true'
        run: |
          git clone --depth=1 https://github.com/osm0sis/AnyKernel3 /tmp/AnyKernel3
          cp ${{ env.KERNEL_DIR }}/out/arch/arm64/boot/Image /tmp/AnyKernel3/
          cd /tmp/AnyKernel3 && zip -r9 "S22-Kernel.zip" * -x .git*

      - name: Upload artifact
        if: env.BUILD_SUCCESS == 'true'
        uses: actions/upload-artifact@v4
        with:
          name: S22-Kernel
          path: /tmp/AnyKernel3/S22-Kernel.zip
