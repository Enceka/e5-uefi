#!/bin/sh
# EDK2 build environment for the Rongyue E5 (Unisoc UMS9621) firmware.
#
# Everything is derived from the location of this file, so the repository can be
# cloned anywhere.  Source it before calling build_e5.sh, or let build_e5.sh
# source it for you:
#
#   . ./env.sh
#   ./build_e5.sh DEBUG
#
# Optional overrides, all of them defaulting to something inside the repository:
#   E5_LOCAL_DEPS   directory holding iasl/nasm/libuuid when they are not
#                   installed system-wide (see Building.md, "No root" section)
#   CLANGDWARF_BIN  directory with clang, llvm-ar, llvm-objcopy, llvm-rc
#   WORKSPACE       EDK2 workspace (Conf/ and Build/ live here)

# Locate the repository root.  When sourced from a shell $0 is the shell
# itself, so fall back to the current directory; refuse to guess if neither
# looks like this repository.
_e5_probe() { [ -f "$1/Platforms/Unisoc/e5Pkg/e5.dsc" ] && printf '%s\n' "$1"; }
_e5_root=
for _e5_cand in "${BASH_SOURCE%/*}" "${0%/*}" "$PWD" "$(pwd)"; do
  [ -n "$_e5_cand" ] || continue
  _e5_root=$(_e5_probe "$(cd "$_e5_cand" 2>/dev/null && pwd)")
  [ -n "$_e5_root" ] && break
done
if [ -z "$_e5_root" ]; then
  echo "env.sh: cannot locate the e5-uefi tree; source it from the repository or run build_e5.sh" >&2
  return 1 2>/dev/null || exit 1
fi
E5_REPO=$_e5_root
export E5_REPO

# EDK2 workspace.  The repository root works: it already carries the two
# package roots (Platforms/Unisoc, Silicon/Unisoc) and the submodules.
export WORKSPACE=${WORKSPACE:-$E5_REPO}
export EDK_TOOLS_PATH=${EDK_TOOLS_PATH:-$WORKSPACE/Mu_Basecore/BaseTools}
export EDK_TOOLS_BIN=$EDK_TOOLS_PATH/Source/C/bin
export CONF_PATH=${CONF_PATH:-$WORKSPACE/Conf}

# Every package root the platform DSC refers to.  A missing entry makes "build"
# print "- Failed -" with no error message at all, so the list has to be
# complete.  Note the two Unisoc roots are the *package* roots, not
# Platforms/ and Silicon/: e5.dsc says "FLASH_DEFINITION = e5Pkg/e5.fdf" and
# "!include UMS9621Pkg/UMS9621Pkg.dsc.inc", both resolved from there.
#
# Silicon/Silicium is the uefi-sheng repository itself, so the SiliciumPkg
# package root sits two levels down inside it.
export PACKAGES_PATH=$WORKSPACE/Platforms/Unisoc\
:$WORKSPACE/Silicon/Unisoc\
:$WORKSPACE/Silicon/Silicium/Silicon/Silicium\
:$WORKSPACE/Mu_Basecore\
:$WORKSPACE/Common/Mu\
:$WORKSPACE/Common/Mu_OEM_Sample

# CLANGDWARF toolchain.  clang, llvm-ar, llvm-objcopy, llvm-rc and ld.lld are
# all in /usr/bin on Fedora/Debian; set CLANGDWARF_BIN for a Homebrew or a
# custom LLVM prefix.
export CLANGDWARF_BIN=${CLANGDWARF_BIN:-/usr/bin/}
export CLANG_BIN=${CLANG_BIN:-$CLANGDWARF_BIN}

# Optional self-contained dependencies.  When the RPMs from Building.md have
# been unpacked into $E5_LOCAL_DEPS/usr, use them instead of system packages:
# iasl and nasm from PATH, uuid.h from CPATH, libuuid.so from EXTRA_LDFLAGS.
E5_LOCAL_DEPS=${E5_LOCAL_DEPS:-$E5_REPO/.deps/local}
if [ -d "$E5_LOCAL_DEPS/usr" ]; then
  export PATH=$E5_LOCAL_DEPS/usr/bin:$PATH
  export CPATH=$E5_LOCAL_DEPS/usr/include${CPATH:+:$CPATH}
  export LIBRARY_PATH=$E5_LOCAL_DEPS/usr/lib64${LIBRARY_PATH:+:$LIBRARY_PATH}
  export EXTRA_LDFLAGS="-L$E5_LOCAL_DEPS/usr/lib64${EXTRA_LDFLAGS:+ $EXTRA_LDFLAGS}"
fi

# BaseTools C tools, the EDK2 Python wrappers (that is where "build" lives).
export PATH=$EDK_TOOLS_BIN:$EDK_TOOLS_PATH/BinWrappers/PosixLike:$PATH

# The BinWrappers exec "python" unless PYTHON_COMMAND is set; most
# distributions only ship python3.
export PYTHON_COMMAND=${PYTHON_COMMAND:-python3}

# FD geometry.  These are fdf macros and must reach "build" as -D options;
# build_e5.sh passes them through.
export E5_FD_BASE=${E5_FD_BASE:-0x80800000}
export E5_FD_SIZE=${E5_FD_SIZE:-0x400000}
export E5_FD_BLOCKS=${E5_FD_BLOCKS:-0x400}
