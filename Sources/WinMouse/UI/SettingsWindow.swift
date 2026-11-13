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
    private var multiplierValue: NSTextField!
    private var multiplierSlider: NSSlider!
    private var dpiAnchorCheck: NSButton!
    private var dpiPopUp: NSPopUpButton!
    private var pollHzPopUp: NSPopUpButton!
    private var curveView: CurveGraphView!
    private var monitorLine1: NSTextField!
    private var monitorLine2: NSTextField!
    private var sourceLabel: NSTextField!

    // 滚轮与按键页
    private var scrollSpeedValue: NSTextField!
    private var scrollSpeedSlider: NSSlider!
    private var scrollInvertCheck: NSButton!
    private var remapCheck: NSButton!

    // 关于页
    private var loginCheck: NSButton!

    private static let dpiOptions: [Double] = [400, 800, 1200, 1600, 3200, 6400]
    private static let pollHzOptions: [Double] = [125, 250, 500, 1000, 2000, 4000, 8000]
    private static let width: CGFloat = 540
    private static let margin: CGFloat = 24
    private static let labelColumn: CGFloat = 76

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
        if !trusted {
            statusLabel.stringValue = "● 未获辅助功能权限"
            statusLabel.textColor = .systemOrange
        } else if !running {
            statusLabel.stringValue = "● 事件接管未启动"
            statusLabel.textColor = .systemOrange
        } else if !s.enabled {
            statusLabel.stringValue = "● 已暂停"
            statusLabel.textColor = .secondaryLabelColor
        } else {
            statusLabel.stringValue = "● 正在接管鼠标"
            statusLabel.textColor = .systemGreen
        }
        authButton.isHidden = trusted

        let wantSegment = (s.mode == .windowsCurve) ? 0 : 1
        if modeSegments.selectedSegment != wantSegment {
            modeSegments.selectedSegment = wantSegment
            refreshCurve()
        }
        if enableCheck.state != (s.enabled ? .on : .off) {
            enableCheck.state = s.enabled ? .on : .off
        }
        if #available(macOS 13.0, *) {
            loginCheck.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        }

        // 实时监测：300ms 无移动事件视为静止
        let m = EventTap.shared.monitor
        let idle = m.uptime == 0 || ProcessInfo.processInfo.systemUptime - m.uptime > 0.3
        curveView.current = (idle || !s.enabled) ? nil : (m.reportCounts, m.curveGain)

        if !s.enabled {
            monitorLine1.stringValue = "已暂停：勾选“启用”后接管鼠标移动"
            monitorLine2.stringValue = " "
        } else if idle {
            monitorLine1.stringValue = "移动鼠标查看实时数据"
            monitorLine2.stringValue = String(format: "灵敏度 ×%.2f", s.multiplier)
        } else {
            monitorLine1.stringValue = String(format: "每报 %.1f 计数 ｜ %.2f counts/ms ≈ %.1f 英寸/秒（按 %d DPI）",
                                              m.reportCounts, m.speed, m.speed * 1000 / s.dpi, Int(s.dpi))
            monitorLine2.stringValue = String(format: "曲线 ×%.2f ｜ 灵敏度 ×%.2f ｜ 总增益 ×%.2f",
                                              m.curveGain, m.gain / max(m.curveGain, 0.0001), m.gain)
        }

        if m.uptime == 0 {
            sourceLabel.stringValue = "输入来源：等待鼠标移动…"
            sourceLabel.textColor = .secondaryLabelColor
        } else if m.rawInput {
            let scale = m.systemScale > 0 ? String(format: "，已绕过 macOS 自身缩放 ×%.2f", m.systemScale) : ""
            sourceLabel.stringValue = "输入来源：设备原始计数 ✓" + scale
            sourceLabel.textColor = .secondaryLabelColor
        } else {
            sourceLabel.stringValue = "输入来源：macOS 增量（未取到原始计数）——请关闭系统“指针加速”"
            sourceLabel.textColor = .systemOrange
        }
    }

    // MARK: - 动作

    @objc private func pickTab(_ sender: NSSegmentedControl) {
        showPage(sender.selectedSegment, animate: true)
    }

    /// 切换页面，窗口高度贴合当前页（保持标题栏位置不动）
    private func showPage(_ index: Int, animate: Bool) {
        let pages: [NSView] = [pagePointer, pageScroll, pageAbout]
        for (i, page) in pages.enumerated() { page.isHidden = i != index }
        guard let win = window else { return }
        let height = 16 + tabSegments.fittingSize.height + 18 + pages[index].fittingSize.height + 20
        var frame = win.frameRect(forContentRect: NSRect(x: 0, y: 0, width: Self.width, height: height))
        frame.origin.x = win.frame.minX
        frame.origin.y = win.frame.maxY - frame.height
        win.setFrame(frame, display: true, animate: animate && win.isVisible)
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
        let m = Self.fromSlider(sender.doubleValue)
        Settings.shared.multiplier = m
        multiplierValue.stringValue = String(format: "×%.2f", m)
    }

    @objc private func dpiAnchorChanged(_ sender: NSButton) {
        Settings.shared.dpiCompensation = (sender.state == .on)
        syncControls()
    }

    @objc private func dpiChanged(_ sender: NSPopUpButton) {
        if let v = sender.selectedItem?.representedObject as? Double {
            Settings.shared.dpi = v
            refreshCurve()
        }
    }

    @objc private func pollHzChanged(_ sender: NSPopUpButton) {
        if let v = sender.selectedItem?.representedObject as? Double {
            Settings.shared.pollHz = v
            refreshCurve()
        }
    }

    @objc private func scrollSpeedChanged(_ sender: NSSlider) {
        let m = Self.fromSlider(sender.doubleValue)
        Settings.shared.scrollSpeed = m
        scrollSpeedValue.stringValue = String(format: "×%.2f", m)
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
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 600),
                           styleMask: [.titled, .closable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "WinMouse 设置"
        win.isReleasedWhenClosed = false
        let content = win.contentView!

        tabSegments = NSSegmentedControl(labels: ["指针", "滚轮与按键", "关于"],
                                         trackingMode: .selectOne,
                                         target: self,
                                         action: #selector(pickTab(_:)))
        tabSegments.selectedSegment = 0
        tabSegments.segmentDistribution = .fillEqually
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

        // 页面只钉顶部和左右，高度由内容决定；窗口高度随当前页调整（showPage）
        var cons: [NSLayoutConstraint] = [
            content.widthAnchor.constraint(equalToConstant: Self.width),
            tabSegments.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            tabSegments.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            tabSegments.widthAnchor.constraint(equalToConstant: 320),
        ]
        for page in pages {
            cons.append(page.topAnchor.constraint(equalTo: tabSegments.bottomAnchor, constant: 18))
            cons.append(page.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.margin))
            cons.append(page.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.margin))
        }
        NSLayoutConstraint.activate(cons)

        window = win
        showPage(0, animate: false)
        return win
    }

    // MARK: 指针页

    private func makePointerPage() -> NSView {
        statusLabel = NSTextField(labelWithString: "● …")
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        authButton = NSButton(title: "授权辅助功能…", target: NSApp.delegate,
                              action: #selector(AppDelegate.openAuthPane(_:)))
        authButton.bezelStyle = .rounded
        authButton.controlSize = .small

        enableCheck = NSButton(checkboxWithTitle: "启用（接管鼠标移动）",
                               target: self, action: #selector(enableChanged(_:)))
        mouseOnlyCheck = NSButton(checkboxWithTitle: "仅接管鼠标，放行触控板与绘图板",
                                  target: self, action: #selector(mouseOnlyChanged(_:)))

        modeSegments = NSSegmentedControl(labels: ["Windows 曲线（EPP 开）", "纯线性（EPP 关）"],
                                          trackingMode: .selectOne,
                                          target: self,
                                          action: #selector(pickMode(_:)))

        // 对数刻度：×0.5–×2 的常用校准区间占滑轨中段，便于细调
        multiplierSlider = NSSlider(value: 0, minValue: log2(0.2), maxValue: log2(8.0),
                                    target: self, action: #selector(multiplierChanged(_:)))
        multiplierValue = valueLabel("×1.00")

        pollHzPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        pollHzPopUp.target = self
        pollHzPopUp.action = #selector(pollHzChanged(_:))
        pollHzPopUp.addItem(withTitle: "自动（按 HID 事件）")
        pollHzPopUp.lastItem?.representedObject = 0.0
        for hz in Self.pollHzOptions {
            pollHzPopUp.addItem(withTitle: "\(Int(hz)) Hz")
            pollHzPopUp.lastItem?.representedObject = hz
        }

        dpiPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        dpiPopUp.target = self
        dpiPopUp.action = #selector(dpiChanged(_:))
        for dpi in Self.dpiOptions {
            dpiPopUp.addItem(withTitle: "\(Int(dpi)) DPI")
            dpiPopUp.lastItem?.representedObject = dpi
        }
        dpiAnchorCheck = NSButton(checkboxWithTitle: "曲线锚定 400dpi 基准",
                                  target: self, action: #selector(dpiAnchorChanged(_:)))

        let form = formGrid([
            ("状态", hstack(statusLabel, authButton)),
            ("接管", enableCheck),
            ("", mouseOnlyCheck),
            ("曲线模式", modeSegments),
            ("灵敏度", sliderRow(multiplierSlider, multiplierValue)),
            ("回报率", pollHzPopUp),
            ("", hintLabel("自动 = 按 HID 事件逐报计算，与 Windows 一致；无线鼠标事件抖动大时可手动指定。")),
            ("鼠标 DPI", hstack(dpiPopUp, dpiAnchorCheck)),
            ("", hintLabel("DPI 用于换算手速显示。Windows 不识别 DPI，曲线默认只看计数；勾选锚定后拐点按 400dpi 手速固定。")),
        ])

        curveView = CurveGraphView()
        curveView.translatesAutoresizingMaskIntoConstraints = false
        curveView.heightAnchor.constraint(equalToConstant: 200).isActive = true
        refreshCurve()

        monitorLine1 = monitorLabel()
        monitorLine2 = monitorLabel()
        sourceLabel = monitorLabel()

        let sep = separator()
        let stack = NSStackView(views: [
            form,
            sep,
            section("实时曲线"),
            curveView,
            monitorLine1, monitorLine2, sourceLabel,
            hintLabel("校准：同一只鼠标、同样 DPI，两台电脑上移动相同手上距离，调“灵敏度”到光标行程一致；先中速，再验证慢速与快速甩动。读到原始计数时 macOS 的“跟踪速度”不再起作用。",
                      width: Self.width - Self.margin * 2),
        ])
        stack.setCustomSpacing(16, after: form)
        stack.setCustomSpacing(16, after: sep)
        stack.setCustomSpacing(4, after: monitorLine1)
        stack.setCustomSpacing(4, after: monitorLine2)
        stack.setCustomSpacing(12, after: sourceLabel)
        return wrap(stack, stretch: [sep, curveView])
    }

    /// 曲线图跟随当前模式 / DPI 锚定重绘（横轴为每报计数，与回报率无关）
    private func refreshCurve() {
        guard let curveView else { return }
        let s = Settings.shared
        curveView.gainAt = { c in
            let s = Settings.shared
            return TransferFunction(mode: s.mode, multiplier: 1, dpi: s.dpi,
                                    dpiCompensation: s.dpiCompensation, pollHz: s.pollHz)
                .gain(reportCounts: c)
        }
        if s.mode == .windowsCurve {
            let shift = s.dpiCompensation ? s.dpi / 400.0 : 1.0
            curveView.controlPoints = TransferFunction.controlPointCounts.map { $0 * shift }
        } else {
            curveView.controlPoints = []
        }
    }

    // MARK: 滚轮与按键页

    private func makeScrollPage() -> NSView {
        scrollSpeedSlider = NSSlider(value: 0, minValue: log2(0.25), maxValue: log2(8.0),
                                     target: self, action: #selector(scrollSpeedChanged(_:)))
        scrollSpeedValue = valueLabel("×1.00")
        scrollInvertCheck = NSButton(checkboxWithTitle: "反转滚轮方向（仅鼠标）",
                                     target: self, action: #selector(scrollInvertChanged(_:)))
        remapCheck = NSButton(checkboxWithTitle: "X1/X2 → 后退/前进（⌘[ / ⌘]）",
                              target: self, action: #selector(remapChanged(_:)))

        let form = formGrid([
            ("滚轮速度", sliderRow(scrollSpeedSlider, scrollSpeedValue)),
            ("", scrollInvertCheck),
            ("", hintLabel("只影响鼠标的离散滚轮；触控板连续滚动原样放行。")),
            ("侧键", remapCheck),
            ("", hintLabel("在 Safari / Chrome / Finder 等应用中作后退/前进。")),
        ])
        return wrap(NSStackView(views: [form]))
    }

    // MARK: 关于页

    private func makeAboutPage() -> NSView {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let title = NSTextField(labelWithString: "WinMouse" + (version.map { " v\($0)" } ?? ""))
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let subtitle = hintLabel("把 Windows 鼠标手感搬到 macOS：指针曲线 · 滚轮增强 · 侧键映射",
                                 width: Self.width - Self.margin * 2)
        subtitle.font = .systemFont(ofSize: 12)

        let steps = bodyLabel(
            "1. 授予辅助功能权限（下方按钮）\n" +
            "2. 系统设置 → 鼠标 → 高级 → 关闭“指针加速”\n" +
            "    读到原始计数时这一步可省，但取不到时需要它避免双重加速\n" +
            "3. 在“指针”页边看实时监测边校准灵敏度")
        let curve = bodyLabel(
            "加速曲线取自 Windows 注册表 SmoothMouseXCurve / YCurve（五点实测值），" +
            "按每次上报的原始计数查曲线、不看时间，与 Windows 行为一致。" +
            "在 Windows 上运行 scripts/read_curve.ps1 可重新导出。")
        let refs = hintLabel("参考：微软《Pointer Ballistics for Windows XP》；LinearMouse / Mac Mouse Fix / Mos",
                             width: Self.width - Self.margin * 2)

        let auth = NSButton(title: "打开辅助功能授权页", target: NSApp.delegate,
                            action: #selector(AppDelegate.openAuthPane(_:)))
        auth.bezelStyle = .rounded
        loginCheck = NSButton(checkboxWithTitle: "开机自启",
                              target: self, action: #selector(loginChanged(_:)))

        let stack = NSStackView(views: [
            title, subtitle,
            section("使用步骤"), steps,
            section("曲线数据"), curve,
            hstack(auth, loginCheck),
            refs,
        ])
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(18, after: subtitle)
        stack.setCustomSpacing(6, after: stack.views[2])
        stack.setCustomSpacing(16, after: steps)
        stack.setCustomSpacing(6, after: stack.views[4])
        stack.setCustomSpacing(18, after: curve)
        stack.setCustomSpacing(18, after: stack.views[6])
        return wrap(stack)
    }

    // MARK: - 控件工具

    /// 对数滑块值 → 倍率（保留两位小数）
    private static func fromSlider(_ v: Double) -> Double {
        (pow(2, v) * 100).rounded() / 100
    }

    private func section(_ title: String) -> NSTextField {
        let f = NSTextField(labelWithString: title)
        f.font = .systemFont(ofSize: 13, weight: .semibold)
        return f
    }

    private func hintLabel(_ text: String,
                           width: CGFloat = SettingsWindow.width - SettingsWindow.margin * 2
                               - SettingsWindow.labelColumn - 12) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = .systemFont(ofSize: 11)
        f.textColor = .secondaryLabelColor
        f.preferredMaxLayoutWidth = width
        f.isSelectable = false
        return f
    }

    private func bodyLabel(_ text: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = .systemFont(ofSize: 12)
        f.textColor = .labelColor
        f.preferredMaxLayoutWidth = Self.width - Self.margin * 2
        f.isSelectable = false
        return f
    }

    private func valueLabel(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        f.alignment = .right
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(equalToConstant: 48).isActive = true
        return f
    }

    private func monitorLabel() -> NSTextField {
        let f = NSTextField(labelWithString: " ")
        f.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        f.textColor = .secondaryLabelColor
        f.lineBreakMode = .byTruncatingTail
        return f
    }

    private func sliderRow(_ slider: NSSlider, _ value: NSTextField) -> NSView {
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 300).isActive = true
        return hstack(slider, value)
    }

    private func hstack(_ views: NSView...) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = 10
        return s
    }

    /// 左列右对齐标签 + 右列控件的表单；标签为空表示续行
    private func formGrid(_ rows: [(String, NSView)]) -> NSGridView {
        let grid = NSGridView(views: rows.map { title, control -> [NSView] in
            guard !title.isEmpty else { return [NSGridCell.emptyContentView, control] }
            let label = NSTextField(labelWithString: title + "：")
            label.textColor = .secondaryLabelColor
            return [label, control]
        })
        grid.columnSpacing = 12
        grid.rowSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = Self.labelColumn
        grid.rowAlignment = .none
        for i in 0..<grid.numberOfRows {
            grid.row(at: i).yPlacement = .center
        }
        return grid
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
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
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
        multiplierSlider.doubleValue = log2(s.multiplier)
        multiplierValue.stringValue = String(format: "×%.2f", s.multiplier)
        dpiAnchorCheck.state = s.dpiCompensation ? .on : .off
        let curveMode = s.mode == .windowsCurve
        dpiAnchorCheck.isEnabled = curveMode
        pollHzPopUp.isEnabled = curveMode
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
        scrollSpeedSlider.doubleValue = log2(s.scrollSpeed)
        scrollSpeedValue.stringValue = String(format: "×%.2f", s.scrollSpeed)
        scrollInvertCheck.state = s.scrollInvert ? .on : .off
        remapCheck.state = s.remapSideButtons ? .on : .off
        if #available(macOS 13.0, *) {
            loginCheck.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        }
        refreshCurve()
    }
}
