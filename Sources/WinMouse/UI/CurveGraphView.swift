import AppKit

/// Windows 五点曲线的归一化增益图：横轴鼠标速度（counts/ms，对数刻度），
/// 纵轴归一化增益（慢速 = 1×）。蓝点为曲线控制点，红点为当前实时速度。
final class CurveGraphView: NSView {

    /// 当前速度（counts/ms），0 表示静止（不画红点）
    var currentSpeed: Double = 0 { didSet { needsDisplay = true } }
    /// 归一化增益函数（读取当前 DPI/锚定设置；不含灵敏度倍率）
    var gainAt: (Double) -> Double = { _ in 1 } { didSet { needsDisplay = true } }

    private let minV = 0.01
    private let maxV = 100.0
    private let maxG = 5.0

    override func draw(_ dirty: NSRect) {
        super.draw(dirty)
        let plot = NSRect(x: bounds.minX + 36, y: bounds.minY + 22,
                          width: bounds.width - 36 - 10, height: bounds.height - 22 - 14)

        // 网格
        NSColor.separatorColor.setStroke()
        let grid = NSBezierPath()
        grid.lineWidth = 0.5
        for v in [0.01, 0.1, 1.0, 10.0, 100.0] {
            let x = xPos(v, in: plot)
            grid.move(to: NSPoint(x: x, y: plot.minY))
            grid.line(to: NSPoint(x: x, y: plot.maxY))
        }
        for g in 1...Int(maxG) {
            let y = yPos(Double(g), in: plot)
            grid.move(to: NSPoint(x: plot.minX, y: y))
            grid.line(to: NSPoint(x: plot.maxX, y: y))
        }
        grid.stroke()

        // 坐标标签
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        for v in [0.01, 0.1, 1.0, 10.0, 100.0] {
            let str = NSAttributedString(string: String(format: "%g", v), attributes: attrs)
            let x = xPos(v, in: plot)
            str.draw(at: NSPoint(x: x - str.size().width / 2, y: plot.minY - 14))
        }
        for g in 1...Int(maxG) {
            NSAttributedString(string: "\(g)×", attributes: attrs)
                .draw(at: NSPoint(x: plot.minX - 22, y: yPos(Double(g), in: plot) - 5))
        }
        NSAttributedString(string: "速度 counts/ms（对数轴）", attributes: attrs)
            .draw(at: NSPoint(x: plot.minX, y: plot.maxY + 3))

        // 增益曲线
        let path = NSBezierPath()
        let steps = 240
        for i in 0...steps {
            let v = minV * pow(maxV / minV, Double(i) / Double(steps))
            let p = NSPoint(x: xPos(v, in: plot), y: yPos(gainAt(v), in: plot))
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 1.5
        path.stroke()

        // 曲线控制点（锚定开启时随 DPI 平移）
        let s = Settings.shared
        NSColor.controlAccentColor.setFill()
        for x in TransferFunction.curveX.dropFirst() {
            let v = s.dpiCompensation ? x * s.dpi / 400.0 : x
            let p = NSPoint(x: xPos(v, in: plot), y: yPos(gainAt(v), in: plot))
            NSBezierPath(ovalIn: NSRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)).fill()
        }

        // 当前速度红点
        if currentSpeed > minV {
            let p = NSPoint(x: xPos(currentSpeed, in: plot),
                            y: yPos(gainAt(currentSpeed), in: plot))
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)).fill()
        }
    }

    private func xPos(_ v: Double, in r: NSRect) -> CGFloat {
        let t = (log10(max(v, minV)) - log10(minV)) / (log10(maxV) - log10(minV))
        return r.minX + CGFloat(min(t, 1.0)) * r.width
    }

    private func yPos(_ g: Double, in r: NSRect) -> CGFloat {
        r.minY + CGFloat(min(g, maxG) / maxG) * r.height
    }
}
