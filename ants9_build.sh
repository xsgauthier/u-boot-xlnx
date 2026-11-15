# if we execute under WSL, check case sensitivity of parent directory
# using fsutil.exe file queryCaseSensitiveInfo u-boot-xlnx | grep 'disabled'
if grep -qi 'Microsoft' <<< "$(uname -r)"; then
    if grep -q 'disabled' <<< "$(fsutil.exe file queryCaseSensitiveInfo .)"; then
        echo "Warning: WSL is running in case-insensitive mode. This may cause issues with U-Boot build."
        WINPATH=$(wslpath -w "$PWD")
        echo "Current directory: $PWD"
        echo "Windows path: $WINPATH"
        echo "Attempting to enable case sensitivity for the current directory using fsutil.exe..."
        fsutil.exe file setCaseSensitiveInfo $WINPATH enable
        if [ $? -ne 0 ]; then
            echo "Failed to enable case sensitivity. Please run 'fsutil.exe file setCaseSensitiveInfo ${WINPATH} enable' manually."
            exit 1
        fi
        echo "Enabled case sensitivity for the current directory. Please restart the script."
        exit 1
    fi
fi

export ARCH=arm
export CROSS_COMPILE=arm-linux-gnueabihf-
VENDOR=jsgrd
BOARD=ants9

function update_platform() {
    echo "Copying device tree source from ../S9_DEBIAN/boot/${BOARD}/devicetree.dts to dts/upstream/src/arm/xilinx/zynq-${BOARD}.dts"
    cp -f ../S9_DEBIAN/boot/${BOARD}/devicetree.dts ./dts/upstream/src/arm/xilinx/zynq-${BOARD}.dts
    cp -f ../S9_DEBIAN/boot/${BOARD}/devicetree.dts ./arch/arm/dts/zynq-${BOARD}.dts

    echo "Sourcing ps7_init_gpl.c from ../S9_DEBIAN/boot/${BOARD}/export/ants9/hw/ps7_init_gpl.c"
    cp -f ../S9_DEBIAN/boot/${BOARD}/export/ants9/hw/ps7_init_gpl.c ./board/${VENDOR}/${BOARD}/zynq-${BOARD}/ps7_init_gpl.c
    cp -f ../S9_DEBIAN/boot/${BOARD}/export/ants9/hw/ps7_init_gpl.h ./board/${VENDOR}/${BOARD}/zynq-${BOARD}/ps7_init_gpl.h

    PS7_DIR="board/${VENDOR}/${BOARD}/zynq-${BOARD}"

    # 1.1 Fix empty C function prototypes in ps7_init_gpl.h for -Werror=strict-prototypes
    echo "Patching ${PS7_DIR}/ps7_init_gpl.h to fix empty C function prototypes"

    # 1. Fix empty function prototypes in ps7_init_gpl.h
    sed -i -E \
        -e 's/^((int|void|unsigned long)[[:space:]]+[a-zA-Z0-9_]+)[[:space:]]*\(\)[[:space:]]*;/\1(void);/' \
        "${PS7_DIR}/ps7_init_gpl.h"

    if [ $? -ne 0 ]; then
        echo "Failed to patch ${PS7_DIR}/ps7_init_gpl.h"
        exit 1
    fi

    # 2. Fix empty function definitions & declarations in ps7_init_gpl.c (including ps7GetSiliconVersion)
    sed -i -E \
        -e 's/^(([a-zA-Z0-9_]+[[:space:]]+)*[a-zA-Z0-9_]+)[[:space:]]*\(\)[[:space:]]*\{/\1(void) {/' \
        -e 's/^(([a-zA-Z0-9_]+[[:space:]]+)*[a-zA-Z0-9_]+)[[:space:]]*\(\)[[:space:]]*;/\1(void);/' \
        "${PS7_DIR}/ps7_init_gpl.c"
    if [ $? -ne 0 ]; then
        echo "Failed to patch ${PS7_DIR}/ps7_init_gpl.c"
        exit 1
    fi

    # 1.2 Replace bare-metal xil_io.h with U-Boot's <asm/io.h> and writel/readl macros in ps7_init_gpl.c
    echo "Patching ${PS7_DIR}/ps7_init_gpl.c to replace xil_io.h with <asm/io.h> and writel/readl macros"
    sed -i 's|^#include "xil_io.h"|#include <asm/io.h>\n#define Xil_Out32(addr, val) writel((val), (addr))\n#define Xil_In32(addr) readl((addr))|' \
        "${PS7_DIR}/ps7_init_gpl.c"

    if [ $? -ne 0 ]; then
        echo "Failed to patch ${PS7_DIR}/ps7_init_gpl.c"
        exit 1
    fi

}

function patch_xlnx_uboot() {
    if grep -q 'conv=block,sync bs=4' scripts/Makefile.xpl; then
        sed -i 's/conv=block,sync bs=4/conv=sync bs=4/' scripts/Makefile.xpl
        echo "Patched scripts/Makefile.xpl (removed invalid block conversion)"
    else
        echo "scripts/Makefile.xpl already patched"
    fi
}

function generate_boot_script() {
    export BOOTIMG_ROOT=$(realpath ../S9_DEBIAN/BOOTFAT)

    echo "Generating boot script (boot.cmd) and copying U-Boot binary to ${BOOTIMG_ROOT}"
    cat << EOF > boot.cmd
# Load bitstream into RAM and program Zynq PL (supports standard Vivado .bit header)
fatload mmc 0:1 0x2000000 system.bit
fpga loadb 0 0x2000000 \${filesize}

echo "Loading Linux uImage and DTB..."
fatload mmc 0:1 0x08000000 uImage
fatload mmc 0:1 0x07F00000 zynq-ants9.dtb

setenv bootargs "mem=496M console=ttyPS0,115200n8 earlycon root=/dev/mmcblk0p2 rootfstype=ext4 rw rootwait uio_pdrv_genirq.of_id=generic-uio"
bootm 0x08000000 - 0x07F00000
EOF

    cat boot.cmd
    # Copy the built U-Boot binary to the BOOTIMG_ROOT directory
    # /$BOOTIMG_ROOT (FAT32)
    # ├── boot.bin
    # ├── u-boot.img
    # ├── system.bit
    # ├── uImage
    # ├── zynq-${BOARD}.dtb
    # └── boot.scr

    mkdir -p "${BOOTIMG_ROOT}" || { echo "Error: Failed to create directory ${BOOTIMG_ROOT}"; exit 1; }

    cp -f spl/boot.bin "${BOOTIMG_ROOT}/boot.bin" || { echo "Error: Failed to copy boot.bin"; exit 1; }
    cp -f u-boot.img "${BOOTIMG_ROOT}/u-boot.img" || { echo "Error: Failed to copy u-boot.img"; exit 1; }
    # <vivado-project>/<project>.runs/impl_1/<top_module>.bit
    cp -f "../S9_DEBIAN/boot/${BOARD}/hw/system_bd_wrapper.bit" "${BOOTIMG_ROOT}/system.bit" || { echo "Error: Failed to copy system.bit"; exit 1; }
    cp -f "../S9_DEBIAN/linux/uImage" "${BOOTIMG_ROOT}/uImage" || { echo "Error: Failed to copy uImage"; exit 1; }
    cp -f "./arch/arm/dts/zynq-${BOARD}.dtb" "${BOOTIMG_ROOT}/zynq-${BOARD}.dtb" || { echo "Error: Failed to copy zynq-${BOARD}.dtb"; exit 1; }
    ./tools/mkimage -C none -A arm -T script -d boot.cmd "${BOOTIMG_ROOT}/boot.scr" || { echo "Error: Failed to generate boot.scr"; exit 1; }

    echo "Boot script and U-Boot binary copied to ${BOOTIMG_ROOT}"
}


# delete .config if argument is passed to the script -f, forcing a rebuild of U-Boot. 
for arg in "$@"; do
    if [ "$arg" == "-f" ]; then
        echo "Forcing rebuild of U-Boot by deleting .config"
        [ -f .config ] && rm -f .config
    fi
    if [ "$arg" == "-p" ]; then
        echo "Updating platform files for ${BOARD}"
        update_platform
        exit 0
    fi
    if [ "$arg" == "-c" ]; then
        echo "Cleaning build artifacts"
        make clean
        exit 0
    fi
    if [ "$arg" == "-b" ]; then
        generate_boot_script
        exit 0
    fi
    if [ "$arg" == "-h" ] || [ "$arg" == "--help" ]; then
        echo "Usage: $0 [-f] [-p] [-c] [-h|--help]"
        echo "  -f    Force rebuild of U-Boot by deleting .config"
        echo "  -p    Update platform files for ${BOARD} and exit."
        echo "  -b    Update boot script and copy U-Boot binary to BOOTIMG_ROOT and exit."
        echo "  -c    Clean build artifacts by running 'make clean' and exit."
        echo "  -h    Show this help message"
        exit 0
    fi
done

if [ ! -f .config ]; then
    echo "No .config file found. Generating default configuration for ${BOARD}."
    make clean
    make bitmain_antminer_s9_defconfig

    ./scripts/config --set-str CONFIG_SYS_PROMPT "${BOARD}> "
    ./scripts/config --set-str CONFIG_SYS_VENDOR "${VENDOR}"
    ./scripts/config --set-str CONFIG_SYS_BOARD "${BOARD}"
    ./scripts/config --set-str CONFIG_DEFAULT_DEVICE_TREE "zynq-${BOARD}"

    # Disable host EFI capsule tool if gnutls-dev is not installed
    #./scripts/config --disable CONFIG_EFI_RUNTIME_UPDATE_CAPSULE
    #./scripts/config --disable CONFIG_TOOLS_MKEFICAPSULE

    # Ensure distro boot & ext4 filesystem commands are active
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
fi

## Do not build U-Boot if the source code is already built.
if [ -f u-boot.elf ]; then
    echo "U-Boot binary already exists. Skipping build. add -f to force complete build."
    exit 0
fi

update_platform
patch_xlnx_uboot

echo "Running make -j$(nproc) to build U-Boot for ${BOARD}"
make -j$(nproc)
if [ $? -ne 0 ]; then
    echo "U-Boot build failed."
    exit 1
fi

generate_boot_script
