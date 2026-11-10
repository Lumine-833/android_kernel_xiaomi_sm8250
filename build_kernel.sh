#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Build helper for LineageOS android_kernel_xiaomi_sm8250 (kona / SM8250, Linux 4.19)
# with SukiSU Ultra integrated through the "builtin" branch (manual hooks).
#
# Usage:
#   ./build_kernel.sh [device] [ksu|noksu]
#
#   device : any SM8250 codename of this tree (default: munch)
#   ksu    : ksu     -> build with SukiSU Ultra (default)
#            noksu   -> build a clean kernel
#
# Env:
#   KSU_CHECK_ONLY=1   only compile drivers/kernelsu/ksu.o (fast syntax/API check)
#   OUT_DIR=<path>     override output directory (default: ./out)
#
set -euo pipefail

DEVICE="${1:-munch}"
KSU_MODE="${2:-ksu}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT_DIR:-$ROOT/out}"
AK3_DIR="$ROOT/anykernel"
DEFCONFIG="vendor/kona-perf_defconfig"

cd "$ROOT"

log() { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "arch/arm64/configs/$DEFCONFIG" ] || die "defconfig not found: arch/arm64/configs/$DEFCONFIG"
case "$DEVICE" in
	'') die "empty device codename" ;;
esac

export ARCH=arm64
export SUBARCH=arm64
export LC_ALL=C

JOBS="$(nproc)"
MAKE_OPTS=(-j"$JOBS" O="$OUT" ARCH=arm64 SUBARCH=arm64)

# ---------------------------------------------------------------- toolchain
if ! command -v clang >/dev/null 2>&1; then
	die "clang not found in PATH"
fi
log "clang: $(clang --version | head -n1)"

# LLVM=1 gives us ld.lld/llvm-ar/llvm-objcopy/llvm-strip in one shot.
TOOLCHAIN=(LLVM=1 LLVM_IAS=1)
if command -v ld.lld >/dev/null 2>&1; then
	TOOLCHAIN+=(LD=ld.lld)
fi
if command -v ccache >/dev/null 2>&1; then
	TOOLCHAIN+=(CC="ccache clang")
	export CCACHE_DIR="${CCACHE_DIR:-$HOME/.cache/ccache}"
	export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-5G}"
fi

# ---------------------------------------------------------------- configure
log "generating $DEFCONFIG"
make "${MAKE_OPTS[@]}" "${TOOLCHAIN[@]}" "$DEFCONFIG"

CONFIG="$OUT/.config"
[ -f "$CONFIG" ] || die "no .config generated"

log "applying kernel configuration"
"$ROOT/scripts/config" --file "$CONFIG" \
	-e KSU \
	-e KSU_FEATURE_ADBROOT \
	-e PS5169 \
	-d KSU_SUSFS \
	-d KPM \
	-d KSU_DEBUG \
	-d CC_WERROR

if [ "$KSU_MODE" = "noksu" ]; then
	"$ROOT/scripts/config" --file "$CONFIG" -d KSU
fi

make "${MAKE_OPTS[@]}" "${TOOLCHAIN[@]}" olddefconfig >/dev/null

if [ "$KSU_MODE" != "noksu" ]; then
	grep -q '^CONFIG_KSU=y' "$CONFIG" || die "CONFIG_KSU was not enabled"
	log "SukiSU Ultra: enabled (builtin / manual hooks)"
else
	log "SukiSU Ultra: disabled"
fi

# ---------------------------------------------------------------- headers
# flask.h / av_permissions.h are generated while security/selinux is built.
# drivers/kernelsu includes them, and drivers/ is built in parallel with
# security/, so generate them up front to avoid a race.
log "generating SELinux headers"
make "${MAKE_OPTS[@]}" "${TOOLCHAIN[@]}" security/selinux/ >/dev/null

# ---------------------------------------------------------------- compile
if [ "${KSU_CHECK_ONLY:-0}" = "1" ]; then
	log "compile check: drivers/kernelsu"
	# prepare + init/ are needed because generated/compile.h is only created
	# while building init/, and drivers/kernelsu includes it.
	make "${MAKE_OPTS[@]}" "${TOOLCHAIN[@]}" prepare
	make "${MAKE_OPTS[@]}" "${TOOLCHAIN[@]}" -j1 init/
	make "${MAKE_OPTS[@]}" "${TOOLCHAIN[@]}" drivers/kernelsu/
	log "KernelSU objects compiled successfully"
	exit 0
fi

log "building kernel ($JOBS jobs)"
make "${MAKE_OPTS[@]}" "${TOOLCHAIN[@]}"

IMAGE="$OUT/arch/arm64/boot/Image"
[ -f "$IMAGE" ] || die "kernel image not produced at $IMAGE"
log "kernel image: $IMAGE ($(du -h "$IMAGE" | cut -f1))"

# ---------------------------------------------------------------- package
KSU_TAG="SukiSU"
[ "$KSU_MODE" = "noksu" ] && KSU_TAG="NoKSU"
GIT_SHA="$(git rev-parse --short=8 HEAD 2>/dev/null || echo unknown)"
STAMP="$(date +%Y%m%d_%H%M%S)"
ZIP_NAME="Kona_${DEVICE}_${KSU_TAG}_${STAMP}_${GIT_SHA}.zip"

log "packaging $ZIP_NAME with AnyKernel3"
rm -rf "$AK3_DIR"
git clone --depth=1 --quiet https://github.com/osm0sis/AnyKernel3 "$AK3_DIR"
cp "$ROOT/.github/anykernel/anykernel.sh" "$AK3_DIR/anykernel.sh"
sed -i "s/@DEVICE@/${DEVICE}/g" "$AK3_DIR/anykernel.sh"
cp "$IMAGE" "$AK3_DIR/Image"
cp "$OUT/System.map" "$AK3_DIR/System.map" 2>/dev/null || true
(cd "$AK3_DIR" && zip -r9 "$ROOT/$ZIP_NAME" . -x '*.git*' 'README.md' >/dev/null)
log "flashable zip: $ROOT/$ZIP_NAME"

echo "$ZIP_NAME" > "$ROOT/.last_zip_name"
