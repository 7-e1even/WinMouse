import AppKit

/// 增益曲线图：横轴"每次上报计数"（对数刻度，即 Windows 查曲线用的量，与回报率无关），
/// 纵轴曲线增益（不含灵敏度倍率）。圆点为五点曲线的拐点，红点为最近一次移动事件。
final class CurveGraphView: NSView {

    /// 最近一次移动：曲线输入（每报计数）与实际曲线增益；nil = 静止（不画红点）
    var current: (counts: Double, gain: Double)? {
        didSet {
            if current?.counts != oldValue?.counts || current?.gain != oldValue?.gain {
                needsDisplay = true
            }
        }
    }
    /// 曲线增益函数：每报计数 → 增益（读取当前模式/DPI 锚定；不含灵敏度倍率）
    var gainAt: (Double) -> Double = { _ in 1 } { didSet { needsDisplay = true } }
    /// 拐点位置（每报计数）；线性模式为空
    var controlPoints: [Double] = [] { didSet { needsDisplay = true } }

    private let minC = 0.5
    private let maxC = 300.0
    private let maxG = 3.0

    override func draw(_ dirty: NSRect) {
        super.draw(dirty)

        // 卡片底
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.controlBackgroundColor.setFill()
        card.fill()
        NSColor.separatorColor.setStroke()
        card.lineWidth = 1
        card.stroke()

        let plot = NSRect(x: bounds.minX + 40, y: bounds.minY + 34,
                          width: bounds.width - 40 - 16, height: bounds.height - 34 - 26)

        let small: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let title: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        // 网格与刻度
        let grid = NSBezierPath()
        grid.lineWidth = 0.5
        let xTicks: [Double] = [0.5, 1, 2, 5, 10, 20, 50, 100, 200]
        for c in xTicks {
            let x = xPos(c, in: plot)
            grid.move(to: NSPoint(x: x, y: plot.minY))
            grid.line(to: NSPoint(x: x, y: plot.maxY))
            let s = NSAttributedString(string: String(format: "%g", c), attributes: small)
            s.draw(at: NSPoint(x: x - s.size().width / 2, y: plot.minY - 14))
        }
        for g in stride(from: 0.5, through: maxG, by: 0.5) {
            let y = yPos(g, in: plot)
            grid.move(to: NSPoint(x: plot.minX, y: y))
            grid.line(to: NSPoint(x: plot.maxX, y: y))
            if g == g.rounded() {
                let s = NSAttributedString(string: String(format: "%.0f×", g), attributes: small)
                s.draw(at: NSPoint(x: plot.minX - s.size().width - 6, y: y - 6))
            }
        }
        NSColor.separatorColor.setStroke()
        grid.stroke()

        // 1× 参考线
        let unity = NSBezierPath()
        unity.move(to: NSPoint(x: plot.minX, y: yPos(1, in: plot)))
        unity.line(to: NSPoint(x: plot.maxX, y: yPos(1, in: plot)))
        unity.lineWidth = 1
        unity.setLineDash([3, 3], count: 2, phase: 0)
        NSColor.tertiaryLabelColor.setStroke()
        unity.stroke()

        NSAttributedString(string: "每次上报计数（对数轴）", attributes: title)
            .draw(at: NSPoint(x: plot.midX - 50, y: bounds.minY + 4))
        NSAttributedString(string: "曲线增益", attributes: title)
            .draw(at: NSPoint(x: plot.minX, y: plot.maxY + 7))

        // 增益曲线
        let path = NSBezierPath()
        let steps = 240
        for i in 0...steps {
            let c = minC * pow(maxC / minC, Double(i) / Double(steps))
            let p = NSPoint(x: xPos(c, in: plot), y: yPos(gainAt(c), in: plot))
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 2
        path.lineJoinStyle = .round
        path.stroke()

        // 拐点
        for c in controlPoints where c >= minC && c <= maxC {
            let p = NSPoint(x: xPos(c, in: plot), y: yPos(gainAt(c), in: plot))
            let dot = NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
            NSColor.controlBackgroundColor.setFill()
            dot.fill()
            NSColor.controlAccentColor.setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
        }

        // 最近一次移动
        if let cur = current, cur.counts > 0 {
            let p = NSPoint(x: xPos(cur.counts, in: plot), y: yPos(cur.gain, in: plot))
            NSColor.systemRed.withAlphaComponent(0.25).setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)).fill()
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)).fill()
        }
    }

    private func xPos(_ c: Double, in r: NSRect) -> CGFloat {
        let t = (log10(max(c, minC)) - log10(minC)) / (log10(maxC) - log10(minC))
        return r.minX + CGFloat(min(t, 1.0)) * r.width
    }

    private func yPos(_ g: Double, in r: NSRect) -> CGFloat {
        r.minY + CGFloat(min(max(g, 0), maxG) / maxG) * r.height
    }
}
