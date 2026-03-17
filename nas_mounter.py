#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
教师文件夹 NAS 登录器
平台: 统信 UOS · ARM64 (Debian)
UI  : GTK3 + PyGObject
功能: 登录后自动挂载 3 个 SMB 共享目录
"""

import gi
gi.require_version('Gtk', '3.0')
try:
    gi.require_version('Notify', '0.7')
    from gi.repository import Notify
    HAS_NOTIFY = True
except Exception:
    HAS_NOTIFY = False

from gi.repository import Gtk, GLib, Gdk, GdkPixbuf, Pango

import os
import subprocess
import threading
import json
import logging
import shutil
from pathlib import Path

# ═══════════════════════════════════════════════════════════════════════════════
#  配置
# ═══════════════════════════════════════════════════════════════════════════════
APP_NAME    = "教师文件夹"
APP_VERSION = "2.0.0"
CONFIG_DIR  = Path.home() / ".config" / "teacher-nas"
CONFIG_FILE = CONFIG_DIR / "config.json"
LOG_FILE    = CONFIG_DIR / "teacher-nas.log"
MOUNT_BASE  = Path.home() / "NAS"
BG_IMAGE    = Path(__file__).parent / "assets" / "background.jpg"

# 3 个共享目录（与图片完全对应）
SHARES = [
    {
        "label":  "照片和视频",
        "host":   "192.168.30.98",
        "share":  "照片和视频",       # NAS 上的共享文件夹名
        "mount":  "photos",          # 本地挂载目录名（ASCII，避免路径问题）
    },
    {
        "label":  "公共空间",
        "host":   "192.168.30.98",
        "share":  "公共空间",
        "mount":  "public",
    },
    {
        "label":  "homes",
        "host":   "192.168.30.99",
        "share":  "homes",
        "mount":  "homes",
    },
]

DEFAULT_CONFIG = {
    "username":      "",
    "password":      "",
    "save_password": False,
}

# ═══════════════════════════════════════════════════════════════════════════════
#  日志
# ═══════════════════════════════════════════════════════════════════════════════
CONFIG_DIR.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(LOG_FILE),
        logging.StreamHandler(),
    ]
)
log = logging.getLogger(__name__)

# ═══════════════════════════════════════════════════════════════════════════════
#  配置管理
# ═══════════════════════════════════════════════════════════════════════════════
def load_config() -> dict:
    if CONFIG_FILE.exists():
        try:
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                return {**DEFAULT_CONFIG, **json.load(f)}
        except Exception as e:
            log.warning(f"加载配置失败: {e}")
    return dict(DEFAULT_CONFIG)


def save_config(cfg: dict):
    try:
        with open(CONFIG_FILE, "w", encoding="utf-8") as f:
            json.dump(cfg, f, ensure_ascii=False, indent=2)
    except Exception as e:
        log.error(f"保存配置失败: {e}")

# ═══════════════════════════════════════════════════════════════════════════════
#  SMB 挂载逻辑
# ═══════════════════════════════════════════════════════════════════════════════
def get_mount_point(s: dict) -> Path:
    return MOUNT_BASE / s["mount"]


def is_mounted(mp: Path) -> bool:
    try:
        r = subprocess.run(["findmnt", "-n", str(mp)], capture_output=True)
        return r.returncode == 0
    except FileNotFoundError:
        try:
            return str(mp) in Path("/proc/mounts").read_text()
        except Exception:
            return False


def get_mounted_user(mp: Path) -> str:
    """从 /proc/mounts 读取已挂载的 SMB 用户名，找不到返回空字符串"""
    try:
        for line in Path("/proc/mounts").read_text().splitlines():
            parts = line.split()
            # 格式: device mountpoint fstype options ...
            if len(parts) >= 4 and parts[1] == str(mp):
                # options 示例: username=admin,password=...,uid=...
                for opt in parts[3].split(","):
                    if opt.startswith("username="):
                        return opt.split("=", 1)[1]
    except Exception:
        pass
    return ""


def _do_umount(mp: Path):
    """卸载挂载点，失败则懒卸载"""
    try:
        r = subprocess.run(["sudo", "umount", str(mp)],
                           capture_output=True, text=True, timeout=10)
        if r.returncode != 0:
            subprocess.run(["sudo", "umount", "-l", str(mp)],
                           capture_output=True, timeout=10)
    except Exception as e:
        log.warning(f"卸载失败 {mp}: {e}")


def _try_mount(smb_path: str, mp: Path, opts: str):
    """执行一次 mount.cifs，返回 (ok, stderr)"""
    cmd = ["sudo", "mount", "-t", "cifs", smb_path, str(mp), "-o", opts]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        return r.returncode == 0, r.stderr.strip()
    except subprocess.TimeoutExpired:
        return False, "连接超时"
    except Exception as e:
        return False, str(e)


def mount_share(s: dict, username: str, password: str):
    mp = get_mount_point(s)
    mp.mkdir(parents=True, exist_ok=True)

    # 如果已挂载，检查是否是同一账号
    if is_mounted(mp):
        mounted_user = get_mounted_user(mp)
        if mounted_user and mounted_user.lower() == username.lower():
            # 账号一致，无需重新挂载
            log.info(f"[{s['label']}] 已以 {username} 挂载，跳过")
            return True, f"{s['label']} 已挂载"
        else:
            # 账号不同（或无法读取），先卸载再重新挂载
            log.info(f"[{s['label']}] 检测到账号变更（{mounted_user} → {username}），重新挂载")
            _do_umount(mp)

    smb_path = f"//{s['host']}/{s['share']}"
    uid, gid = os.getuid(), os.getgid()
    base_opts = f"username={username},password={password},uid={uid},gid={gid},iocharset=utf8"

    err = ""
    # 依次尝试 SMB 3.0 → 2.1 → 2.0 → 1.0
    for ver in ("3.0", "2.1", "2.0", "1.0"):
        ok, err = _try_mount(smb_path, mp, f"{base_opts},vers={ver}")
        if ok:
            log.info(f"挂载成功 [{s['label']}] vers={ver}")
            return True, f"{s['label']} 挂载成功"
        log.debug(f"vers={ver} 失败: {err}")

    log.error(f"挂载失败 [{s['label']}]: {err}")
    if "Permission denied" in err or "LOGON_FAILURE" in err:
        return False, "账号或密码错误"
    if "No route to host" in err or "Connection refused" in err:
        return False, f"无法连接 {s['host']}，请检查网络"
    return False, f"{s['label']} 挂载失败: {err or '未知错误'}"


def unmount_share(s: dict):
    mp = get_mount_point(s)
    if not is_mounted(mp):
        return True, f"{s['label']} 未挂载"
    try:
        r = subprocess.run(["sudo", "umount", str(mp)],
                           capture_output=True, text=True, timeout=10)
        if r.returncode == 0:
            return True, f"{s['label']} 已卸载"
        # 懒卸载
        subprocess.run(["sudo", "umount", "-l", str(mp)],
                       capture_output=True, timeout=10)
        return True, f"{s['label']} 已强制卸载"
    except Exception as e:
        return False, str(e)


def open_mount_point(s: dict):
    mp = get_mount_point(s)
    if mp.exists():
        try:
            subprocess.Popen(["xdg-open", str(mp)])
        except Exception as e:
            log.warning(f"打开文件管理器失败: {e}")

# ═══════════════════════════════════════════════════════════════════════════════
#  CSS 样式
# ═══════════════════════════════════════════════════════════════════════════════
CSS = """
/* login card */
.login-card {
    background-color: rgba(255, 255, 255, 0.97);
    border-radius: 4px;
    padding: 36px 48px 40px 48px;
}

/* title */
.login-title {
    color: #4169E1;
    font-size: 28px;
    font-weight: bold;
    letter-spacing: 2px;
}

/* field label */
.field-label {
    font-size: 15px;
    color: #333333;
    min-width: 40px;
}

/* entry */
.login-entry {
    font-size: 15px;
    border: 1px solid #cccccc;
    border-radius: 2px;
    padding: 6px 8px;
    min-width: 220px;
    background-color: white;
}
.login-entry:focus {
    border-color: #4169E1;
}

/* remember checkbox */
.remember-check {
    font-size: 13px;
    color: #4169E1;
}
.remember-check check {
    background-color: white;
    border: 1px solid #4169E1;
}
.remember-check:checked check {
    background-color: #4169E1;
}

/* login button */
.login-btn {
    background-color: #4169E1;
    color: white;
    font-size: 18px;
    font-weight: bold;
    letter-spacing: 4px;
    border-radius: 4px;
    border: none;
    padding: 10px 0;
    min-width: 280px;
}
.login-btn:hover {
    background-color: #3558c8;
}
.login-btn:active {
    background-color: #2a47b0;
}
.login-btn:disabled {
    background-color: #9aabe8;
}

/* error label */
.error-label {
    color: #e74c3c;
    font-size: 13px;
}

/* progress dialog */
.progress-title {
    font-size: 15px;
    font-weight: bold;
    color: #333333;
}
.progress-sub {
    font-size: 13px;
    color: #666666;
}
"""

# ═══════════════════════════════════════════════════════════════════════════════
#  登录窗口
# ═══════════════════════════════════════════════════════════════════════════════
class LoginWindow(Gtk.Window):

    def __init__(self, config: dict):
        super().__init__(title=APP_NAME)
        self.config = config
        self.set_default_size(900, 560)
        self.set_resizable(False)
        self.set_position(Gtk.WindowPosition.CENTER)

        self._apply_css()
        self._build_ui()

    # ── CSS ───────────────────────────────────────────────────────────────────
    def _apply_css(self):
        provider = Gtk.CssProvider()
        provider.load_from_data(CSS.encode("utf-8"))
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(),
            provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION,
        )

    # ── 构建 UI ───────────────────────────────────────────────────────────────
    def _build_ui(self):
        # 最外层：overlay，背景图 + 登录卡片叠加
        overlay = Gtk.Overlay()
        self.add(overlay)

        # ── 背景层 ────────────────────────────────────────────────────────────
        self.bg_area = Gtk.DrawingArea()
        self.bg_area.connect("draw", self._on_draw_bg)
        overlay.add(self.bg_area)

        # ── 居中登录卡片 ───────────────────────────────────────────────────────
        center = Gtk.Box()
        center.set_halign(Gtk.Align.CENTER)
        center.set_valign(Gtk.Align.CENTER)
        overlay.add_overlay(center)

        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        card.get_style_context().add_class("login-card")
        center.add(card)

        # 标题
        title = Gtk.Label(label="教师文件夹")
        title.get_style_context().add_class("login-title")
        title.set_margin_bottom(28)
        card.pack_start(title, False, False, 0)

        # 表单 grid
        grid = Gtk.Grid(column_spacing=12, row_spacing=14)
        card.pack_start(grid, False, False, 0)

        # 账号
        lbl_user = Gtk.Label(label="账号")
        lbl_user.get_style_context().add_class("field-label")
        lbl_user.set_halign(Gtk.Align.END)
        grid.attach(lbl_user, 0, 0, 1, 1)

        self.entry_user = Gtk.Entry()
        self.entry_user.get_style_context().add_class("login-entry")
        self.entry_user.set_text(self.config.get("username", ""))
        self.entry_user.connect("activate", self._on_login)
        grid.attach(self.entry_user, 1, 0, 1, 1)

        # 密码
        lbl_pass = Gtk.Label(label="密码")
        lbl_pass.get_style_context().add_class("field-label")
        lbl_pass.set_halign(Gtk.Align.END)
        grid.attach(lbl_pass, 0, 1, 1, 1)

        self.entry_pass = Gtk.Entry()
        self.entry_pass.get_style_context().add_class("login-entry")
        self.entry_pass.set_visibility(False)
        self.entry_pass.set_input_purpose(Gtk.InputPurpose.PASSWORD)
        if self.config.get("save_password"):
            self.entry_pass.set_text(self.config.get("password", ""))
        self.entry_pass.connect("activate", self._on_login)
        grid.attach(self.entry_pass, 1, 1, 1, 1)

        # 记住密码
        remember_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        remember_box.set_halign(Gtk.Align.END)
        self.chk_remember = Gtk.CheckButton(label="记住账号密码")
        self.chk_remember.get_style_context().add_class("remember-check")
        self.chk_remember.set_active(self.config.get("save_password", False))
        remember_box.pack_end(self.chk_remember, False, False, 0)
        grid.attach(remember_box, 0, 2, 2, 1)

        # 错误提示
        self.error_lbl = Gtk.Label(label="")
        self.error_lbl.get_style_context().add_class("error-label")
        self.error_lbl.set_halign(Gtk.Align.CENTER)
        self.error_lbl.set_no_show_all(True)
        card.pack_start(self.error_lbl, False, False, 6)

        # 登录按钮
        self.btn_login = Gtk.Button(label="登  录")
        self.btn_login.get_style_context().add_class("login-btn")
        self.btn_login.set_margin_top(20)
        self.btn_login.connect("clicked", self._on_login)
        card.pack_start(self.btn_login, False, False, 0)

        # 加载背景图（异步，避免阻塞）
        self._bg_pixbuf = None
        if BG_IMAGE.exists():
            try:
                self._bg_pixbuf = GdkPixbuf.Pixbuf.new_from_file(str(BG_IMAGE))
            except Exception as e:
                log.warning(f"加载背景图失败: {e}")

        self.show_all()
        # 默认焦点
        if not self.entry_user.get_text():
            self.entry_user.grab_focus()
        else:
            self.entry_pass.grab_focus()

    # ── 背景绘制 ──────────────────────────────────────────────────────────────
    def _on_draw_bg(self, widget, cr):
        w = widget.get_allocated_width()
        h = widget.get_allocated_height()

        if self._bg_pixbuf:
            # 等比缩放适配窗口，再整体缩小 5% 确保内容完整显示
            img_w = self._bg_pixbuf.get_width()
            img_h = self._bg_pixbuf.get_height()
            scale = max(w / img_w, h / img_h) * 0.95
            new_w = int(img_w * scale)
            new_h = int(img_h * scale)
            scaled = self._bg_pixbuf.scale_simple(
                new_w, new_h, GdkPixbuf.InterpType.BILINEAR)
            ox = (w - new_w) // 2
            oy = (h - new_h) // 2
            Gdk.cairo_set_source_pixbuf(cr, scaled, ox, oy)
        else:
            # 渐变蓝色背景（无背景图时）
            import cairo
            grad = cairo.LinearGradient(0, 0, w, h)
            grad.add_color_stop_rgb(0.0, 0.35, 0.55, 0.75)
            grad.add_color_stop_rgb(1.0, 0.55, 0.70, 0.85)
            cr.set_source(grad)

        cr.paint()
        return False

    # ── 登录逻辑 ──────────────────────────────────────────────────────────────
    def _on_login(self, _):
        username = self.entry_user.get_text().strip()
        password = self.entry_pass.get_text()

        if not username:
            self._show_error("请输入账号")
            self.entry_user.grab_focus()
            return
        if not password:
            self._show_error("请输入密码")
            self.entry_pass.grab_focus()
            return

        self._hide_error()
        self.btn_login.set_sensitive(False)
        self.btn_login.set_label("连接中…")

        # 保存配置
        self.config["username"] = username
        self.config["save_password"] = self.chk_remember.get_active()
        self.config["password"] = password if self.chk_remember.get_active() else ""
        save_config(self.config)

        # 弹出进度对话框
        self._progress_dlg = MountProgressDialog(self, username, password)
        self._progress_dlg.connect("destroy", self._on_progress_closed)
        self._progress_dlg.start()

    def _on_progress_closed(self, dlg):
        self.btn_login.set_sensitive(True)
        self.btn_login.set_label("登  录")

    def _show_error(self, msg: str):
        self.error_lbl.set_text(msg)
        self.error_lbl.show()

    def _hide_error(self):
        self.error_lbl.hide()


# ═══════════════════════════════════════════════════════════════════════════════
#  挂载进度对话框
# ═══════════════════════════════════════════════════════════════════════════════
class MountProgressDialog(Gtk.Dialog):
    """显示 3 个共享目录的挂载进度"""

    def __init__(self, parent: Gtk.Window, username: str, password: str):
        super().__init__(
            title="正在连接...",
            transient_for=parent,
            modal=True,
            destroy_with_parent=True,
        )
        self.username = username
        self.password = password
        self.set_default_size(360, 220)
        self.set_resizable(False)
        self.set_position(Gtk.WindowPosition.CENTER_ON_PARENT)

        # 结果跟踪
        self._results = []  # list of (ok, msg, share)
        self._row_refs = {}  # mount_name -> {stack, status, spinner}

        self._build_content()
        self.show_all()

    def _build_content(self):
        area = self.get_content_area()
        area.set_spacing(0)
        area.set_margin_start(24)
        area.set_margin_end(24)
        area.set_margin_top(20)
        area.set_margin_bottom(20)

        # 标题
        ttl = Gtk.Label(label="正在挂载共享目录")
        ttl.get_style_context().add_class("progress-title")
        ttl.set_halign(Gtk.Align.START)
        ttl.set_margin_bottom(16)
        area.pack_start(ttl, False, False, 0)

        # 每个共享一行
        for s in SHARES:
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
            row.set_margin_bottom(8)

            # 图标（spinner / ✓ / ✗）
            spinner = Gtk.Spinner()
            spinner.set_size_request(20, 20)
            spinner.start()

            icon_stack = Gtk.Stack()
            icon_stack.set_transition_type(Gtk.StackTransitionType.CROSSFADE)
            icon_stack.set_transition_duration(200)
            icon_stack.add_named(spinner, "spin")

            ok_lbl = Gtk.Label()
            ok_lbl.set_markup('<span foreground="#27ae60" font_desc="Bold 15">✓</span>')
            icon_stack.add_named(ok_lbl, "ok")

            err_lbl = Gtk.Label()
            err_lbl.set_markup('<span foreground="#e74c3c" font_desc="Bold 15">✗</span>')
            icon_stack.add_named(err_lbl, "err")

            icon_stack.set_visible_child_name("spin")

            # 标签
            name_lbl = Gtk.Label(label=s["label"])
            name_lbl.set_halign(Gtk.Align.START)
            name_lbl.set_hexpand(True)
            name_lbl.get_style_context().add_class("progress-sub")

            # 状态文字
            status_lbl = Gtk.Label(label="等待中…")
            status_lbl.get_style_context().add_class("progress-sub")
            status_lbl.set_halign(Gtk.Align.END)

            row.pack_start(icon_stack, False, False, 0)
            row.pack_start(name_lbl, True, True, 0)
            row.pack_end(status_lbl, False, False, 0)
            area.pack_start(row, False, False, 0)

            self._row_refs[s["mount"]] = {
                "stack":  icon_stack,
                "status": status_lbl,
                "spinner": spinner,
            }

        area.show_all()

    # ── 启动挂载线程 ──────────────────────────────────────────────────────────
    def start(self):
        threading.Thread(target=self._mount_all, daemon=True).start()

    def _mount_all(self):
        results = []
        for s in SHARES:
            # 更新 UI：标记为"连接中"
            GLib.idle_add(self._set_status, s["mount"], "spin", "连接中…")
            ok, msg = mount_share(s, self.username, self.password)
            results.append((ok, msg, s))
            icon_name = "ok" if ok else "err"
            text = "已挂载" if ok else msg
            GLib.idle_add(self._set_status, s["mount"], icon_name, text)
            if ok:
                GLib.idle_add(self._row_refs[s["mount"]]["spinner"].stop)

        self._results = results
        GLib.idle_add(self._on_done, results)

    def _set_status(self, mount_name: str, icon: str, text: str):
        row = self._row_refs.get(mount_name)
        if row:
            row["stack"].set_visible_child_name(icon)
            row["status"].set_text(text)

    def _on_done(self, results):
        all_ok   = all(ok for ok, _, __ in results)
        any_ok   = any(ok for ok, _, __ in results)
        failed   = [(msg, s) for ok, msg, s in results if not ok]

        if all_ok:
            # 全部成功：短暂停留后关闭，打开文件管理器
            GLib.timeout_add(800, self._finish_success)
        else:
            # 部分或全部失败：添加关闭按钮
            self.set_title("连接结果")
            if failed:
                area = self.get_content_area()
                err_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
                err_box.set_margin_top(12)
                for msg, s in failed:
                    lbl = Gtk.Label(label=f"  • {s['label']}: {msg}")
                    lbl.set_halign(Gtk.Align.START)
                    lbl.get_style_context().add_class("error-label")
                    err_box.pack_start(lbl, False, False, 0)
                area.pack_start(err_box, False, False, 0)
                err_box.show_all()

            btn_close = self.add_button("关闭", Gtk.ResponseType.CLOSE)
            btn_close.show()
            if any_ok:
                btn_open = self.add_button("打开已挂载的目录", Gtk.ResponseType.OK)
                btn_open.show()
                self.connect("response", self._on_response, results)
            else:
                self.connect("response", lambda d, r: (d.destroy(), Gtk.main_quit()))

    def _on_response(self, dlg, response, results):
        if response == Gtk.ResponseType.OK:
            for ok, _, s in results:
                if ok:
                    open_mount_point(s)
        dlg.destroy()
        Gtk.main_quit()

    def _finish_success(self):
        # 打开所有挂载点
        for s in SHARES:
            if is_mounted(get_mount_point(s)):
                open_mount_point(s)
        # 发送桌面通知
        if HAS_NOTIFY:
            try:
                if not Notify.is_initted():
                    Notify.init(APP_NAME)
                n = Notify.Notification.new(
                    "教师文件夹已连接",
                    "3 个共享目录已成功挂载",
                    "network-server",
                )
                n.show()
            except Exception:
                pass
        # 关闭进度对话框 + 主窗口，退出程序
        self.destroy()
        Gtk.main_quit()
        return False  # 不再重复


# ═══════════════════════════════════════════════════════════════════════════════
#  应用入口
# ═══════════════════════════════════════════════════════════════════════════════
def main():
    config = load_config()
    MOUNT_BASE.mkdir(parents=True, exist_ok=True)

    win = LoginWindow(config)
    win.connect("destroy", Gtk.main_quit)
    win.show_all()
    Gtk.main()


if __name__ == "__main__":
    main()
