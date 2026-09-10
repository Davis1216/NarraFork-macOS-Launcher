import Cocoa
import WebKit

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate, NSMenuDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var backendProcess: Process?
    var weStartedBackend: Bool = false
    var checkTimer: Timer?
    var retryCount: Int = 0
    let targetPort: Int = 7788
    var statusItem: NSStatusItem?
    var versionMenuItem: NSMenuItem?
    var versionSubmenu: NSMenu?
    var currentActiveVersion: String = "0.7.2"
    var isAppTerminating: Bool = false
    var activityToken: NSObjectProtocol?

    var targetURL: URL {
        return URL(string: "http://127.0.0.1:\(targetPort)")!
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // 1. 提升主进程 QoS，防止系统调度迟滞与 App Nap 降频
        Thread.current.qualityOfService = .userInteractive
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "NarraFork High Performance Rendering & Background Core"
        )

        setupMenu()
        setupStatusItem()
        setupWindow()
        checkAndApplyPlacedUpdate()
        resolveActiveCoreVersion()
        loadSplashScreen()
        checkAndStartBackend()
    }

    // MARK: - Status Bar Item
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }

        button.image = createStatusIcon()
        button.toolTip = "NarraFork 核心服务 (运行中)"

        let menu = NSMenu()
        menu.delegate = self

        let showItem = NSMenuItem(title: "显示主窗口", action: #selector(showMainWindow), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        let hideItem = NSMenuItem(title: "隐藏主窗口", action: #selector(hideMainWindow), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)

        menu.addItem(NSMenuItem.separator())

        let browserItem = NSMenuItem(title: "在浏览器中打开 (localhost:\(targetPort))", action: #selector(openInBrowser), keyEquivalent: "")
        browserItem.target = self
        menu.addItem(browserItem)

        menu.addItem(NSMenuItem.separator())

        let restartItem = NSMenuItem(title: "重启核心服务", action: #selector(restartCoreBackend), keyEquivalent: "")
        restartItem.target = self
        menu.addItem(restartItem)

        // 核心版本管理与回退
        let verItem = NSMenuItem(title: "核心版本回退与切换", action: nil, keyEquivalent: "")
        let verSub = NSMenu(title: "核心版本回退与切换")
        verItem.submenu = verSub
        menu.addItem(verItem)
        self.versionMenuItem = verItem
        self.versionSubmenu = verSub

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出 NarraFork", action: #selector(quitApplication), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        refreshVersionSubmenu()
    }

    func createStatusIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size)
        img.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.8)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)

            // Vertical line
            ctx.move(to: CGPoint(x: 4.5, y: 7.0))
            ctx.addLine(to: CGPoint(x: 4.5, y: 15.0))
            ctx.strokePath()

            // Bottom node
            ctx.strokeEllipse(in: CGRect(x: 2.5, y: 2.5, width: 4.0, height: 4.0))

            // Top right node
            ctx.strokeEllipse(in: CGRect(x: 11.5, y: 11.5, width: 4.0, height: 4.0))

            // Curved branch
            ctx.move(to: CGPoint(x: 13.5, y: 11.5))
            ctx.addQuadCurve(to: CGPoint(x: 6.5, y: 4.5), control: CGPoint(x: 13.5, y: 4.5))
            ctx.strokePath()
        }
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    @objc func showMainWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func hideMainWindow() {
        window.orderOut(nil)
    }

    @objc func toggleMainWindow() {
        if window.isVisible {
            window.orderOut(nil)
        } else {
            showMainWindow()
        }
    }

    @objc func openInBrowser() {
        NSWorkspace.shared.open(targetURL)
    }

    @objc func restartCoreBackend() {
        checkTimer?.invalidate()
        if let proc = backendProcess {
            proc.terminationHandler = nil
            if proc.isRunning {
                proc.terminate()
                let deadline = Date().addingTimeInterval(1.0)
                while proc.isRunning && Date() < deadline {
                    usleep(50_000)
                }
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
            }
        }
        backendProcess = nil
        killAnyProcessOnPort(port: targetPort)
        checkAndApplyPlacedUpdate()
        resolveActiveCoreVersion()
        clearWebViewCache { [weak self] in
            guard let self = self else { return }
            self.loadSplashScreen(status: "正在重启核心服务...")
            self.launchBackendProcess()
        }
    }

    // MARK: - Version Rollback & Multi-Version Management (版本回退与多版本管理)

    struct VersionEntry {
        let version: String
        let path: String
        let date: Date
        let isCurrent: Bool
    }

    func getBinaryVersion(at url: URL) -> String? {
        let filename = url.lastPathComponent
        if let match = filename.range(of: #"[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression) {
            return String(filename[match])
        }
        // Fallback: fast extraction using strings | grep
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "strings \"\(url.path)\" | grep -m 1 \"bunfs/root/narrafork-\""]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let out = String(data: data, encoding: .utf8),
           let match = out.range(of: #"[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression) {
            return String(out[match])
        }
        return nil
    }

    func archiveKnownBinaries() {
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser
        let versionsDir = homeDir.appendingPathComponent(".narrafork/versions")
        try? fm.createDirectory(at: versionsDir, withIntermediateDirectories: true)

        // 1. 当前生效的核心
        if let binURL = findBackendBinary(), let ver = getBinaryVersion(at: binURL) {
            currentActiveVersion = ver
            let targetURL = versionsDir.appendingPathComponent("narrafork-\(ver)-macos-arm64")
            if !fm.fileExists(atPath: targetURL.path) {
                try? fm.copyItem(at: binURL, to: targetURL)
                NSLog("NarraFork: 已自动归档当前核心 v%@ 至版本库", ver)
            }
        }

        // 2. App 内嵌核心 (Resources/narrafork-backend)
        if let resURL = Bundle.main.resourceURL {
            let bundled = resURL.appendingPathComponent("narrafork-backend")
            if fm.fileExists(atPath: bundled.path), let ver = getBinaryVersion(at: bundled) {
                let targetURL = versionsDir.appendingPathComponent("narrafork-\(ver)-macos-arm64")
                if !fm.fileExists(atPath: targetURL.path) {
                    try? fm.copyItem(at: bundled, to: targetURL)
                }
            }
        }

        // 3. 伴随 bin/ 目录核心
        let appDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let binDir = appDir.appendingPathComponent("bin")
        if let files = try? fm.contentsOfDirectory(at: binDir, includingPropertiesForKeys: nil) {
            for file in files {
                guard file.lastPathComponent.hasPrefix("narrafork") && !file.lastPathComponent.hasSuffix(".md") else { continue }
                if let ver = getBinaryVersion(at: file) {
                    let targetURL = versionsDir.appendingPathComponent("narrafork-\(ver)-macos-arm64")
                    if !fm.fileExists(atPath: targetURL.path) {
                        try? fm.copyItem(at: file, to: targetURL)
                        NSLog("NarraFork: 已自动收录 bin/ 核心 v%@ 至版本库", ver)
                    }
                }
            }
        }
    }

    func scanAvailableVersions() -> [VersionEntry] {
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser
        let versionsDir = homeDir.appendingPathComponent(".narrafork/versions")
        try? fm.createDirectory(at: versionsDir, withIntermediateDirectories: true)

        var versionsMap: [String: VersionEntry] = [:]

        // 扫描 ~/.narrafork/versions/
        if let files = try? fm.contentsOfDirectory(at: versionsDir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for file in files {
                guard file.lastPathComponent.hasPrefix("narrafork") && !file.lastPathComponent.hasSuffix(".json") && !file.lastPathComponent.hasSuffix(".txt") else { continue }
                if let ver = getBinaryVersion(at: file) {
                    let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                    let isCur = (ver == currentActiveVersion)
                    versionsMap[ver] = VersionEntry(version: ver, path: file.path, date: date, isCurrent: isCur)
                }
            }
        }

        // 确保当前活跃版本在列表中
        if versionsMap[currentActiveVersion] == nil, let curURL = findBackendBinary() {
            let date = (try? curURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            versionsMap[currentActiveVersion] = VersionEntry(version: currentActiveVersion, path: curURL.path, date: date, isCurrent: true)
        }

        return versionsMap.values.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    func resolveActiveCoreVersion() {
        if let activeURL = findBackendBinary(), let ver = getBinaryVersion(at: activeURL) {
            currentActiveVersion = ver
        }
        versionMenuItem?.title = "核心版本回退与切换 (当前: v\(currentActiveVersion))"
    }

    func refreshVersionSubmenu() {
        guard let submenu = versionSubmenu else { return }
        submenu.removeAllItems()

        resolveActiveCoreVersion()

        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let activeJsonURL = homeDir.appendingPathComponent(".narrafork/active_version.json")
        var isPinned = false
        if let data = try? Data(contentsOf: activeJsonURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let p = json["isPinned"] as? Bool, p {
            isPinned = true
        }

        if isPinned {
            let resetItem = NSMenuItem(title: "⚡ 恢复自动使用最新版本核心", action: #selector(resetToLatestVersion), keyEquivalent: "")
            resetItem.target = self
            submenu.addItem(resetItem)
            submenu.addItem(NSMenuItem.separator())
        }

        let entries = scanAvailableVersions()
        if entries.isEmpty {
            let emptyItem = NSMenuItem(title: "暂无其他可回退版本", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            submenu.addItem(emptyItem)
        } else {
            for entry in entries {
                let isCurrent = (entry.version == currentActiveVersion)
                let itemTitle = isCurrent ? "✓ v\(entry.version) (当前运行中)" : "   v\(entry.version) (点击切换至此版本)"
                let item = NSMenuItem(title: itemTitle, action: isCurrent ? nil : #selector(handleVersionSwitch(_:)), keyEquivalent: "")
                item.target = self
                item.state = isCurrent ? .on : .off
                item.representedObject = ["version": entry.version, "path": entry.path]
                submenu.addItem(item)
            }
        }

        submenu.addItem(NSMenuItem.separator())

        let importItem = NSMenuItem(title: "📥 导入其他版本核心...", action: #selector(importVersionBinary), keyEquivalent: "")
        importItem.target = self
        submenu.addItem(importItem)

        let openDirItem = NSMenuItem(title: "📂 打开版本备份目录 (~/.narrafork/versions)", action: #selector(openVersionsFolder), keyEquivalent: "")
        openDirItem.target = self
        submenu.addItem(openDirItem)
    }

    @objc func resetToLatestVersion() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let activeJsonURL = homeDir.appendingPathComponent(".narrafork/active_version.json")
        try? FileManager.default.removeItem(at: activeJsonURL)
        checkAndApplyPlacedUpdate()
        resolveActiveCoreVersion()
        loadSplashScreen(status: "正在切换回最新版本核心 (v\(currentActiveVersion))...")
        restartCoreBackend()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu == statusItem?.menu {
            refreshVersionSubmenu()
        }
    }

    @objc func handleVersionSwitch(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String],
              let targetVer = info["version"],
              let targetPath = info["path"] else { return }

        let alert = NSAlert()
        alert.messageText = "确认切换核心版本至 v\(targetVer)？"
        alert.informativeText = """
        即将执行核心版本切换：
        • 目标版本：v\(targetVer)
        • 当前版本：v\(currentActiveVersion)

        安全保障：
        系统会在切换前自动为您的数据库创建带时间戳的完整快照备份。
        确认后将平滑重启核心服务以应用新版本，您的所有工作区与个人数据均完整保留。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确认切换并重启")
        alert.addButton(withTitle: "取消")

        NSApp.activate(ignoringOtherApps: true)
        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            executeVersionSwitch(toVersion: targetVer, binaryPath: targetPath)
        }
    }

    func executeVersionSwitch(toVersion: String, binaryPath: String) {
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser

        // 1. 数据库自动安全备份快照 (Automatic database snapshot)
        let dbURL = homeDir.appendingPathComponent(".narrafork/narrafork.db")
        if fm.fileExists(atPath: dbURL.path) {
            let df = DateFormatter()
            df.dateFormat = "yyyyMMdd_HHmmss"
            let timeStr = df.string(from: Date())
            let backupURL = homeDir.appendingPathComponent(".narrafork/narrafork.db.bak_switch_to_v\(toVersion)_\(timeStr)")
            try? fm.copyItem(at: dbURL, to: backupURL)
            NSLog("NarraFork: 切换版本前数据库安全快照已生成: %@", backupURL.path)
        }

        // 2. 优雅停止当前正在运行的后端
        checkTimer?.invalidate()
        if let proc = backendProcess {
            proc.terminationHandler = nil
            if proc.isRunning {
                proc.terminate()
                let deadline = Date().addingTimeInterval(1.2)
                while proc.isRunning && Date() < deadline {
                    usleep(50_000)
                }
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
            }
        }
        backendProcess = nil
        killAnyProcessOnPort(port: targetPort)

        // 3. 记录当前激活版本到 ~/.narrafork/active_version.json (标记为用户显式 Pin)
        let activeJsonURL = homeDir.appendingPathComponent(".narrafork/active_version.json")
        let activeInfo: [String: Any] = [
            "version": toVersion,
            "binaryPath": binaryPath,
            "isPinned": true,
            "switchedAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let data = try? JSONSerialization.data(withJSONObject: activeInfo, options: [.prettyPrinted]) {
            try? data.write(to: activeJsonURL)
        }

        // 4. 同步更新 App Bundle Resources/narrafork-backend (若有写权限)
        if let resURL = Bundle.main.resourceURL {
            let targetBackend = resURL.appendingPathComponent("narrafork-backend")
            if fm.isWritableFile(atPath: resURL.path) || fm.isWritableFile(atPath: targetBackend.path) {
                try? fm.removeItem(at: targetBackend)
                try? fm.copyItem(atPath: binaryPath, toPath: targetBackend.path)

                let procChmod = Process()
                procChmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
                procChmod.arguments = ["+x", targetBackend.path]
                try? procChmod.run()
                procChmod.waitUntilExit()

                let procXattr = Process()
                procXattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                procXattr.arguments = ["-cr", targetBackend.path]
                try? procXattr.run()
                procXattr.waitUntilExit()
            }
        }

        // 5. 清理 WebKit 网页缓存（彻底避免因版本切换导致旧模块脚本与新核心资源哈希不匹配引发 "Importing a module script failed"）
        clearWebViewCache { [weak self] in
            guard let self = self else { return }
            self.currentActiveVersion = toVersion
            self.loadSplashScreen(status: "正在以 v\(toVersion) 重新启动核心服务...")
            self.launchBackendProcess()
            self.refreshVersionSubmenu()
        }
    }

    @objc func importVersionBinary() {
        let openPanel = NSOpenPanel()
        openPanel.title = "选择要导入的 NarraFork 核心二进制文件"
        openPanel.message = "请选择官方发布的 macOS arm64/x64 二进制（例如 narrafork-0.7.0-macos-arm64）"
        openPanel.prompt = "导入核心"
        openPanel.canChooseFiles = true
        openPanel.canChooseDirectories = false
        openPanel.allowsMultipleSelection = false

        NSApp.activate(ignoringOtherApps: true)
        openPanel.begin { [weak self] response in
            guard let self = self, response == .OK, let chosenURL = openPanel.url else { return }
            self.processImportedBinary(chosenURL)
        }
    }

    func processImportedBinary(_ sourceURL: URL) {
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser
        let versionsDir = homeDir.appendingPathComponent(".narrafork/versions")
        try? fm.createDirectory(at: versionsDir, withIntermediateDirectories: true)

        let ver = getBinaryVersion(at: sourceURL) ?? "custom"
        let destURL = versionsDir.appendingPathComponent("narrafork-\(ver)-macos-arm64")

        do {
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: sourceURL, to: destURL)

            let procChmod = Process()
            procChmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            procChmod.arguments = ["+x", destURL.path]
            try? procChmod.run()
            procChmod.waitUntilExit()

            let procXattr = Process()
            procXattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            procXattr.arguments = ["-cr", destURL.path]
            try? procXattr.run()
            procXattr.waitUntilExit()

            refreshVersionSubmenu()

            let alert = NSAlert()
            alert.messageText = "已成功导入核心版本 v\(ver)"
            alert.informativeText = "核心文件已归档至版本管理库。是否立即切换运行该版本？"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "立即切换")
            alert.addButton(withTitle: "稍后手动切换")
            let resp = alert.runModal()
            if resp == .alertFirstButtonReturn {
                self.executeVersionSwitch(toVersion: ver, binaryPath: destURL.path)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "导入核心失败"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
        }
    }

    @objc func openVersionsFolder() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let versionsDir = homeDir.appendingPathComponent(".narrafork/versions")
        try? FileManager.default.createDirectory(at: versionsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(versionsDir)
    }

    func clearWebViewCache(completion: (() -> Void)? = nil) {
        let types: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache,
            WKWebsiteDataTypeServiceWorkerRegistrations
        ]
        WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: Date.distantPast) {
            completion?()
        }
    }

    @objc func quitApplication() {
        isAppTerminating = true
        checkTimer?.invalidate()
        if let proc = backendProcess, proc.isRunning {
            proc.terminate()
        }
        NSApp.terminate(nil)
    }

    // MARK: - Window Setup (性能极致优化版)
    func setupWindow() {
        let screenRect = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let winWidth: CGFloat = min(1440, screenRect.width * 0.9)
        let winHeight: CGFloat = min(920, screenRect.height * 0.9)
        let initialRect = NSRect(x: (screenRect.width - winWidth) / 2 + screenRect.origin.x,
                                 y: (screenRect.height - winHeight) / 2 + screenRect.origin.y,
                                 width: winWidth,
                                 height: winHeight)

        // 移除 fullSizeContentView，避免网页视图与 macOS 标题栏事件碰撞导致的拖动卡顿
        window = NSWindow(contentRect: initialRect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered,
                          defer: false)
        window.title = "NarraFork"
        window.minSize = NSSize(width: 1000, height: 650)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.08, blue: 0.09, alpha: 1.0)

        // 关键优化：开启硬件加速图层支持 (CoreAnimation CALayer backing)
        // 彻底解决 WindowServer 软件重绘导致的鼠标拖拽丢帧与卡顿
        window.contentView?.wantsLayer = true
        window.contentView?.layerContentsRedrawPolicy = .onSetNeedsDisplay

        // WebKit Configuration 性能优化
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        config.allowsAirPlayForMediaPlayback = false
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.wantsLayer = true
        webView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }

        window.contentView?.addSubview(webView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setupMenu() {
        let mainMenu = NSMenu()

        // App Menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let appName = "NarraFork"
        appMenu.addItem(withTitle: "关于 \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "隐藏 \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "退出 \(appName)", action: #selector(quitApplication), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit Menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View Menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "视图")
        viewMenu.addItem(withTitle: "重新加载", action: #selector(reloadPage), keyEquivalent: "r")
        let forceReload = NSMenuItem(title: "强制刷新", action: #selector(forceReloadPage), keyEquivalent: "r")
        forceReload.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(forceReload)
        viewMenu.addItem(NSMenuItem.separator())
        let fullScreen = NSMenuItem(title: "进入全屏幕", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreen)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Window Menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "关闭窗口 (缩至状态栏)", action: #selector(hideMainWindow), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc func reloadPage() {
        webView.reload()
    }

    @objc func forceReloadPage() {
        webView.reloadFromOrigin()
    }

    func loadSplashScreen(status: String = "正在启动本地核心服务...") {
        let appVer = currentActiveVersion.isEmpty ? "0.7.2" : currentActiveVersion
        let displayVersion = appVer.hasPrefix("v") ? appVer : "v\(appVer)"
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          * { box-sizing: border-box; }
          body {
            margin: 0;
            background: #141517;
            color: #c1c2c5;
            font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Segoe UI", sans-serif;
            display: flex;
            flex-direction: column;
            align-items: center;
            justify-content: center;
            height: 100vh;
            user-select: none;
            position: relative;
            overflow: hidden;
          }
          .card {
            display: flex;
            flex-direction: column;
            align-items: center;
            padding: 40px;
            margin-bottom: 24px;
          }
          .logo {
            width: 84px;
            height: 84px;
            border-radius: 22px;
            background: linear-gradient(135deg, #182848, #22b8cf);
            box-shadow: 0 10px 30px rgba(34, 184, 207, 0.3);
            display: flex;
            align-items: center;
            justify-content: center;
            margin-bottom: 24px;
          }
          .title {
            font-size: 24px;
            font-weight: 700;
            color: #ffffff;
            letter-spacing: -0.5px;
            margin: 0 0 8px 0;
          }
          .subtitle {
            font-size: 14px;
            color: #909296;
            margin: 0 0 28px 0;
          }
          .loader {
            display: flex;
            align-items: center;
            gap: 12px;
            background: rgba(255, 255, 255, 0.04);
            padding: 10px 20px;
            border-radius: 30px;
            border: 1px solid rgba(255, 255, 255, 0.08);
          }
          .spinner {
            width: 16px;
            height: 16px;
            border: 2px solid rgba(255, 255, 255, 0.15);
            border-top-color: #22b8cf;
            border-radius: 50%;
            animation: spin 0.8s linear infinite;
          }
          @keyframes spin {
            to { transform: rotate(360deg); }
          }
          .status {
            font-size: 13px;
            color: #ced4da;
          }
          .footer {
            position: absolute;
            bottom: 28px;
            left: 0;
            right: 0;
            display: flex;
            flex-direction: column;
            align-items: center;
            gap: 8px;
            text-align: center;
            pointer-events: none;
          }
          .footer-version {
            display: inline-flex;
            align-items: center;
            gap: 6px;
            padding: 3px 12px;
            background: rgba(34, 184, 207, 0.1);
            border: 1px solid rgba(34, 184, 207, 0.25);
            border-radius: 12px;
            font-size: 11px;
            font-weight: 600;
            color: #22b8cf;
            letter-spacing: 0.3px;
          }
          .footer-copyright {
            font-size: 11.5px;
            color: #6c757d;
            letter-spacing: -0.1px;
            line-height: 1.5;
          }
          .footer-copyright strong {
            color: #adb5bd;
            font-weight: 600;
          }
          .footer-divider {
            margin: 0 6px;
            opacity: 0.4;
          }
        </style>
        </head>
        <body>
          <div class="card">
            <div class="logo">
              <svg width="46" height="46" viewBox="0 0 24 24" fill="none" stroke="#ffffff" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round">
                <line x1="6" y1="3" x2="6" y2="15"></line>
                <circle cx="18" cy="6" r="3"></circle>
                <circle cx="6" cy="18" r="3"></circle>
                <path d="M18 9a9 9 0 0 1-9 9"></path>
              </svg>
            </div>
            <div class="title">NarraFork</div>
            <div class="subtitle">以「叙事分叉」为核心的 AI 协作编程平台</div>
            <div class="loader">
              <div class="spinner"></div>
              <div class="status" id="status">\(status)</div>
            </div>
          </div>
          <div class="footer">
            <div class="footer-version">NarraFork \(displayVersion)</div>
            <div class="footer-copyright">
              <span>NarraFork macOS Launcher 由 <strong>Davis</strong> 制作</span>
              <span class="footer-divider">•</span>
              <span>NarraFork 属于 <strong>NarraFork 团队</strong> 所有</span>
            </div>
          </div>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func ensureBrowserAutoOpenDisabled() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let narraDir = homeDir.appendingPathComponent(".narrafork")
        let settingsFile = narraDir.appendingPathComponent("settings.json")
        try? FileManager.default.createDirectory(at: narraDir, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: settingsFile.path) {
            if let data = try? Data(contentsOf: settingsFile),
               var json = try? JSONSerialization.jsonObject(with: data, options: [.mutableContainers, .mutableLeaves]) as? [String: Any] {
                var server = json["server"] as? [String: Any] ?? [:]
                if (server["openBrowser"] as? String) != "off" {
                    server["openBrowser"] = "off"
                    json["server"] = server
                    if let updatedData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) {
                        try? updatedData.write(to: settingsFile)
                    }
                }
            }
        } else {
            let minimalSettings: [String: Any] = [
                "server": [
                    "openBrowser": "off",
                    "port": targetPort,
                    "host": "127.0.0.1"
                ]
            ]
            if let initData = try? JSONSerialization.data(withJSONObject: minimalSettings, options: [.prettyPrinted, .sortedKeys]) {
                try? initData.write(to: settingsFile)
            }
        }
    }

    // MARK: - In-Place Auto Update Mechanism
    func checkAndApplyPlacedUpdate() {
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser
        let versionsDir = homeDir.appendingPathComponent(".narrafork/versions")
        try? fm.createDirectory(at: versionsDir, withIntermediateDirectories: true)

        guard let resURL = Bundle.main.resourceURL else { return }
        let targetBackend = resURL.appendingPathComponent("narrafork-backend")

        // 1. 检查是否存在来自官方更新的 placed-update.json
        let updateJsonURL = homeDir.appendingPathComponent(".narrafork/updates/placed-update.json")
        var candidateUpdateURL: URL? = nil

        if let data = try? Data(contentsOf: updateJsonURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let newPath = json["newBinaryPath"] as? String,
           fm.fileExists(atPath: newPath) {
            candidateUpdateURL = URL(fileURLWithPath: newPath)
        }

        // 2. 检查 App Bundle Resources 目录下是否有官方下载的 narrafork-*-macos-arm64
        if candidateUpdateURL == nil,
           let resFiles = try? fm.contentsOfDirectory(at: resURL, includingPropertiesForKeys: nil) {
            let updateFiles = resFiles.filter {
                $0.lastPathComponent.hasPrefix("narrafork-") &&
                $0.lastPathComponent != "narrafork-backend" &&
                !$0.lastPathComponent.hasSuffix(".db") &&
                !$0.lastPathComponent.hasSuffix(".icns")
            }
            if let newest = updateFiles.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first {
                candidateUpdateURL = newest
            }
        }

        // 3. 检查 ~/.narrafork/versions/ 中是否有更高版本（且用户未固定回退）
        let activeJsonURL = homeDir.appendingPathComponent(".narrafork/active_version.json")
        var isUserPinned = false
        if let data = try? Data(contentsOf: activeJsonURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pinned = json["isPinned"] as? Bool, pinned {
            isUserPinned = true
        }

        if !isUserPinned,
           let versionFiles = try? fm.contentsOfDirectory(at: versionsDir, includingPropertiesForKeys: nil) {
            let binaries = versionFiles.filter {
                $0.lastPathComponent.hasPrefix("narrafork") &&
                !$0.lastPathComponent.hasSuffix(".json") &&
                !$0.lastPathComponent.hasSuffix(".txt")
            }
            let currentVer = fm.fileExists(atPath: targetBackend.path) ? (getBinaryVersion(at: targetBackend) ?? "0.0.0") : "0.0.0"
            for b in binaries {
                if let v = getBinaryVersion(at: b) {
                    if v.compare(currentVer, options: .numeric) == .orderedDescending {
                        if candidateUpdateURL == nil || v.compare(getBinaryVersion(at: candidateUpdateURL!) ?? "0.0.0", options: .numeric) == .orderedDescending {
                            candidateUpdateURL = b
                        }
                    }
                }
            }
        }

        // 如果找到了更新的核心文件，执行原子部署与同步归档
        if let updateURL = candidateUpdateURL, updateURL.path != targetBackend.path {
            guard let newVer = getBinaryVersion(at: updateURL) else { return }
            NSLog("NarraFork: 检测到更高版本核心 v%@ (%@)，正在应用...", newVer, updateURL.path)

            // 归档旧版本
            if fm.fileExists(atPath: targetBackend.path), let oldVer = getBinaryVersion(at: targetBackend) {
                let archiveOld = versionsDir.appendingPathComponent("narrafork-\(oldVer)-macos-arm64")
                if !fm.fileExists(atPath: archiveOld.path) {
                    try? fm.copyItem(at: targetBackend, to: archiveOld)
                    NSLog("NarraFork: 旧版本 v%@ 已自动归档至版本库: %@", oldVer, archiveOld.path)
                }
            }

            // 归档新版本至 ~/.narrafork/versions/
            let archiveNew = versionsDir.appendingPathComponent("narrafork-\(newVer)-macos-arm64")
            if !fm.fileExists(atPath: archiveNew.path) && updateURL.path != archiveNew.path {
                try? fm.copyItem(at: updateURL, to: archiveNew)
                NSLog("NarraFork: 新版本 v%@ 已同步归档至版本库: %@", newVer, archiveNew.path)
            }

            // 部署至 App Bundle 的 narrafork-backend (若有写权限)
            if fm.isWritableFile(atPath: resURL.path) || fm.isWritableFile(atPath: targetBackend.path) {
                do {
                    if fm.fileExists(atPath: targetBackend.path) {
                        try fm.removeItem(at: targetBackend)
                    }
                    try fm.copyItem(at: updateURL, to: targetBackend)

                    let procChmod = Process()
                    procChmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
                    procChmod.arguments = ["+x", targetBackend.path]
                    try? procChmod.run()
                    procChmod.waitUntilExit()

                    let procXattr = Process()
                    procXattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                    procXattr.arguments = ["-cr", targetBackend.path]
                    try? procXattr.run()
                    procXattr.waitUntilExit()

                    // 如果新文件来自 Resources 临时存放目录，清理冗余副本
                    if updateURL.path.contains("/Contents/Resources/") && updateURL.path != targetBackend.path {
                        try? fm.removeItem(at: updateURL)
                    }

                    try? fm.removeItem(at: updateJsonURL)
                    try? fm.removeItem(at: activeJsonURL)
                    currentActiveVersion = newVer
                    NSLog("NarraFork: 核心成功热升级至 v%@", newVer)
                } catch {
                    NSLog("NarraFork: 写入更新至 targetBackend 失败: %@", error.localizedDescription)
                }
            } else {
                // 如果 Bundle 无法写入，通过 active_version.json 指向 ~/.narrafork/versions/ 的新版本
                let activeInfo: [String: Any] = [
                    "version": newVer,
                    "binaryPath": archiveNew.path,
                    "switchedAt": ISO8601DateFormatter().string(from: Date())
                ]
                if let d = try? JSONSerialization.data(withJSONObject: activeInfo, options: [.prettyPrinted]) {
                    try? d.write(to: activeJsonURL)
                }
                try? fm.removeItem(at: updateJsonURL)
                currentActiveVersion = newVer
                NSLog("NarraFork: 无 Bundle 写权限，已通过 active_version.json 指向版本库 v%@", newVer)
            }
        }
    }

    func getRunningServerInfo() -> (pid: pid_t, version: String?)? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let lockURL = homeDir.appendingPathComponent(".narrafork/narrafork.lock")
        if let data = try? Data(contentsOf: lockURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pidInt = json["pid"] as? Int {
            let pid = pid_t(pidInt)
            if kill(pid, 0) == 0 {
                var runningVer: String? = nil
                if let argv = json["argv"] as? [String] {
                    let joined = argv.joined(separator: " ")
                    if let match = joined.range(of: #"[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression) {
                        runningVer = String(joined[match])
                    }
                }
                if runningVer == nil, let execPath = json["execPath"] as? String {
                    if let match = execPath.range(of: #"[0-9]+\.[0-9]+\.[0-9]+"#, options: .regularExpression) {
                        runningVer = String(execPath[match])
                    }
                }
                return (pid: pid, version: runningVer)
            }
        }

        // 备用方案：通过 lsof 查询占用 targetPort 端口的 PID
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "lsof -ti :\(targetPort) -sTCP:LISTEN"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        if let s = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let pidInt = Int(s) {
            let pid = pid_t(pidInt)
            return (pid: pid, version: nil)
        }

        return nil
    }

    func killRunningProcess(pid: pid_t) {
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(1.2)
        while kill(pid, 0) == 0 && Date() < deadline {
            usleep(50_000)
        }
        if kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
        }
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let lockURL = homeDir.appendingPathComponent(".narrafork/narrafork.lock")
        try? FileManager.default.removeItem(at: lockURL)
        usleep(80_000)
    }

    func killAnyProcessOnPort(port: Int) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "lsof -ti :\(port) -sTCP:LISTEN"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        if let s = String(data: d, encoding: .utf8) {
            let pids = s.split(separator: "\n").compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            for p in pids {
                kill(pid_t(p), SIGTERM)
            }
            usleep(150_000)
            for p in pids {
                if kill(pid_t(p), 0) == 0 {
                    kill(pid_t(p), SIGKILL)
                }
            }
        }
    }

    func checkAndStartBackend() {
        checkAndApplyPlacedUpdate()
        resolveActiveCoreVersion()
        ensureBrowserAutoOpenDisabled()
        archiveKnownBinaries()

        pingServer { [weak self] isRunning in
            guard let self = self else { return }
            if isRunning {
                // 如果端口已经在监听，检查运行的版本是否与当前目标版本一致
                if let runningInfo = self.getRunningServerInfo() {
                    if let runningVer = runningInfo.version, runningVer != self.currentActiveVersion {
                        NSLog("NarraFork: 检测到端口 %d 运行着旧版本 v%@ (PID %d)，而当前设定版本为 v%@，正在重启以生效最新版本...", self.targetPort, runningVer, runningInfo.pid, self.currentActiveVersion)
                        self.killRunningProcess(pid: runningInfo.pid)
                        self.loadSplashScreen(status: "正在将核心升级为 v\(self.currentActiveVersion)...")
                        self.launchBackendProcess()
                        return
                    }
                }
                self.loadApp()
            } else {
                self.launchBackendProcess()
            }
        }
    }

    func pingServer(completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: targetURL)
        request.timeoutInterval = 0.5
        request.httpMethod = "GET"

        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let httpResponse = response as? HTTPURLResponse, (200...499).contains(httpResponse.statusCode) {
                    completion(true)
                } else {
                    completion(false)
                }
            }
        }
        task.resume()
    }

    func findBackendBinary() -> URL? {
        let fm = FileManager.default
        let homeDir = fm.homeDirectoryForCurrentUser
        let versionsDir = homeDir.appendingPathComponent(".narrafork/versions")

        // 0. 优先级最高：用户手动选择激活的历史版本 (~/.narrafork/active_version.json)
        let activeJsonURL = homeDir.appendingPathComponent(".narrafork/active_version.json")
        if let data = try? Data(contentsOf: activeJsonURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let customPath = json["binaryPath"] as? String,
           fm.isExecutableFile(atPath: customPath) || fm.fileExists(atPath: customPath) {
            return URL(fileURLWithPath: customPath)
        }

        var candidateURL: URL? = nil
        var candidateVer: String? = nil

        // 1. 扫描 ~/.narrafork/versions/ 中的所有版本，寻找最高版本
        if let versionFiles = try? fm.contentsOfDirectory(at: versionsDir, includingPropertiesForKeys: nil) {
            for vf in versionFiles {
                guard vf.lastPathComponent.hasPrefix("narrafork") &&
                      !vf.lastPathComponent.hasSuffix(".json") &&
                      !vf.lastPathComponent.hasSuffix(".txt") else { continue }
                if let v = getBinaryVersion(at: vf) {
                    if candidateVer == nil || v.compare(candidateVer!, options: .numeric) == .orderedDescending {
                        candidateURL = vf
                        candidateVer = v
                    }
                }
            }
        }

        // 2. 检查 App Bundle Resources/narrafork-backend
        if let resURL = Bundle.main.resourceURL {
            let bundled = resURL.appendingPathComponent("narrafork-backend")
            if fm.isExecutableFile(atPath: bundled.path) || fm.fileExists(atPath: bundled.path) {
                if let v = getBinaryVersion(at: bundled) {
                    if candidateVer == nil || v.compare(candidateVer!, options: .numeric) == .orderedDescending {
                        candidateURL = bundled
                        candidateVer = v
                    }
                } else if candidateURL == nil {
                    candidateURL = bundled
                }
            }
        }

        // 3. 伴随 bin/ 目录核心
        let appDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let binDir = appDir.appendingPathComponent("bin")
        if let files = try? fm.contentsOfDirectory(at: binDir, includingPropertiesForKeys: nil) {
            let sorted = files.filter { $0.lastPathComponent.hasPrefix("narrafork") && !$0.lastPathComponent.hasSuffix(".md") }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for vf in sorted {
                if let v = getBinaryVersion(at: vf) {
                    if candidateVer == nil || v.compare(candidateVer!, options: .numeric) == .orderedDescending {
                        candidateURL = vf
                        candidateVer = v
                    }
                }
            }
        }

        // 4. 伴随 App 所在目录
        if let files = try? fm.contentsOfDirectory(at: appDir, includingPropertiesForKeys: nil) {
            let sorted = files.filter { $0.lastPathComponent.hasPrefix("narrafork") && !$0.lastPathComponent.hasSuffix(".app") && !$0.lastPathComponent.hasSuffix(".md") }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for vf in sorted {
                if let v = getBinaryVersion(at: vf) {
                    if candidateVer == nil || v.compare(candidateVer!, options: .numeric) == .orderedDescending {
                        candidateURL = vf
                        candidateVer = v
                    }
                }
            }
        }

        return candidateURL
    }

    func launchBackendProcess() {
        if let oldProc = backendProcess {
            oldProc.terminationHandler = nil
            if oldProc.isRunning {
                oldProc.terminate()
            }
        }
        backendProcess = nil
        killAnyProcessOnPort(port: targetPort)

        ensureBrowserAutoOpenDisabled()

        guard let binURL = findBackendBinary() else {
            showError("未找到 NarraFork 后端二进制文件。\n请确保 narrafork-backend 位于应用 Resources 目录下。")
            return
        }

        // Set permissions
        let procChmod = Process()
        procChmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        procChmod.arguments = ["+x", binURL.path]
        try? procChmod.run()
        procChmod.waitUntilExit()

        let procXattr = Process()
        procXattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        procXattr.arguments = ["-cr", binURL.path]
        try? procXattr.run()
        procXattr.waitUntilExit()

        // 关键优化：给核心后端进程指定高优先级 QoS (.userInitiated)，消除 kernel nice 降频
        // 绑定 0.0.0.0，允许同一 Wi-Fi 下的 iPhone / iPad 局域网无缝访问
        let proc = Process()
        proc.executableURL = binURL
        proc.arguments = ["--host=0.0.0.0", "--port=\(targetPort)"]
        proc.qualityOfService = .userInitiated

        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let homePath = homeDir.path

        // 核心优化：注入完整的用户开发环境 PATH
        // 彻底解决 macOS GUI 应用从 Finder/Dock 启动时缺少 /opt/homebrew/bin、OrbStack、Node、Bun、Java、Git 等工具链导致"检测不到环境"的问题
        var env = ProcessInfo.processInfo.environment
        let extraPaths = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "\(homePath)/.local/bin",
            "\(homePath)/.orbstack/bin",
            "\(homePath)/.cargo/bin",
            "\(homePath)/.nvm/current/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var pathComponents = currentPath.components(separatedBy: ":")
        for p in extraPaths.reversed() {
            if !pathComponents.contains(p) && FileManager.default.fileExists(atPath: p) {
                pathComponents.insert(p, at: 0)
            }
        }
        env["PATH"] = pathComponents.joined(separator: ":")
        env["HOME"] = homePath
        env["USER"] = ProcessInfo.processInfo.userName
        env["SHELL"] = env["SHELL"] ?? "/bin/zsh"
        env["NARRAFORK_FORCE_UNLOCK"] = "1"
        proc.environment = env

        let logDir = homeDir.appendingPathComponent(".narrafork")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

        // 首次安装与初次启动守护：如果用户没有数据库，自动部署纯净就绪模板（彻底规避官方迁移Bug）
        let dbFile = logDir.appendingPathComponent("narrafork.db")
        if !FileManager.default.fileExists(atPath: dbFile.path),
           let resURL = Bundle.main.resourceURL {
            let templateDB = resURL.appendingPathComponent("template_narrafork.db")
            if FileManager.default.fileExists(atPath: templateDB.path) {
                try? FileManager.default.copyItem(at: templateDB, to: dbFile)
            }
        }
        let logFile = logDir.appendingPathComponent("app_backend.log")

        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }

        if let fileHandle = try? FileHandle(forWritingTo: logFile) {
            _ = try? fileHandle.seekToEnd()
            proc.standardOutput = fileHandle
            proc.standardError = fileHandle
        }

        proc.terminationHandler = { [weak self] p in
            guard let self = self else { return }
            DispatchQueue.main.async {
                NSLog("NarraFork: 后端核心进程 (PID %d) 已退出", p.processIdentifier)
                if self.isAppTerminating { return }

                // 若当前运行的核心实例已不是触发退出的 PID，说明已被显式重启逻辑替换，忽略此回调
                if let current = self.backendProcess, current.processIdentifier != p.processIdentifier {
                    return
                }
                self.backendProcess = nil

                NSLog("NarraFork: 核心进程退出，外壳正在自动接管并守护重启...")
                self.checkAndApplyPlacedUpdate()
                self.resolveActiveCoreVersion()
                self.clearWebViewCache { [weak self] in
                    guard let self = self else { return }
                    self.loadSplashScreen(status: "核心服务正在重新启动 (v\(self.currentActiveVersion))...")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        guard let self = self else { return }
                        self.killAnyProcessOnPort(port: self.targetPort)
                        self.launchBackendProcess()
                    }
                }
            }
        }

        do {
            try proc.run()
            self.backendProcess = proc
            self.weStartedBackend = true
            startPolling()
        } catch {
            showError("启动后端核心失败: \(error.localizedDescription)")
        }
    }

    func startPolling() {
        self.retryCount = 0
        self.checkTimer?.invalidate()
        self.checkTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
            guard let self = self else { return }
            self.retryCount += 1
            self.pingServer { [weak self] ready in
                guard let self = self else { return }
                if ready {
                    timer.invalidate()
                    // 平滑缓冲 200ms，确保后端 SQLite 迁移校验与路由完全就绪，彻底避免冷启动时首批 API 请求竞态
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        self?.loadApp()
                    }
                } else if self.retryCount > 60 {
                    timer.invalidate()
                    self.showError("等待服务就绪超时。请检查日志: ~/.narrafork/app_backend.log")
                }
            }
        }
    }

    func loadApp() {
        let req = URLRequest(url: self.targetURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        self.webView.load(req)
    }

    func showError(_ msg: String) {
        let html = """
        <!DOCTYPE html>
        <html>
        <head><meta charset="utf-8">
        <style>
          body {
            margin: 0; background: #141517; color: #ff6b6b;
            font-family: -apple-system, sans-serif;
            display: flex; flex-direction: column; align-items: center; justify-content: center;
            height: 100vh; text-align: center; padding: 30px;
          }
          h2 { color: #fa5252; margin-bottom: 12px; }
          pre { background: rgba(0,0,0,0.4); padding: 16px; border-radius: 8px; color: #ced4da; font-size: 13px; max-width: 600px; text-align: left; }
          button {
            margin-top: 20px; background: #228be6; color: #fff; border: none; padding: 10px 24px;
            border-radius: 6px; font-size: 14px; cursor: pointer;
          }
          button:hover { background: #1c7ed6; }
        </style>
        </head>
        <body>
          <h2>启动异常</h2>
          <pre>\(msg)</pre>
          <button onclick="location.reload()">重新检查</button>
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - Window Delegate & Close to Status Bar
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        isAppTerminating = true
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
        }
        checkTimer?.invalidate()
        if weStartedBackend, let proc = backendProcess, proc.isRunning {
            proc.terminate()
            let deadline = Date().addingTimeInterval(1.2)
            while proc.isRunning && Date() < deadline {
                usleep(50_000)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
    }

    // WKUIDelegate: Alert
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "NarraFork"
        alert.informativeText = message
        alert.addButton(withTitle: "确定")
        alert.runModal()
        completionHandler()
    }

    // WKUIDelegate: Confirm
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "NarraFork"
        alert.informativeText = message
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let res = alert.runModal()
        completionHandler(res == .alertFirstButtonReturn)
    }

    // WKUIDelegate: Prompt
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "NarraFork"
        alert.informativeText = prompt
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.stringValue = defaultText ?? ""
        alert.accessoryView = input
        let res = alert.runModal()
        if res == .alertFirstButtonReturn {
            completionHandler(input.stringValue)
        } else {
            completionHandler(nil)
        }
    }

    // WKUIDelegate: File Chooser
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.begin { result in
            if result == .OK {
                completionHandler(panel.urls)
            } else {
                completionHandler(nil)
            }
        }
    }

    // WKUIDelegate: Handle target="_blank" and external links
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            if url.host == "127.0.0.1" || url.host == "localhost" {
                webView.load(navigationAction.request)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
        return nil
    }

    // MARK: - WKNavigationDelegate: 瞬时连接抖动静默平滑重试
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        // 如果是冷启动瞬时连接拒绝或找不到主机，0.5秒后自动静默重试，绝不展示白屏或报错
        if nsError.domain == NSURLErrorDomain {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                self.loadApp()
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                self.loadApp()
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
