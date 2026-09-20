import Foundation

/// 全局设置，UserDefaults 持久化。
/// UserDefaults 本身线程安全：UI 在主线程读写，事件 tap 在专用事件线程读取，无需额外加锁。
final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard
    private init() {}

    struct Snapshot {
        let enabled: Bool
        let mouseOnly: Bool
        let transferFunction: TransferFunction
        let scrollEnabled: Bool
        let scrollSpeed: Double
        let scrollInvert: Bool
        let remapSideButtons: Bool
    }

    var snapshot: Snapshot {
        Snapshot(enabled: enabled, mouseOnly: mouseOnly, transferFunction: transferFunction,
                 scrollEnabled: scrollEnabled, scrollSpeed: scrollSpeed,
                 scrollInvert: scrollInvert, remapSideButtons: remapSideButtons)
    }

    /// UserDefaults 键名集中定义（改名会丢失已保存的设置，勿动）
    private enum Key {
        static let enabled = "winmouse.enabled"
        static let mouseOnly = "winmouse.mouseonly"
        static let mode = "winmouse.mode"
        static let multiplier = "winmouse.multiplier"
        static let dpi = "winmouse.dpi"
        static let dpiCompensation = "winmouse.dpi.compensation"
        static let pollHz = "winmouse.pollhz"
        static let scrollEnabled = "winmouse.scroll.enabled"
        static let scrollSpeed = "winmouse.scroll.speed"
        static let scrollInvert = "winmouse.scroll.invert"
        static let sideButtons = "winmouse.sidebuttons"
    }

    // MARK: 指针移动

    var enabled: Bool {
        get { d.object(forKey: Key.enabled) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.enabled) }
    }

    /// 仅接管真实鼠标（HID 来源事件），放行触控板/软件合成的移动
    var mouseOnly: Bool {
        get { d.object(forKey: Key.mouseOnly) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.mouseOnly) }
    }

    var mode: TransferFunction.Mode {
        get { TransferFunction.Mode(rawValue: d.string(forKey: Key.mode) ?? "") ?? .windowsCurve }
        set { d.set(newValue.rawValue, forKey: Key.mode) }
    }

    var multiplier: Double {
        get {
            let v = d.double(forKey: Key.multiplier)
            return v > 0 ? v : 1.0
        }
        set { d.set(min(max(newValue, 0.2), 8.0), forKey: Key.multiplier) }
    }

    var dpi: Double {
        get {
            let v = d.double(forKey: Key.dpi)
            return v >= 100 ? v : 800.0
        }
        set { d.set(newValue, forKey: Key.dpi) }
    }

    /// 曲线速度轴锚定 400dpi 基准（默认关闭 = Windows 原生行为：不识别鼠标 DPI）
    var dpiCompensation: Bool {
        get { d.bool(forKey: Key.dpiCompensation) }
        set { d.set(newValue, forKey: Key.dpiCompensation) }
    }

    /// 鼠标回报率 Hz；0 = 默认 1000。曲线 X 轴按每次上报计数折算，
    /// 回报率选错会让加速段整体偏移（2.4G 无线鼠标常为 125Hz）
    var pollHz: Double {
        get {
            let v = d.double(forKey: Key.pollHz)
            return v == 0 || (125...8000).contains(v) ? v : 0
        }
        set { d.set(newValue, forKey: Key.pollHz) }
    }

    /// 生效回报率
    var effectivePollHz: Double {
        pollHz > 0 ? pollHz : 1000
    }

    var transferFunction: TransferFunction {
        TransferFunction(mode: mode, multiplier: multiplier, dpi: dpi,
                         dpiCompensation: dpiCompensation, pollHz: effectivePollHz)
    }

    // MARK: 滚轮

    var scrollEnabled: Bool {
        get { d.object(forKey: Key.scrollEnabled) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.scrollEnabled) }
    }

    /// 滚轮速度倍率（0.25×–8×）
    var scrollSpeed: Double {
        get {
            let v = d.double(forKey: Key.scrollSpeed)
            return v > 0 ? v : 1.0
        }
        set { d.set(min(max(newValue, 0.25), 8.0), forKey: Key.scrollSpeed) }
    }

    /// 反转滚轮方向（只影响鼠标滚轮，触控板不受影响）
    var scrollInvert: Bool {
        get { d.bool(forKey: Key.scrollInvert) }
        set { d.set(newValue, forKey: Key.scrollInvert) }
    }

    // MARK: 侧键

    /// X1/X2 → 前进/后退
    var remapSideButtons: Bool {
        get { d.object(forKey: Key.sideButtons) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.sideButtons) }
    }
}
