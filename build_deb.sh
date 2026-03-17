#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# build_deb.sh — 打包 teacher-nas.deb
# !! 必须在 UOS / Debian ARM64 上运行，Windows 没有 dpkg-deb 命令 !!
# 用法: bash build_deb.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── 检查是否在 Linux 上运行 ───────────────────────────────────────────────────
if ! command -v dpkg-deb >/dev/null 2>&1; then
    echo "错误：dpkg-deb 命令不存在。"
    echo "请把整个 nas_login 目录复制到 UOS 上，再运行此脚本。"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_DIR="$SCRIPT_DIR/deb_build/teacher-nas_1.0.0_all"
ASSETS_SRC="$SCRIPT_DIR/assets"
ASSETS_DST="$PKG_DIR/usr/share/teacher-nas/assets"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  教师文件夹 NAS 登录器 · deb 打包脚本"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── 步骤 1：复制 assets 资源文件进 deb 目录 ───────────────────────────────────
echo "步骤 1/4  复制资源文件..."
mkdir -p "$ASSETS_DST"
mkdir -p "$PKG_DIR/usr/share/pixmaps"

if [ -f "$ASSETS_SRC/background.jpg" ]; then
    cp "$ASSETS_SRC/background.jpg" "$ASSETS_DST/"
    echo "  ✓ background.jpg"
else
    echo "  ⚠ 未找到 assets/background.jpg，程序将使用纯色背景"
fi

if [ -f "$ASSETS_SRC/logo.png" ]; then
    cp "$ASSETS_SRC/logo.png" "$ASSETS_DST/"
    cp "$ASSETS_SRC/logo.png" "$PKG_DIR/usr/share/pixmaps/teacher-nas.png"
    echo "  ✓ logo.png（同时复制到系统图标目录）"
else
    echo "  ⚠ 未找到 assets/logo.png，桌面图标将使用系统默认图标"
fi

# 检查 GPG 公钥是否已放入 deb 目录（由 sign_deb.sh 生成）
PUBKEY_IN_DEB="$PKG_DIR/usr/share/teacher-nas/teacher-nas-key.gpg"
if [ -f "$PUBKEY_IN_DEB" ]; then
    echo "  ✓ GPG 公钥已就位（teacher-nas-key.gpg）"
else
    echo "  ⚠ GPG 公钥未找到，安装时将无法自动导入公钥"
    echo "    → 打包完成后请运行: bash sign_deb.sh"
fi

# 同步 postinst 到 usr/share（供 install_uos.sh 补跑用）
cp "$PKG_DIR/DEBIAN/postinst" "$PKG_DIR/usr/share/teacher-nas/postinst"
echo "  ✓ postinst 已同步到 usr/share/teacher-nas/"

# ── 步骤 2：设置文件权限 ──────────────────────────────────────────────────────
echo ""
echo "步骤 2/4  设置文件权限..."
chmod 755 "$PKG_DIR/DEBIAN/postinst"
chmod 755 "$PKG_DIR/DEBIAN/prerm"
chmod 755 "$PKG_DIR/usr/bin/teacher-nas"
chmod 755 "$PKG_DIR/usr/share/teacher-nas/postinst"
chmod 644 "$PKG_DIR/usr/share/teacher-nas/nas_mounter.py"
chmod 644 "$PKG_DIR/usr/share/applications/teacher-nas.desktop"
find "$ASSETS_DST" -type f -exec chmod 644 {} \; 2>/dev/null || true
echo "  ✓ 权限设置完成"

# ── 步骤 3：计算包大小 ────────────────────────────────────────────────────────
echo ""
echo "步骤 3/4  计算包大小..."
INSTALLED_SIZE=$(du -sk "$PKG_DIR/usr" 2>/dev/null | cut -f1)
if grep -q "^Installed-Size:" "$PKG_DIR/DEBIAN/control"; then
    sed -i "s/^Installed-Size:.*/Installed-Size: $INSTALLED_SIZE/" "$PKG_DIR/DEBIAN/control"
else
    echo "Installed-Size: $INSTALLED_SIZE" >> "$PKG_DIR/DEBIAN/control"
fi
echo "  ✓ Installed-Size: ${INSTALLED_SIZE} KB"

# ── 步骤 4：生成 .deb 包 ──────────────────────────────────────────────────────
echo ""
echo "步骤 4/4  生成 .deb 包..."
OUTPUT="$SCRIPT_DIR/teacher-nas_1.0.0_all.deb"
dpkg-deb --build --root-owner-group "$PKG_DIR" "$OUTPUT"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅  打包成功！"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  deb 包位置: $OUTPUT"
echo "  包大小:     $(du -sh "$OUTPUT" | cut -f1)"
echo ""
echo "  ─── 安装方式（推荐）───────────────────────────────────────────"
echo "  bash install_uos.sh"
echo "  （自动绕过 UOS 安全钩子，安装后补跑配置，一键完成）"
echo ""
echo "  ─── 如需 GPG 签名（让老师双击安装）──────────────────────────"
echo "  bash sign_deb.sh"
echo ""
