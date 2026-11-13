import Foundation

/// 指针传递函数：把"鼠标瞬时速度 (counts/ms)"映射为"光标增益"。
///
/// Windows EPP（Win 8/8.1/10/11）实际运行的公式（Mark C. Cranness 逆向并实测验证，
/// 见 donewmouseaccel 博客 "Out of sync and upside down"）：
///
///     X = 每次上报的计数 mickeys_per_poll / 3.5
///     Y = SmoothMouse 曲线插值(X)
///     像素增益 = (Y / X) × 屏幕DPI / 420        （420 = 3.5 × 120）
///
/// 屏幕按 100% 缩放（96 DPI）、滑块 6/11（EPP 下 ×1.0）时：
/// 慢速 ×0.569、每报约 7.9 计数（X≈2.26）处 ×1.0、末点 ×2.54，再往外按末段斜率外推、趋近 ×2.69。
/// 曲线只看"每次上报的计数"、不看时间，因此换算成手速时与回报率有关
/// （1000Hz 鼠标每报 7.9 计数 = 7.9 counts/ms；回报率越高加速来得越晚——与真实 Windows 一致）。
///
/// 曲线数据取自 Windows 注册表 SmoothMouseXCurve / SmoothMouseYCurve（16.16 定点）。
/// 如 Windows 侧曲线有改动，可用 scripts/read_curve.ps1 重新导出并替换常量。
struct TransferFunction {

    enum Mode: String {
        /// Windows 默认手感：EPP 开启，带加速曲线
        case windowsCurve
        /// Windows 游戏手感：EPP 关闭，纯线性 1:1
        case linear
    }

    // 注册表实测值（16.16 定点 → Double）
    static let curveX: [Double] = [
        0,
        28181.0 / 65536.0,
        81920.0 / 65536.0,
        252969.0 / 65536.0,
        2621440.0 / 65536.0,
    ]
    static let curveY: [Double] = [
        0,
        70141.0 / 65536.0,
        271360.0 / 65536.0,
        1244160.0 / 65536.0,
        29081600.0 / 65536.0,
    ]

    /// 公式常数：屏幕按 100% 缩放（96 DPI）；分母 3.5 × 120
    private static let screenScale = 96.0 / 420.0
    /// 慢速段增益（曲线首段斜率 × screenScale ≈ ×0.569）
    private static let slowGain = (curveY[1] / curveX[1]) * screenScale
    /// 曲线 X = 每报计数 / 3.5
    static let countsPerCurveX = 3.5
    /// 控制点（去掉原点）换算成"每次上报计数"，供曲线图标注拐点
    static let controlPointCounts: [Double] = curveX.dropFirst().map { $0 * countsPerCurveX }

    var mode: Mode
    /// 绝对灵敏度，用户校准。吸收 Windows 缩放（如 125%）等绝对量纲差异
    var multiplier: Double
    /// 鼠标 DPI，仅在 dpiCompensation 开启时参与曲线折算
    var dpi: Double
    /// false（默认）= Windows 原生行为：曲线吃原始计数，高 DPI 鼠标更早进入加速段；
    /// true = 把每报计数折算回 400dpi 设计基准（拐点按手速固定）
    var dpiCompensation: Bool
    /// 鼠标回报率 Hz（125–8000）；0 表示按 HID 事件间隔自动估计
    var pollHz: Double = 1000

    /// 曲线输入：等效"每次上报计数"。
    /// 自动回报率时直接等于本事件的计数（时间项约掉，与 Windows 一样不看时间）；
    /// 手动回报率时按 速度 × 上报周期 折算。
    /// - Parameter speed: 瞬时鼠标速度，counts/ms（逐事件计算，与 Windows 一致不做平滑）
    func reportCounts(speed: Double, sampleIntervalMs: Double? = nil) -> Double {
        let rate = pollHz > 0
            ? min(max(pollHz, 125), 8000)
            : 1000.0 / max(sampleIntervalMs ?? 1, 0.125)
        return speed * (1000.0 / min(max(rate, 125), 8000))
    }

    /// - Parameter counts: 每次上报计数（见 reportCounts）
    /// - Returns: 施加在原始位移上的总增益（含灵敏度倍率）
    func gain(reportCounts counts: Double) -> Double {
        switch mode {
        case .linear:
            return multiplier
        case .windowsCurve:
            var x = counts / Self.countsPerCurveX
            if dpiCompensation {
                x *= 400.0 / max(dpi, 100.0)
            }
            guard x > 0.0005 else { return multiplier * Self.slowGain }
            return multiplier * (interpolate(x) / x) * Self.screenScale
        }
    }

    func gain(speed: Double, sampleIntervalMs: Double? = nil) -> Double {
        gain(reportCounts: reportCounts(speed: speed, sampleIntervalMs: sampleIntervalMs))
    }

    /// 五点折线插值；超出末点按末段斜率线性外推
    private func interpolate(_ v: Double) -> Double {
        let xs = Self.curveX, ys = Self.curveY
        if v >= xs[4] {
            let slope = (ys[4] - ys[3]) / (xs[4] - xs[3])
            return ys[4] + (v - xs[4]) * slope
        }
        for i in 1...4 where v <= xs[i] {
            let t = (v - xs[i - 1]) / (xs[i] - xs[i - 1])
            return ys[i - 1] + t * (ys[i] - ys[i - 1])
        }
        return ys[4]
    }
}
