#!/usr/bin/env bash
set -euo pipefail

KERNEL_VERSION="${KERNEL_VERSION:-${VERSION:-5.10.262}}"
LOCALVERSION="${LOCALVERSION:--1.ky10.x86_64}"
KERNEL_RELEASE="${KERNEL_VERSION}${LOCALVERSION}"
SRC_URLS=(
  "${SRC_URL:-}"
  "https://mirrors.ustc.edu.cn/kernel.org/linux/kernel/v5.x/linux-${KERNEL_VERSION}.tar.xz"
  "https://mirrors.tuna.tsinghua.edu.cn/kernel/v5.x/linux-${KERNEL_VERSION}.tar.xz"
  "https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-${KERNEL_VERSION}.tar.xz"
)
WORKDIR="${WORKDIR:-/usr/src}"
SRC_DIR="${WORKDIR}/linux-${KERNEL_VERSION}"
TARBALL="/tmp/linux-${KERNEL_VERSION}.tar.xz"
BUILD_ROOT="${BUILD_ROOT:-/tmp/kernel-${KERNEL_RELEASE}-offline}"
PACKAGE_DIR="${PACKAGE_DIR:-/data/update_kernel}"
PACKAGE_NAME="kernel-${KERNEL_RELEASE}-offline.tar.gz"
PACKAGE_PATH="${PACKAGE_DIR}/${PACKAGE_NAME}"
JOBS="${JOBS:-$(nproc)}"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"
}

fail() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2
  exit 1
}

require_root() {
  [[ "$(id -u)" -eq 0 ]] || fail "请使用 root 权限运行：sudo bash $0"
}

check_system() {
  if [[ -f /etc/os-release ]]; then
    local os_pretty os_id
    os_pretty=$(grep '^PRETTY_NAME=' /etc/os-release | cut -d= -f2- | tr -d '"' || true)
    os_id=$(grep '^ID=' /etc/os-release | cut -d= -f2- | tr -d '"' || true)
    log "当前系统：${os_pretty:-${os_id:-unknown}}"
  fi

  log "当前内核：$(uname -r)"
  [[ "$(uname -m)" == "x86_64" ]] || fail "当前脚本仅支持 x86_64，当前架构：$(uname -m)"

  if ! command -v yum >/dev/null 2>&1 && ! command -v dnf >/dev/null 2>&1; then
    fail "当前脚本适用于 Kylin/CentOS/RHEL 系发行版，需要 yum 或 dnf"
  fi
}

check_compiler() {
  local gcc_major gcc_minor
  gcc_major=$(gcc -dumpfullversion 2>/dev/null | cut -d. -f1 || echo 0)
  gcc_minor=$(gcc -dumpfullversion 2>/dev/null | cut -d. -f2 || echo 0)

  if (( gcc_major > 4 || (gcc_major == 4 && gcc_minor >= 9) )); then
    log "GCC 版本满足要求：$(gcc -dumpfullversion)"
    return
  fi

  fail "Linux Kernel ${KERNEL_VERSION} 要求 GCC >= 4.9，当前 GCC 是 $(gcc -dumpfullversion)"
}

install_build_deps() {
  local pm="yum"
  command -v dnf >/dev/null 2>&1 && pm="dnf"

  log "安装编译依赖"
  ${pm} install -y \
    gcc gcc-c++ make bc bison flex perl \
    elfutils-libelf-devel openssl-devel ncurses-devel \
    xz tar wget curl rsync kmod cpio findutils \
    grubby || fail "依赖安装失败，请检查软件源"

  if ! command -v pahole >/dev/null 2>&1; then
    log "未找到 pahole/dwarves，已在内核配置中禁用 BTF，继续编译"
  fi
}

download_kernel() {
  if [[ -s "${TARBALL}" ]] && tar -tf "${TARBALL}" >/dev/null 2>&1; then
    log "发现已下载文件，跳过下载：${TARBALL}"
  else
    rm -f "${TARBALL}"
    local url
    for url in "${SRC_URLS[@]}"; do
      [[ -n "${url}" ]] || continue
      log "下载 Linux Kernel ${KERNEL_VERSION}：${url}"
      if curl -fL --connect-timeout 10 --retry 2 -o "${TARBALL}" "${url}"; then
        break
      fi
      rm -f "${TARBALL}"
    done
  fi

  [[ -s "${TARBALL}" ]] || fail "内核源码下载失败"

  rm -rf "${SRC_DIR}"
  tar -C "${WORKDIR}" -xf "${TARBALL}"
}

prepare_config() {
  cd "${SRC_DIR}"

  if [[ -f "/boot/config-$(uname -r)" ]]; then
    log "使用当前内核配置作为基础配置"
    cp "/boot/config-$(uname -r)" .config
  else
    log "未找到当前内核配置，使用默认 x86_64 配置"
    make x86_64_defconfig
  fi

  scripts/config --set-str LOCALVERSION "${LOCALVERSION}" || true
  # 磁盘空间受限：禁用调试信息，编译产物体积缩小约 3~4 倍（不影响内核功能）
  scripts/config --disable DEBUG_INFO || true
  scripts/config --disable DEBUG_INFO_DWARF4 || true
  scripts/config --disable DEBUG_INFO_DWARF5 || true
  scripts/config --disable DEBUG_INFO_BTF || true
  scripts/config --disable SYSTEM_TRUSTED_KEYS || true
  scripts/config --disable SYSTEM_REVOCATION_KEYS || true
  scripts/config --set-str SYSTEM_TRUSTED_KEYS "" || true
  scripts/config --set-str SYSTEM_REVOCATION_KEYS "" || true

  log "生成新内核配置"
  make olddefconfig
}

build_kernel() {
  cd "${SRC_DIR}"
  log "开始编译内核，线程数：${JOBS}"
  make -j"${JOBS}"
}

stage_kernel() {
  cd "${SRC_DIR}"
  log "整理离线安装目录：${BUILD_ROOT}"
  rm -rf "${BUILD_ROOT}"
  mkdir -p "${BUILD_ROOT}/boot" "${BUILD_ROOT}/lib/modules"

  log "安装模块到临时目录"
  make INSTALL_MOD_PATH="${BUILD_ROOT}" modules_install

  cp -f "arch/x86/boot/bzImage" "${BUILD_ROOT}/boot/vmlinuz-${KERNEL_RELEASE}"
  cp -f "System.map" "${BUILD_ROOT}/boot/System.map-${KERNEL_RELEASE}"
  cp -f ".config" "${BUILD_ROOT}/boot/config-${KERNEL_RELEASE}"

  local script_dir installer_src
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  installer_src="${script_dir}/install_offline_kernel.sh"
  [[ -f "${installer_src}" ]] || fail "未找到离线安装脚本：${installer_src}（需与打包脚本放在同一目录）"

  log "复制离线安装脚本"
  cp -f "${installer_src}" "${BUILD_ROOT}/install_offline_kernel.sh"
  chmod +x "${BUILD_ROOT}/install_offline_kernel.sh"
}

package_kernel() {
  mkdir -p "${PACKAGE_DIR}"
  rm -f "${PACKAGE_PATH}"

  log "生成离线包：${PACKAGE_PATH}"
  tar -C "$(dirname "${BUILD_ROOT}")" -czf "${PACKAGE_PATH}" "$(basename "${BUILD_ROOT}")"

  log "离线包生成完成：${PACKAGE_PATH}"
  log "客户现场使用（方式一，解压安装）：tar -xzf ${PACKAGE_NAME} && cd $(basename "${BUILD_ROOT}") && sudo ./install_offline_kernel.sh"
  log "客户现场使用（方式二，指定包安装）：sudo ./install_offline_kernel.sh ${PACKAGE_NAME}"
}

main() {
  require_root
  check_system
  install_build_deps
  check_compiler
  download_kernel
  prepare_config
  build_kernel
  stage_kernel
  package_kernel
}

main "$@"
