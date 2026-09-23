#!/usr/bin/env bash
# 固化新内核为默认启动项（新内核试启动成功后在 SSH 里执行一次）
set -euo pipefail

KERNEL_RELEASE="${1:-5.10.262-offline}"
VMLINUZ="/boot/vmlinuz-${KERNEL_RELEASE}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"; }
fail() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || fail "请使用 root 执行：sudo bash $0"

running="$(uname -r)"
log "当前运行内核：${running}"
[[ "${running}" == "${KERNEL_RELEASE}" ]] || fail "运行内核不是 ${KERNEL_RELEASE}，请勿固化！"

[[ -f "${VMLINUZ}" ]] || fail "未找到 ${VMLINUZ}"

grubby --set-default "${VMLINUZ}"
log "默认启动项已固化：$(grubby --default-kernel)"

# 清除一次性启动残留
grub2-editenv unset next_entry 2>/dev/null || true
log "已清除一次性启动标记（next_entry）"

log "固化完成。旧内核 4.19 仍保留在 /boot 作为回退保险。"
