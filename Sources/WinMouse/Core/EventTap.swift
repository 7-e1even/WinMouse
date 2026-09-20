import CoreGraphics
import Foundation

/// 会话级事件 tap：接管鼠标事件，套用 Windows 传递函数后放行。
///
/// 模块（对应三个开源项目的核心功能）：
/// - 指针移动：Windows 曲线/线性增益 —— LinearMouse 核心
/// - 滚轮：速度倍率 + 方向反转（只处理滚轮离散滚动，触控板连续滚动不动）—— Mos 核心
/// - 侧键：X1/X2 重映射为 前进/后退（⌘[ / ⌘]）—— Mac Mouse Fix 核心
///
/// 线程模型（跟手的关键）：
/// tap 不挂在主线程，而是跑在专用事件线程（userInteractive QoS）上，
/// 设置窗口动画、菜单、权限轮询定时器都阻塞不了鼠标事件。
/// - start()/stop()/isRunning：仅主线程调用
/// - port/source、逐事件速度与亚像素余量：仅事件线程访问
/// - lastSpeed/lastEventUptime：事件线程写、主线程读（NSLock 保护）
///
/// 前提：系统设置 → 鼠标 → 高级 → 关闭"指针加速"。
/// 这样到达 tap 的增量才是线性的，这里的增益才是唯一生效的曲线。
final class EventTap {
    static let shared = EventTap()
    private init() {}

    // 仅事件线程访问（stop 的拆除块也在事件线程上执行）
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    // 仅主线程访问
    private var thread: Thread?
    private var eventRunLoop: RunLoop?
    private var threadDone: DispatchSemaphore?
    private(set) var isRunning = false

    // 指针移动：逐事件瞬时速度与亚像素余量（仅事件线程访问）
    private var lastTimestamp: UInt64 = 0
    private var speed: Double = 0
    private var remX: Double = 0
    private var remY: Double = 0

    // 最近一次移动事件的速度与时间（供设置窗口实时监测）
    private let monitorLock = NSLock()
    private var monitorSpeed: Double = 0
    private var monitorUptime: TimeInterval = 0

    // 滚轮：行/像素增量的缩放余量（仅事件线程访问）
    private var remLineV = 0.0
    private var remLineH = 0.0
    private var remPxV = 0.0
    private var remPxH = 0.0

    // 设置很少变化；避免高回报率下每个事件都读 UserDefaults。
    private var cachedSettings: Settings.Snapshot?
    private var cachedSettingsUptime: TimeInterval = 0

    /// 无辅助功能权限时返回 false
    @discardableResult
    func start() -> Bool {
        guard thread == nil else { return true }

        let ready = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        var tapCreated = false

        let t = Thread { [weak self] in
            guard let self else { return }
            let rl = RunLoop.current
            rl.add(Port(), forMode: .common) // 保活：无事件源时 RunLoop 也不退出
            tapCreated = self.installTap(on: rl)
            self.eventRunLoop = rl
            ready.signal()
            guard tapCreated else { return }
            CFRunLoopRun() // 直到 stop() 在本线程拆除 tap 并 CFRunLoopStop
            done.signal()
        }
        t.name = "winmouse.event-tap"
        t.qualityOfService = .userInteractive
        t.start()
        ready.wait()
        threadDone = done

        guard tapCreated else {
            threadDone = nil
            eventRunLoop = nil
            return false
        }
        thread = t
        isRunning = true
        return true
    }

    func stop() {
        guard thread != nil, let rl = eventRunLoop else { return }
        thread = nil
        eventRunLoop = nil
        isRunning = false

        // FIFO：先在事件线程上拆 tap 并复位状态，再停 RunLoop，
        // 保证拆除不会与正在执行的回调竞争
        let cfRL = rl.getCFRunLoop()
        CFRunLoopPerformBlock(cfRL, CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self else { return }
            if let source = self.source { CFRunLoopRemoveSource(cfRL, source, .commonModes) }
            if let port = self.port { CFMachPortInvalidate(port) }
            self.source = nil
            self.port = nil
            self.resetState()
        }
        CFRunLoopPerformBlock(cfRL, CFRunLoopMode.commonModes.rawValue) {
            CFRunLoopStop(cfRL)
        }
        CFRunLoopWakeUp(cfRL)
        threadDone?.wait()
        threadDone = nil
    }

    /// 在调用线程（事件线程）的 RunLoop 上创建并挂载 tap
    private func installTap(on rl: RunLoop) -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.rightMouseDragged.rawValue)
            | (1 << CGEventType.otherMouseDragged.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ in
                EventTap.handle(type: type, event: event)
            },
            userInfo: nil
        ) else { return false }

        port = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(rl.getCFRunLoop(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// 仅在事件线程调用（stop 的拆除块 / 暂停接管时）
    private func resetState() {
        lastTimestamp = 0
        speed = 0
        remX = 0
        remY = 0
        remLineV = 0
        remLineH = 0
        remPxV = 0
        remPxH = 0
        monitorLock.lock()
        monitorSpeed = 0
        monitorUptime = 0
        monitorLock.unlock()
    }

    // MARK: - 监测快照（主线程读）

    var lastSpeed: Double {
        monitorLock.lock()
        defer { monitorLock.unlock() }
        return monitorSpeed
    }

    var lastEventUptime: TimeInterval {
        monitorLock.lock()
        defer { monitorLock.unlock() }
        return monitorUptime
    }

    private func updateMonitor(speed: Double) {
        monitorLock.lock()
        monitorSpeed = speed
        monitorUptime = ProcessInfo.processInfo.systemUptime
        monitorLock.unlock()
    }

    private func settingsSnapshot() -> Settings.Snapshot {
        let now = ProcessInfo.processInfo.systemUptime
        if let cachedSettings, now - cachedSettingsUptime < 0.02 {
            return cachedSettings
        }
        let fresh = Settings.shared.snapshot
        cachedSettings = fresh
        cachedSettingsUptime = now
        return fresh
    }

    // MARK: - 事件处理（C 回调上下文，只能访问静态成员；运行在事件线程）

    private static func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let me = shared

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return handleMove(event, me)
        case .scrollWheel:
            handleScroll(event, me)
            return Unmanaged.passUnretained(event)
        case .otherMouseDown:
            return handleButton(event, down: true)
        case .otherMouseUp:
            return handleButton(event, down: false)
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // 系统超时禁用时自动恢复
            if let p = me.port { CGEvent.tapEnable(tap: p, enable: true) }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // MARK: 指针移动

    private static func handleMove(_ event: CGEvent, _ me: EventTap) -> Unmanaged<CGEvent>? {
        let settings = me.settingsSnapshot()
        guard settings.enabled else {
            me.resetState()
            return Unmanaged.passUnretained(event)
        }

        // 按设备来源过滤：只接管真实鼠标（IOHID 枚举到的鼠标设备 registryID
        // 与事件的 senderID 匹配）。触控板/绘图板/软件合成的移动原样放行，
        // 不套曲线，也不污染速度计算与亚像素状态。
        if settings.mouseOnly {
            guard let sender = event.hidSenderID, MouseDevices.shared.contains(sender) else {
                return Unmanaged.passUnretained(event)
            }
        }

        let dx = Double(event.getIntegerValueField(.mouseEventDeltaX))
        let dy = Double(event.getIntegerValueField(.mouseEventDeltaY))
        guard dx != 0 || dy != 0 else { return Unmanaged.passUnretained(event) }

        // 瞬时速度（counts/ms）：与 Windows 一致逐事件计算，不做平滑；
        // 0.1ms 下限只防止同批事件时间戳相同导致的除零
        let t = event.timestamp
        let magnitude = (dx * dx + dy * dy).squareRoot()
        let expectedDtMs = 1000.0 / min(max(settings.transferFunction.pollHz, 125), 8000)
        if me.lastTimestamp != 0, t > me.lastTimestamp {
            let dtMs = Double(t - me.lastTimestamp) / 1_000_000
            // 静止后的第一批移动不应把空档时间算进速度；Windows 按报告周期处理。
            let sampleDtMs = dtMs > max(20, expectedDtMs * 4) ? expectedDtMs : max(dtMs, 0.1)
            me.speed = magnitude / sampleDtMs
        } else {
            // tap 刚启动或状态刚重置时，也按一个报告周期估算首个事件。
            me.speed = magnitude / expectedDtMs
        }
        me.lastTimestamp = t

        let g = settings.transferFunction.gain(speed: me.speed)
        me.updateMonitor(speed: me.speed)

        // 亚像素余量累加（对应微软文档的 subpixilation）：慢速低增益下不丢步、不抖动
        let rawX = dx * g + me.remX
        let rawY = dy * g + me.remY
        let outX = rawX.rounded(.towardZero)
        let outY = rawY.rounded(.towardZero)
        me.remX = rawX - outX
        me.remY = rawY - outY

        let ix = min(max(Int64(outX), -10000), 10000)
        let iy = min(max(Int64(outY), -10000), 10000)
        event.setIntegerValueField(.mouseEventDeltaX, value: ix)
        event.setIntegerValueField(.mouseEventDeltaY, value: iy)

        return Unmanaged.passUnretained(event)
    }

    // MARK: 滚轮

    private static func handleScroll(_ event: CGEvent, _ me: EventTap) {
        let s = me.settingsSnapshot()
        guard s.enabled, s.scrollEnabled else { return }
        // 只处理滚轮的离散滚动；触控板/平滑滚动的连续事件原样放行
        if event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 { return }

        let m = s.scrollSpeed
        let sign: Double = s.scrollInvert ? -1 : 1
        guard abs(m - 1) > 0.001 || s.scrollInvert else { return }

        let lineV = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
        let lineH = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2))
        let pxV = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        let pxH = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))

        if lineV != 0 {
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1,
                                       value: scaled(lineV, m, sign, &me.remLineV))
        }
        if lineH != 0 {
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2,
                                       value: scaled(lineH, m, sign, &me.remLineH))
        }
        if pxV != 0 {
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1,
                                       value: scaled(pxV, m, sign, &me.remPxV))
        }
        if pxH != 0 {
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2,
                                       value: scaled(pxH, m, sign, &me.remPxH))
        }
    }

    /// 增量缩放 + 余量累加，返回可写入整数字段的新值
    private static func scaled(_ v: Double, _ m: Double, _ sign: Double, _ rem: inout Double) -> Int64 {
        rem += v * m * sign
        let out = rem.rounded(.towardZero)
        rem -= out
        return min(max(Int64(out), -10000), 10000)
    }

    // MARK: 侧键

    /// X1/X2（button number 3/4）→ ⌘[ / ⌘]（Safari/Chrome/Finder 的后退/前进）
    private static func handleButton(_ event: CGEvent, down: Bool) -> Unmanaged<CGEvent>? {
        let s = shared.settingsSnapshot()
        guard s.enabled, s.remapSideButtons else { return Unmanaged.passUnretained(event) }

        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        switch button {
        case 3:
            if down { postKey(virtualKey: 33) } // '['
            return nil // 吞掉原事件
        case 4:
            if down { postKey(virtualKey: 30) } // ']'
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private static func postKey(virtualKey: CGKeyCode) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let flags = CGEventFlags.maskCommand
        let down = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: src, virtualKey: virtualKey, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }
}
