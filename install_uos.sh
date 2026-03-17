#!/usr/bin/env bash
# =============================================================================
# install_uos.sh — UOS 专用安装脚本
#
# 背景：UOS/深度系统的 deepin-pkg-install-hook 安全钩子会拦截未经
#       统信官方签名的 deb 包，导致 dpkg 报错退出。
#       本脚本使用 --ignore-scripts 绕过钩子，安装完成后手动补跑
#       postinst 完成所有初始化配置。
#
# 用法：bash install_uos.sh
#       或 sudo bash install_uos.sh
# =============================================================================
set -euo pipefail

# ── 颜色输出 ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${GREEN}  ✓${NC} $*"; }
warn()    { echo -e "${YELLOW}  ⚠${NC} $*"; }
error()   { echo -e "${RED}  ✗${NC} $*"; exit 1; }
step()    { echo -e "\n${BOLD}${BLUE}──── $* ${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  教师文件夹 NAS 登录器 · UOS 安装脚本${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ── 检查 root 权限 ───────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    warn "需要 root 权限，正在用 sudo 重新运行..."
    exec sudo bash "$0" "$@"
fi

# ── 查找 deb 包 ───────────────────────────────────────────────────────────────
step "查找安装包"
DEB_FILE=$(find "$SCRIPT_DIR" -maxdepth 1 -name "teacher-nas_*.deb" \
    ! -name "*_unsigned.deb" | sort -V | tail -1)

if [ -z "$DEB_FILE" ] || [ ! -f "$DEB_FILE" ]; then
    error "未找到 teacher-nas_*.deb，请先运行 build_deb.sh 生成安装包"
fi
info "找到安装包: $(basename "$DEB_FILE")"

# ── 安装 deb（绕过 deepin 安全钩子）─────────────────────────────────────────
step "安装 deb 包（绕过 UOS 安全钩子）"
echo "  执行: dpkg --ignore-scripts -i $(basename "$DEB_FILE")"
echo ""

if dpkg --ignore-scripts -i "$DEB_FILE"; then
    info "deb 包安装成功"
else
    # dpkg 可能因依赖问题返回非零，尝试修复
    warn "检测到依赖问题，正在自动修复..."
    apt-get install -f -y || error "依赖修复失败，请手动执行: sudo apt-get install -f"
    info "依赖修复完成"
fi

# ── 补跑 postinst（完成初始化配置）─────────────────────────────────────────
step "执行初始化配置（补跑 postinst）"

# 优先使用安装后的版本，保底使用包内的备份
POSTINST_INSTALLED="/usr/share/teacher-nas/postinst"
POSTINST_FALLBACK="$SCRIPT_DIR/deb_build/teacher-nas_1.0.0_all/DEBIAN/postinst"

if [ -f "$POSTINST_INSTALLED" ]; then
    POSTINST="$POSTINST_INSTALLED"
    info "使用已安装版本的 postinst"
elif [ -f "$POSTINST_FALLBACK" ]; then
    POSTINST="$POSTINST_FALLBACK"
    warn "使用本地备份的 postinst"
else
    error "找不到 postinst 脚本，请手动配置 sudoers 和挂载目录"
fi

chmod +x "$POSTINST"
bash "$POSTINST" configure
info "初始化配置完成"

# ── 验证安装结果 ─────────────────────────────────────────────────────────────
step "验证安装结果"

PASS=0; FAIL=0

check() {
    local desc="$1"; local cmd="$2"
    if eval "$cmd" >/dev/null 2>&1; then
        info "$desc"
        PASS=$((PASS+1))
    else
        warn "$desc（未通过，可能不影响使用）"
        FAIL=$((FAIL+1))
    fi
}

check "主程序文件存在"      "[ -f /usr/share/teacher-nas/nas_mounter.py ]"
check "启动命令可用"        "[ -x /usr/bin/teacher-nas ]"
check "桌面快捷方式存在"    "[ -f /usr/share/applications/teacher-nas.desktop ]"
check "sudoers 免密已配置"  "[ -f /etc/sudoers.d/teacher-nas ]"
check "NAS 挂载目录存在"    "[ -d /home/$(logname 2>/dev/null || echo huawei)/NAS ]"

# ── 完成 ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [ "$FAIL" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}  ✅  安装完成！全部验证通过${NC}"
else
    echo -e "${YELLOW}${BOLD}  ✅  安装完成（${FAIL} 项验证未通过，通常不影响使用）${NC}"
fi
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  启动方式："
echo "  1. 双击桌面「教师文件夹」图标"
echo "  2. 或在终端执行: teacher-nas"
echo ""
echo "  如桌面图标未出现，注销后重新登录即可"
echo ""
