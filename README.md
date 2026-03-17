# 教师文件夹 · NAS 登录器

> **平台**：统信 UOS 桌面版 · ARM64（华为笔记本）  
> **底层**：Debian 10+ · apt 包管理  
> **GUI**：GTK3 + PyGObject (Python 3)  
> **功能**：仿校园登录界面，一键挂载 3 个 NAS SMB 共享目录

---

## 界面效果

```
┌─────────────────────────────────────────────────────────┐
│  [校园背景图]              [校徽 Logo + 学校名称]        │
│                                                          │
│              ┌─────────────────────────┐                │
│              │      教师文件夹          │                │
│              │                         │                │
│              │  账号  [___________]    │                │
│              │  密码  [***********]    │                │
│              │                         │                │
│              │  ☑ 记住账号密码          │                │
│              │                         │                │
│              │       [  登  录  ]      │                │
│              └─────────────────────────┘                │
└─────────────────────────────────────────────────────────┘
```

登录成功后自动挂载并弹出进度窗口：

```
正在挂载共享目录
  ○ 照片和视频   连接中…
  ○ 公共空间     连接中…
  ○ homes        连接中…
       ↓
  ✓ 照片和视频   已挂载
  ✓ 公共空间     已挂载
  ✓ homes        已挂载
```

---

## 3 个共享目录说明

| 共享名 | NAS 地址 | 挂载到本地 |
|--------|----------|------------|
| 照片和视频 | 192.168.30.98 | `~/NAS/photos/` |
| 公共空间   | 192.168.30.98 | `~/NAS/public/` |
| homes      | 192.168.30.99 | `~/NAS/homes/`  |

---

## 一、前置条件：开启 UOS 开发者模式

统信 UOS **默认没有 sudo 权限**，必须先开启：

1. 打开「**控制中心**」
2. 进入「**通用**」→「**开发者选项**」
3. 用**微信扫码**登录并绑定手机号
4. 点击开启开发者模式，**重启终端**

---

## 二、文件结构

将整个 `nas_login/` 目录拷贝到 UOS 笔记本，推荐放到 `~/nas_login/`：

```
nas_login/
├── nas_mounter.py          # 主程序（GTK3 登录界面）
├── install.sh              # 一键安装脚本
├── README.md               # 本文件
└── assets/
    ├── README.txt          # 资源目录说明
    ├── gen_background.py   # 可选：生成示例背景图
    ├── background.jpg      # 登录背景图（自行替换）
    └── logo.png            # 校徽 Logo（自行替换）
```

---

## 三、一键安装

```bash
cd ~/nas_login
chmod +x install.sh
bash install.sh
```

安装脚本自动完成：

| 步骤 | 说明 |
|------|------|
| 检测 sudo 权限 | 未开发者模式时给出图文引导 |
| 安装 `cifs-utils` | SMB 挂载支持（内核级） |
| 安装 `python3-gi` | GTK3 Python 绑定 |
| 安装 `gir1.2-gtk-3.0` | GTK3 类型信息 |
| 安装 `gir1.2-notify-0.7` | 系统桌面通知 |
| 配置 sudoers 免密 | 仅对 `mount`/`umount` 免密 |
| 创建桌面快捷方式 | 双击直接打开 |
| 测试网络连通性 | ping 两台 NAS |

---

## 四、启动程序

```bash
python3 ~/nas_login/nas_mounter.py
```

或双击桌面「**教师文件夹**」图标。

---

## 五、替换背景图和 Logo（可选）

```bash
# 替换背景图（学校照片）
cp 你的背景图.jpg ~/nas_login/assets/background.jpg

# 替换校徽 Logo
cp 校徽.png ~/nas_login/assets/logo.png

# 若无图片，可生成示例背景图（需要 Pillow）
sudo apt install python3-pil
python3 ~/nas_login/assets/gen_background.py
```

---

## 六、常见问题

### ❌ 挂载失败：账号或密码错误
- 检查 NAS 账号是否存在，测试账号：`000` / 密码 `123`

### ❌ 挂载失败：无法连接主机
```bash
ping 192.168.30.98
ping 192.168.30.99
# 检查 SMB 端口
nc -zv 192.168.30.98 445
```

### ❌ 提示"Operation not permitted"或需要每次输密码
```bash
# 检查 sudoers 配置
sudo cat /etc/sudoers.d/teacher-nas
# 重新配置
echo "$(whoami) ALL=(ALL) NOPASSWD: /bin/mount, /bin/umount" \
    | sudo tee /etc/sudoers.d/teacher-nas
sudo chmod 440 /etc/sudoers.d/teacher-nas
```

### ❌ GTK3 无法启动（No module named 'gi'）
```bash
sudo apt install python3-gi python3-gi-cairo gir1.2-gtk-3.0
```

### ❌ 中文共享名挂载失败
确认 `cifs-utils` 版本支持 UTF-8（UOS/Debian 的版本通常没问题）：
```bash
sudo mount -t cifs "//192.168.30.98/照片和视频" ~/NAS/photos \
  -o username=000,password=123,iocharset=utf8,vers=3.0
```

### 查看详细日志
```bash
tail -f ~/.config/teacher-nas/teacher-nas.log
```

---

## 七、卸载

```bash
# 卸载挂载点
sudo umount ~/NAS/photos ~/NAS/public ~/NAS/homes

# 删除 sudoers 规则
sudo rm -f /etc/sudoers.d/teacher-nas

# 删除程序文件
rm -rf ~/nas_login
rm -f ~/Desktop/teacher-nas.desktop ~/桌面/teacher-nas.desktop
rm -rf ~/.config/teacher-nas
rm -f ~/.config/autostart/teacher-nas.desktop
```
