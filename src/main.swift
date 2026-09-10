import Cocoa
import WebKit

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate {
    var window: NSWindow!
    var webView: WKWebView!
    var backendProcess: Process?
    var weStartedBackend: Bool = false
    var checkTimer: Timer?
    var retryCount: Int = 0
    let targetPort: Int = 7788
    var statusItem: NSStatusItem?
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

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出 NarraFork", action: #selector(quitApplication), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
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
        if let proc = backendProcess, proc.isRunning {
            proc.terminate()
            let deadline = Date().addingTimeInterval(1.0)
            while proc.isRunning && Date() < deadline {
                usleep(50_000)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
        checkAndApplyPlacedUpdate()
        loadSplashScreen()
        launchBackendProcess()
    }

    @objc func quitApplication() {
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
        editMenu.addItem(withTitle: "剪切", action: Selector(("cut:")), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: Selector(("copy:")), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: Selector(("paste:")), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: Selector(("selectAll:")), keyEquivalent: "a")
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

    func loadSplashScreen() {
        let appVer = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.7.0"
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
              <div class="status" id="status">正在启动本地核心服务...</div>
            </div>
          </div>
          <div class="footer">
            <div class="footer-version">NarraFork macOS Launcher \(displayVersion)</div>
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
        let updateJsonURL = homeDir.appendingPathComponent(".narrafork/updates/placed-update.json")
        guard let data = try? Data(contentsOf: updateJsonURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newPath = json["newBinaryPath"] as? String else {
            return
        }

        // 检查下载的新二进制是否存在
        guard fm.fileExists(atPath: newPath) else { return }

        // 确定 App 内嵌目标路径
        guard let resURL = Bundle.main.resourceURL else { return }
        let targetBackend = resURL.appendingPathComponent("narrafork-backend")

        if newPath == targetBackend.path {
            try? fm.removeItem(at: updateJsonURL)
            return
        }

        NSLog("NarraFork: 检测到已下载热更新 %@，正在同步至 %@", newPath, targetBackend.path)
        do {
            if fm.fileExists(atPath: targetBackend.path) {
                try fm.removeItem(at: targetBackend)
            }
            try fm.copyItem(at: URL(fileURLWithPath: newPath), to: targetBackend)

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

            // 如果下载文件留在 App Bundle Resources 中，删除残留副本以防体积膨胀
            if newPath.contains("/Contents/Resources/") && newPath != targetBackend.path {
                try? fm.removeItem(atPath: newPath)
            }

            // 清理已完成的更新标记
            try? fm.removeItem(at: updateJsonURL)
            NSLog("NarraFork: 热更新文件成功植入并就绪！")
        } catch {
            NSLog("NarraFork: 应用热更新出错: %@", error.localizedDescription)
        }
    }

    func checkAndStartBackend() {
        checkAndApplyPlacedUpdate()
        ensureBrowserAutoOpenDisabled()
        pingServer { [weak self] isRunning in
            guard let self = self else { return }
            if isRunning {
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

        // 1. Inside App Bundle Resources
        if let resURL = Bundle.main.resourceURL {
            let bundled = resURL.appendingPathComponent("narrafork-backend")
            if fm.isExecutableFile(atPath: bundled.path) || fm.fileExists(atPath: bundled.path) {
                return bundled
            }
        }

        // 2. In bin/ directory alongside the App
        let appDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let binDir = appDir.appendingPathComponent("bin")
        if let files = try? fm.contentsOfDirectory(at: binDir, includingPropertiesForKeys: nil) {
            let sorted = files.filter { $0.lastPathComponent.hasPrefix("narrafork") && !$0.lastPathComponent.hasSuffix(".md") }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            if let first = sorted.first {
                return first
            }
        }

        // 3. In same folder as the App Bundle
        if let files = try? fm.contentsOfDirectory(at: appDir, includingPropertiesForKeys: nil) {
            let sorted = files.filter { $0.lastPathComponent.hasPrefix("narrafork") && !$0.lastPathComponent.hasSuffix(".app") && !$0.lastPathComponent.hasSuffix(".md") }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            if let first = sorted.first {
                return first
            }
        }

        return nil
    }

    func launchBackendProcess() {
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
            try? fileHandle.seekToEnd()
            proc.standardOutput = fileHandle
            proc.standardError = fileHandle
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
        self.webView.load(URLRequest(url: self.targetURL))
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
