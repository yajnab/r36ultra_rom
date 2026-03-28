#!/usr/bin/env bash
# Run from the workspace root after kernel_arkos.sh completes.
# - Normalizes ownership on paths touched by sudo (kernel outputs, Arkbuild).
# - Stages Image + DTBs into arkos4clone so build_image.sh sync_kernel_image and
#   clone_support rsync see up-to-date files.
#
# Environment (optional):
#   UNIT=r36ultra  CHIPSET=rk3326
#   KERNEL_DIR=kernel  ARKOS_DIR=arkos4clone  ARKBUILD_DIR=Arkbuild
#   DEVICE_FILES_DIR  Last-resort *.dtb if not under consoles/<UNIT>/ or kernel output.
#
# DTBs for R36 Ultra are expected under ${ARKOS_DIR}/consoles/${UNIT}/ (*.dtb).
# That directory is tried first; then kernel build, Arkbuild/boot, then DEVICE_FILES_DIR.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

KERNEL_DIR="${KERNEL_DIR:-kernel}"
ARKOS_DIR="${ARKOS_DIR:-arkos4clone}"
ARKBUILD_DIR="${ARKBUILD_DIR:-Arkbuild}"
UNIT="${UNIT:-r36ultra}"
CHIPSET="${CHIPSET:-rk3326}"
DTB_GLOB="*${UNIT}*.dtb"

log() { echo "[ci-stage-kernel-artifacts] $*"; }

fix_owner() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  if command -v sudo >/dev/null 2>&1; then
    sudo chown -R "$(id -un):$(id -gn)" "$path" 2>/dev/null || true
  else
    chown -R "$(id -un):$(id -gn)" "$path" 2>/dev/null || true
  fi
}

# kernel_arkos.sh uses sudo for modules_install, mounts, and Arkbuild installs.
fix_owner "$ARKBUILD_DIR"
fix_owner "${KERNEL_DIR}/arch/arm64/boot"
fix_owner "${KERNEL_DIR}/arch/arm64/boot/dts/rockchip"

COMMON_DIR="${ARKOS_DIR}/consoles/kernel/common"
DEVICE_DIR="${ARKOS_DIR}/consoles/${UNIT}"
mkdir -p "$COMMON_DIR" "$DEVICE_DIR"

IMAGE_SRC="${KERNEL_DIR}/arch/arm64/boot/Image"
[[ -f "$IMAGE_SRC" ]] || { echo "ERROR: Kernel Image not found: $IMAGE_SRC"; exit 1; }
install -m0644 "$IMAGE_SRC" "${COMMON_DIR}/Image"
log "Wrote ${COMMON_DIR}/Image"

dtb_list=()

# 1) Canonical: prebuilt DTBs shipped with arkos4clone under consoles/<unit>/ (e.g. r36ultra).
shopt -s nullglob
console_dtbs=( "${DEVICE_DIR}/"*.dtb )
shopt -u nullglob
if [[ ${#console_dtbs[@]} -gt 0 ]]; then
  dtb_list=( "${console_dtbs[@]}" )
  log "Using DTBs from ${DEVICE_DIR}/"
else
  ROCKCHIP_DTS="${KERNEL_DIR}/arch/arm64/boot/dts/rockchip"
  shopt -s nullglob
  dtb_list=( "${ROCKCHIP_DTS}/"${DTB_GLOB} )
  shopt -u nullglob

  if [[ ${#dtb_list[@]} -eq 0 && -d "${ARKBUILD_DIR}/boot" ]]; then
    shopt -s nullglob
    dtb_list=( "${ARKBUILD_DIR}/boot/"${DTB_GLOB} )
    shopt -u nullglob
  fi

  if [[ ${#dtb_list[@]} -eq 0 && -n "${DEVICE_FILES_DIR:-}" && -d "${DEVICE_FILES_DIR}" ]]; then
    shopt -s nullglob
    dtb_list=( "${DEVICE_FILES_DIR}/"${DTB_GLOB} )
    shopt -u nullglob
    [[ ${#dtb_list[@]} -gt 0 ]] && log "Using DTBs from DEVICE_FILES_DIR=${DEVICE_FILES_DIR} (${DTB_GLOB})"
  fi
fi

if [[ ${#dtb_list[@]} -eq 0 ]]; then
  echo "ERROR: No DTBs found."
  echo "       Add *.dtb under ${DEVICE_DIR}/"
  echo "       or build ${DTB_GLOB} under ${KERNEL_DIR}/arch/arm64/boot/dts/rockchip/ (or Arkbuild/boot/),"
  echo "       or set DEVICE_FILES_DIR with matching DTBs."
  exit 1
fi

for f in "${dtb_list[@]}"; do
  base="$(basename "$f")"
  install -m0644 "$f" "${DEVICE_DIR}/${base}"
  install -m0644 "$f" "${COMMON_DIR}/${base}"
  log "Staged DTB: ${DEVICE_DIR}/${base}"
done

LOGO_SRC=""
for d in 720P 768P 540P 480P 854x480P; do
  if [[ -f "${ARKOS_DIR}/consoles/logo/${d}/logo.bmp" ]]; then
    LOGO_SRC="${ARKOS_DIR}/consoles/logo/${d}/logo.bmp"
    break
  fi
done
[[ -n "$LOGO_SRC" ]] || { echo "ERROR: No logo.bmp under ${ARKOS_DIR}/consoles/logo/*/"; exit 1; }

mkdir -p "${ARKBUILD_DIR}"
cp -f "$LOGO_SRC" "${ARKBUILD_DIR}/"
log "Logo -> Arkbuild: $LOGO_SRC"

if [[ -d "${ARKOS_DIR}/consoles/${UNIT}" ]]; then
  if ! cp -a "${ARKOS_DIR}/consoles/${UNIT}/." "${ARKBUILD_DIR}/" 2>/dev/null; then
    log "cp to Arkbuild needed elevated permissions; retrying with sudo + chown"
    sudo cp -a "${ARKOS_DIR}/consoles/${UNIT}/." "${ARKBUILD_DIR}/"
    fix_owner "${ARKBUILD_DIR}"
  fi
fi

log "done"
