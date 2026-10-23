#!/bin/bash
#
# Install the host packages the E5 UEFI build needs, or unpack the three
# binaries that are only needed as binaries into a repository-local directory
# when root is not available.
#
# Usage:
#   ./setup_env.sh -p apt|dnf|pacman     install system packages and pip modules
#   ./setup_env.sh --local-deps          unpack iasl/nasm/libuuid into .deps/local
#   ./setup_env.sh -h                    this help
#
# See Building.md for the full explanation of every step.

set -o pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOCAL_DEPS="${E5_LOCAL_DEPS:-$HERE/.deps/local}"
RPM_DIR="${E5_RPM_DIR:-$HERE/.deps/rpms}"

function _help() {
    cat <<'EOF'
Usage: setup_env.sh [OPTION]

  -p, --package-manager PAK   install build packages with apt, dnf or pacman
      --local-deps            unpack iasl, nasm and libuuid into .deps/local
                              instead of installing them system-wide
  -h, --help                  show this help

The local-deps mode expects the RPMs in .deps/rpms (see Building.md); it needs
rpm2cpio and cpio and never writes outside the repository.
EOF
}

function _error() { echo -e "\033[1;31m$*\033[0m" >&2; exit 1; }

function _local_deps() {
    command -v rpm2cpio >/dev/null || _error "rpm2cpio is missing; install rpm-tools or rpm2cpio"
    command -v cpio >/dev/null || _error "cpio is missing; install cpio"
    mkdir -p "$LOCAL_DEPS" "$RPM_DIR"
    shopt -s nullglob
    local rpms=("$RPM_DIR"/*.rpm)
    shopt -u nullglob
    [ ${#rpms[@]} -gt 0 ] || _error "no RPMs in $RPM_DIR (see Building.md, 'iasl, nasm and libuuid without root')"
    for r in "${rpms[@]}"; do
        echo "== unpacking $(basename "$r")"
        ( cd "$LOCAL_DEPS" && rpm2cpio "$r" | cpio -idm --quiet ) || _error "failed to unpack $r"
    done
    # libuuid-devel only ships the libuuid.so symlink; the runtime library
    # lives in the system directories.
    mkdir -p "$LOCAL_DEPS/usr/lib64"
    if [ ! -e "$LOCAL_DEPS/usr/lib64/libuuid.so.1.3.0" ]; then
        for candidate in /usr/lib64/libuuid.so.1.3.0 /usr/lib/libuuid.so.1.3.0 /usr/lib64/libuuid.so.1; do
            if [ -e "$candidate" ]; then
                ln -sfn "$candidate" "$LOCAL_DEPS/usr/lib64/libuuid.so.1.3.0"
                break
            fi
        done
    fi
    echo "== local dependencies ready in $LOCAL_DEPS"
    echo "   env.sh picks them up automatically; override with E5_LOCAL_DEPS=<dir>"
}

PAK=
ACTION=install
while [ $# -gt 0 ]; do
    case "$1" in
        -p|--package-manager) PAK="$2"; shift 2 ;;
        --local-deps) ACTION=local; shift ;;
        -h|--help) _help; exit 0 ;;
        *) _help; exit 1 ;;
    esac
done

if [ "$ACTION" = local ]; then
    _local_deps
    exit 0
fi

[ -n "$PAK" ] || { _help; exit 1; }

# clang/lld for CLANGDWARF, nasm for ACPI tables, uuid for BaseTools, python3
# for the EDK2 build scripts, plus the usual build essentials.
case "$PAK" in
    apt)
        sudo apt update || _error "apt update failed"
        sudo apt install -y build-essential git python3 python3-pip clang lld llvm \
            nasm uuid-dev acpica-tools curl ca-certificates gettext \
            || _error "failed to install packages"
        ;;
    dnf)
        sudo dnf install -y git make gcc clang lld llvm nasm libuuid-devel \
            acpica-tools python3 python3-pip curl ca-certificates gettext \
            || _error "failed to install packages"
        ;;
    pacman)
        sudo pacman -Syu --needed git base-devel clang lld llvm nasm \
            acpica python python-pip curl ca-certificates gettext \
            || _error "failed to install packages"
        # libuuid lives in the AUR as "uuid"; BaseTools links against it.
        if ! pacman -Q uuid >/dev/null 2>&1; then
            echo "== 'uuid' is not installed; build it from the AUR or use ./setup_env.sh --local-deps"
        fi
        ;;
    *) _error "unknown package manager '$PAK' (use apt, dnf or pacman)" ;;
esac

if [ -f "$HERE/pip-requirements.txt" ]; then
    python3 -m pip install -r "$HERE/pip-requirements.txt" \
        || python3 -m pip install -r "$HERE/pip-requirements.txt" --break-system-packages \
        || echo "== pip modules are optional for this platform; continuing"
fi

echo "== done; next: ./build_e5.sh DEBUG"
