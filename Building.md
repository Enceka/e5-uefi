# Building

> [!TIP]
> A Linux host is the supported path. Everything below was verified on
> Fedora 44 x86_64 with clang 22; the macOS notes at the end are what the port
> was originally written on.

## 1. Clone the source code

```sh
git clone --recursive https://github.com/Enceka/e5-uefi
cd e5-uefi
```

The four submodules are large (mu_basecore alone is several hundred MB), so the
download dominates the first build. If you forgot `--recursive`:

```sh
git submodule update --init --recursive
```

### `Mu_Basecore` needs five more submodules

`mu_basecore` lists submodule paths directly in its `[Includes]` sections, so a
missing one fails at the *parse* stage with
`error 000E: File/directory not found` rather than at compile time:

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

The first two are `google/brotli` and are also needed by the `BrotliCompress`
BaseTool and by FV compression. `oniguruma`, `cmocka`, `googletest` and
`subhook` are not needed for this platform and can stay empty.

This is the one step that fails at random: `github.com/google/brotli` sometimes
drops TLS mid-fetch. Retry, or fetch the single commit directly:

```sh
cd BaseTools/Source/C/BrotliCompress/brotli
for i in 1 2 3 4 5; do
  git fetch --depth 1 origin e230f474b87134e8c6c85b630084c612057f253e && \
    git checkout -q e230f474b87134e8c6c85b630084c612057f253e && break
  sleep 5
done
```

### `Silicon/Silicium` must be the `sheng` branch

`uefi-sheng`'s `main` branch does **not** define `gSiliciumEntryArgHobGuid` in
`SiliciumPkg.dec`, and its `Sec.c` does not record `x0`, so the build dies with

```
E5PayloadDxe.inf(45): error 4000: Value of Guid [gSiliciumEntryArgHobGuid] is not found under [Guids] section
```

The `.gitmodules` in this repository already pins `branch = sheng` and the
`0eb4514db0744b8136a3897ab1af93b713c2c27b` commit, so a normal
`git clone --recursive` gives you the right tree. If you have to fetch it by
hand and want to save bandwidth, only `Silicon/Silicium` is used:

```sh
git clone --filter=blob:none --no-checkout https://github.com/UniXNU/uefi-sheng \
  Silicon/Silicium
cd Silicon/Silicium
git sparse-checkout init --cone
git sparse-checkout set Silicon/Silicium
git checkout sheng
```

If GitHub is unreachable, prefix the URL with `https://gh-proxy.com/`.

## 2. Install the host dependencies

```sh
./setup_env.sh -p dnf        # Fedora / RHEL
./setup_env.sh -p apt        # Debian / Ubuntu
./setup_env.sh -p pacman     # Arch
```

That installs what the build actually uses:

| Dependency | Needed for |
| --- | --- |
| `clang`, `lld`/`ld.lld`, `llvm` (`llvm-ar`, `llvm-objcopy`, `llvm-rc`) | CLANGDWARF toolchain, and the BootShim link |
| `nasm` | BaseTools / ACPI table assembly |
| `iasl` (acpica-tools) | `AcpiTableDxe`'s ASL build |
| `libuuid` + `uuid/uuid.h` | BaseTools (`GenFv`, `VfrCompile` link with `-luuid`) |
| `python3`, `python3-pip` | `build` wrapper, EDK2 Python, the payload scripts |
| `make`, `gcc`, `build-essential` | BaseTools C tools |

The pip modules in `pip-requirements.txt` are optional for this platform — the
build works without them — but `setup_env.sh` installs them anyway.

### iasl, nasm and libuuid without root

If you cannot install system packages, unpack the three RPMs into a
repository-local directory instead. `env.sh` picks it up automatically and
nothing outside the repository is touched:

```sh
mkdir -p .deps/rpms
# put acpica-tools, nasm and libuuid-devel RPMs there, then:
./setup_env.sh --local-deps
```

The three failure modes this works around, in the order you would hit them:

1. **`cannot find -luuid`** when `make -C BaseTools` links `GenFv`/`VfrCompile`.
   `libuuid.so` is a devel-package symlink; the system only has
   `libuuid.so.1.3.0`. `setup_env.sh --local-deps` recreates the symlink and
   `env.sh` adds the directory to `EXTRA_LDFLAGS`.
2. **`uuid/uuid.h` not found** — `env.sh` adds `usr/include` to `CPATH`.
3. **`brotli/c/include` not found** — the brotli submodules from section 1.

Point `E5_LOCAL_DEPS` at a different directory if you keep the unpacked tree
somewhere else.

## 3. Build

```sh
./build_e5.sh DEBUG
```

The script sources `env.sh`, seeds `Conf/{target,tools_def,build_rule}.txt` from
the BaseTools templates on first run, builds BaseTools if
`BaseTools/Source/C/bin/GenFv` is missing, then:

1. `build -a AARCH64 -t CLANGDWARF -b DEBUG -p e5Pkg/e5.dsc -n 8`
   `-D FD_BASE=0x80800000 -D FD_SIZE=0x400000 -D FD_BLOCKS=0x400`;
2. copies `Build/e5Pkg/DEBUG_CLANGDWARF/FV/SILICIUM_UEFI.fd` to `build/`;
3. compiles `BootShim/BootShim.S` and `BootShim/BootShimExc.c` for
   `aarch64-linux-gnu`, links them with `ld.lld -T BootShim/BootShim.ld` to
   `0x80080000`, and produces `BootShim.bin`;
4. runs `Resources/Scripts/mk-boot-payload.py`, which checks the `ARMd` magic,
   back-fills `image_size` in the Image header and concatenates shim + FV.

A successful run ends like this:

```
FVMAIN [99%Full] 2207744 (0x21b000) total, 2207736 (0x21aff8) used, 8 (0x8) free
FVMAIN_COMPACT [9%Full] 4194304 (0x400000) total, 413488 (0x64f30) used, 3780816 (0x39b0d0) free

- Done -
== building boot shim ==
== assembling boot image payload ==
shim 11664 bytes, firmware 4194304 bytes, payload 4205968 bytes
```

`WORKSPACE` defaults to the repository root, so `Conf/` and `Build/` land there;
both are in `.gitignore`.

### Environment knobs

| Variable | Default | Meaning |
| --- | --- | --- |
| `WORKSPACE` | repository root | where `Conf/` and `Build/` live |
| `EDK_TOOLS_PATH` | `$WORKSPACE/Mu_Basecore/BaseTools` | BaseTools location |
| `CLANGDWARF_BIN` | `/usr/bin/` | clang, llvm-ar, llvm-objcopy, llvm-rc |
| `E5_LD_LLD` | `ld.lld` from `PATH` | linker used for the shim |
| `E5_LOCAL_DEPS` | `<repo>/.deps/local` | unpacked iasl/nasm/libuuid |
| `E5_BUILD_DIR` | `<repo>/build` | where the three artifacts are written |
| `E5_FD_BASE` / `E5_FD_SIZE` / `E5_FD_BLOCKS` | `0x80800000` / `0x400000` / `0x400` | fdf macros |
| `E5_JOBS` | `nproc` (EDK2: 8) | parallelism |
| `SELFTEST=1` | off | shim arms the watchdog and parks instead of entering SEC |
| `SHIM_FLAGS` | empty | extra assembler flags, e.g. `-DNO_WATCHDOG -DSHIM_SELFTEST` |

`FD_BASE`, `FD_SIZE` and `FD_BLOCKS` are fdf macros and must reach `build` as
`-D` options; a bare `build` without them fails with
`expected Hex base address near line 22`.

`-D CLANG`, `-D ENABLE_SECUREBOOT=0` and `-fno-stack-protector` are already set
in `Silicon/Unisoc/UMS9621Pkg/UMS9621Pkg.dsc.inc`; you do not pass them again.

## 4. Verify the artifacts

```sh
cd build
wc -c SILICIUM_UEFI.fd              # 4194304
SHIM=$(wc -c < BootShim.bin)        # 11664
wc -c e5-uefi.bin                   # $SHIM + 4194304 = 4205968
xxd -l 4 -p e5-uefi.bin             # 10000014  -> b _Start
xxd -s 0x10 -l 4 -p e5-uefi.bin     # image_size, back-filled total length
xxd -s 0x38 -l 4 e5-uefi.bin        # ARMd
xxd -s 8 -l 8 -p e5-uefi.bin        # 00000800 00000000 -> text_offset 0x80000
grep -abo _FVH e5-uefi.bin          # $SHIM + 0x28: the FV header sits right after the shim
cmp -n 4194304 -i $SHIM:0 e5-uefi.bin SILICIUM_UEFI.fd   # plain concatenation
VolInfo SILICIUM_UEFI.fd            # Signature _FVH
llvm-objdump -f BootShim.elf        # start address: 0x0000000080080000
```

Use `llvm-objdump`, not GNU `objdump`: a host `objdump` without the AArch64
backend reports `can't disassemble for architecture UNKNOWN!`. The first words
must be the AArch64 Image header and `b _Start`:

```
0000000080080000 <_Head>:
80080000: 14000010      b       0x80080040 <_Start>
80080008: 00 00 08 00   .word   0x00080000
80080038: 41 52 4d 64   .word   0x644d5241
```

## 5. Reproducibility

Two consecutive builds of the same tree produce different `e5-uefi.bin`: `Sec.c`
compiles `__TIME__`/`__DATE__` into the volume and that lands inside the
compressed `FVMAIN_COMPACT`. Do not use binary comparison to decide whether a
code change took effect; compare the per-module `.efi` files under
`Build/e5Pkg/DEBUG_CLANGDWARF/AARCH64/`.

## 6. Common failures

| Symptom | Cause |
| --- | --- |
| `build` prints only `- Failed -`, no error | `PACKAGES_PATH` is missing a package root, or points at `Platforms/` instead of `Platforms/Unisoc` |
| `error 4000: ... gSiliciumEntryArgHobGuid` | `Silicon/Silicium` is on `main` instead of `sheng` |
| `error 0001: File open failure` | `Conf/build_rule.txt` missing — the script seeds it, check `CONF_PATH` |
| `error 000E: File/directory not found` (`mipisyst`, `libfdt`, `libspdm`) | mu_basecore submodules from section 1 |
| `cannot find -luuid` | libuuid devel files — section 2 |
| `cp: ... *.pdb: No such file or directory` | harmless: CLANGDWARF produces no pdb, the rule is ignored |
| `ArmPsciResetSystemLib.inf does not support LIBRARY_CLASS HwResetSystemLib` | harmless Silicium warning |

## 7. macOS notes

The port was originally built on macOS with Homebrew LLVM:

- `CLANGDWARF_BIN=/opt/homebrew/opt/llvm/bin/`;
- `ld.lld` is **not** in that prefix, it lives in `/opt/homebrew/bin/ld.lld` —
  set `E5_LD_LLD`;
- `build`'s shebang is `env python`, which does not exist on a stock macOS;
  either set `PYTHON_COMMAND=python3` (what `env.sh` does) or wrap it in a
  `#!/bin/sh` script that `exec`s `python3`;
- linker scripts accept `/* */` comments only, never `//`.
