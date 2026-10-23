#!/bin/sh
# Build the E5 UEFI firmware and the boot shim that LK jumps to.
#
# Usage:  ./build_e5.sh [DEBUG|RELEASE]
#
# Output:
#   build/SILICIUM_UEFI.fd   raw firmware volume, linked for 0x80800000
#   build/BootShim.bin       the loader LK actually enters at 0x80080000
#   build/e5-uefi.bin        shim + FV, this is what goes into the boot partition
#
# The EDK2 environment comes from env.sh next to this script; BaseTools and
# Conf/ are prepared automatically on the first run (see Building.md).

set -e

MODE=${1:-DEBUG}

# SELFTEST=1 builds a shim that arms the watchdog and then parks instead of
# entering SEC.  One boot then answers two questions at once: did LK really
# jump to 0x80080000, and does the dead man's switch reset the board.
# Extra flags handed to the assembler, e.g. SHIM_FLAGS="-DNO_WATCHDOG -DSHIM_SELFTEST".
SHIM_EXTRA=${SHIM_FLAGS:-}
if [ "${SELFTEST:-0}" = "1" ]; then
  SHIM_EXTRA="$SHIM_EXTRA -DSHIM_SELFTEST"
  echo "== SELFTEST build: shim parks after arming the watchdog =="
fi
if [ -n "$SHIM_EXTRA" ]; then
  echo "== shim flags:$SHIM_EXTRA"
fi

ROOT=$(cd "$(dirname "$0")" && pwd)
OUT=${E5_BUILD_DIR:-$ROOT/build}

# shellcheck source=env.sh
. "$ROOT/env.sh"

FD_BASE=${E5_FD_BASE:-0x80800000}
FD_SIZE=${E5_FD_SIZE:-0x400000}
FD_BLOCKS=${E5_FD_BLOCKS:-0x400}

# EDK2 wants Conf/{target,tools_def,build_rule}.txt next to WORKSPACE.  This is
# what edksetup.sh does; doing it here keeps "source env.sh" the only setup
# step.  Never overwrite: Conf/ is where local tweaks live.
mkdir -p "$CONF_PATH"
for t in target tools_def build_rule; do
  [ -f "$CONF_PATH/$t.txt" ] || cp "$EDK_TOOLS_PATH/Conf/$t.template" "$CONF_PATH/$t.txt"
done

# mu_basecore puts submodule paths straight into its [Includes] sections, so a
# missing one fails at parse time with "error 000E: File/directory not found".
# Only these five are needed; oniguruma, cmocka, googletest and subhook are not.
MISSING=
for sub in \
  BaseTools/Source/C/BrotliCompress/brotli \
  MdeModulePkg/Library/BrotliCustomDecompressLib/brotli \
  MdePkg/Library/MipiSysTLib/mipisyst \
  MdePkg/Library/BaseFdtLib/libfdt \
  SecurityPkg/DeviceSecurity/SpdmLib/libspdm; do
  [ -n "$(ls -A "$WORKSPACE/Mu_Basecore/$sub" 2>/dev/null)" ] || MISSING="$MISSING $sub"
done
if [ -n "$MISSING" ]; then
  echo "== initializing mu_basecore submodules:$MISSING"
  # Retry: google/brotli occasionally drops TLS mid-fetch.
  for i in 1 2 3; do
    # shellcheck disable=SC2086
    git -C "$WORKSPACE/Mu_Basecore" submodule update --init --depth 1 $MISSING && break
    echo "== retry $i"
    sleep 5
  done
fi

# BaseTools has to be built once, from the workspace root (it bakes the
# workspace path into the generated makefiles).
if [ ! -x "$EDK_TOOLS_BIN/GenFv" ] || [ ! -x "$EDK_TOOLS_BIN/VfrCompile" ]; then
  echo "== building BaseTools =="
  make -C "$EDK_TOOLS_PATH" -j"${E5_JOBS:-$(nproc 2>/dev/null || echo 4)}"
fi

LLVM=${E5_LLVM_BIN:-${CLANGDWARF_BIN:-/usr/bin}}
LLVM=${LLVM%/}
# ld.lld is not always next to clang, ask the environment first.
LD_LLD=${E5_LD_LLD:-$(command -v ld.lld || echo "$LLVM/ld.lld")}
PYTHON=${E5_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}
BUILD_DIR="$WORKSPACE/Build/e5Pkg/${MODE}_CLANGDWARF"

mkdir -p "$OUT"

echo "== building EDK2 platform ($MODE) =="
build -a AARCH64 -t CLANGDWARF -b "$MODE" -p e5Pkg/e5.dsc -n "${E5_JOBS:-8}" \
  -D FD_BASE=$FD_BASE -D FD_SIZE=$FD_SIZE -D FD_BLOCKS=$FD_BLOCKS

FD="$BUILD_DIR/FV/SILICIUM_UEFI.fd"
test -f "$FD"
cp "$FD" "$OUT/SILICIUM_UEFI.fd"

echo "== building boot shim =="
"$LLVM/clang" --target=aarch64-linux-gnu -c "$ROOT/BootShim/BootShim.S" -o "$OUT/BootShim.o" \
  -DFD_BASE=$FD_BASE -DFD_SIZE=$FD_SIZE $SHIM_EXTRA
# The exception reporter.  -mgeneral-regs-only because a fault can be taken
# before SEC has enabled FP/SIMD, so the handler may not touch those registers.
# -ffreestanding/-nostdlib because there is no libc at 0x80080000; the file
# carries its own memset-free helpers.  Built -fno-pic so that no relocation
# survives into the fixed-address image.
# -mstrict-align: the handler runs with the MMU off, so every access is Device
# memory and an unaligned store is an alignment fault.  Without this the
# compiler emits "stur x8, [sp, #4]" for the record buffer and the handler
# faults on its own stack -- reproduced in qemu.
# -ffunction-sections/-fdata-sections: BootShim.ld has to be able to place every
# piece of it ahead of _Payload, which must stay the last byte of the image.
"$LLVM/clang" --target=aarch64-linux-gnu -c "$ROOT/BootShim/BootShimExc.c" \
  -o "$OUT/BootShimExc.o" -ffreestanding -nostdlib -fno-pic -fno-stack-protector \
  -fno-asynchronous-unwind-tables -ffunction-sections -fdata-sections \
  -mstrict-align -mgeneral-regs-only -O2 \
  -I"$ROOT/Silicon/Unisoc/UMS9621Pkg/Library/SprdDebugSerialPortLib"
"$LD_LLD" -T "$ROOT/BootShim/BootShim.ld" -o "$OUT/BootShim.elf" "$OUT/BootShim.o" "$OUT/BootShimExc.o"
"$LLVM/llvm-objcopy" -O binary "$OUT/BootShim.elf" "$OUT/BootShim.bin"

echo "== assembling boot image payload =="
"$PYTHON" "$ROOT/Resources/Scripts/mk-boot-payload.py" "$OUT/BootShim.bin" "$OUT/SILICIUM_UEFI.fd" "$OUT/e5-uefi.bin"

ls -l "$OUT"
