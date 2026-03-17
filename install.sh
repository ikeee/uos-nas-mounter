#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 教师文件夹 NAS 登录器 · 安装脚本
# 适用: 统信 UOS 桌面版 · ARM64 (Debian)
# 用法: bash install.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
BLU='\033[0;34m'; CYN='\033[0;36m'; NC='\033[0m'
BOLD='\033[1m'

info()  { echo -e "${BLU}[信息]${NC} $*"; }
ok()    { echo -e "${GRN}[完成]${NC} $*"; }
warn()  { echo -e "${YLW}[警告]${NC} $*"; }
err()   { echo -e "${RED}[错误]${NC} $*"; exit 1; }
step()  { echo -e "\n${BOLD}${CYN}▶ $*${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo -e "${BLU}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BLU}║   教师文件夹 NAS 登录器 · 安装向导                  ║${NC}"
echo -e "${BLU}║   统信 UOS ARM64 / Debian                           ║${NC}"
echo -e "${BLU}╚══════════════════════════════════════════════════════╝${NC}"

# ── 步骤 1: 系统检测 ──────────────────────────────────────────────────────────
step "步骤 1/7  检测系统环境"

ARCH=$(uname -m)
info "CPU 架构: $ARCH"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    info "操作系统: ${PRETTY_NAME:-未知}"
fi

if ! command -v apt &>/dev/null; then
    err "未找到 apt 包管理器，本脚本仅支持统信 UOS / Debian 系系统"
fi
ok "系统检测通过"

# ── 步骤 2: 检测开发者模式（sudo 权限） ───────────────────────────────────────
step "步骤 2/7  检测 sudo 权限（UOS 开发者模式）"

if ! sudo -v 2>/dev/null; then
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ⚠ 无法获取 sudo 权限，需要先开启 UOS 开发者模式   ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  开启步骤:"
    echo "  1. 打开「控制中心」"
    echo "  2. 点击「通用」→「开发者选项」"
    echo "  3. 使用微信扫码登录，绑定手机号后开启"
    echo "  4. 重新打开终端，再次运行此脚本"
    echo ""
    exit 1
fi
ok "sudo 权限正常"

# ── 步骤 3: 更新软件源 ────────────────────────────────────────────────────────
step "步骤 3/7  更新软件包索引"
sudo apt-get update -qq 2>/dev/null && ok "软件源更新完成" || warn "软件源更新失败，继续安装…"

# ── 步骤 4: 安装 SMB 挂载工具 ────────────────────────────────────────────────
step "步骤 4/7  安装 SMB 挂载依赖 (cifs-utils)"

if dpkg -s cifs-utils &>/dev/null 2>&1; then
    ok "cifs-utils 已安装，跳过"
else
    info "正在安装 cifs-utils..."
    sudo apt-get install -y cifs-utils \
        || err "cifs-utils 安装失败，请手动执行: sudo apt install cifs-utils"
    ok "cifs-utils 安装完成"
fi

# ── 步骤 5: 安装 GTK3 Python 绑定 ────────────────────────────────────────────
step "步骤 5/7  安装 GTK3 Python 绑定 (PyGObject)"

PKGS_NEEDED=()
PKG_LIST=(
    "python3"
    "python3-gi"
    "python3-gi-cairo"
    "gir1.2-gtk-3.0"
    "gir1.2-notify-0.7"
    "libgtk-3-0"
)

for pkg in "${PKG_LIST[@]}"; do
    if ! dpkg -s "$pkg" &>/dev/null 2>&1; then
        PKGS_NEEDED+=("$pkg")
    fi
done

if [ ${#PKGS_NEEDED[@]} -eq 0 ]; then
    ok "GTK3 依赖已全部安装，跳过"
else
    info "正在安装: ${PKGS_NEEDED[*]}"
    sudo apt-get install -y "${PKGS_NEEDED[@]}" \
        || err "GTK3 依赖安装失败\n手动执行: sudo apt install python3-gi python3-gi-cairo gir1.2-gtk-3.0"
    ok "GTK3 依赖安装完成"
fi

# 验证 GTK3 可用
if ! python3 -c "
import gi
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk
" 2>/dev/null; then
    err "GTK3 Python 绑定验证失败，请检查 DISPLAY 环境变量或重新安装"
fi
ok "GTK3 Python 绑定验证通过"

# ── 步骤 6: 配置 mount/umount sudo 免密 ──────────────────────────────────────
step "步骤 6/7  配置 mount/umount sudo 免密"

SUDOERS_FILE="/etc/sudoers.d/teacher-nas"
ME=$(whoami)

SUDOERS_LINE="${ME} ALL=(ALL) NOPASSWD: /bin/mount, /bin/umount, /usr/bin/mount, /usr/bin/umount"

if sudo test -f "$SUDOERS_FILE" 2>/dev/null; then
    ok "sudo 免密规则已存在，跳过"
else
    echo "$SUDOERS_LINE" | sudo tee "$SUDOERS_FILE" > /dev/null
    sudo chmod 440 "$SUDOERS_FILE"
    if sudo visudo -cf "$SUDOERS_FILE" 2>/dev/null; then
        ok "sudo 免密规则已配置 ($SUDOERS_FILE)"
    else
        sudo rm -f "$SUDOERS_FILE"
        warn "sudoers 语法验证失败，已回滚。挂载时会弹出密码输入框。"
    fi
fi

# ── 步骤 7: 创建桌面快捷方式 ─────────────────────────────────────────────────
step "步骤 7/7  创建桌面快捷方式"

DESKTOP_CONTENT="[Desktop Entry]
Version=1.0
Type=Application
Name=教师文件夹
Name[zh_CN]=教师文件夹
Comment=NAS SMB 登录器
Comment[zh_CN]=NAS SMB 登录器
Exec=python3 ${SCRIPT_DIR}/nas_mounter.py
Icon=network-server
Terminal=false
Categories=Network;FileManager;
StartupNotify=true"

CREATED_DESKTOP=0
for DESK_DIR in "$HOME/Desktop" "$HOME/桌面"; do
    if [ -d "$DESK_DIR" ]; then
        TARGET="$DESK_DIR/teacher-nas.desktop"
        echo "$DESKTOP_CONTENT" > "$TARGET"
        chmod +x "$TARGET"
        ok "桌面快捷方式: $TARGET"
        CREATED_DESKTOP=1
    fi
done
[ $CREATED_DESKTOP -eq 0 ] && warn "未找到桌面目录，跳过快捷方式创建"

# 创建挂载根目录
mkdir -p "$HOME/NAS"
ok "挂载目录: $HOME/NAS/"

# ── 网络测试 ──────────────────────────────────────────────────────────────────
echo ""
info "测试 NAS 网络连通性..."
for IP in 192.168.30.98 192.168.30.99; do
    if ping -c 1 -W 2 "$IP" &>/dev/null; then
        ok "$IP  可达 ✓"
    else
        warn "$IP  无法 ping 通（SMB 端口可能仍可用）"
    fi
done

# ── 完成 ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GRN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GRN}║              ✅  安装完成！                          ║${NC}"
echo -e "${GRN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  启动方式（任选）："
echo -e "  ${YLW}方式 1${NC}: 双击桌面「教师文件夹」图标"
echo -e "  ${YLW}方式 2${NC}: 终端运行:"
echo -e "          ${CYN}python3 ${SCRIPT_DIR}/nas_mounter.py${NC}"
echo ""
echo "  【可选】放置背景图："
echo "  将学校背景图命名为 background.jpg"
echo "  复制到: ${SCRIPT_DIR}/assets/background.jpg"
echo ""
echo "  【可选】放置校徽 Logo："
echo "  将校徽图命名为 logo.png（宽240px），"
echo "  复制到: ${SCRIPT_DIR}/assets/logo.png"
echo ""
echo "  配置文件: $HOME/.config/teacher-nas/config.json"
echo "  操作日志: $HOME/.config/teacher-nas/teacher-nas.log"
echo ""
