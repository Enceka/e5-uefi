##
#  EDK2 platform description for the Rongyue E5 (Unisoc UMS9621 / Qogirn6lite).
#
#  The E5 has no UEFI firmware: LK (the stock Android bootloader) loads whatever
#  sits at offset 0x1000 of the boot partition to 0x80080000 and jumps to it
#  with x0 = physical address of the merged vendor FDT.  BootShim (see
#  ../../BootShim) turns that into a normal EDK2 entry: it copies the FD to
#  PcdFdBaseAddress and branches to SEC, keeping x0 intact so that SEC can
#  stash it in the gSiliciumEntryArgHobGuid HOB.
#
#  SPDX-License-Identifier: BSD-2-Clause-Patent
##

[Defines]
  PLATFORM_NAME                  = e5
  PLATFORM_GUID                  = 1C0A6E52-3D74-4F1B-8E29-5A7C0D4B93F8
  PLATFORM_VERSION               = 0.1
  DSC_SPECIFICATION              = 0x00010005
  OUTPUT_DIRECTORY               = Build/e5Pkg
  SUPPORTED_ARCHITECTURES        = AARCH64
  BUILD_TARGETS                  = RELEASE|DEBUG
  SKUID_IDENTIFIER               = DEFAULT
  FLASH_DEFINITION               = e5Pkg/e5.fdf
  #
  # The panel is 320x480, far below the 640x475 SimpleFbDxe insists on, so the
  # platform supplies its own GOP driver (SprdGopDxe).
  #
  USE_CUSTOM_DISPLAY_DRIVER      = 1

!include UMS9621Pkg/UMS9621Pkg.dsc.inc

[PcdsFixedAtBuild]
  #
  # DDR: 2 GiB at 0x80000000 (memory@80000000 in the vendor FDT).
  #
  gArmTokenSpaceGuid.PcdSystemMemoryBase|0x80000000

  #
  # UEFI stack: inside the "UEFI Stack" region of MemoryMapLib.
  #
  gArmPlatformTokenSpaceGuid.PcdCPUCoresStackBase|0x80480000
  gArmPlatformTokenSpaceGuid.PcdCPUCorePrimaryStackSize|0x40000

  #
  # 临时调试开关：打开 DEBUG_PAGING (0x02000000)。
  #
  # SiliciumPkg.dsc.inc 把 PcdDebugPrintErrorLevel 设成 0x8007EE0F，其中不含
  # DEBUG_PAGING 位，所以 ArmMmuLibCore.c 里 UpdateRegionMappingRecursive 每次
  # 递归入口的那条 DEBUG 被压制了。SEC 在 ArmConfigureMmu 里挂死时，屏幕停在
  # "MMU: HOBs built, enabling" 之后，无法判断是循环前、循环中（哪个 region /
  # 哪一层）还是循环后的寄存器写入挂住。打开这一位就能让 39 个 region 打出约
  # 150 行 trace，把挂死点夹出来。
  #
  # 值 = 0x8007EE0F | 0x02000000。定位完成后请删掉这一段，恢复原级别。
  #
  gEfiMdePkgTokenSpaceGuid.PcdDebugPrintErrorLevel|0x8207EE0F

  #
  # SMBIOS.
  #
  gSiliciumPkgTokenSpaceGuid.PcdSmbiosSystemManufacturer|"Rongyue"
  gSiliciumPkgTokenSpaceGuid.PcdSmbiosSystemModel|"E5"
  gSiliciumPkgTokenSpaceGuid.PcdSmbiosSystemRetailModel|"e5"
  gSiliciumPkgTokenSpaceGuid.PcdSmbiosSystemRetailSku|"E5_ums9158_1h10"
  gSiliciumPkgTokenSpaceGuid.PcdSmbiosSystemBoardModel|"ums9158_1h10"

  #
  # Panel: 320x480, RGB565.  Measured from DPU PANEL_SIZE = 0x01e00140
  # (480 << 16 | 320) and LAY0_CTRL format field 4 on the running device.
  #
  gSiliciumPkgTokenSpaceGuid.PcdFrameBufferWidth|320
  gSiliciumPkgTokenSpaceGuid.PcdFrameBufferHeight|480
  gSiliciumPkgTokenSpaceGuid.PcdFrameBufferColorDepth|16

[LibraryClasses]
  #
  # Memory map: describes every reserved region of the vendor FDT plus the
  # peripherals EDK2 needs.  Also the source of "Display Reserved", which both
  # SEC (to clear the panel) and SprdGopDxe (to publish GOP) look up by name.
  #
  MemoryMapLib|e5Pkg/Library/MemoryMapLib/MemoryMapLib.inf

[Components]
  #
  # Display: our own GOP, because SimpleFbDxe rejects anything under 640x475.
  #
  UMS9621Pkg/Drivers/SprdGopDxe/SprdGopDxe.inf

  #
  # Bring-up probe: dumps the DXE view of the world at the end of dispatch and
  # resets, so that every experiment ends with a readable ramoops log instead of
  # a board that has to be power cycled by hand.
  #
  UMS9621Pkg/Drivers/E5BringupDxe/E5BringupDxe.inf

  #
  # Payload volume: publishes the boot image ramdisk (/chosen linux,initrd-start)
  # as a read-only block device so the FAT payload inside it becomes a UEFI
  # volume. Built here so it keeps compiling, but deliberately absent from
  # e5.fdf until the DXE core is confirmed running on hardware -- a fault
  # during dispatch would hide the EndOfDxe marker.
  #
  e5Pkg/Drivers/E5PayloadDxe/E5PayloadDxe.inf
