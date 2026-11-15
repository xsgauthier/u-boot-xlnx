# Load bitstream into RAM and program Zynq PL (supports standard Vivado .bit header)
fatload mmc 0:1 0x2000000 system.bit
fpga loadb 0 0x2000000 ${filesize}

# Load Linux kernel and Device Tree
fatload mmc 0:1 0x3000000 uImage
fatload mmc 0:1 0x2A00000 zynq-ants9.dtb

# Boot Linux
setenv bootargs "mem=496M console=ttyPS0,115200n8 ramdisk_size=409600 root=/dev/mmcblk0p2 rootfstype=ext4 rw rootwait uio_pdrv_genirq.of_id=generic-uio"
bootm 0x3000000 - 0x2A00000
