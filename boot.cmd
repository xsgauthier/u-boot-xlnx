# Load bitstream into RAM and program Zynq PL (supports standard Vivado .bit header)
fatload mmc 0:1 0x2000000 system.bit
fpga loadb 0 0x2000000 ${filesize}

# Unlock SLCR, enable PS-PL level shifters, release FPGA resets, lock SLCR
mw.l 0xf8000008 0xdf0d
mw.l 0xf8000900 0xf
mw.l 0xf8000240 0x0
mw.l 0xf8000004 0x767b

echo "Loading Linux uImage and DTB..."
fatload mmc 0:1 0x08000000 uImage
fatload mmc 0:1 0x07F00000 zynq-ants9.dtb

# Inject MAC address (26:a4:19:dc:cb:d0) directly into the loaded Device Tree
fdt addr 0x07F00000
fdt resize 0x1000
fdt set /axi/ethernet@e000b000 local-mac-address [26 a4 19 dc cb d0]

setenv bootargs "mem=496M console=ttyPS0,115200n8 earlycon clk_ignore_unused root=/dev/mmcblk0p2 rootfstype=ext4 rw rootwait uio_pdrv_genirq.of_id=generic-uio"
bootm 0x08000000 - 0x07F00000
