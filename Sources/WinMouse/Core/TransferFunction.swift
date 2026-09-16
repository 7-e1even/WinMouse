import Foundation

/// 指针传递函数：把"鼠标瞬时速度 (counts/ms)"映射为"光标增益"。
///
/// 曲线数据取自 Windows 机器注册表
/// `HKCU\Control Panel\Mouse\SmoothMouseXCurve / SmoothMouseYCurve`（16.16 定点），
/// 即"增强指针精度"(EPP) 开启时 Windows 实际使用的加速曲线。
/// 如 Windows 侧曲线有改动，可用 scripts/read_curve.ps1 重新导出并替换常量。
struct TransferFunction {

    enum Mode: String {
        /// Windows 默认手感：EPP 开启，带加速曲线（慢速基准，急甩最高约 4.4×）
        case windowsCurve
        /// Windows 游戏手感：EPP 关闭，纯线性 1:1
        case linear
    }

    // 本机注册表实测值（16.16 定点 → Double）
    // X = 输入速度轴 counts/ms（按 400dpi 基准锚定）；Y = 曲线输出轴
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
    /// 曲线第一段斜率（慢速段增益 2.489），归一化基准
    static let baseGain = curveY[1] / curveX[1]

    var mode: Mode
    /// 绝对灵敏度，用户校准。吸收 DPI、屏幕缩放等全部绝对量纲，曲线形状不受它影响。
    var multiplier: Double
    /// 鼠标 DPI，仅在 dpiCompensation 开启时参与曲线折算。
    var dpi: Double
    /// false（默认）= Windows 原生行为：系统不识别鼠标 DPI，曲线直接吃原始 counts/ms，
    /// 高 DPI 鼠标会更早进入加速段；true = 把速度折算回 400dpi 设计基准（拐点按手速固定）。
    var dpiCompensation: Bool

    /// - Parameter speed: 瞬时鼠标速度，counts/ms（逐事件计算，与 Windows 一致不做平滑）
    /// - Returns: 施加在原始位移上的总增益
    func gain(speed: Double) -> Double {
        switch mode {
        case .linear:
            return multiplier
        case .windowsCurve:
            let v = dpiCompensation ? speed * 400.0 / max(dpi, 100.0) : speed
            return multiplier * normalizedCurveGain(v)
        }
    }

    /// 归一化曲线增益：慢速 = 1.0，快速甩动最高约 4.4×
    private func normalizedCurveGain(_ v: Double) -> Double {
        guard v > 0.0005 else { return 1.0 }
        return (interpolate(v) / v) / Self.baseGain
    }

    /// 五点折线插值；超出末点按末段斜率线性外推
    /// （对应微软《Pointer Ballistics for Windows XP》文档对曲线求值的描述）
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
