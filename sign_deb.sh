#!/usr/bin/env bash
# =============================================================================
# sign_deb.sh — 给 teacher-nas.deb 添加 GPG 签名
# !! 必须在 UOS / Debian 上运行 !!
# 用法: bash sign_deb.sh
# =============================================================================
set -euo pipefail

# ── 配置 ────────────────────────────────────────────────────────────────────
GPG_NAME="Teacher NAS"
GPG_EMAIL="admin@school.local"
DEB_FILE=""          # 留空则自动查找当前目录下的 .deb 文件

# ── 颜色输出 ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}  ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}  ⚠${NC} $*"; }
error()   { echo -e "${RED}  ✗${NC} $*"; exit 1; }
section() { echo ""; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; echo "  $*"; echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 环境检查 ─────────────────────────────────────────────────────────────────
section "环境检查"

if ! command -v gpg >/dev/null 2>&1; then
    error "gpg 未安装，请执行: sudo apt-get install -y gnupg"
fi
info "gpg $(gpg --version | head -1 | awk '{print $3}')"

if ! command -v dpkg-sig >/dev/null 2>&1; then
    warn "dpkg-sig 未安装，正在安装..."
    sudo apt-get install -y dpkg-sig || error "dpkg-sig 安装失败，请手动执行: sudo apt-get install -y dpkg-sig"
fi
info "dpkg-sig 已就绪"

# ── 查找 deb 文件 ─────────────────────────────────────────────────────────────
if [ -z "$DEB_FILE" ]; then
    DEB_FILE=$(find "$SCRIPT_DIR" -maxdepth 1 -name "*.deb" | head -1)
fi

if [ -z "$DEB_FILE" ] || [ ! -f "$DEB_FILE" ]; then
    error "找不到 .deb 文件，请先运行 build_deb.sh 生成安装包"
fi
info "目标 deb: $(basename "$DEB_FILE")"

# ── 检查/生成 GPG 密钥 ───────────────────────────────────────────────────────
section "GPG 密钥"

KEY_ID=$(gpg --list-secret-keys --with-colons 2>/dev/null \
    | awk -F: '/^uid/ { print $10 }' \
    | grep -F "$GPG_NAME" \
    | head -1 || true)

if [ -z "$KEY_ID" ]; then
    warn "未找到密钥「${GPG_NAME}」，正在生成..."
    # 批量生成密钥（无交互、无密码保护）
    gpg --batch --gen-key <<EOF
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: ${GPG_NAME}
Name-Email: ${GPG_EMAIL}
Expire-Date: 0
%no-protection
%commit
EOF
    info "密钥生成完成"
else
    info "已找到现有密钥：${KEY_ID}"
fi

# 获取密钥指纹（用于后续操作）
KEY_FPR=$(gpg --list-secret-keys --with-colons --fingerprint "${GPG_EMAIL}" 2>/dev/null \
    | awk -F: '/^fpr/ {print $10; exit}')
info "密钥指纹: ${KEY_FPR}"

# ── 导出公钥文件 ──────────────────────────────────────────────────────────────
section "导出公钥"

PUBKEY_FILE="$SCRIPT_DIR/teacher-nas-key.asc"
gpg --export --armor "${GPG_EMAIL}" > "$PUBKEY_FILE"
info "公钥已导出: teacher-nas-key.asc"

# 同时导出二进制格式，用于打包进 deb
PUBKEY_GPG="$SCRIPT_DIR/deb_build/teacher-nas_1.0.0_all/usr/share/teacher-nas/teacher-nas-key.gpg"
mkdir -p "$(dirname "$PUBKEY_GPG")"
gpg --export "${GPG_EMAIL}" > "$PUBKEY_GPG"
info "公钥（二进制）已放入 deb 目录，postinst 将在安装时自动导入"

# ── 对 deb 签名 ───────────────────────────────────────────────────────────────
section "签名 deb 包"

# 先备份原包
cp "$DEB_FILE" "${DEB_FILE%.deb}_unsigned.deb"
info "原包已备份为: $(basename "${DEB_FILE%.deb}_unsigned.deb")"

# 执行签名
dpkg-sig --sign builder -k "${GPG_EMAIL}" "$DEB_FILE"
info "签名完成: $(basename "$DEB_FILE")"

# 验证签名
echo ""
echo "  签名验证结果:"
dpkg-sig --verify "$DEB_FILE" | sed 's/^/    /'

# ── 完成提示 ──────────────────────────────────────────────────────────────────
section "✅  签名完成！"

echo ""
echo "  已签名的 deb:  $(basename "$DEB_FILE")"
echo "  公钥文件:      teacher-nas-key.asc"
echo ""
echo "  ┌─ 分发方式 ────────────────────────────────────────────────────┐"
echo "  │                                                               │"
echo "  │  第一台（管理员手动装，公钥自动写入系统）:                      │"
echo "  │    sudo dpkg -i $(basename "$DEB_FILE")          │"
echo "  │                                                               │"
echo "  │  后续所有台（公钥已在包内，双击即可装）:                        │"
echo "  │    双击 $(basename "$DEB_FILE") → UOS 软件中心弹出 → 安装    │"
echo "  │                                                               │"
echo "  └───────────────────────────────────────────────────────────────┘"
echo ""
