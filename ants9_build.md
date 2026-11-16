# ANTS9 U-Boot Build Guide

This document describes the steps and options used by `ants9_build.sh` to prepare, configure, and build U-Boot for the Antminer S9 (`ants9`) target.

## Overview

The script configures the build for the `arm` architecture and uses the GNU ARM hard-float cross-compiler:

```bash
export ARCH=arm
export CROSS_COMPILE=arm-linux-gnueabihf-
VENDOR=jsgrd
BOARD=ants9
```

## Prerequisites

Before running the build:

- A Linux environment with the ARM cross-toolchain installed.
- The U-Boot source tree checked out in the current working directory.
- A sibling directory named `../S9_DEBIAN` containing the platform files, including:
  - `../S9_DEBIAN/boot/${BOARD}/devicetree.dts`
  - `../S9_DEBIAN/boot/${BOARD}/export/ants9/hw/ps7_init_gpl.c`
  - `../S9_DEBIAN/boot/${BOARD}/export/ants9/hw/ps7_init_gpl.h`
  - `../S9_DEBIAN/hdl/s9switcher.runs/impl_1/system_bd_wrapper.bit`
  - `../S9_DEBIAN/linux/uImage`

## WSL case-sensitivity check

If the build is running under WSL, the script checks whether the parent directory is case-sensitive:

```bash
if grep -qi 'Microsoft' <<< "$(uname -r)"; then
    if grep -q 'disabled' <<< "$(fsutil.exe file queryCaseSensitiveInfo .)"; then
        echo "Warning: WSL is running in case-insensitive mode. This may cause issues with U-Boot build."
        WINPATH=$(wslpath -w "$PWD")
        echo "Current directory: $PWD"
        echo "Windows path: $WINPATH"
        echo "Attempting to enable case sensitivity for the current directory using fsutil.exe..."
        fsutil.exe file setCaseSensitiveInfo $WINPATH enable
        ...
    fi
fi
```

If case sensitivity is disabled, the script exits and asks you to run:

```powershell
fsutil.exe file setCaseSensitiveInfo <windows-path> enable
```

Then restart the script.

## Platform update step

The script provides a `update_platform()` function that copies the board-specific device tree and Zynq initialization files into the proper U-Boot source locations:

```bash
cp -f ../S9_DEBIAN/boot/${BOARD}/devicetree.dts ./dts/upstream/src/arm/xilinx/zynq-${BOARD}.dts
cp -f ../S9_DEBIAN/boot/${BOARD}/devicetree.dts ./arch/arm/dts/zynq-${BOARD}.dts
cp -f ../S9_DEBIAN/boot/${BOARD}/export/ants9/hw/ps7_init_gpl.c ./board/${VENDOR}/${BOARD}/zynq-${BOARD}/ps7_init_gpl.c
cp -f ../S9_DEBIAN/boot/${BOARD}/export/ants9/hw/ps7_init_gpl.h ./board/${VENDOR}/${BOARD}/zynq-${BOARD}/ps7_init_gpl.h
```

After copying, it patches generated files so they compile cleanly under U-Boot's stricter rules:

- fixes empty C function prototypes in `ps7_init_gpl.h`
- fixes empty function definitions and declarations in `ps7_init_gpl.c`
- replaces bare-metal `xil_io.h` includes with U-Boot's `asm/io.h` and defines `Xil_Out32` / `Xil_In32` macros using `writel` / `readl`

## Xilinx U-Boot patch step

The script patches `scripts/Makefile.xpl` if it still contains the invalid conversion option:

```bash
if grep -q 'conv=block,sync bs=4' scripts/Makefile.xpl; then
    sed -i 's/conv=block,sync bs=4/conv=sync bs=4/' scripts/Makefile.xpl
    echo "Patched scripts/Makefile.xpl (removed invalid block conversion)"
else
    echo "scripts/Makefile.xpl already patched"
fi
```

## Boot script generation

`generate_boot_script()` creates a boot script and copies the required runtime files to the FAT boot image directory.

The generated `boot.cmd` loads a bitstream, programs the FPGA, loads the Linux kernel image and DTB, sets a MAC address into the device tree, sets boot arguments, and boots Linux with `bootm`:

```bash
fatload mmc 0:1 0x2000000 system.bit
fpga loadb 0 0x2000000 ${filesize}

mw.l 0xf8000008 0xdf0d
mw.l 0xf8000900 0xf
mw.l 0xf8000240 0x0
mw.l 0xf8000004 0x767b

echo "Loading Linux uImage and DTB..."
fatload mmc 0:1 0x08000000 uImage
fatload mmc 0:1 0x07F00000 zynq-ants9.dtb

fdt addr 0x07F00000
fdt resize 0x1000
fdt set /axi/ethernet@e000b000 local-mac-address [26 a4 19 dc cb d0]

setenv bootargs "mem=496M console=ttyPS0,115200n8 earlycon clk_ignore_unused root=/dev/mmcblk0p2 rootfstype=ext4 rw rootwait uio_pdrv_genirq.of_id=generic-uio"
bootm 0x08000000 - 0x07F00000
```

The script then copies the following files into the FAT boot directory (`../S9_DEBIAN/BOOTFAT`):

- `boot.bin`
- `u-boot.img`
- `system.bit`
- `uImage`
- `zynq-ants9.dtb`
- `boot.scr`

It compiles the DTB from the platform DTS with `dtc` and generates `boot.scr` using:

```bash
./tools/mkimage -C none -A arm -T script -d boot.cmd "${BOOTIMG_ROOT}/boot.scr"
```

## Command-line options

The script supports the following arguments:

```bash
./ants9_build.sh [-f] [-p] [-c] [-b] [-h|--help]
```

- `-f` — force a rebuild by deleting `.config`
- `-p` — update the board/platform files and exit
- `-c` — clean build artifacts with `make clean` and exit
- `-b` — generate the boot script and copy U-Boot artifacts to the boot image directory and exit
- `-h` or `--help` — show usage

## Default configuration and build flow

If `.config` does not exist, the script does the following:

```bash
make clean
make bitmain_antminer_s9_defconfig

./scripts/config --set-str CONFIG_SYS_PROMPT "${BOARD}> "
./scripts/config --set-str CONFIG_SYS_VENDOR "${VENDOR}"
./scripts/config --set-str CONFIG_SYS_BOARD "${BOARD}"
./scripts/config --set-str CONFIG_DEFAULT_DEVICE_TREE "zynq-${BOARD}"

./scripts/config --enable CONFIG_DISTRO_DEFAULTS
./scripts/config --enable CONFIG_CMD_EXT4
./scripts/config --enable CONFIG_CMD_FAT
./scripts/config --enable CONFIG_SUPPORT_RAW_INITRD
./scripts/config --enable CONFIG_CMD_FPGA
./scripts/config --enable CONFIG_FPGA_ZYNQPL
./scripts/config --enable CONFIG_SERIAL_ZYNQ
./scripts/config --enable CONFIG_DM_SERIAL

./scripts/config --enable CONFIG_AUTOBOOT
./scripts/config --set-val CONFIG_BOOTDELAY 15
./scripts/config --enable CONFIG_USE_BOOTCOMMAND
./scripts/config --set-str CONFIG_BOOTCOMMAND "fatload mmc 0:1 0x1000000 boot.scr && source 0x1000000"

make olddefconfig
```

After that, the script checks whether `u-boot.elf` already exists. If it does, the build exits early with:

```bash
U-Boot binary already exists. Skipping build. add -f to force complete build.
```

If it is not built yet, the script runs:

```bash
update_platform
patch_xlnx_uboot
make -j$(nproc)
```

If the build succeeds, it runs:

```bash
generate_boot_script
```

## Typical build workflow

1. Ensure your WSL case sensitivity is enabled if needed.
2. Run the script normally:

   ```bash
   ./ants9_build.sh
   ```

3. If you need to regenerate platform files only:

   ```bash
   ./ants9_build.sh -p
   ```

4. If you want to clean the build artifacts:

   ```bash
   ./ants9_build.sh -c
   ```

5. If you want to regenerate the boot script and boot image files only:

   ```bash
   ./ants9_build.sh -b
   ```

6. If you want to force a complete rebuild:

   ```bash
   ./ants9_build.sh -f
   ```

## Detailed workflow for updating the core and device tree

Use the following sequence whenever the FPGA core or device tree changes.

### 1) In Vivado

Perform the required hardware update and export it for software:

1. Validate the block design.
2. Generate the block design.
3. Run synthesis.
4. Run implementation.
5. Generate the bitstream.
6. Export hardware.

This produces the updated hardware description and the XSA used by Vitis.

### 2) In Vitis

After exporting hardware from Vivado:

1. Re-read the XSA by clicking the `vitis-comp.json` entry in the Vitis project.
2. Rebuild the project from the tasks panel.
3. Open the following files side-by-side in WinMerge:
   - `F:\GIT_WS\S9_DEBIAN\boot\ants9\hw\linux_dt\system.dts`
   - `F:\GIT_WS\S9_DEBIAN\boot\ants9\devicetree.dts`

A practical WinMerge command is:

```powershell
"C:\Program Files\WinMerge\WinMergeU.exe" "F:\GIT_WS\S9_DEBIAN\boot\ants9\hw\linux_dt\system.dts" "F:\GIT_WS\S9_DEBIAN\boot\ants9\devicetree.dts"
```

Review the differences carefully. Some changes must not be merged blindly, especially incorrect `compatible` entries and other board-specific metadata that should remain aligned with the custom Antminer S9 setup.

### 3) In WSL Ubuntu

Once the DTS changes are reviewed and corrected:

```bash
cd /mnt/f/GIT_WS/u-boot-xlnx
./ants9_build.sh
```

This rebuilds U-Boot with the updated platform files and generates the boot artifacts.

### 4) Update the boot partition

After the build completes, copy the contents of:

`F:\GIT_WS\S9_DEBIAN\BOOTFAT`

into the target boot partition. There are two common ways to do this:

- physically remove the SD card and copy the files onto the boot partition, or
- copy them to the system and run:

```bash
./update_boot_partition
```

This ensures the board boots with the new U-Boot image, device tree, and boot script.

## Notes

The script is specifically tailored to the Antminer S9 target and expects the board support files and Linux image from the `../S9_DEBIAN` tree. It also sets the boot command to load `boot.scr` from MMC and execute it before booting Linux from the SD card.
