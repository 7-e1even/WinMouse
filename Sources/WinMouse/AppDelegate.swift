import AppKit
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?
    private var updateTimer: Timer?

    // 菜单项（refreshState 更新勾选态）
    private let enableItem = NSMenuItem()
    private let curveItem = NSMenuItem()
    private let linearItem = NSMenuItem()
    private let loginItem = NSMenuItem()
    private let updateItem = NSMenuItem()

    // 更新状态：pendingRelease 非空时菜单项变为"下载并安装 vX.Y.Z"
    private var pendingRelease: Updater.Release?
    private var updateBusy = false

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = buildMenu()
        MouseDevices.shared.start()

        // 首次启动弹一次系统授权提示；之后轮询，用户勾选后自动开始工作
        if !AXIsProcessTrusted() {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as NSDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            // 未授权时直接展示设置窗口：用户第一眼能看到状态与授权入口
            SettingsWindow.shared.show()
        }
        refreshState()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshState()
        }

        // 自动检查更新：启动 5 秒后一次，之后每 6 小时看一次是否距上次满 24h
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.autoCheckUpdate()
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.autoCheckUpdate()
        }
    }

    /// 再次打开 .app（已运行时）→ 唤出设置窗口；刘海屏挤掉菜单栏图标时的兜底入口
    func applicationShouldHandleReopen(_ application: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindow.shared.show()
        return true
    }

    // MARK: - 菜单栏

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        configure(enableItem, "启用（接管鼠标移动）", #selector(toggleEnabled(_:)))
        configure(curveItem, "Windows 曲线（EPP 开 · 默认手感）", #selector(pickCurve(_:)))
        configure(linearItem, "纯线性（EPP 关 · 游戏手感）", #selector(pickLinear(_:)))

        let settingsItem = NSMenuItem()
        configure(settingsItem, "设置…", #selector(openSettings(_:)))
        configure(loginItem, "开机自启", #selector(toggleLogin(_:)))
        let authItem = NSMenuItem()
        configure(authItem, "授权辅助功能…", #selector(openAuthPane(_:)))
        configure(updateItem, "检查更新…", #selector(updateClicked(_:)))
        let quitItem = NSMenuItem()
        configure(quitItem, "退出 WinMouse", #selector(quit(_:)))

        menu.items = [
            enableItem, .separator(),
            curveItem, linearItem, .separator(),
            settingsItem, loginItem, authItem, updateItem, .separator(),
            quitItem,
        ]
        return menu
    }

    private func configure(_ item: NSMenuItem, _ title: String, _ action: Selector) {
        item.title = title
        item.action = action
        item.target = self
    }

    func refreshState() {
        let trusted = AXIsProcessTrusted()
        if trusted { EventTap.shared.start() }

        let running = trusted && EventTap.shared.isRunning
        // SF Symbols 模板图：随菜单栏深浅色自适应；取不到时回退 emoji
        let symbolName = running ? "computermouse" : "exclamationmark.triangle"
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "WinMouse") {
            symbol.isTemplate = true
            statusItem.button?.image = symbol
            statusItem.button?.title = ""
        } else {
            statusItem.button?.image = nil
            statusItem.button?.title = running ? "🖱️" : "⚠️"
        }

        let s = Settings.shared
        enableItem.state = s.enabled ? .on : .off
        curveItem.state = (s.mode == .windowsCurve) ? .on : .off
        linearItem.state = (s.mode == .linear) ? .on : .off
        if #available(macOS 13.0, *) {
            loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        }
    }

    // MARK: - 动作

    @objc private func toggleEnabled(_ sender: Any?) {
        Settings.shared.enabled.toggle()
        refreshState()
    }

    @objc private func pickCurve(_ sender: Any?) {
        Settings.shared.mode = .windowsCurve
        refreshState()
    }

    @objc private func pickLinear(_ sender: Any?) {
        Settings.shared.mode = .linear
        refreshState()
    }

    @objc func toggleLogin(_ sender: Any?) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "设置开机自启失败"
            alert.informativeText = "\(error.localizedDescription)\n可手动将 WinMouse 加入 系统设置 → 通用 → 登录项。"
            alert.runModal()
        }
        refreshState()
    }

    @objc func openAuthPane(_ sender: Any?) {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func openSettings(_ sender: Any?) {
        SettingsWindow.shared.show()
    }

    @objc private func quit(_ sender: Any?) {
        EventTap.shared.stop()
        NSApp.terminate(nil)
    }

    // MARK: - 自动更新

    /// 静默检查：只在有新版本时改菜单项标题，不打扰
    private func autoCheckUpdate() {
        guard pendingRelease == nil, !updateBusy else { return }
        Task {
            guard Updater.shared.dueForAutoCheck() else { return }
            Updater.shared.markAutoChecked()
            guard let rel = try? await Updater.shared.fetchLatest(),
                  Updater.isVersion(rel.version, newerThan: Updater.shared.currentVersion)
            else { return }
            await MainActor.run {
                pendingRelease = rel
                updateItem.title = "下载并安装 \(rel.tag)…"
            }
        }
    }

    @objc private func updateClicked(_ sender: Any?) {
        // 已发现新版本 → 直接进入下载安装
        if let rel = pendingRelease {
            askAndInstall(rel)
            return
        }
        guard !updateBusy else { return }
        updateBusy = true
        updateItem.title = "正在检查…"
        Task {
            do {
                guard let rel = try await Updater.shared.fetchLatest(),
                      Updater.isVersion(rel.version, newerThan: Updater.shared.currentVersion)
                else {
                    await MainActor.run {
                        updateBusy = false
                        updateItem.title = "检查更新…"
                        alert("已是最新版本", "当前版本 \(Updater.shared.currentVersionDisplay)")
                    }
                    return
                }
                await MainActor.run {
                    updateBusy = false
                    pendingRelease = rel
                    updateItem.title = "下载并安装 \(rel.tag)…"
                    askAndInstall(rel)
                }
            } catch {
                await MainActor.run {
                    updateBusy = false
                    updateItem.title = "检查更新…"
                    alert("检查更新失败", error.localizedDescription)
                }
            }
        }
    }

    private func askAndInstall(_ rel: Updater.Release) {
        let a = NSAlert()
        a.messageText = "发现新版本 \(rel.tag)"
        a.informativeText = rel.notes.isEmpty
            ? "是否下载并重启以完成更新？"
            : "\(rel.notes)\n\n是否下载并重启以完成更新？"
        a.addButton(withTitle: "立即更新")
        a.addButton(withTitle: "稍后")
        guard a.runModal() == .alertFirstButtonReturn else { return }

        // swift run 方式没有 .app 包结构，无法自我替换
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            alert("无法自动更新", "当前以 swift run 方式运行，请使用打包后的 WinMouse.app。")
            return
        }
        guard !updateBusy else { return }
        updateBusy = true
        updateItem.title = "正在下载…"
        Task {
            do {
                let zip = try await Updater.shared.download(rel)
                try await Updater.shared.install(from: zip) // 成功路径在 install 内完成重启
            } catch {
                await MainActor.run {
                    updateBusy = false
                    updateItem.title = "下载并安装 \(rel.tag)…"
                    alert("更新失败", error.localizedDescription)
                }
            }
        }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}
