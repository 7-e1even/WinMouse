import AppKit
import ServiceManagement

/// 设置窗口：指针 / 滚轮与按键 / 关于 三页。
/// 指针页带实时曲线图与速度/增益监测，便于对照 Windows 校准。
final class SettingsWindow: NSObject {
    static let shared = SettingsWindow()
    private override init() {}

    private var window: NSWindow?
    private var timer: Timer?

    private var tabSegments: NSSegmentedControl!
    private var pagePointer: NSView!
    private var pageScroll: NSView!
    private var pageAbout: NSView!

    // 指针页
    private var statusLabel: NSTextField!
    private var authButton: NSButton!
    private var enableCheck: NSButton!
    private var mouseOnlyCheck: NSButton!
    private var modeSegments: NSSegmentedControl!
    private var multiplierLabel: NSTextField!
    private var multiplierSlider: NSSlider!
    private var dpiAnchorCheck: NSButton!
    private var dpiPopUp: NSPopUpButton!
    private var pollHzPopUp: NSPopUpButton!
    private var pollHintLabel: NSTextField!
    private var curveView: CurveGraphView!
    private var monitorLabel: NSTextField!

    // 滚轮与按键页
    private var scrollSpeedLabel: NSTextField!
    private var scrollSpeedSlider: NSSlider!
    private var scrollInvertCheck: NSButton!
    private var remapCheck: NSButton!

    // 关于页
    private var loginCheck: NSButton!

    private static let dpiOptions: [Double] = [400, 800, 1200, 1600, 3200, 6400]
    private static let pollHzOptions: [Double] = [125, 250, 500, 1000, 2000, 4000, 8000]

    func show() {
        if window == nil { window = makeWindow() }
        syncControls()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.tick()
            }
        }
    }

    // MARK: - 实时刷新（10Hz，窗口可见时才工作）

    private func tick() {
        guard window?.isVisible == true else { return }
        let s = Settings.shared

        let trusted = AXIsProcessTrusted()
        let running = trusted && EventTap.shared.isRunning
        statusLabel.stringValue = running ? "✅ 事件接管中" : "⚠️ 未获辅助功能权限"
        statusLabel.textColor = running ? .systemGreen : .systemOrange
        authButton.isHidden = trusted

        let wantSegment = (s.mode == .windowsCurve) ? 0 : 1
        if modeSegments.selectedSegment != wantSegment {
            modeSegments.selectedSegment = wantSegment
        }
        if #available(macOS 13.0, *) {
            loginCheck.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        }

        // 实时监测：300ms 无移动事件视为静止
        let tap = EventTap.shared
        let idle = ProcessInfo.processInfo.systemUptime - tap.lastEventUptime > 0.3
        let v = idle ? 0 : tap.lastSpeed
        curveView.currentSpeed = v
        if !s.enabled {
            monitorLabel.stringValue = "已暂停：勾选“启用”后接管鼠标移动"
        } else if v <= 0 {
            monitorLabel.stringValue = String(format: "移动鼠标查看实时速度与增益 ｜ 灵敏度 ×%.2f", s.multiplier)
        } else if s.mode == .windowsCurve {
            let shape = TransferFunction(mode: .windowsCurve, multiplier: 1,
                                         dpi: s.dpi, dpiCompensation: s.dpiCompensation,
                                         pollHz: s.effectivePollHz).gain(speed: v)
            let total = s.transferFunction.gain(speed: v)
            monitorLabel.stringValue = String(format: "速度 %.2f counts/ms ≈ %.1f 英寸/秒 ｜ 曲线 ×%.2f ｜ 总增益 ×%.2f",
                                              v, v * 1000 / s.dpi, shape, total)
        } else {
            let total = s.transferFunction.gain(speed: v)
            monitorLabel.stringValue = String(format: "速度 %.2f counts/ms ≈ %.1f 英寸/秒 ｜ 线性模式总增益 ×%.2f",
                                              v, v * 1000 / s.dpi, total)
        }
    }

    // MARK: - 动作

    @objc private func pickTab(_ sender: NSSegmentedControl) {
        pagePointer.isHidden = sender.selectedSegment != 0
        pageScroll.isHidden = sender.selectedSegment != 1
        pageAbout.isHidden = sender.selectedSegment != 2
    }

    @objc private func enableChanged(_ sender: NSButton) {
        Settings.shared.enabled = (sender.state == .on)
        (NSApp.delegate as? AppDelegate)?.refreshState()
    }

    @objc private func mouseOnlyChanged(_ sender: NSButton) {
        Settings.shared.mouseOnly = (sender.state == .on)
    }

    @objc private func pickMode(_ sender: NSSegmentedControl) {
        Settings.shared.mode = (sender.selectedSegment == 0) ? .windowsCurve : .linear
        syncControls()
        (NSApp.delegate as? AppDelegate)?.refreshState()
    }

    @objc private func multiplierChanged(_ sender: NSSlider) {
        Settings.shared.multiplier = sender.doubleValue
        multiplierLabel.stringValue = String(format: "指针灵敏度 ×%.2f", sender.doubleValue)
    }

    @objc private func dpiAnchorChanged(_ sender: NSButton) {
        Settings.shared.dpiCompensation = (sender.state == .on)
        syncControls()
        curveView.needsDisplay = true
    }

    @objc private func dpiChanged(_ sender: NSPopUpButton) {
        if let v = sender.selectedItem?.representedObject as? Double {
            Settings.shared.dpi = v
            curveView.needsDisplay = true
        }
    }

    @objc private func pollHzChanged(_ sender: NSPopUpButton) {
        if let v = sender.selectedItem?.representedObject as? Double {
            Settings.shared.pollHz = v
            curveView.needsDisplay = true
        }
    }

    @objc private func scrollSpeedChanged(_ sender: NSSlider) {
        Settings.shared.scrollSpeed = sender.doubleValue
        scrollSpeedLabel.stringValue = String(format: "滚轮速度 ×%.2f", sender.doubleValue)
    }

    @objc private func scrollInvertChanged(_ sender: NSButton) {
        Settings.shared.scrollInvert = (sender.state == .on)
    }

    @objc private func remapChanged(_ sender: NSButton) {
        Settings.shared.remapSideButtons = (sender.state == .on)
    }

    @objc private func loginChanged(_ sender: NSButton) {
        (NSApp.delegate as? AppDelegate)?.toggleLogin(nil)
    }

    // MARK: - 窗口

    private func makeWindow() -> NSWindow {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 660))

        tabSegments = NSSegmentedControl(labels: ["指针", "滚轮与按键", "关于"],
                                         trackingMode: .selectOne,
                                         target: self,
                                         action: #selector(pickTab(_:)))
        tabSegments.selectedSegment = 0
        tabSegments.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(tabSegments)

        pagePointer = makePointerPage()
        pageScroll = makeScrollPage()
        pageAbout = makeAboutPage()
        let pages = [pagePointer!, pageScroll!, pageAbout!]
        for page in pages {
            page.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(page)
        }
        pageScroll.isHidden = true
        pageAbout.isHidden = true

        var cons: [NSLayoutConstraint] = [
            tabSegments.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            tabSegments.centerXAnchor.constraint(equalTo: content.centerXAnchor),
        ]
        for page in pages {
            cons.append(page.topAnchor.constraint(equalTo: tabSegments.bottomAnchor, constant: 16))
            cons.append(page.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24))
            cons.append(page.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24))
            cons.append(page.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16))
        }
        NSLayoutConstraint.activate(cons)

        let win = NSWindow(contentRect: content.bounds,
                           styleMask: [.titled, .closable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "WinMouse 设置"
        win.contentView = content
        win.isReleasedWhenClosed = false
        return win
    }

    // MARK: 指针页

    private func makePointerPage() -> NSView {
        statusLabel = NSTextField(labelWithString: "状态：…")
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        authButton = NSButton(title: "打开辅助功能授权页", target: NSApp.delegate,
                              action: #selector(AppDelegate.openAuthPane(_:)))
        authButton.bezelStyle = .rounded
        authButton.controlSize = .small
        let statusRow = NSStackView(views: [statusLabel, authButton])
        statusRow.orientation = .horizontal
        statusRow.spacing = 8

        enableCheck = NSButton(checkboxWithTitle: "启用（接管鼠标移动）",
                               target: self, action: #selector(enableChanged(_:)))
        mouseOnlyCheck = NSButton(checkboxWithTitle: "仅接管鼠标，放行触控板（推荐 MacBook 开启）",
                                  target: self, action: #selector(mouseOnlyChanged(_:)))

        modeSegments = NSSegmentedControl(labels: ["Windows 曲线（EPP 开）", "纯线性（EPP 关）"],
                                          trackingMode: .selectOne,
                                          target: self,
                                          action: #selector(pickMode(_:)))

        multiplierLabel = NSTextField(labelWithString: "指针灵敏度 ×1.00")
        multiplierSlider = NSSlider(value: 1, minValue: 0.2, maxValue: 8.0,
                                    target: self, action: #selector(multiplierChanged(_:)))
        multiplierSlider.translatesAutoresizingMaskIntoConstraints = false
        multiplierSlider.widthAnchor.constraint(equalToConstant: 280).isActive = true

        dpiAnchorCheck = NSButton(checkboxWithTitle: "曲线速度轴锚定 400dpi 基准（默认关 = Windows 原生，不识别 DPI）",
                                  target: self, action: #selector(dpiAnchorChanged(_:)))
        dpiPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        dpiPopUp.target = self
        dpiPopUp.action = #selector(dpiChanged(_:))
        for dpi in Self.dpiOptions {
            dpiPopUp.addItem(withTitle: "\(Int(dpi)) DPI")
            dpiPopUp.lastItem?.representedObject = dpi
        }
        let dpiRow = NSStackView(views: [NSTextField(labelWithString: "鼠标 DPI（仅锚定模式生效）"), dpiPopUp])
        dpiRow.orientation = .horizontal
        dpiRow.spacing = 8

        pollHzPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        pollHzPopUp.target = self
        pollHzPopUp.action = #selector(pollHzChanged(_:))
        pollHzPopUp.addItem(withTitle: "默认（1000 Hz）")
        pollHzPopUp.lastItem?.representedObject = 0.0
        for hz in Self.pollHzOptions {
            pollHzPopUp.addItem(withTitle: "\(Int(hz)) Hz")
            pollHzPopUp.lastItem?.representedObject = hz
        }
        let pollRow = NSStackView(views: [NSTextField(labelWithString: "鼠标回报率"), pollHzPopUp])
        pollRow.orientation = .horizontal
        pollRow.spacing = 8

        pollHintLabel = NSTextField(labelWithString: "加速手感与 Windows 不一致时，尝试改选回报率（2.4G 无线鼠标常为 125Hz）")
        pollHintLabel.font = .systemFont(ofSize: 11)
        pollHintLabel.textColor = .secondaryLabelColor

        curveView = CurveGraphView()
        curveView.translatesAutoresizingMaskIntoConstraints = false
        curveView.heightAnchor.constraint(equalToConstant: 190).isActive = true
        curveView.gainAt = { v in
            let s = Settings.shared
            return TransferFunction(mode: .windowsCurve, multiplier: 1,
                                    dpi: s.dpi, dpiCompensation: s.dpiCompensation,
                                    pollHz: s.effectivePollHz).gain(speed: v)
        }

        monitorLabel = NSTextField(labelWithString: "移动鼠标查看实时速度与增益")
        monitorLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        monitorLabel.textColor = .secondaryLabelColor

        let sep1 = separator()
        let sep2 = separator()
        let stack = NSStackView(views: [
            section("状态"), statusRow,
            sep1,
            section("指针"), enableCheck, mouseOnlyCheck, modeSegments,
            multiplierLabel, multiplierSlider,
            dpiAnchorCheck, dpiRow, pollRow, pollHintLabel,
            sep2,
            section("曲线（实时）"), curveView, monitorLabel,
            hintLabel("校准：同一只鼠标、同样 DPI，两台电脑上移动相同手上距离，调“指针灵敏度”到光标行程一致。先中速校准，再验证慢速与快速甩动。"),
        ])
        return wrap(stack, stretch: [sep1, sep2, curveView])
    }

    // MARK: 滚轮与按键页

    private func makeScrollPage() -> NSView {
        scrollSpeedLabel = NSTextField(labelWithString: "滚轮速度 ×1.00")
        scrollSpeedSlider = NSSlider(value: 1, minValue: 0.25, maxValue: 8.0,
                                     target: self, action: #selector(scrollSpeedChanged(_:)))
        scrollSpeedSlider.translatesAutoresizingMaskIntoConstraints = false
        scrollSpeedSlider.widthAnchor.constraint(equalToConstant: 280).isActive = true

        scrollInvertCheck = NSButton(checkboxWithTitle: "反转滚轮方向（仅鼠标）",
                                     target: self, action: #selector(scrollInvertChanged(_:)))
        remapCheck = NSButton(checkboxWithTitle: "侧键 X1/X2 → 后退/前进（⌘[ / ⌘]）",
                              target: self, action: #selector(remapChanged(_:)))

        let sep = separator()
        let stack = NSStackView(views: [
            section("滚轮"),
            scrollSpeedLabel, scrollSpeedSlider, scrollInvertCheck,
            hintLabel("只影响鼠标的离散滚轮；触控板连续滚动原样放行，不受影响。"),
            sep,
            section("侧键"),
            remapCheck,
            hintLabel("映射为 ⌘[ / ⌘]，在 Safari / Chrome / Finder 等应用中作后退/前进。"),
        ])
        return wrap(stack, stretch: [sep])
    }

    // MARK: 关于页

    private func makeAboutPage() -> NSView {
        let about = NSTextField(labelWithString:
            "WinMouse v1.1\n\n" +
            "把 Windows 鼠标手感搬到 macOS。\n" +
            "加速曲线取自你的 Windows 注册表（SmoothMouseXCurve/YCurve，五点实测值），\n" +
            "逐事件瞬时速度求增益，与 Windows 行为一致；\n" +
            "在 Windows 上运行 scripts/read_curve.ps1 可重新导出。\n\n" +
            "功能：指针曲线（类 LinearMouse）· 滚轮增强（类 Mos）· 侧键映射（类 Mac Mouse Fix）\n\n" +
            "使用步骤\n" +
            "1. 系统设置 → 鼠标 → 高级 → 关闭“指针加速”\n" +
            "2. 授予辅助功能权限（下方按钮）\n" +
            "3. 在“指针”页边看实时监测边校准灵敏度\n\n" +
            "参考：微软《Pointer Ballistics for Windows XP》；LinearMouse / Mac Mouse Fix / Mos")
        about.font = .systemFont(ofSize: 12)
        about.textColor = .secondaryLabelColor
        about.lineBreakMode = .byWordWrapping
        about.preferredMaxLayoutWidth = 460

        let auth = NSButton(title: "打开辅助功能授权页", target: NSApp.delegate,
                            action: #selector(AppDelegate.openAuthPane(_:)))
        auth.bezelStyle = .rounded

        loginCheck = NSButton(checkboxWithTitle: "开机自启",
                              target: self, action: #selector(loginChanged(_:)))

        let stack = NSStackView(views: [about, auth, loginCheck])
        return wrap(stack)
    }

    // MARK: - 控件工具

    private func section(_ title: String) -> NSTextField {
        let f = NSTextField(labelWithString: title)
        f.font = .systemFont(ofSize: 13, weight: .semibold)
        return f
    }

    private func hintLabel(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: 11)
        f.textColor = .secondaryLabelColor
        f.lineBreakMode = .byWordWrapping
        f.preferredMaxLayoutWidth = 460
        return f
    }

    private func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return b
    }

    /// 把 stack 包装成页面容器；stretch 里的视图拉满整页宽
    private func wrap(_ stack: NSStackView, stretch: [NSView] = []) -> NSView {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        for v in stretch {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return container
    }

    private func syncControls() {
        guard window != nil else { return }
        let s = Settings.shared
        enableCheck.state = s.enabled ? .on : .off
        mouseOnlyCheck.state = s.mouseOnly ? .on : .off
        modeSegments.selectedSegment = (s.mode == .windowsCurve) ? 0 : 1
        multiplierSlider.doubleValue = s.multiplier
        multiplierLabel.stringValue = String(format: "指针灵敏度 ×%.2f", s.multiplier)
        dpiAnchorCheck.state = s.dpiCompensation ? .on : .off
        let curveMode = s.mode == .windowsCurve
        dpiAnchorCheck.isEnabled = curveMode
        dpiPopUp.isEnabled = curveMode && s.dpiCompensation
        if let idx = Self.dpiOptions.enumerated().min(by: {
            abs($0.element - s.dpi) < abs($1.element - s.dpi)
        })?.offset {
            dpiPopUp.selectItem(at: idx)
        }
        if s.pollHz == 0 {
            pollHzPopUp.selectItem(at: 0)
        } else if let idx = Self.pollHzOptions.enumerated().min(by: {
            abs($0.element - s.pollHz) < abs($1.element - s.pollHz)
        })?.offset {
            pollHzPopUp.selectItem(at: idx + 1)
        }
        scrollSpeedSlider.doubleValue = s.scrollSpeed
        scrollSpeedLabel.stringValue = String(format: "滚轮速度 ×%.2f", s.scrollSpeed)
        scrollInvertCheck.state = s.scrollInvert ? .on : .off
        remapCheck.state = s.remapSideButtons ? .on : .off
        if #available(macOS 13.0, *) {
            loginCheck.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        }
    }
}
