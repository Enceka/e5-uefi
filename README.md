# UEFI for Rongyue E5 (Unisoc UMS9621)

<p align="center"><strong>English</strong> · <a href="README.zh-CN.md">简体中文</a></p>

A UEFI firmware port for the **Rongyue E5** (荣悦 E5), an Android phone built on the
Unisoc **UMS9621** SoC (Qogirn6lite), board name `ums9158_1h10`. The device ships no
UEFI firmware at all: the stock bootloader hands control to whatever sits at offset
`0x1000` of the boot partition, so a small shim plus a Project Mu / Project Silicium
firmware volume can be dropped into `boot_b` and driven from there.

This repository is the firmware companion of the E5 bring-up work. It is **not** a
finished port — read [Status](#status) before flashing anything.

## Boot chain

```
bootrom -> FDL (Unisoc download tool) -> uboot partition (LK)
        -> boot_a / boot_b, offset 0x1000
        -> 0x80080000   BootShim (AArch64 Image header + copy loop + watchdog)
        -> 0x80800000   SILICIUM_UEFI.fd (Project Mu / Silicium EDK2 firmware)
```

LK always loads the boot partition's payload to `0x80080000` and jumps to it with
`x0` holding the physical address of the merged vendor FDT (measured on hardware:
`x0 = 0x86000000`). EDK2 needs its firmware volume at `PcdFdBaseAddress`, so
`BootShim` copies the volume to `0x80800000` and branches into SEC, leaving `x0`
intact so SEC can stash it in `gSiliciumEntryArgHobGuid`.

`0x80200000` is **not** usable as the FD base: the shim copies forwards in 16-byte
steps, so a 4 MiB volume overlapping its own source range
(`0x80080000..0x80480000`) would be destroyed while being copied.

## Repository layout

| Path | Purpose |
| --- | --- |
| [Platforms/Unisoc/e5Pkg](Platforms/Unisoc/e5Pkg) | Platform description (`e5.dsc`/`e5.fdf`), component lists, memory map, payload driver |
| [Silicon/Unisoc/UMS9621Pkg](Silicon/Unisoc/UMS9621Pkg) | SoC layer: GIC/timer/core PCDs, UART + ramoops console, GOP driver, bring-up probe |
| [BootShim](BootShim) | Loader that turns the LK handoff into a normal EDK2 entry point |
| [Resources/Scripts](Resources/Scripts) | `mk-boot-payload.py` (shim + FV assembly), `make-e5-adt.py` (Apple device tree) |
| [Resources/Configs/e5.toml](Resources/Configs/e5.toml) | FD base/size and boot image parameters |
| [tools](tools) | Device-side iteration: `e5-uefi-cycle.sh`, `e5-cycle.sh`, `e5-misc.py`, `mkfont.py` |
| [docs](docs) | Hardware facts, bring-up reports, build environment, ADT notes |

Silicium's SEC, DXE core, BDS, DtPlatformDxe, ArmGicDxe, TimerDxe and CpuDxe are used
unmodified; only the SoC and platform layers are new.

## Build

```sh
git clone --recursive https://github.com/Enceka/e5-uefi   # lighter clone: Building.md
cd e5-uefi
./setup_env.sh -p dnf          # apt / dnf / pacman; see Building.md if you have no root
./build_e5.sh DEBUG
```

Products:

| File | Size (this revision) | What it is |
| --- | --- | --- |
| `build/SILICIUM_UEFI.fd` | 4194304 | Raw firmware volume, linked for `0x80800000` |
| `build/BootShim.bin` | 11664 | Loader entered at `0x80080000` |
| `build/e5-uefi.bin` | 4205968 | Shim + FV, the file that goes into `boot_b` |

The EDK2 build is **not byte-reproducible**: `Sec.c` compiles `__TIME__`/`__DATE__`
into the volume, so two builds differ. Compare the per-module `.efi` files under
`Build/e5Pkg/DEBUG_CLANGDWARF/AARCH64/` instead of the images.

`env.sh` derives `WORKSPACE`, `EDK_TOOLS_PATH`, `PACKAGES_PATH` and the toolchain
paths from the repository root; nothing is hard-coded to a home directory.

## Flash

The E5 is an A/B device. The safe pattern, used for every test below, is: write the
payload into `boot_b`, arm `misc` so LK prefers slot B for a bounded number of
tries, and let LK roll back to Android by itself once the tries run out. No recovery
image, no manual rescue.

```sh
tools/e5-uefi-cycle.sh flash     # write payload into boot_b and arm misc for slot B
tools/e5-uefi-cycle.sh collect   # reboot, wait for Android, pull the ramoops console
tools/e5-uefi-cycle.sh run       # both
```

`tries_remaining` must be 2 or more: LK stores the displayed value plus one, so `1`
means "already used up" and drops the board into download mode instead of booting.
The scripts talk to a specific device serial (`adb -s TS30520241202952`) and route
privileged commands through `/debug_ramdisk/su`, because the stock build's adbd
refuses `adb root`. Edit the serial for your own unit.

## Status

| Item | State |
| --- | --- |
| EDK2 + Mu + Silicium toolchain builds the platform | **Verified**, `build_e5.sh DEBUG` produces the 4 MiB FV |
| BootShim is loaded by LK and entered at `0x80080000` | **Verified on hardware** — framebuffer stays scanned out, red/green alternating fill seen by eye |
| SEC starts and prints | **Verified** — the first hardware boot printed `Failed to Configure MMU` to ramoops |
| MemoryMapLib regions | 39 regions, all 4 KiB aligned, no overlaps |
| Watchdog reset path | Verified: `hw_rst_mode == 2`, `hw watchdog int raw status 0x8`; the effective timeout is LK's ~300 s, not the shim's 60 s |
| **MMU configuration completes** | **No.** SEC stops inside `ArmConfigureMmu`; the board is reset by the watchdog in under a second |
| DXE dispatch | Not reached; no DXE log has ever been captured |
| BDS / DarwinBoot / XNU | Not started |
| eMMC storage driver | Not implemented; `SdDxe`/`EmmcDxe`/`Fat` are not in the FV |
| Multi-core DXE | Single core only (`ArmPsciMpServicesDxe` is not in the FV) |

The current in-flight debugging switch is `gEfiMdePkgTokenSpaceGuid.PcdDebugPrintErrorLevel|0x8207EE0F`
in [e5.dsc](Platforms/Unisoc/e5Pkg/e5.dsc): it turns on `DEBUG_PAGING`, which
Silicium suppresses, so that `ArmMmuLibCore.c` prints one line per region and the
hang can be bracketed. It is temporary and marked as such in the source.

**This firmware does not boot to a UEFI shell and XNU does not run on it.**

## Documentation

- [Building.md](Building.md) — Linux build environment, dependency by dependency
- [docs/uefi-bringup.md](docs/uefi-bringup.md) — the UEFI port itself: boot chain, PCDs, build, hardware runs
- [docs/m0-bringup-report.md](docs/m0-bringup-report.md) — bare-metal M0 report: what LK actually hands over
- [docs/research-e5-hardware.md](docs/research-e5-hardware.md) — SoC/board facts, each marked confirmed / inferred / unverified
- [docs/research-xnu-port.md](docs/research-xnu-port.md) — what an XNU port would need
- [docs/adt-e5.md](docs/adt-e5.md) — the Apple device tree format and the E5's values
- [docs/build-linux.md](docs/build-linux.md) — the original Chinese build-environment notes

The documents under `docs/` are in Chinese, as written during the bring-up; this
README and `Building.md` are the English entry points.

## Upstream and licenses

Built on [Microsoft Project Mu](https://github.com/microsoft/mu_basecore)
(`mu_basecore`, `mu_plus`, `mu_oem_sample`, branch `release/202608`) and on
[Project Silicium](https://github.com/Project-Silicium/Mu-Silicium) as vendored by
[UniXNU/uefi-sheng](https://github.com/UniXNU/uefi-sheng), branch `sheng`. The
`sheng` branch is required: its `SiliciumPkg.dec` defines
`gSiliciumEntryArgHobGuid`, which the platform needs to receive `x0`.

| Submodule | Upstream | Commit |
| --- | --- | --- |
| `Mu_Basecore` | microsoft/mu_basecore | `26bfddb2194b2058f7ac6163b00a2d94a9b7eac6` |
| `Common/Mu` | microsoft/mu_plus | `566cf5c8c2c8adf8e1a337ced1d147bc6246856f` |
| `Common/Mu_OEM_Sample` | microsoft/mu_oem_sample | `9292f9254adb94c5e5bb09a370b9662fcd66a953` |
| `Silicon/Silicium` | UniXNU/uefi-sheng (`sheng`) | `0eb4514db0744b8136a3897ab1af93b713c2c27b` |

See [LICENSE](LICENSE) and the individual file headers. Original E5 files are
BSD-2-Clause-Patent; upstream directories can carry other licenses.
