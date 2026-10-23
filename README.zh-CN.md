# 荣悦 E5（Unisoc UMS9621）UEFI

<p align="center"><a href="README.md">English</a> · <strong>简体中文</strong></p>

这是**荣悦 E5** 的 UEFI 固件移植仓库。E5 是一台基于紫光展锐 **UMS9621**（Qogirn6lite）
的 Android 手机，板级名 `ums9158_1h10`。这块板子上没有 UEFI 固件：原厂引导器把 boot 分区
偏移 `0x1000` 的内容装到 `0x80080000` 就跳过去，所以只要把「一小段搬运器 + Project Mu /
Project Silicium 的固件卷」写进 `boot_b`，就能把 UEFI 跑起来。

本仓库是 E5 移植工作的固件配套仓库，**不是一个完成的移植**——刷机前请先看
[当前状态](#当前状态)。

## 引导链

```
bootrom -> FDL（展锐下载工具）-> uboot 分区（LK）
        -> boot_a / boot_b 偏移 0x1000
        -> 0x80080000   BootShim（AArch64 Image 头 + 拷贝循环 + 看门狗布置）
        -> 0x80800000   SILICIUM_UEFI.fd（Project Mu / Silicium 的 EDK2 固件）
```

LK 永远把 boot 分区的负载装到 `0x80080000` 并跳过去，`x0` 是合并后的 vendor FDT
物理地址（实机实测 `x0 = 0x86000000`）。EDK2 的固件卷必须落在 `PcdFdBaseAddress`，
所以 `BootShim` 先把固件卷搬到 `0x80800000` 再跳进 SEC，并保留 `x0`，让 SEC 把它塞进
`gSiliciumEntryArgHobGuid`。

FD 不能放在 `0x80200000`：shim 以 16 字节为单位**向前**拷贝，4 MiB 的卷会落进自己的源
区间 `0x80080000..0x80480000`，边拷边把自己覆盖掉。

## 仓库结构

| 路径 | 用途 |
| --- | --- |
| [Platforms/Unisoc/e5Pkg](Platforms/Unisoc/e5Pkg) | 平台描述（`e5.dsc`/`e5.fdf`）、组件清单、整机内存图、payload 驱动 |
| [Silicon/Unisoc/UMS9621Pkg](Silicon/Unisoc/UMS9621Pkg) | SoC 层：GIC／定时器／核数 PCD、UART + ramoops 双通道控制台、自写 GOP、bring-up 探针 |
| [BootShim](BootShim) | 把 LK 的交接契约变成标准 EDK2 入口的搬运器 |
| [Resources/Scripts](Resources/Scripts) | `mk-boot-payload.py`（shim 与 FV 拼接）、`make-e5-adt.py`（Apple 设备树） |
| [Resources/Configs/e5.toml](Resources/Configs/e5.toml) | FD 基址／大小与 boot image 参数 |
| [tools](tools) | 实机迭代工具：`e5-uefi-cycle.sh`、`e5-cycle.sh`、`e5-misc.py`、`mkfont.py` |
| [docs](docs) | 硬件事实、bring-up 报告、构建环境、ADT 记录 |

Silicium 自带的 SEC、DXE core、BDS、DtPlatformDxe、ArmGicDxe、TimerDxe、CpuDxe 全部原样
复用，新增的只有 SoC 与平台两层。

## 构建

```sh
git clone --recursive https://github.com/Enceka/e5-uefi
cd e5-uefi
./setup_env.sh -p dnf          # apt / dnf / pacman；没有 root 见 Building.md
./build_e5.sh DEBUG
```

产物：

| 文件 | 本轮大小 | 说明 |
| --- | --- | --- |
| `build/SILICIUM_UEFI.fd` | 4194304 | 原始固件卷，按 `0x80800000` 链接 |
| `build/BootShim.bin` | 11664 | 在 `0x80080000` 被进入的搬运器 |
| `build/e5-uefi.bin` | 4205968 | shim + FV，写进 `boot_b` 的就是它 |

EDK2 这一侧**不是字节可复现**的：`Sec.c` 把 `__TIME__`/`__DATE__` 编进固件卷，两次构建
必然不同。要比对就比 `Build/e5Pkg/DEBUG_CLANGDWARF/AARCH64/` 下各模块的 `.efi`。

`env.sh` 里的 `WORKSPACE`、`EDK_TOOLS_PATH`、`PACKAGES_PATH` 与工具链路径全部由仓库
根目录推导，没有任何写死的家目录。

## 刷机

E5 是 A/B 设备。所有实机试验都用同一个安全套路：把负载写进 `boot_b`，改 `misc` 让 LK
优先选 slot B 若干次，次数用完 LK 自己回滚到 Android。不需要 recovery 镜像，也不需要
手动救砖。

```sh
tools/e5-uefi-cycle.sh flash     # 写 boot_b，并把 misc 布置成选 slot B
tools/e5-uefi-cycle.sh collect   # 重启、等 Android 回来、取 ramoops console
tools/e5-uefi-cycle.sh run       # 两步一起做
```

`tries_remaining` 必须 ≥ 2：LK 存的是「显示值 + 1」，写 1 等于「已经用完」，会直接进
下载模式而不是启动。脚本里的设备序列号（`adb -s TS30520241202952`）和
`/debug_ramdisk/su` 都是本机实测值——原厂 adbd 拒绝 `adb root`——换机器要自己改。

## 当前状态

| 项 | 状态 |
| --- | --- |
| EDK2 + Mu + Silicium 构建链 | **已验证**，`build_e5.sh DEBUG` 产出 4 MiB 固件卷 |
| LK 确实跳到 `0x80080000` | **实机验证**——交接后帧缓冲仍在扫描输出，红绿交替铺满整屏，人眼确认 |
| SEC 跑起来并打印 | **已验证**——第一次实机就打到 `Failed to Configure MMU`（ramoops） |
| MemoryMapLib 内存图 | 39 个 region，全部 4 KiB 对齐，无重叠 |
| 看门狗复位路径 | 已验证：`hw_rst_mode == 2`、`hw watchdog int raw status 0x8`；真正生效的是 LK 留下的约 300 秒，不是 shim 的 60 秒 |
| **MMU 配置是否完成** | **否。** SEC 停在 `ArmConfigureMmu` 里，不到 1 秒就被看门狗复位 |
| DXE 派发 | 未到达，至今没拿到任何 DXE 日志 |
| BDS / DarwinBoot / XNU | 未启用 |
| eMMC 存储驱动 | 未实现，`SdDxe`/`EmmcDxe`/`Fat` 没有挂进 FV |
| 多核 DXE | 只有单核（FV 里没有 `ArmPsciMpServicesDxe`） |

当前在飞的调试开关是 [e5.dsc](Platforms/Unisoc/e5Pkg/e5.dsc) 里的
`gEfiMdePkgTokenSpaceGuid.PcdDebugPrintErrorLevel|0x8207EE0F`：它打开 Silicium 原本压掉的
`DEBUG_PAGING`，让 `ArmMmuLibCore.c` 每个 region 打一行，用来夹出挂死点。这是临时开关，
源码里已经标注。

**这套固件不会启动到 UEFI Shell，XNU 也没有在它上面跑起来。**

## 文档

- [Building.md](Building.md) — Linux 构建环境，逐个依赖说明
- [docs/uefi-bringup.md](docs/uefi-bringup.md) — UEFI 移植本身：引导链、PCD、构建、实机记录
- [docs/m0-bringup-report.md](docs/m0-bringup-report.md) — M0 裸机实测：LK 到底交接了什么
- [docs/research-e5-hardware.md](docs/research-e5-hardware.md) — SoC／板级事实，每条标注已确认／推断／未验证
- [docs/research-xnu-port.md](docs/research-xnu-port.md) — XNU 移植需要什么
- [docs/adt-e5.md](docs/adt-e5.md) — Apple 设备树格式与 E5 的取值
- [docs/build-linux.md](docs/build-linux.md) — 构建环境的原始中文记录

## 上游与许可证

基于 [Microsoft Project Mu](https://github.com/microsoft/mu_basecore)（`mu_basecore`、
`mu_plus`、`mu_oem_sample`，分支 `release/202608`）与
[Project Silicium](https://github.com/Project-Silicium/Mu-Silicium)（经
[UniXNU/uefi-sheng](https://github.com/UniXNU/uefi-sheng) 的 `sheng` 分支引入）。必须用
`sheng` 分支：只有它的 `SiliciumPkg.dec` 定义了 `gSiliciumEntryArgHobGuid`，平台靠这个
HOB 拿到 `x0`。

| 子模块 | 上游 | 提交 |
| --- | --- | --- |
| `Mu_Basecore` | microsoft/mu_basecore | `26bfddb2194b2058f7ac6163b00a2d94a9b7eac6` |
| `Common/Mu` | microsoft/mu_plus | `566cf5c8c2c8adf8e1a337ced1d147bc6246856f` |
| `Common/Mu_OEM_Sample` | microsoft/mu_oem_sample | `9292f9254adb94c5e5bb09a370b9662fcd66a953` |
| `Silicon/Silicium` | UniXNU/uefi-sheng（`sheng`） | `0eb4514db0744b8136a3897ab1af93b713c2c27b` |

许可见 [LICENSE](LICENSE) 与各文件头。E5 原创文件采用 BSD-2-Clause-Patent，上游目录可能
带有包括 GPL 在内的其他许可证。
