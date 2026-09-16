import CoreGraphics
import Foundation

/// 会话级事件 tap：接管鼠标事件，套用 Windows 传递函数后放行。
///
/// 模块（对应三个开源项目的核心功能）：
/// - 指针移动：Windows 曲线/线性增益 —— LinearMouse 核心
/// - 滚轮：速度倍率 + 方向反转（只处理滚轮离散滚动，触控板连续滚动不动）—— Mos 核心
/// - 侧键：X1/X2 重映射为 前进/后退（⌘[ / ⌘]）—— Mac Mouse Fix 核心
///
/// 前提：系统设置 → 鼠标 → 高级 → 关闭"指针加速"。
/// 这样到达 tap 的增量才是线性的，这里的增益才是唯一生效的曲线。
final class EventTap {
    static let shared = EventTap()
    private init() {}

    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    // 指针移动：逐事件瞬时速度与亚像素余量（仅主线程访问）
    private var lastTimestamp: UInt64 = 0
    private var speed: Double = 0
    private var remX: Double = 0
    private var remY: Double = 0

    /// 最近一次移动事件的速度与时间（供设置窗口实时监测，仅主线程访问）
    private(set) var lastSpeed: Double = 0
    private(set) var lastEventUptime: TimeInterval = 0

    // 滚轮：行/像素增量的缩放余量
    private var remLineV = 0.0
    private var remLineH = 0.0
    private var remPxV = 0.0
    private var remPxH = 0.0

    var isRunning: Bool { port != nil }

    /// 无辅助功能权限时返回 false
    @discardableResult
    func start() -> Bool {
        guard port == nil else { return true }

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
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMachPortInvalidate(port) }
        source = nil
        port = nil
        resetState()
    }

    private func resetState() {
        lastTimestamp = 0
        speed = 0
        lastSpeed = 0
        lastEventUptime = 0
        remX = 0
        remY = 0
        remLineV = 0
        remLineH = 0
        remPxV = 0
        remPxH = 0
    }

    // MARK: - 事件处理（C 回调上下文，只能访问静态成员）

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
        let settings = Settings.shared
        guard settings.enabled else {
            me.resetState()
            return Unmanaged.passUnretained(event)
        }

        let dx = Double(event.getIntegerValueField(.mouseEventDeltaX))
        let dy = Double(event.getIntegerValueField(.mouseEventDeltaY))
        guard dx != 0 || dy != 0 else { return Unmanaged.passUnretained(event) }

        // 瞬时速度（counts/ms）：与 Windows 一致逐事件计算，不做平滑；
        // 0.1ms 下限只防止同批事件时间戳相同导致的除零
        let t = event.timestamp
        if me.lastTimestamp != 0, t > me.lastTimestamp {
            let dtMs = Double(t - me.lastTimestamp) / 1_000_000
            me.speed = (dx * dx + dy * dy).squareRoot() / max(dtMs, 0.1)
        }
        me.lastTimestamp = t

        let g = settings.transferFunction.gain(speed: me.speed)
        me.lastSpeed = me.speed
        me.lastEventUptime = ProcessInfo.processInfo.systemUptime

        // 亚像素余量累加（对应微软文档的 subpixilation）：慢速低增益下不丢步、不抖动
        let rawX = dx * g + me.remX
        let rawY = dy * g + me.remY
        let outX = rawX.rounded(.towardZero)
        let outY = rawY.rounded(.towardZero)
        me.remX = rawX - outX
        me.remY = rawY - outY

        let ix = min(max(Int(outX), -10000), 10000)
        let iy = min(max(Int(outY), -10000), 10000)
        event.setIntegerValueField(.mouseEventDeltaX, value: ix)
        event.setIntegerValueField(.mouseEventDeltaY, value: iy)
        event.setDoubleValueField(.mouseEventPixelDeltaX, value: Double(ix))
        event.setDoubleValueField(.mouseEventPixelDeltaY, value: Double(iy))

        return Unmanaged.passUnretained(event)
    }

    // MARK: 滚轮

    private static func handleScroll(_ event: CGEvent, _ me: EventTap) {
        let s = Settings.shared
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
    private static func scaled(_ v: Double, _ m: Double, _ sign: Double, _ rem: inout Double) -> Int {
        rem += v * m * sign
        let out = rem.rounded(.towardZero)
        rem -= out
        return min(max(Int(out), -10000), 10000)
    }

    // MARK: 侧键

    /// X1/X2（button number 3/4）→ ⌘[ / ⌘]（Safari/Chrome/Finder 的后退/前进）
    private static func handleButton(_ event: CGEvent, down: Bool) -> Unmanaged<CGEvent>? {
        let s = Settings.shared
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
