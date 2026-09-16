// 生成 WinMouse 应用图标：build/icon_1024.png
// 设计（简约版）：纯色蓝底 + 白色鼠标剪影（胶囊机身 + 滚轮槽）
// 用法：swift scripts/make_icon.swift，再用 iconutil 打包 .icns（见 make_app.sh 注释）
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let S = 1024
let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let W = CGFloat(S), H = CGFloat(S)

// 背景：圆角矩形，极轻的垂直渐变（近似纯色，保留一点厚度感）
let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: W, height: H),
                    cornerWidth: 228, cornerHeight: 228, transform: nil)
ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
let grad = CGGradient(colorsSpace: nil, colors: [
    CGColor(red: 0.09, green: 0.38, blue: 0.82, alpha: 1),
    CGColor(red: 0.06, green: 0.30, blue: 0.70, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: W / 2, y: H), end: CGPoint(x: W / 2, y: 0), options: [])

// 鼠标剪影：白色胶囊 + 深蓝滚轮槽
let mw: CGFloat = 360, mh: CGFloat = 560
let mx = W / 2 - mw / 2, my = H / 2 - mh / 2
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.addPath(CGPath(roundedRect: CGRect(x: mx, y: my, width: mw, height: mh),
                   cornerWidth: mw / 2, cornerHeight: mw / 2, transform: nil))
ctx.fillPath()

let slotW: CGFloat = 60, slotH: CGFloat = 132
let slotY = my + mh - (mh * 0.18) - slotH // 顶部留 18% 边距
ctx.setFillColor(CGColor(red: 0.07, green: 0.33, blue: 0.75, alpha: 1))
ctx.addPath(CGPath(roundedRect: CGRect(x: W / 2 - slotW / 2, y: slotY, width: slotW, height: slotH),
                   cornerWidth: slotW / 2, cornerHeight: slotW / 2, transform: nil))
ctx.fillPath()
ctx.restoreGState()

let img = ctx.makeImage()!
let url = URL(fileURLWithPath: "build/icon_1024.png") as CFURL
let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("图标已生成：build/icon_1024.png")
