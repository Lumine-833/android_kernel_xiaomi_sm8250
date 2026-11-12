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

# ---------------------------------------------------------------- build stamp
# Names (zip, tag, release) use this timezone. The CI runner is UTC.
# POSIX TZ spec, so it does not depend on tzdata being installed: UTC-8 == UTC+8.
TZ_SPEC="${TZ_SPEC:-UTC-8}"
TZ_OFF="$(TZ="$TZ_SPEC" date +%z)"		# e.g. +0800
TZ_SIGN="${TZ_OFF:0:1}"
TZ_HH="$((10#${TZ_OFF:1:2}))"
TZ_MM="${TZ_OFF:3:2}"
if [ "$TZ_MM" = "00" ]; then
	TZ_LABEL="UTC${TZ_SIGN}${TZ_HH}"
else
	TZ_LABEL="UTC${TZ_SIGN}${TZ_HH}:${TZ_MM}"
fi

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

# The LineageOS build merges per-device fragments on top of the QCOM defconfig.
# Without them the kernel has no touchscreen, fingerprint, charger, backlight
# or machine specific code at all - it still builds, but the device is unusable.
COMMON_CFG="arch/arm64/configs/vendor/xiaomi/sm8250-common.config"
DEVICE_CFG="arch/arm64/configs/vendor/xiaomi/${DEVICE}.config"
MERGE_LIST=("$COMMON_CFG")
if [ -f "$DEVICE_CFG" ]; then
	MERGE_LIST+=("$DEVICE_CFG")
else
	log "WARNING: $DEVICE_CFG not found, merging the common config only"
fi
log "merging device fragments: ${MERGE_LIST[*]}"
"$ROOT/scripts/kconfig/merge_config.sh" -m -O "$OUT" "$CONFIG" "${MERGE_LIST[@]}" >/dev/null

log "applying kernel configuration"
"$ROOT/scripts/config" --file "$CONFIG" \
	-e KSU \
	-e KSU_FEATURE_ADBROOT \
	-e KSU_SUSFS \
	-e PS5169 \
	-e KSU_SUSFS_SUS_PATH \
	-e KSU_SUSFS_SUS_MOUNT \
	-e KSU_SUSFS_SUS_KSTAT \
	-e KSU_SUSFS_SPOOF_UNAME \
	-e KSU_SUSFS_ENABLE_LOG \
	-e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
	-e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
	-d KSU_SUSFS_OPEN_REDIRECT \
	-d KSU_SUSFS_SUS_MAP \
	-d KSU_SUSFS_PRIORITY_UID_FILTER \
	-d KPM \
	-d KSU_DEBUG \
	-d CC_WERROR

if [ "$KSU_MODE" = "noksu" ]; then
	"$ROOT/scripts/config" --file "$CONFIG" -d KSU
fi

make "${MAKE_OPTS[@]}" "${TOOLCHAIN[@]}" olddefconfig >/dev/null

log "config: $(grep -E '^CONFIG_(KSU|TOUCHSCREEN_FOCALTECH|TOUCHSCREEN_FTS|TOUCHSCREEN_XIAOMI_TOUCHFEATURE|PS5169|MACH_XIAOMI_[A-Z]+)=' "$CONFIG" | tr '\n' ' ')"

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
# Flavour comes from what was actually built, so one script serves every
# branch: NoKSU / SukiSU / SukiSU+SuSFS.
if [ "$KSU_MODE" = "noksu" ]; then
	KSU_FLAVOR="NoKSU"
	KSU_SLUG="noksu"
elif grep -q '^CONFIG_KSU_SUSFS=y' "$CONFIG"; then
	KSU_FLAVOR="SukiSU+SuSFS"
	KSU_SLUG="sukisu-susfs"
else
	KSU_FLAVOR="SukiSU"
	KSU_SLUG="sukisu"
fi

BUILD_DATE="$(TZ="$TZ_SPEC" date +%Y%m%d)"
BUILD_TIME="$(TZ="$TZ_SPEC" date +%H%M%S)"
BUILD_STAMP="$(TZ="$TZ_SPEC" date +%Y-%m-%d-%H:%M:%S)"
BUILD_DATETIME="$(TZ="$TZ_SPEC" date +'%Y-%m-%d %H:%M:%S')"
ZIP_BASE="Kernel_${DEVICE}_${KSU_SLUG}_${BUILD_DATE}_${BUILD_TIME}_anykernel3"
TMP_ZIP=".ak3_${DEVICE}_pending.zip"

log "packaging $ZIP_BASE with AnyKernel3"
rm -rf "$AK3_DIR"
git clone --depth=1 --quiet https://github.com/osm0sis/AnyKernel3 "$AK3_DIR"
cp "$ROOT/.github/anykernel/anykernel.sh" "$AK3_DIR/anykernel.sh"
sed -i "s/@DEVICE@/${DEVICE}/g" "$AK3_DIR/anykernel.sh"
cp "$IMAGE" "$AK3_DIR/Image"
cp "$OUT/System.map" "$AK3_DIR/System.map" 2>/dev/null || true
(cd "$AK3_DIR" && zip -r9 "$ROOT/$TMP_ZIP" . -x '*.git*' 'README.md' >/dev/null)

MD5_8="$(md5sum "$ROOT/$TMP_ZIP" | cut -c1-8)"
ZIP_NAME="${ZIP_BASE}_${MD5_8}.zip"
mv "$ROOT/$TMP_ZIP" "$ROOT/$ZIP_NAME"
log "flashable zip: $ROOT/$ZIP_NAME"

# Everything the workflow needs to name the artifact, tag and release.
{
	printf "TAG='v%s-%s'\n" "$BUILD_DATE" "$BUILD_TIME"
	printf "RELEASE_NAME='Kernel for %s [%s]'\n" "$DEVICE" "$KSU_FLAVOR"
	printf "ZIP_NAME='%s'\n" "$ZIP_NAME"
	printf "ZIP_BASE='%s'\n" "$ZIP_BASE"
	printf "MD5=%s\n" "$MD5_8"
	printf "DEVICE='%s'\n" "$DEVICE"
	printf "KSU_FLAVOR='%s'\n" "$KSU_FLAVOR"
	printf "KSU_SLUG='%s'\n" "$KSU_SLUG"
	printf "BUILD_DATETIME='%s'\n" "$BUILD_DATETIME"
} > "$ROOT/.build_info"

log "tag:     v${BUILD_DATE}-${BUILD_TIME}"
log "release: Kernel for ${DEVICE} [${KSU_FLAVOR}]"
log "zip:     ${ZIP_NAME}"
