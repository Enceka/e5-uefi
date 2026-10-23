# 在 Linux 上构建 E5 的 EDK2 固件

> **说明**：本文是 E5 构建环境最早的中文记录，其中的 `~/e5uefi/*` 目录布局
> 已被 git 子模块取代。当前仓库的实际做法（`env.sh` 相对仓库根推导一切、
> `build_e5.sh` 自动补 `Conf/` 与 BaseTools）见 [Building.md](../Building.md)；
> 下文保留原样作为踩坑记录。


这份文档记录的是「一台干净的 Linux 机器（Fedora 44 x86_64，无 sudo 密码）
怎么从零把 `./build_e5.sh DEBUG` 跑通」，以及每一步踩过的坑。英文版见
[Building.md](../Building.md)。

结论先放这里：**构建本身没有任何 C 源码改动**，`Silicon/Unisoc/UMS9621Pkg/`、
`Platforms/Unisoc/e5Pkg/`、`BootShim/` 都是原样。所有工作量都在
「把依赖仓、工具链和 workspace 摆到位」。

## 一、本仓库的布局

四个 EDK2 依赖仓已经变成 git 子模块，不再散落在仓库外的目录里：

| 子模块路径 | 仓库 | 分支 |
| --- | --- | --- |
| `Mu_Basecore` | `microsoft/mu_basecore` | `release/202608` |
| `Common/Mu` | `microsoft/mu_plus` | `release/202608` |
| `Common/Mu_OEM_Sample` | `microsoft/mu_oem_sample` | `release/202608` |
| `Silicon/Silicium` | `UniXNU/uefi-sheng` | **`sheng`** |

`git clone --recursive` 之后就是全部源码。`env.sh` 把 `WORKSPACE` 设成仓库根，
`Conf/` 和 `Build/` 都落在那里（两者都在 `.gitignore` 里）。

## 二、`Mu_Basecore` 必须补子模块

`mu_basecore` 的 `MdePkg.dec` / `SecurityPkg.dec` 直接把子模块路径写进了
`[Includes]`，缺一个 `build` 就在**解析阶段**报 `error 000E: File/directory not
found`（而不是编译时才炸）：

```sh
cd Mu_Basecore
git submodule update --init --depth 1 \
  BaseTools/Source/C/BrotliCompress/brotli \
  MdeModulePkg/Library/BrotliCustomDecompressLib/brotli \
  MdePkg/Library/MipiSysTLib/mipisyst \
  MdePkg/Library/BaseFdtLib/libfdt \
  SecurityPkg/DeviceSecurity/SpdmLib/libspdm
cd ..
```

前两个是 google/brotli（`e230f47`），BaseTools 的 BrotliCompress 和 FV 压缩都要它；
`mipisyst` / `libfdt` / `libspdm` 只是 `[Includes]` 里挂着的路径，用到与否都得在。
剩下的 `oniguruma` / `cmocka` / `googletest` / `subhook` 可以不拉（本次没拉，构建通过）。

这一步是本流程里唯一会随机失败的地方：`github.com/google/brotli` 偶尔 TLS 断连，
`git submodule update` 会报

```
fatal: unable to access 'https://github.com/google/brotli/': TLS connect error: ...
致命错误：获取了子模组路径 '.../brotli'，但是它没有包含 e230f474...。直接获取该提交失败。
```

重试即可，子模块目录已经存在时可以直接补拉那一个 commit：

```sh
cd BaseTools/Source/C/BrotliCompress/brotli
for i in 1 2 3 4 5; do
  git fetch --depth 1 origin e230f474b87134e8c6c85b630084c612057f253e && \
    git checkout -q e230f474b87134e8c6c85b630084c612057f253e && break
  sleep 5
done
```

`MdeModulePkg/Library/BrotliCustomDecompressLib/brotli` 是同一个仓的同一个 commit，同样处理。
`mipisyst` 的 `370b594` 有时也拉不下来，那就从另一份已有的 mu_basecore 里取：

```sh
git fetch --depth 1 file:///path/to/other/mu_basecore/MdePkg/Library/MipiSysTLib/mipisyst 370b5944c046bab043dd8b133727b2135af7747a
```

## 三、`Silicon/Silicium` 必须用 `sheng` 分支

`uefi-sheng` 的 `main`（`3aa95a7`）里 `SiliciumPkg.dec` **没有**
`gSiliciumEntryArgHobGuid`，`Sec.c` 里也没有记录 x0 的那段，构建直接死在

```
E5PayloadDxe.inf(45): error 4000: Value of Guid [gSiliciumEntryArgHobGuid] is not found under [Guids] section
```

`sheng`（`0eb4514`）有：`SiliciumPkg.dec:15` 定义该 GUID，
`Sec/AArch64/ModuleEntryPoint.S` 把 x0 传进 `Sec.c` 再塞进 HOB。平台的
`E5PayloadDxe` 和 `DtPlatformDxe` 都靠这个 HOB 拿设备树。

本仓库的 `.gitmodules` 已经把分支和提交都钉好了，正常 `clone --recursive` 就是对的。
如果只想省流量地手拉这一份（只用到 `Silicon/Silicium`）：

```sh
git clone --filter=blob:none --no-checkout https://github.com/UniXNU/uefi-sheng Silicon/Silicium
cd Silicon/Silicium
git sparse-checkout init --cone
git sparse-checkout set Silicon/Silicium
git checkout sheng
```

GitHub 直连不通时把 URL 换成 `https://gh-proxy.com/https://github.com/...`。

## 四、没有 sudo 也要有 iasl / nasm / libuuid

做法是把 RPM 解开到仓库内的 `.deps/local/`，再用环境变量指过去，系统目录一个字节都不动：

```sh
mkdir -p .deps/rpms
# 把 acpica-tools（iasl）、nasm、libuuid-devel 三个 RPM 放进 .deps/rpms
./setup_env.sh --local-deps
```

`setup_env.sh --local-deps` 做的事和手工版本一致：

```sh
cd .deps/local
for r in .deps/rpms/*.rpm; do rpm2cpio "$r" | cpio -idm --quiet; done
# libuuid-devel 里只有 libuuid.so -> libuuid.so.1.3.0 的软链，运行时库在系统里
ln -sfn /usr/lib64/libuuid.so.1.3.0 .deps/local/usr/lib64/libuuid.so.1.3.0
```

三个坑各自的表现：

1. **缺 `-luuid`**：`make -C BaseTools` 在链接 `GenFv`/`VfrCompile` 时
   `cannot find -luuid`。`libuuid.so` 是 devel 包才有的软链，系统里只有
   `libuuid.so.1.3.0`。`env.sh` 会把 `.deps/local/usr/lib64` 加进
   `EXTRA_LDFLAGS`。
2. **缺 `uuid.h`**：`env.sh` 把 `.deps/local/usr/include` 加进 `CPATH`。
3. **缺 brotli 子模块**：`BrotliCompress` 编译时找不到 `brotli/c/include`，先做第二节那步。

目录不在仓库内也没问题：`E5_LOCAL_DEPS=/somewhere/local ./build_e5.sh DEBUG`。

## 五、编译 BaseTools

`build_e5.sh` 会自己检查 `BaseTools/Source/C/bin/GenFv`，缺了就编译一次（必须在
workspace 根上编，生成的 makefile 里会写死路径）。手工版本：

```sh
. ./env.sh
make -C "$EDK_TOOLS_PATH" -j8
```

产物在 `Mu_Basecore/BaseTools/Source/C/bin/`：BrotliCompress、EfiRom、GenCrc32、GenFfs、
GenFv、GenFw、GenSec、GenStm、LzmaCompress、TianoCompress、VfrCompile、VolInfo、DevicePath。

## 六、workspace 与环境脚本

EDK2 要求 `WORKSPACE` 旁边有 `Conf/`，里面是 `target.txt` / `tools_def.txt` /
`build_rule.txt`。`edksetup.sh` 干的就是把 `BaseTools/Conf/*.template` 复制过去；
`build_e5.sh` 把同一件事做了，所以「source 一下 env.sh」就是全部准备：

```sh
. ./env.sh
```

`env.sh` 设的变量（这个文件在仓库里，可以直接读）：

| 变量 | 默认值 | 为什么 |
| --- | --- | --- |
| `E5_REPO` | 由脚本位置推导 | 仓库根 |
| `WORKSPACE` | `$E5_REPO` | 放 `Conf/` 和 `Build/` |
| `EDK_TOOLS_PATH` | `$WORKSPACE/Mu_Basecore/BaseTools` | 指向子模块里的 BaseTools |
| `EDK_TOOLS_BIN` | `$EDK_TOOLS_PATH/Source/C/bin` | 上面编出来的 C 工具 |
| `CONF_PATH` | `$WORKSPACE/Conf` | EDK2 优先读这个环境变量 |
| `PACKAGES_PATH` | Platforms/Unisoc + Silicon/Unisoc + Silicon/Silicium + Mu_Basecore + Common/Mu + Common/Mu_OEM_Sample | **少一个就 `- Failed -` 且不打印任何错误** |
| `CLANGDWARF_BIN` / `CLANG_BIN` | `/usr/bin/` | CLANGDWARF 的 clang / llvm-ar / llvm-objcopy 都在这 |
| `PATH` | C 工具 + BinWrappers/PosixLike（+ `.deps/local/usr/bin`） | iasl、nasm、`build` |
| `CPATH` / `LIBRARY_PATH` / `EXTRA_LDFLAGS` | `.deps/local/usr/...` | libuuid |
| `PYTHON_COMMAND` | `python3` | `build` 的 shebang 是 `env python`，Fedora 只有 `python3` |
| `E5_FD_BASE/SIZE/BLOCKS` | 0x80800000 / 0x400000 / 0x400 | 见第八节 |

注意 `PACKAGES_PATH` 里那两个 E5 包根目录要写成 **`Platforms/Unisoc`** 和
**`Silicon/Unisoc`**，不是 `Platforms/`：`e5Pkg/e5.dsc` 里
`FLASH_DEFINITION = e5Pkg/e5.fdf`、`!include UMS9621Pkg/UMS9621Pkg.dsc.inc` 都是从这两个
根算相对路径的。写成上一层的话 `build` 只吐一行 `- Failed -`，**没有任何报错**，
这是最容易浪费半小时的地方。

## 七、构建

```sh
./build_e5.sh DEBUG
```

脚本先 `. ./env.sh`，补 `Conf/`，必要时编 BaseTools，然后：

1. `build -a AARCH64 -t CLANGDWARF -b DEBUG -p e5Pkg/e5.dsc -n 8`
   `-D FD_BASE=0x80800000 -D FD_SIZE=0x400000 -D FD_BLOCKS=0x400`；
2. 把 `$WORKSPACE/Build/e5Pkg/DEBUG_CLANGDWARF/FV/SILICIUM_UEFI.fd` 拷到
   `build/SILICIUM_UEFI.fd`；
3. 编 `BootShim/BootShim.S`（`--target=aarch64-linux-gnu`）和
   `BootShim/BootShimExc.c`，用 `ld.lld -T BootShim/BootShim.ld` 链到
   `0x80080000`，`llvm-objcopy -O binary` 出 `BootShim.bin`；
4. `Resources/Scripts/mk-boot-payload.py` 校验 `ARMd`、回填 Image 头的
   `image_size`、把 shim 与 FD 纯拼接成 `build/e5-uefi.bin`。

成功时尾部长这样：

```
FVMAIN [99%Full] 2207744 (0x21b000) total, 2207736 (0x21aff8) used, 8 (0x8) free
FVMAIN_COMPACT [9%Full] 4194304 (0x400000) total, 413488 (0x64f30) used, 3780816 (0x39b0d0) free

- Done -
== building boot shim ==
== assembling boot image payload ==
shim 11664 bytes, firmware 4194304 bytes, payload 4205968 bytes
```

几个开关不变：`SELFTEST=1`、`SHIM_FLAGS=...`（见 `docs/uefi-bringup.md` 9.3），
`E5_FD_BASE/SIZE/BLOCKS` 覆盖 fdf 宏，`E5_LOCAL_DEPS` 换依赖目录，
`E5_BUILD_DIR` 换产物目录。

### 7.1 `-D CLANG -D ENABLE_SECUREBOOT=0` 与 `-fno-stack-protector`

这三样写在 `UMS9621Pkg.dsc.inc:19-20`，本次构建确认生效（编译命令行里能看到）：

```
-fno-stack-protector -D CLANG -D ENABLE_SECUREBOOT=0
```

所以**不需要**在命令行重复传，也不需要改 C 源码。

## 八、产物校验

```sh
cd build
wc -c SILICIUM_UEFI.fd          # 4194304
SHIM=$(wc -c < BootShim.bin)    # 11664
wc -c e5-uefi.bin               # $SHIM + 4194304 = 4205968
xxd -l 4 -p e5-uefi.bin         # 10000014   b _Start
xxd -s 0x10 -l 4 -p e5-uefi.bin # image_size（回填后的总长）
xxd -s 0x38 -l 4 e5-uefi.bin    # ARMd
xxd -s 8 -l 8 -p e5-uefi.bin    # 00000800 00000000  text_offset = 0x80000
grep -abo _FVH e5-uefi.bin      # $SHIM + 0x28，FV 头正好在 shim 之后
cmp -n 4194304 -i $SHIM:0 e5-uefi.bin SILICIUM_UEFI.fd   # 纯拼接，无额外封装
VolInfo SILICIUM_UEFI.fd        # Signature _FVH，Header Length 0x48，Attributes CFEFF
llvm-objdump -f BootShim.elf    # start address: 0x0000000080080000
llvm-nm BootShim.elf | grep _Start
llvm-objdump -d BootShim.elf | head
```

反汇编要用 `llvm-objdump`：Fedora 的 GNU `objdump` 没编 aarch64 后端，会直接报
`can't disassemble for architecture UNKNOWN!`。反汇编开头应当就是 AArch64 Image 头 +
`b _Start`：

```
0000000080080000 <_Head>:
80080000: 14000010      b       0x80080040 <_Start>
80080004: 00 00 00 00   .word   0x00000000
80080008: 00 00 08 00   .word   0x00080000
...
80080038: 41 52 4d 64   .word   0x644d5241
```

## 九、踩过的坑

1. **`PACKAGES_PATH` 少一层 → `- Failed -` 且无报错**。要 `Platforms/Unisoc` 和
   `Silicon/Unisoc`，不是 `Platforms/`。
2. **`Silicon/Silicium` 用了 `main`** → `error 4000: Value of Guid
   [gSiliciumEntryArgHobGuid] is not found`。改 `sheng` 分支。
3. **`Conf/build_rule.txt` 不存在** → `error 0001: File open failure`。除了
   `target.txt`/`tools_def.txt`，`build_rule.txt` 也要从模板复制（`build_e5.sh`
   现在自动做）。
4. **子模块缺失** → `error 000E: File/directory not found`，报的是
   `MipiSysTLib/mipisyst/library/include`、`DeviceSecurity/SpdmLib/libspdm/include`、
   `BaseFdtLib/libfdt` 之类。按第二节补齐。
5. **BaseTools 链接缺 `-luuid`** → `EXTRA_LDFLAGS` 指向解出来的 `lib64`，
   并且补 `libuuid.so.1.3.0` 软链（devel 包里只有 `libuuid.so`）。
6. **`build` 的 `env python`** → 设 `PYTHON_COMMAND=python3`（Fedora 上 `/usr/bin/python`
   其实存在，但显式设了更稳）。
7. **`/tmp` 是 3.8 GB tmpfs** → 大目录别放 `/tmp`，`Build/` 默认落在仓库根，`/tmp` 只放日志。
8. **`cp: ... *.pdb: 没有那个文件或目录`** → CLANGDWARF 不产生 pdb，make 里这一条是
   被 `(已忽略)` 掉的，不是错误。
9. **`warning: ArmPsciResetSystemLib.inf does not support LIBRARY_CLASS
   HwResetSystemLib`** → Silicium 的旧写法，无害，构建继续。
10. **子模块偶尔拉不下来** → `google/brotli` 的 TLS 断连是本流程里唯一会随机失败的地方，
    重试或按第二节补那一个 commit。
11. **GNU `objdump` 反汇编不了 `BootShim.elf`** → 用 `llvm-objdump`。

## 十、可复现性

同一份源码连编两次 `e5-uefi.bin` 字节不同，第一个差异落在压缩后的 FVMAIN_COMPACT 里，
原因见 `docs/uefi-bringup.md` 第八节（`Sec.c` 把 `__TIME__`/`__DATE__` 编进固件）。
**不要用二进制比对判断代码有没有变**，要比就比 `Build/e5Pkg/DEBUG_CLANGDWARF/AARCH64/`
下各模块的 `.efi`。
