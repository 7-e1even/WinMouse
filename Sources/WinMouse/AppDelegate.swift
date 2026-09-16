import AppKit
import ApplicationServices
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?

    // 菜单项（refreshState 更新勾选态）
    private let enableItem = NSMenuItem()
    private let curveItem = NSMenuItem()
    private let linearItem = NSMenuItem()
    private let loginItem = NSMenuItem()

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
        let quitItem = NSMenuItem()
        configure(quitItem, "退出 WinMouse", #selector(quit(_:)))

        menu.items = [
            enableItem, .separator(),
            curveItem, linearItem, .separator(),
            settingsItem, loginItem, authItem, .separator(),
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
}
