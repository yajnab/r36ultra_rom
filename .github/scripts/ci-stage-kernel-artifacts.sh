#!/usr/bin/env bash
# Run from the workspace root after kernel_arkos.sh completes.
# - Normalizes ownership on paths touched by sudo (kernel outputs, Arkbuild).
# - Mirrors everything under ${ARKOS_DIR}/consoles/<UNIT>/ (e.g. r36ultra) into
#   consoles/kernel/common/ except Image; then installs the freshly built kernel Image.
# - If no *.dtb appears after that, falls back to kernel / Arkbuild / DEVICE_FILES_DIR.
#
# Environment (optional):
#   UNIT=r36ultra  CHIPSET=rk3326
#   KERNEL_DIR=kernel  ARKOS_DIR=arkos4clone  ARKBUILD_DIR=Arkbuild
#   DEVICE_FILES_DIR  Last-resort *.dtb if still missing.

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

# Return 0 if both paths refer to the same existing file (symlinks resolved).
same_file_path() {
  local a="$1" b="$2"
  [[ -e "$a" && -e "$b" ]] || return 1
  local ra rb
  ra="$(realpath "$a" 2>/dev/null)" || return 1
  rb="$(realpath "$b" 2>/dev/null)" || return 1
  [[ "$ra" == "$rb" ]]
}

# GNU install fails with "are the same file" when src and dst are identical.
install_dtb_unless_same() {
  local src="$1" dst="$2"
  [[ -e "$src" ]] || { echo "ERROR: missing $src"; return 1; }
  if [[ -e "$dst" ]] && same_file_path "$src" "$dst"; then
    log "Skip install (already same file): $dst"
    return 0
  fi
  install -m0644 "$src" "$dst"
}

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

# --- Mirror full device console folder into kernel/common (boot.ini, dtbs, extras). ---
# Kernel Image always comes from the build below, not from the repo copy.
if [[ -d "$DEVICE_DIR" ]] && compgen -G "${DEVICE_DIR}/*" >/dev/null 2>&1; then
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude='Image' "${DEVICE_DIR}/" "${COMMON_DIR}/"
    log "Mirrored ${DEVICE_DIR}/ -> ${COMMON_DIR}/ (excluding Image)"
  else
    shopt -s dotglob nullglob
    for item in "${DEVICE_DIR}"/*; do
      [[ -e "$item" ]] || continue
      base="$(basename "$item")"
      [[ "$base" == "Image" ]] && continue
      rm -rf "${COMMON_DIR:?}/${base}" 2>/dev/null || true
      cp -a "$item" "${COMMON_DIR}/"
    done
    shopt -u dotglob nullglob
    log "Mirrored ${DEVICE_DIR}/ -> ${COMMON_DIR}/ (cp fallback, excluding Image)"
  fi
fi

IMAGE_SRC="${KERNEL_DIR}/arch/arm64/boot/Image"
[[ -f "$IMAGE_SRC" ]] || { echo "ERROR: Kernel Image not found: $IMAGE_SRC"; exit 1; }
install -m0644 "$IMAGE_SRC" "${COMMON_DIR}/Image"
log "Wrote ${COMMON_DIR}/Image"

# --- DTBs: already mirrored from DEVICE_DIR; else pull from kernel / Arkbuild / device_files. ---
dtb_list=()
shopt -s nullglob
dtb_list=( "${COMMON_DIR}/"*.dtb )
if [[ ${#dtb_list[@]} -eq 0 ]]; then
  dtb_list=( "${DEVICE_DIR}/"*.dtb )
fi
shopt -u nullglob

if [[ ${#dtb_list[@]} -eq 0 ]]; then
  ROCKCHIP_DTS="${KERNEL_DIR}/arch/arm64/boot/dts/rockchip"
  shopt -s nullglob
  # Glob must be anchored in the target dir: do not use "${dir}/"${DTB_GLOB} (unsafe).
  dtb_list=( "${ROCKCHIP_DTS}/"*${UNIT}*.dtb )
  shopt -u nullglob

  if [[ ${#dtb_list[@]} -eq 0 && -d "${ARKBUILD_DIR}/boot" ]]; then
    shopt -s nullglob
    dtb_list=( "${ARKBUILD_DIR}/boot/"*${UNIT}*.dtb )
    shopt -u nullglob
  fi

  if [[ ${#dtb_list[@]} -eq 0 && -n "${DEVICE_FILES_DIR:-}" && -d "${DEVICE_FILES_DIR}" ]]; then
    shopt -s nullglob
    dtb_list=( "${DEVICE_FILES_DIR}/"*${UNIT}*.dtb )
    shopt -u nullglob
    [[ ${#dtb_list[@]} -gt 0 ]] && log "Using DTBs from DEVICE_FILES_DIR=${DEVICE_FILES_DIR} (${DTB_GLOB})"
  fi
fi

if [[ ${#dtb_list[@]} -eq 0 ]]; then
  echo "ERROR: No *.dtb found after mirroring ${DEVICE_DIR}/"
  echo "       Add DTBs under ${DEVICE_DIR}/ or build ${DTB_GLOB} in the kernel tree,"
  echo "       or set DEVICE_FILES_DIR with matching DTBs."
  exit 1
fi

# If DTBs came from kernel fallback paths, also place them in device + common trees.
shopt -s nullglob
already_in_common=( "${COMMON_DIR}/"*.dtb )
shopt -u nullglob
if [[ ${#already_in_common[@]} -eq 0 ]]; then
  for f in "${dtb_list[@]}"; do
    base="$(basename "$f")"
    dest_dev="${DEVICE_DIR}/${base}"
    dest_com="${COMMON_DIR}/${base}"
    install_dtb_unless_same "$f" "$dest_dev"
    install_dtb_unless_same "$f" "$dest_com"
    log "Staged DTB (from kernel/fallback): ${dest_com}"
  done
else
  log "DTB(s) present under ${COMMON_DIR}/ after mirror ($(printf '%s ' "${already_in_common[@]}"))"
fi

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
