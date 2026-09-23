#!/usr/bin/env bash
# 内核离线安装脚本（完全离线：不联网、不编译、不调用包管理器）
# 仅使用系统自带工具：cp / depmod / dracut / grub2-mkconfig / grubby
#
# 用法一（推荐）：脚本与离线包放同一目录直接执行（未解压时自动查找并解压 *.tar.gz）
#   sudo ./install_offline_kernel.sh
#
# 用法二：直接指定离线包文件
#   sudo ./install_offline_kernel.sh kernel-<release>-offline.tar.gz
#
# 可选环境变量：
#   BOOT_MIN_MB=300    /boot 最低可用空间（MB），新内核实际占用约 50~100MB
set -euo pipefail

BOOT_MIN_MB="${BOOT_MIN_MB:-300}"
PKG_TMPDIR=""
BASE_DIR=""

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"
}

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${PKG_TMPDIR}" ]]; then
    rm -rf "${PKG_TMPDIR}"
  fi
  return 0
}
trap cleanup EXIT

require_root() {
  [[ "$(id -u)" -eq 0 ]] || fail "请使用 root 权限运行：sudo bash $0"
}

# 解压离线包并定位内容目录（须包含 boot/ 与 lib/modules/）
extract_tarball() {
  local tarball=$1
  PKG_TMPDIR=$(mktemp -d /tmp/offline-kernel.XXXXXX)
  log "解压离线包：${tarball}"
  tar -xzf "${tarball}" -C "${PKG_TMPDIR}"
  if [[ -d "${PKG_TMPDIR}/boot" && -d "${PKG_TMPDIR}/lib/modules" ]]; then
    BASE_DIR="${PKG_TMPDIR}"
  else
    BASE_DIR=$(ls -1d "${PKG_TMPDIR}"/*/ 2>/dev/null | head -n1 || true)
  fi
  [[ -n "${BASE_DIR}" ]] || fail "离线包内为空：${tarball}"
}

# 定位离线包内容目录（须包含 boot/ 与 lib/modules/）
detect_base_dir() {
  if [[ $# -ge 1 ]]; then
    extract_tarball "$1"
  else
    BASE_DIR=$(cd "$(dirname "$0")" && pwd)

    # 目录结构不完整时，自动查找并解压同目录下的离线包
    if [[ ! -d "${BASE_DIR}/boot" || ! -d "${BASE_DIR}/lib/modules" ]]; then
      local tarball
      tarball=$(ls -1 "${BASE_DIR}"/*offline*.tar.gz 2>/dev/null | head -n1 || true)
      if [[ -z "${tarball}" ]]; then
        # 未匹配 *offline*.tar.gz 时，若目录下仅有一个 tar.gz 则直接使用
        local all
        all=$(ls -1 "${BASE_DIR}"/*.tar.gz 2>/dev/null || true)
        [[ "$(wc -l <<<"${all}")" -eq 1 ]] && tarball="${all}"
      fi
      [[ -n "${tarball}" ]] || fail "未找到离线包（须含 boot/ 与 lib/modules/ 或提供 *.tar.gz）：${BASE_DIR}"
      extract_tarball "${tarball}"
    fi
  fi

  [[ -d "${BASE_DIR}/boot" && -d "${BASE_DIR}/lib/modules" ]] \
    || fail "离线包目录结构不完整（须含 boot/ 与 lib/modules/）：${BASE_DIR}"
}

check_target() {
  [[ "$(uname -m)" == "x86_64" ]] || fail "当前离线包仅支持 x86_64，当前架构：$(uname -m)"

  local boot_free_mb
  boot_free_mb=$(df -Pm /boot | awk 'NR==2 {print $4}')
  if [[ "${boot_free_mb}" -lt "${BOOT_MIN_MB}" ]]; then
    fail "/boot 可用空间不足 ${BOOT_MIN_MB}MB，当前约 ${boot_free_mb}MB，请先清理旧内核"
  fi

  command -v depmod >/dev/null 2>&1 || fail "未找到 depmod（kmod），无法生成模块依赖"
  if ! command -v dracut >/dev/null 2>&1 && ! command -v mkinitrd >/dev/null 2>&1; then
    fail "未找到 dracut 或 mkinitrd，无法生成 initramfs"
  fi
  command -v grubby >/dev/null 2>&1 || log "未找到 grubby，将跳过默认启动项设置，请手动修改 GRUB 配置"
}

update_bootloader() {
  local kernel_release=$1

  if command -v grub2-mkconfig >/dev/null 2>&1; then
    if [[ -d /sys/firmware/efi && -d /boot/efi/EFI ]]; then
      local efi_cfg
      efi_cfg=$(find /boot/efi/EFI -name grub.cfg 2>/dev/null | head -n1 || true)
      if [[ -n "${efi_cfg}" ]]; then
        log "更新 UEFI GRUB 配置：${efi_cfg}"
        grub2-mkconfig -o "${efi_cfg}"
      fi
    fi

    if [[ -f /boot/grub2/grub.cfg ]]; then
      log "更新 GRUB 配置：/boot/grub2/grub.cfg"
      grub2-mkconfig -o /boot/grub2/grub.cfg
    fi
  fi

  if command -v grubby >/dev/null 2>&1; then
    local old_default new_title
    old_default=$(grubby --default-kernel 2>/dev/null || true)
    new_title=$(grubby --info="/boot/vmlinuz-${kernel_release}" 2>/dev/null | awk -F= '/^title=/{print $2; exit}' | tr -d '"')

    if [[ -n "${old_default}" && "${old_default}" != "/boot/vmlinuz-${kernel_release}" ]]; then
      # 远程安全模式：默认项保持旧内核，新内核仅一次性试启动
      grubby --set-default "${old_default}" || true
      log "默认启动项保持旧内核：${old_default}"
      if command -v grub2-reboot >/dev/null 2>&1 && [[ -n "${new_title}" ]]; then
        grub2-reboot "${new_title}" || grub2-reboot 0 || true
        log "已设置一次性启动：下次重启进入新内核 ${kernel_release}"
        log "新内核启动成功（SSH 可连、uname -r 正确）后固化默认项："
        log "  grubby --set-default /boot/vmlinuz-${kernel_release}"
        log "若新内核启动失败：直接强制重启，将自动进入旧内核 ${old_default}"
      else
        log "grub2-reboot 不可用，重启时请在 GRUB 菜单手动选择新内核 ${kernel_release}"
      fi
    else
      grubby --set-default "/boot/vmlinuz-${kernel_release}" || true
      log "默认启动项已设为：${kernel_release}"
    fi
    grubby --default-kernel || true
  fi
}

install_files() {
  local base_dir=$1

  local kernel_release
  # 从包内 lib/modules 下的实际模块目录推导内核 release，目录/压缩包改名不影响
  kernel_release=$(ls -1 "${base_dir}/lib/modules" 2>/dev/null | head -n1 || true)
  [[ -n "${kernel_release}" ]] || fail "无法确定内核 release：${base_dir}/lib/modules 为空"
  [[ -f "${base_dir}/boot/vmlinuz-${kernel_release}" ]] || fail "包内缺少 boot/vmlinuz-${kernel_release}"

  log "开始离线安装内核：${kernel_release}"

  log "安装内核文件到 /boot"
  cp -f "${base_dir}/boot/vmlinuz-${kernel_release}" /boot/
  cp -f "${base_dir}/boot/System.map-${kernel_release}" /boot/
  cp -f "${base_dir}/boot/config-${kernel_release}" /boot/

  log "安装模块到 /lib/modules"
  rm -rf "/lib/modules/${kernel_release}"
  cp -a "${base_dir}/lib/modules/${kernel_release}" /lib/modules/

  log "生成模块依赖"
  depmod -a "${kernel_release}"

  log "生成 initramfs：/boot/initramfs-${kernel_release}.img"
  if command -v dracut >/dev/null 2>&1; then
    dracut -f "/boot/initramfs-${kernel_release}.img" "${kernel_release}"
  else
    mkinitrd "/boot/initramfs-${kernel_release}.img" "${kernel_release}"
  fi

  update_bootloader "${kernel_release}"

  # 安装结果自检
  local f
  for f in \
    "/boot/vmlinuz-${kernel_release}" \
    "/boot/System.map-${kernel_release}" \
    "/boot/config-${kernel_release}" \
    "/boot/initramfs-${kernel_release}.img"; do
    [[ -s "${f}" ]] || fail "安装自检失败，缺少文件：${f}"
  done

  log "离线安装完成。请重启后执行：uname -r（预期输出 ${kernel_release}）"
}

main() {
  require_root
  detect_base_dir "$@"
  check_target
  install_files "${BASE_DIR}"
}

main "$@"
