#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
NarraFork macOS Launcher 打包工具 (macOS GUI / CLI)
优化版：原生文件选择器（绝不置灰）、标准目录框架（bin/dist/assets/src/scripts）
"""

import os
import sys
import re
import shutil
import subprocess
import threading
import tkinter as tk
from tkinter import ttk, filedialog, messagebox, scrolledtext
from PIL import Image, ImageTk

# 标准工程目录定义
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
BIN_DIR = os.path.join(PROJECT_ROOT, "bin")
DIST_DIR = os.path.join(PROJECT_ROOT, "dist")
ASSETS_DIR = os.path.join(PROJECT_ROOT, "assets")
SRC_DIR = os.path.join(PROJECT_ROOT, "src")
SCRIPTS_DIR = os.path.join(PROJECT_ROOT, "scripts")

DEFAULT_APP_OUTPUT = os.path.join(DIST_DIR, "NarraFork.app")
APPLICATIONS_APP = "/Applications/NarraFork.app"
DESKTOP_DIR = os.path.expanduser("~/Desktop")

ICON_PATH = os.path.join(ASSETS_DIR, "AppIcon.icns")
ICON_PNG_PATH = os.path.join(ASSETS_DIR, "NarraFork_1024.png")
WRAPPER_BIN_PATH = os.path.join(ASSETS_DIR, "NarraFork_wrapper")
SWIFT_SRC_PATH = os.path.join(SRC_DIR, "main.swift")

INFO_PLIST_TEMPLATE = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>NarraFork</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>top.maplex.narrafork</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>NarraFork</string>
    <key>CFBundleDisplayName</key>
    <string>NarraFork</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>{version}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSAppSleepDisabled</key>
    <true/>
    <key>LSRequiresNativeExecution</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
"""


def extract_version(filepath):
    """从文件名或二进制信息提取版本号"""
    basename = os.path.basename(filepath)
    match = re.search(r"(\d+\.\d+\.\d+)", basename)
    if match:
        return match.group(1)
    match2 = re.search(r"v?(\d+\.\d+)", basename)
    if match2:
        return match2.group(1)
    return "0.6.6"


def choose_file_macos(initial_dir=""):
    """
    通过 macOS 原生 AppleScript 调用标准 NSOpenPanel
    解决 Tkinter 在 macOS 上因 filetypes 参数导致无扩展名 Unix 二进制文件被置灰无法选中的问题
    """
    if not initial_dir or not os.path.isdir(initial_dir):
        initial_dir = BIN_DIR if os.path.isdir(BIN_DIR) else PROJECT_ROOT

    applescript = f'''
    try
        set defaultPath to POSIX file "{initial_dir}" as alias
        set chosenFile to choose file with prompt "请选择 NarraFork 核心二进制文件:" default location defaultPath
        return POSIX path of chosenFile
    on error
        return ""
    end try
    '''
    try:
        proc = subprocess.run(["osascript", "-e", applescript], capture_output=True, text=True)
        res = proc.stdout.strip()
        if res and os.path.isfile(res):
            return res
    except Exception:
        pass

    # 备用方案：Tkinter 原生对话框（绝对不传 filetypes，避免过滤掉二进制）
    try:
        return filedialog.askopenfilename(
            title="请选择 NarraFork 核心二进制文件",
            initialdir=initial_dir,
        )
    except Exception:
        return ""


def check_and_repair_database(log_fn=print):
    """
    预检并修复 ~/.narrafork/narrafork.db
    彻底规避 Drizzle ORM 153 号迁移 (0153_tan_bushwacker) 在 SQLite 中因表重命名导致的列解析崩溃
    """
    db_path = os.path.expanduser("~/.narrafork/narrafork.db")
    if not os.path.isfile(db_path):
        return

    try:
        import sqlite3
        conn = sqlite3.connect(db_path)
        cur = conn.cursor()

        cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='__drizzle_migrations'")
        if not cur.fetchone():
            conn.close()
            return

        cur.execute("SELECT hash FROM __drizzle_migrations")
        applied = set(r[0] for r in cur.fetchall())

        h153 = "c7b99902ad0e9c6be8886a2959e1b1396a476933996188fac394fe741d1aded6"
        if h153 not in applied:
            log_fn("🔧 检测到数据库待升级，正在进行 153 号迁移结构安全对齐...")
            cur.execute("PRAGMA foreign_keys = OFF")
            cur.execute("""CREATE TABLE IF NOT EXISTS `__new_file_attributions` (
                `id` text PRIMARY KEY NOT NULL,
                `device_id` text DEFAULT 'local' NOT NULL,
                `workspace_path` text NOT NULL,
                `file_path` text NOT NULL,
                `narrator_id` text,
                `user_id` text,
                `subagent_type` text,
                `action` text NOT NULL,
                `tool_name` text,
                `tool_use_id` text,
                `operation_id` text,
                `effect_id` text,
                `scope_id` text,
                `file_key` text,
                `actor_subject_key` text,
                `actor_snapshot_json` text,
                `attribution_grade` text,
                `lines_added` integer,
                `lines_removed` integer,
                `changed_at` text NOT NULL,
                CONSTRAINT "ck_file_attr_line_counts" CHECK(
                    ("lines_added" IS NULL OR (typeof("lines_added") = 'integer' AND "lines_added" >= 0))
                    AND ("lines_removed" IS NULL OR (typeof("lines_removed") = 'integer' AND "lines_removed" >= 0))
                )
            )""")
            cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='file_attributions'")
            if cur.fetchone():
                cur.execute("PRAGMA table_info(file_attributions)")
                cols = [r[1] for r in cur.fetchall()]
                common_cols = [c for c in ["id", "device_id", "workspace_path", "file_path", "narrator_id", "user_id", "subagent_type", "action", "tool_name", "tool_use_id", "lines_added", "lines_removed", "changed_at"] if c in cols]
                cols_str = ", ".join(f'"{c}"' for c in common_cols)
                cur.execute(f'INSERT INTO `__new_file_attributions`({cols_str}) SELECT {cols_str} FROM `file_attributions`')
                cur.execute("DROP TABLE `file_attributions`")
                cur.execute("ALTER TABLE `__new_file_attributions` RENAME TO `file_attributions`")
            cur.execute("INSERT OR IGNORE INTO __drizzle_migrations (hash, created_at) VALUES (?, ?)", (h153, 1788757911275))
            conn.commit()
            log_fn("✅ 数据库迁移安全兼容预检完成！")
        conn.close()
    except Exception as e:
        log_fn(f"⚠️ 数据库预检提示: {e}")


def detect_binary_arch(filepath):
    """检测二进制架构 (arm64 或 x64)"""
    if not filepath or not os.path.isfile(filepath):
        return "arm64"
    fn = os.path.basename(filepath).lower()
    if "x64" in fn or "x86_64" in fn or "intel" in fn:
        return "x64"
    if "arm64" in fn or "aarch64" in fn:
        return "arm64"
    try:
        res = subprocess.run(["file", filepath], capture_output=True, text=True)
        if "x86_64" in res.stdout:
            return "x64"
        if "arm64" in res.stdout:
            return "arm64"
    except Exception:
        pass
    return "arm64"


def build_dmg(app_path, ver, arch="arm64", log_fn=print):
    """构建精美、纯中文界面与全中文使用说明的 macOS DMG 安装镜像 (支持 dmgbuild / create-dmg 双引擎)"""
    arch_tag = "x64" if arch.lower() in ("x64", "x86_64", "intel") else "arm64"
    arch_display = "Intel 芯片" if arch_tag == "x64" else "Apple Silicon"
    dmg_output = os.path.join(DIST_DIR, f"NarraFork-v{ver}-macOS-{arch_tag}.dmg")
    bg_path = os.path.join(ASSETS_DIR, "dmg_background.png")
    readme_path = os.path.join(ASSETS_DIR, "安装使用必读.txt")

    log_fn(f"\n📀 正在构建精美中文 DMG 安装包: {os.path.basename(dmg_output)} ({arch_display})...")

    # 1. 优先采用现代化 dmgbuild 直接二进制写入 .DS_Store (完美兼容 macOS Sonoma/Sequoia 视网膜背景)
    try:
        import dmgbuild
        from ds_store import DSStore
        orig_ds_setitem = DSStore.Partial.__setitem__
        def patched_ds_setitem(self, code, value):
            if code in ('icvp', b'icvp') and isinstance(value, dict):
                # 暗色无缝底色兜底，彻底消除窗口被用户拉大时右下角出现的白边
                value['backgroundColorRed'] = 12.0 / 255.0
                value['backgroundColorGreen'] = 14.0 / 255.0
                value['backgroundColorBlue'] = 18.0 / 255.0
            return orig_ds_setitem(self, code, value)
        DSStore.Partial.__setitem__ = patched_ds_setitem

        settings = {
            "volume_name": f"NarraFork 安装程序 ({arch_display})",
            "icon": ICON_PATH if os.path.isfile(ICON_PATH) else None,
            "background": bg_path if os.path.isfile(bg_path) else None,
            "icon_size": 105,
            "text_size": 12,
            "window_rect": ((200, 120), (660, 460)),
            "format": "UDZO",
            "filesystem": "HFS+",
            "files": [
                (app_path, "NarraFork.app"),
            ],
            "symlinks": {
                "Applications": "/Applications",
            },
            "icon_locations": {
                "NarraFork.app": (160, 175),
                "Applications": (500, 175),
            },
            "hide_extensions": ["NarraFork.app"],
        }
        if os.path.isfile(readme_path):
            settings["files"].append((readme_path, "安装使用必读.txt"))
            settings["icon_locations"]["安装使用必读.txt"] = (330, 310)

        if os.path.exists(dmg_output):
            os.remove(dmg_output)

        dmgbuild.build_dmg(dmg_output, f"NarraFork 安装程序 ({arch_display})", settings=settings)
        if os.path.isfile(dmg_output):
            log_fn(f"✅ 中文 DMG 安装镜像构建成功 (dmgbuild 原生引擎): {dmg_output}")
            return dmg_output
    except ImportError:
        pass
    except Exception as e:
        log_fn(f"⚠️ dmgbuild 引擎构建提示: {e}，正在切换 create-dmg 引擎...")

    # 2. 备用引擎: create-dmg
    if shutil.which("create-dmg"):
        staging_dir = f"/tmp/narrafork_dmg_staging_{arch_tag}"
        if os.path.exists(staging_dir):
            shutil.rmtree(staging_dir)
        os.makedirs(staging_dir, exist_ok=True)
        shutil.copytree(app_path, os.path.join(staging_dir, "NarraFork.app"))

        cmd = [
            "create-dmg",
            "--volname", f"NarraFork 安装程序 ({arch_display})",
            "--volicon", ICON_PATH,
            "--background", bg_path,
            "--window-pos", "200", "120",
            "--window-size", "660", "460",
            "--icon-size", "105",
            "--text-size", "12",
            "--icon", "NarraFork.app", "160", "175",
            "--hide-extension", "NarraFork.app",
            "--app-drop-link", "500", "175",
            "--format", "UDZO",
            "--overwrite",
        ]
        if os.path.isfile(readme_path):
            cmd.extend(["--add-file", "安装使用必读.txt", readme_path, "330", "310"])

        cmd.extend([dmg_output, staging_dir])

        try:
            proc = subprocess.run(cmd, capture_output=True, text=True)
            if os.path.exists(staging_dir):
                shutil.rmtree(staging_dir)
            if os.path.isfile(dmg_output):
                log_fn(f"✅ 中文 DMG 安装镜像构建成功 (create-dmg): {dmg_output}")
                return dmg_output
        except Exception as e:
            log_fn(f"⚠️ create-dmg 构建出错: {e}")

    log_fn("⚠️ 未找到可用的 DMG 构建工具 (请安装 dmgbuild 或 create-dmg)。")
    return None


def build_narrafork_app(
    selected_binary,
    install_to_applications=True,
    update_desktop_shortcut=True,
    reveal_in_finder=True,
    create_dmg_installer=True,
    target_arch=None,
    log_fn=print,
):
    """执行核心打包流程"""
    if not selected_binary or not os.path.isfile(selected_binary):
        raise ValueError(f"指定的二进制文件不存在: {selected_binary}")

    ver = extract_version(selected_binary)
    arch = target_arch or detect_binary_arch(selected_binary)
    arch_display = "Intel 芯片 (x64)" if arch == "x64" else "Apple Silicon (arm64)"

    log_fn(f"\n========================================")
    log_fn(f"🚀 开始构建 NarraFork v{ver} 客户端 [{arch_display}]...")

    # 1. 检查并终止正在运行的旧实例
    log_fn("🔍 检查并安全退出正在运行的 NarraFork 实例...")
    subprocess.run(["killall", "NarraFork"], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    subprocess.run(["killall", "narrafork-backend"], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    try:
        res = subprocess.run(["lsof", "-ti", ":7788"], capture_output=True, text=True)
        if res.stdout.strip():
            for pid_s in res.stdout.strip().split():
                subprocess.run(["kill", "-9", pid_s], stderr=subprocess.DEVNULL)
    except Exception:
        pass
    import time
    for _ in range(15):
        res = subprocess.run(["lsof", "-ti", ":7788"], capture_output=True, text=True)
        if not res.stdout.strip():
            break
        time.sleep(0.1)

    # 2. 预检数据库迁移健康度
    check_and_repair_database(log_fn=log_fn)

    # 2. 准备输出目录
    out_app = DEFAULT_APP_OUTPUT
    os.makedirs(DIST_DIR, exist_ok=True)
    macos_dir = os.path.join(out_app, "Contents", "MacOS")
    res_dir = os.path.join(out_app, "Contents", "Resources")

    log_fn(f"📁 创建 App Bundle: {out_app}")
    if os.path.exists(out_app):
        shutil.rmtree(out_app)
    os.makedirs(macos_dir, exist_ok=True)
    os.makedirs(res_dir, exist_ok=True)

    # 3. 部署应用外壳二进制 (优先采用双架构通用二进制 Universal 2)
    target_wrapper = os.path.join(macos_dir, "NarraFork")
    if os.path.isfile(WRAPPER_BIN_PATH):
        log_fn("⚡ 部署原生防误触状态栏外壳 (NarraFork_wrapper)...")
        shutil.copy2(WRAPPER_BIN_PATH, target_wrapper)
    else:
        log_fn("🔨 从源码编译 Universal 2 原生外壳 (src/main.swift)...")
        if not os.path.isfile(SWIFT_SRC_PATH):
            raise RuntimeError(f"未找到源码文件: {SWIFT_SRC_PATH}")
        tmp_arm = "/tmp/NarraFork_wrapper_arm64"
        tmp_x64 = "/tmp/NarraFork_wrapper_x86_64"
        cmd_arm = ["swiftc", "-O", "-target", "arm64-apple-macos12.0", "-framework", "Cocoa", "-framework", "WebKit", SWIFT_SRC_PATH, "-o", tmp_arm]
        cmd_x64 = ["swiftc", "-O", "-target", "x86_64-apple-macos12.0", "-framework", "Cocoa", "-framework", "WebKit", SWIFT_SRC_PATH, "-o", tmp_x64]
        res_arm = subprocess.run(cmd_arm, capture_output=True, text=True)
        res_x64 = subprocess.run(cmd_x64, capture_output=True, text=True)
        if res_arm.returncode == 0 and res_x64.returncode == 0:
            subprocess.run(["lipo", "-create", tmp_arm, tmp_x64, "-output", target_wrapper], check=True)
            shutil.copy2(target_wrapper, WRAPPER_BIN_PATH)
        elif res_arm.returncode == 0:
            shutil.copy2(tmp_arm, target_wrapper)
        else:
            raise RuntimeError(f"Swift 编译失败: {res_arm.stderr}")
    os.chmod(target_wrapper, 0o755)

    # 4. 植入官方高清原生图标 (AppIcon.icns)
    log_fn("🎨 植入官方 Retina 原生图标 (AppIcon.icns)...")
    target_icns = os.path.join(res_dir, "AppIcon.icns")
    if not os.path.isfile(ICON_PATH):
        raise RuntimeError(f"未找到图标文件: {ICON_PATH}")
    shutil.copy2(ICON_PATH, target_icns)

    # 5. 植入核心后端二进制
    log_fn(f"📦 嵌入核心后端二进制 ({os.path.basename(selected_binary)})...")
    target_backend = os.path.join(res_dir, "narrafork-backend")
    shutil.copy2(selected_binary, target_backend)
    os.chmod(target_backend, 0o755)
    subprocess.run(["xattr", "-cr", target_backend], stderr=subprocess.DEVNULL)

    # 5.1 植入就绪纯净数据库模板 (确保在新 Mac 用户电脑上开箱即用，零迁移闪退)
    template_db_src = os.path.join(ASSETS_DIR, "template_narrafork.db")
    if os.path.isfile(template_db_src):
        log_fn("💾 嵌入就绪纯净数据库模板 (template_narrafork.db)...")
        shutil.copy2(template_db_src, os.path.join(res_dir, "template_narrafork.db"))

    # 6. 生成 Info.plist
    log_fn(f"📝 写入应用配置 Info.plist (版本: v{ver})...")
    plist_content = INFO_PLIST_TEMPLATE.format(version=ver)
    with open(os.path.join(out_app, "Contents", "Info.plist"), "w", encoding="utf-8") as f:
        f.write(plist_content)

    # 7. 清除隔离属性并执行代码签名
    log_fn("🔐 清除安全隔离属性并执行自签名 (codesign)...")
    subprocess.run(["xattr", "-cr", out_app], stderr=subprocess.DEVNULL)
    sign_res = subprocess.run(
        ["codesign", "--force", "--deep", "--sign", "-", out_app],
        capture_output=True,
        text=True,
    )
    if sign_res.returncode != 0:
        log_fn(f"⚠️ 签名警告: {sign_res.stderr}")

    subprocess.run(["touch", out_app])
    log_fn(f"✅ 本地 App 成功生成于: {out_app}")

    # 8. 同步覆盖至 /Applications
    deployed_app = out_app
    if install_to_applications:
        log_fn(f"📥 正在安装到系统应用目录 ({APPLICATIONS_APP})...")
        if os.path.exists(APPLICATIONS_APP):
            shutil.rmtree(APPLICATIONS_APP)
        shutil.copytree(out_app, APPLICATIONS_APP)
        subprocess.run(["touch", APPLICATIONS_APP])
        deployed_app = APPLICATIONS_APP
        log_fn(f"✅ 系统应用程序已同步更新！")

        # 自动同步归档一份到用户版本库 ~/.narrafork/versions/
        try:
            versions_dir = os.path.expanduser("~/.narrafork/versions")
            os.makedirs(versions_dir, exist_ok=True)
            archived_bin = os.path.join(versions_dir, f"narrafork-{ver}-macos-{arch}")
            if not os.path.isfile(archived_bin):
                shutil.copy2(target_backend, archived_bin)
                os.chmod(archived_bin, 0o755)
        except Exception:
            pass

    # 9. 更新桌面快捷方式
    if update_desktop_shortcut:
        desktop_link = os.path.join(DESKTOP_DIR, "NarraFork.app")
        log_fn(f"🔗 更新桌面快捷方式: {desktop_link} -> {deployed_app}")
        if os.path.islink(desktop_link) or os.path.isfile(desktop_link):
            os.remove(desktop_link)
        elif os.path.isdir(desktop_link):
            shutil.rmtree(desktop_link)
        os.symlink(deployed_app, desktop_link)

    # 10. 生成精美中文 DMG 安装镜像 (如果启用)
    dmg_file = None
    if create_dmg_installer:
        dmg_file = build_dmg(out_app, ver, arch=arch, log_fn=log_fn)

    # 11. 刷新系统图标缓存
    log_fn("🔄 刷新 Finder / Dock 图标缓存...")
    subprocess.run(["qlmanage", "-r", "cache"], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    subprocess.run(["killall", "Finder"], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    subprocess.run(["killall", "Dock"], stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)

    log_fn("🎉 打包与部署全部完成！")

    # 12. 在访达中定位
    if reveal_in_finder:
        target_to_reveal = dmg_file if (dmg_file and os.path.isfile(dmg_file)) else deployed_app
        subprocess.run(["open", "-R", target_to_reveal])

    return deployed_app, ver, dmg_file


class CanvasButton(tk.Canvas):
    """跨平台防颜色覆盖的高对比度自绘圆角按钮"""
    def __init__(
        self,
        parent,
        text,
        command=None,
        bg_color="#0969da",
        hover_color="#0550ae",
        text_color="#ffffff",
        font=("PingFang SC", 13, "bold"),
        height=38,
        radius=7,
        **kwargs,
    ):
        super().__init__(
            parent,
            height=height,
            highlightthickness=0,
            bg=parent["bg"],
            cursor="pointinghand",
            **kwargs,
        )
        self.command = command
        self.text = text
        self.bg_color = bg_color
        self.hover_color = hover_color
        self.text_color = text_color
        self.font = font
        self.radius = radius
        self.is_hovered = False
        self.is_disabled = False

        self.bind("<Configure>", self._draw)
        self.bind("<Enter>", self._on_enter)
        self.bind("<Leave>", self._on_leave)
        self.bind("<Button-1>", self._on_click)

    def _draw(self, event=None):
        self.delete("all")
        w = self.winfo_width()
        h = self.winfo_height()
        if w <= 1 or h <= 1:
            return
        color = "#8c959f" if self.is_disabled else (self.hover_color if self.is_hovered else self.bg_color)
        r = min(self.radius, h // 2, w // 2)

        if r > 0:
            self.create_arc(0, 0, 2*r, 2*r, start=90, extent=90, fill=color, outline=color)
            self.create_arc(w-2*r, 0, w, 2*r, start=0, extent=90, fill=color, outline=color)
            self.create_arc(w-2*r, h-2*r, w, h, start=270, extent=90, fill=color, outline=color)
            self.create_arc(0, h-2*r, 2*r, h, start=180, extent=90, fill=color, outline=color)
            self.create_rectangle(r, 0, w-r, h, fill=color, outline=color)
            self.create_rectangle(0, r, w, h-r, fill=color, outline=color)
        else:
            self.create_rectangle(0, 0, w, h, fill=color, outline=color)

        self.create_text(w / 2, h / 2, text=self.text, fill=self.text_color, font=self.font)

    def _on_enter(self, e):
        if not self.is_disabled:
            self.is_hovered = True
            self._draw()

    def _on_leave(self, e):
        self.is_hovered = False
        self._draw()

    def _on_click(self, e):
        if not self.is_disabled and self.command:
            self.command()

    def set_state(self, state, text=None):
        self.is_disabled = (state == "disabled")
        if text:
            self.text = text
        self._draw()


class AppPackagerUI(tk.Tk):
    def __init__(self, preselected=None):
        super().__init__()
        self.title("NarraFork macOS Launcher 打包工具")
        self.geometry("650x600")
        self.minsize(630, 560)
        self.selected_binary = None
        self.logo_image = None

        self.update_idletasks()
        w, h = 650, 600
        x = (self.winfo_screenwidth() // 2) - (w // 2)
        y = (self.winfo_screenheight() // 2) - (h // 2)
        self.geometry(f"{w}x{h}+{x}+{y}")

        self.setup_ui()

        if preselected and os.path.isfile(preselected):
            self.set_binary_file(preselected)
        else:
            self.auto_discover_binary()

    def setup_ui(self):
        bg_main = "#f6f8fa"
        self.configure(bg=bg_main)

        # 1. 顶部 Header
        header_frame = tk.Frame(self, bg=bg_main, padx=20, pady=16)
        header_frame.pack(fill="x")

        if os.path.isfile(ICON_PNG_PATH):
            try:
                pil_img = Image.open(ICON_PNG_PATH).resize((54, 54), Image.Resampling.LANCZOS)
                self.logo_image = ImageTk.PhotoImage(pil_img)
                logo_label = tk.Label(header_frame, image=self.logo_image, bg=bg_main)
                logo_label.pack(side="left", padx=(0, 14))
            except Exception:
                pass

        title_box = tk.Frame(header_frame, bg=bg_main)
        title_box.pack(side="left", fill="both", expand=True)

        title_lbl = tk.Label(
            title_box,
            text="NarraFork macOS Launcher 打包工具",
            font=("PingFang SC", 18, "bold"),
            fg="#1f2328",
            bg=bg_main,
            anchor="w",
        )
        title_lbl.pack(fill="x")

        sub_lbl = tk.Label(
            title_box,
            text="选择新版本核心，一键构建并部署带官方 Logo & 状态栏常驻的 macOS 应用",
            font=("PingFang SC", 12),
            fg="#656d76",
            bg=bg_main,
            anchor="w",
        )
        sub_lbl.pack(fill="x", pady=(3, 0))

        # 分割线
        divider = tk.Frame(self, bg="#d0d7de", height=1)
        divider.pack(fill="x", padx=20, pady=2)

        # 2. 中间内容容器
        content_frame = tk.Frame(self, bg=bg_main, padx=20, pady=12)
        content_frame.pack(fill="both", expand=True)

        # 第一部分: 文件选择
        sec1_lbl = tk.Label(
            content_frame,
            text="1. 选择核心二进制文件 (如 bin/narrafork-0.7.0-macos-arm64):",
            font=("PingFang SC", 13, "bold"),
            fg="#1f2328",
            bg=bg_main,
            anchor="w",
        )
        sec1_lbl.pack(fill="x", pady=(0, 8))

        file_pick_frame = tk.Frame(content_frame, bg=bg_main)
        file_pick_frame.pack(fill="x", pady=(0, 4))

        self.path_var = tk.StringVar(value="尚未选择文件")
        self.path_entry = tk.Entry(
            file_pick_frame,
            textvariable=self.path_var,
            font=("Menlo", 11),
            fg="#1f2328",
            bg="#ffffff",
            relief="solid",
            bd=1,
            highlightthickness=0,
            state="readonly",
        )
        self.path_entry.pack(side="left", fill="x", expand=True, ipady=6, padx=(0, 10))

        browse_btn = CanvasButton(
            file_pick_frame,
            text="选择文件...",
            command=self.browse_file,
            bg_color="#0969da",
            hover_color="#0550ae",
            text_color="#ffffff",
            font=("PingFang SC", 12, "bold"),
            height=34,
            width=104,
            radius=6,
        )
        browse_btn.pack(side="right")

        self.info_var = tk.StringVar(value="💡 提示: 可直接将下载的核心放入 bin/ 目录，工具将自动优先识别！")
        self.info_lbl = tk.Label(
            content_frame,
            textvariable=self.info_var,
            font=("PingFang SC", 11),
            fg="#656d76",
            bg=bg_main,
            anchor="w",
        )
        self.info_lbl.pack(fill="x", pady=(2, 12))

        # 第二部分: 打包选项
        sec2_lbl = tk.Label(
            content_frame,
            text="2. 打包与部署选项:",
            font=("PingFang SC", 13, "bold"),
            fg="#1f2328",
            bg=bg_main,
            anchor="w",
        )
        sec2_lbl.pack(fill="x", pady=(2, 6))

        options_frame = tk.Frame(content_frame, bg=bg_main)
        options_frame.pack(fill="x", pady=(0, 12))

        self.opt_install_app = tk.BooleanVar(value=True)
        chk1 = tk.Checkbutton(
            options_frame,
            text="同步覆盖安装至 /Applications (系统应用目录)",
            variable=self.opt_install_app,
            fg="#24292f",
            bg=bg_main,
            activebackground=bg_main,
            activeforeground="#24292f",
            font=("PingFang SC", 12),
        )
        chk1.pack(anchor="w", pady=2)

        self.opt_desktop_shortcut = tk.BooleanVar(value=True)
        chk2 = tk.Checkbutton(
            options_frame,
            text="更新桌面快捷方式 (Desktop/NarraFork.app)",
            variable=self.opt_desktop_shortcut,
            fg="#24292f",
            bg=bg_main,
            activebackground=bg_main,
            activeforeground="#24292f",
            font=("PingFang SC", 12),
        )
        chk2.pack(anchor="w", pady=2)

        self.opt_reveal_finder = tk.BooleanVar(value=True)
        chk3 = tk.Checkbutton(
            options_frame,
            text="打包完成后在访达 (Finder) 中显示产物",
            variable=self.opt_reveal_finder,
            fg="#24292f",
            bg=bg_main,
            activebackground=bg_main,
            activeforeground="#24292f",
            font=("PingFang SC", 12),
        )
        chk3.pack(anchor="w", pady=2)

        self.opt_create_dmg = tk.BooleanVar(value=True)
        chk4 = tk.Checkbutton(
            options_frame,
            text="同步生成精美中文 DMG 安装镜像 (dist/NarraFork-v...-macOS-arm64.dmg)",
            variable=self.opt_create_dmg,
            fg="#24292f",
            bg=bg_main,
            activebackground=bg_main,
            activeforeground="#24292f",
            font=("PingFang SC", 12),
        )
        chk4.pack(anchor="w", pady=2)

        # 大打包按钮
        self.build_btn = CanvasButton(
            content_frame,
            text="🚀 开始一键打包 NarraFork.app",
            command=self.start_packaging_thread,
            bg_color="#1f883d",
            hover_color="#1a7f37",
            text_color="#ffffff",
            font=("PingFang SC", 14, "bold"),
            height=44,
            radius=8,
        )
        self.build_btn.pack(fill="x", pady=(4, 14))

        # 第三部分: 日志输出框
        log_header = tk.Frame(content_frame, bg=bg_main)
        log_header.pack(fill="x", pady=(0, 4))
        log_lbl = tk.Label(
            log_header,
            text="运行日志:",
            font=("PingFang SC", 11, "bold"),
            fg="#656d76",
            bg=bg_main,
        )
        log_lbl.pack(side="left")

        log_container = tk.Frame(content_frame, bg="#d0d7de", bd=1)
        log_container.pack(fill="both", expand=True)

        self.log_text = scrolledtext.ScrolledText(
            log_container,
            font=("Menlo", 11),
            fg="#e6edf3",
            bg="#1b1f24",
            insertbackground="#ffffff",
            relief="flat",
            bd=0,
            spacing1=3,
            spacing3=3,
            height=6,
        )
        self.log_text.pack(fill="both", expand=True, padx=1, pady=1)

        self.log("就绪。请选择待打包的核心二进制文件。")

    def log(self, text):
        self.log_text.insert("end", text + "\n")
        self.log_text.see("end")

    def auto_discover_binary(self):
        """自动扫描 bin/ 目录、更新记录、App内更新、下载目录和项目根目录"""
        # 1. 检查 NarraFork 应用内下载的更新标记文件 (~/.narrafork/updates/placed-update.json)
        placed_json = os.path.expanduser("~/.narrafork/updates/placed-update.json")
        if os.path.isfile(placed_json):
            try:
                import json
                with open(placed_json, "r", encoding="utf-8") as f:
                    info = json.load(f)
                new_path = info.get("newBinaryPath")
                if new_path and os.path.isfile(new_path):
                    target_in_bin = os.path.join(BIN_DIR, os.path.basename(new_path))
                    if not os.path.isfile(target_in_bin):
                        os.makedirs(BIN_DIR, exist_ok=True)
                        shutil.copy2(new_path, target_in_bin)
                        os.chmod(target_in_bin, 0o755)
                    self.set_binary_file(target_in_bin)
                    self.log(f"💡 自动捕获应用内已下载的更新核心: {os.path.basename(target_in_bin)}")
                    return
            except Exception:
                pass

        # 2. 检查 .app 内部可能被放置的更新二进制
        app_res_dirs = [
            os.path.join(DIST_DIR, "NarraFork.app", "Contents", "Resources"),
            os.path.join(APPLICATIONS_APP, "Contents", "Resources"),
        ]
        for res_d in app_res_dirs:
            if os.path.isdir(res_d):
                for f in os.listdir(res_d):
                    if f.startswith("narrafork-") and "macos" in f and not f.endswith(".json"):
                        src = os.path.join(res_d, f)
                        if os.path.isfile(src):
                            target_in_bin = os.path.join(BIN_DIR, f)
                            if not os.path.isfile(target_in_bin):
                                os.makedirs(BIN_DIR, exist_ok=True)
                                shutil.copy2(src, target_in_bin)
                                os.chmod(target_in_bin, 0o755)
                            self.set_binary_file(target_in_bin)
                            self.log(f"💡 自动从应用资源目录提取最新核心: {f}")
                            return

        # 3. 扫描 bin/、项目根目录、下载目录
        search_dirs = [BIN_DIR, PROJECT_ROOT, os.path.expanduser("~/Downloads")]
        candidates = []
        for root in search_dirs:
            if os.path.isdir(root):
                for f in os.listdir(root):
                    # 匹配任何核心二进制名字，排除 app 和 zip
                    if ("narrafork" in f.lower() or "narra" in f.lower()) and not f.endswith(".app") and not f.endswith(".zip") and not f.endswith(".py") and not f.endswith(".command") and not f.endswith(".md"):
                        full = os.path.join(root, f)
                        if os.path.isfile(full):
                            candidates.append(full)

        # 优先选择在 bin/ 目录中的文件
        if candidates:
            bin_candidates = [c for c in candidates if os.path.dirname(c) == BIN_DIR]
            if bin_candidates:
                bin_candidates.sort(key=lambda x: os.path.getmtime(x), reverse=True)
                self.set_binary_file(bin_candidates[0])
            else:
                candidates.sort(key=lambda x: os.path.getmtime(x), reverse=True)
                chosen = candidates[0]
                target_in_bin = os.path.join(BIN_DIR, os.path.basename(chosen))
                if chosen != target_in_bin and not os.path.isfile(target_in_bin):
                    os.makedirs(BIN_DIR, exist_ok=True)
                    shutil.copy2(chosen, target_in_bin)
                    os.chmod(target_in_bin, 0o755)
                    self.set_binary_file(target_in_bin)
                else:
                    self.set_binary_file(chosen)

    def browse_file(self):
        """打开系统原生文件选择对话框（绝不置灰无扩展名文件）"""
        init_dir = BIN_DIR if os.path.isdir(BIN_DIR) else PROJECT_ROOT
        selected = choose_file_macos(initial_dir=init_dir)
        if selected and os.path.isfile(selected):
            self.set_binary_file(selected)

    def set_binary_file(self, filepath):
        self.selected_binary = filepath
        self.path_var.set(filepath)
        size_mb = os.path.getsize(filepath) / (1024 * 1024)
        ver = extract_version(filepath)
        arch = detect_binary_arch(filepath)
        arch_display = "💻 Intel 芯片 (x64)" if arch == "x64" else "🍎 Apple Silicon (arm64)"
        self.info_var.set(f"✅ 已选中: {os.path.basename(filepath)}  |  架构: {arch_display}  |  大小: {size_mb:.1f} MB  |  版本: v{ver}")
        self.info_lbl.config(fg="#1a7f37")
        self.log(f"已选定核心文件: {filepath} (v{ver}, 架构: {arch_display})")

    def start_packaging_thread(self):
        if not self.selected_binary or not os.path.isfile(self.selected_binary):
            messagebox.showwarning("提示", "请先选择有效的 NarraFork 核心二进制文件！", parent=self)
            return

        self.build_btn.set_state("disabled", "⏳ 正在打包中，请稍候...")
        t = threading.Thread(target=self._worker, daemon=True)
        t.start()

    def _worker(self):
        try:
            deployed_app, ver, dmg_file = build_narrafork_app(
                self.selected_binary,
                install_to_applications=self.opt_install_app.get(),
                update_desktop_shortcut=self.opt_desktop_shortcut.get(),
                reveal_in_finder=self.opt_reveal_finder.get(),
                create_dmg_installer=self.opt_create_dmg.get(),
                log_fn=self.log,
            )
            arch = detect_binary_arch(self.selected_binary)
            arch_display = "Intel 芯片 (x64)" if arch == "x64" else "Apple Silicon (arm64)"
            dmg_msg = f"\n• 中文 DMG 镜像: {dmg_file} (支持 {arch_display})" if dmg_file else ""
            self.after(
                100,
                lambda: messagebox.showinfo(
                    "打包完成",
                    f"🎉 NarraFork v{ver} [{arch_display}] 客户端已成功打包并部署！\n\n"
                    f"• 本地 App: {deployed_app}{dmg_msg}\n"
                    f"• 外壳支持: Universal 2 (原生支持 Apple Silicon & Intel 双架构)\n"
                    f"• 核心架构: {arch_display}\n"
                    f"• 桌面快捷方式: 已自动更新\n\n现在可直接双击运行，或将 DMG 分享给其他 Mac 用户！",
                    parent=self,
                ),
            )
        except Exception as e:
            self.log(f"\n❌ 打包出错: {str(e)}")
            self.after(100, lambda err=str(e): messagebox.showerror("打包失败", f"错误详情:\n{err}", parent=self))
        finally:
            self.after(
                100,
                lambda: self.build_btn.set_state("normal", "🚀 开始一键打包 NarraFork.app"),
            )


def main():
    import argparse
    parser = argparse.ArgumentParser(description="NarraFork macOS Launcher 打包工具 (支持 Apple Silicon & Intel 芯片)")
    parser.add_argument("binary", nargs="?", help="核心二进制文件路径")
    parser.add_argument("--cli", action="store_true", help="以命令行模式直接打包 (不启动 GUI)")
    parser.add_argument("--arch", choices=["arm64", "x64", "all"], help="指定构建芯片架构 (arm64: Apple Silicon, x64: Intel, all: 双架构同时构建)")
    parser.add_argument("--no-dmg", action="store_true", help="不生成 DMG 安装镜像")
    parser.add_argument("--no-install", action="store_true", help="不安装到 /Applications")
    
    args, unknown = parser.parse_known_args()

    # 兼容原生旧调用格式: python3 package_app.py --cli <path>
    target_bin = None
    if args.binary:
        target_bin = args.binary
    elif unknown:
        for u in unknown:
            if os.path.isfile(u):
                target_bin = u
                break

    if args.cli or args.arch:
        if args.arch == "all":
            print("\n🌟 正在执行双芯片架构全量构建 (Apple Silicon arm64 + Intel x64)...")
            built_count = 0
            arm_bin = None
            x64_bin = None
            for root in [BIN_DIR, PROJECT_ROOT, os.path.expanduser("~/Downloads")]:
                if not os.path.isdir(root): continue
                for f in os.listdir(root):
                    fp = os.path.join(root, f)
                    if not os.path.isfile(fp) or f.endswith(".md") or f.endswith(".json"): continue
                    if "narrafork" in f.lower():
                        detected = detect_binary_arch(fp)
                        if detected == "arm64" and (not arm_bin or os.path.getmtime(fp) > os.path.getmtime(arm_bin)):
                            arm_bin = fp
                        elif detected == "x64" and (not x64_bin or os.path.getmtime(fp) > os.path.getmtime(x64_bin)):
                            x64_bin = fp

            if arm_bin:
                print(f"\n▶ 正在为 Apple Silicon (arm64) 构建安装包: {arm_bin}")
                build_narrafork_app(arm_bin, create_dmg_installer=not args.no_dmg, install_to_applications=not args.no_install, reveal_in_finder=False)
                built_count += 1
            else:
                print("⚠️ 未找到 arm64 核心文件，跳过 arm64 构建")

            if x64_bin:
                print(f"\n▶ 正在为 Intel (x64) 构建安装包: {x64_bin}")
                build_narrafork_app(x64_bin, create_dmg_installer=not args.no_dmg, install_to_applications=False, update_desktop_shortcut=False, reveal_in_finder=False)
                built_count += 1
            else:
                print("⚠️ 未找到 x64 核心文件，跳过 x64 构建 (请在 bin/ 放入 narrafork-*-macos-x64)")

            print(f"\n🎉 构建流程结束，成功构建 {built_count} 个架构版本！产物位于 dist/ 目录。")
            return
        elif args.arch == "x64" or (target_bin and detect_binary_arch(target_bin) == "x64"):
            x64_bin = target_bin
            if not x64_bin:
                for root in [BIN_DIR, PROJECT_ROOT, os.path.expanduser("~/Downloads")]:
                    if not os.path.isdir(root): continue
                    for f in os.listdir(root):
                        fp = os.path.join(root, f)
                        if os.path.isfile(fp) and "narrafork" in f.lower() and detect_binary_arch(fp) == "x64":
                            if not x64_bin or os.path.getmtime(fp) > os.path.getmtime(x64_bin):
                                x64_bin = fp
            if not x64_bin or not os.path.isfile(x64_bin):
                print("❌ 错误: 未找到适用于 Intel (x64) 的 NarraFork 核心二进制文件。")
                print("💡 请将官方发布的 narrafork-*-macos-x64 放入 bin/ 目录后重试。")
                sys.exit(1)
            print(f"💻 正在为 Intel 芯片 (x64) 构建安装包: {x64_bin}")
            build_narrafork_app(x64_bin, create_dmg_installer=not args.no_dmg, install_to_applications=False, update_desktop_shortcut=False, reveal_in_finder=False)
            return
        elif target_bin:
            build_narrafork_app(target_bin, create_dmg_installer=not args.no_dmg, reveal_in_finder=False)
            return
        else:
            candidates = []
            for root in [BIN_DIR, PROJECT_ROOT]:
                if os.path.isdir(root):
                    for f in os.listdir(root):
                        fp = os.path.join(root, f)
                        if os.path.isfile(fp) and "narrafork" in f.lower() and not f.endswith(".md") and not f.endswith(".json"):
                            candidates.append(fp)
            if candidates:
                candidates.sort(key=lambda x: os.path.getmtime(x), reverse=True)
                build_narrafork_app(candidates[0], reveal_in_finder=False)
                return
            else:
                print("用法: python3 package_app.py --cli <核心二进制路径> [--arch arm64|x64|all]")
                sys.exit(1)
    else:
        preselected = target_bin
        gui = AppPackagerUI(preselected=preselected)
        gui.mainloop()


if __name__ == "__main__":
    main()
