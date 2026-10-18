// 앱 아이콘(AppIcon.icns)을 그려서 만드는 스크립트
// 사용: swift tools/make_icon.swift <출력 폴더>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let size: CGFloat = 1024

func draw() -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    // 바탕: macOS 아이콘 비율의 둥근 사각형 + 코랄→보라 그라데이션
    let inset: CGFloat = 100
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let colors = [NSColor(red: 0.96, green: 0.52, blue: 0.40, alpha: 1).cgColor,
                  NSColor(red: 0.82, green: 0.33, blue: 0.56, alpha: 1).cgColor,
                  NSColor(red: 0.42, green: 0.33, blue: 0.84, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    ctx.restoreGState()

    // 게이지: 옅은 바탕 링 + 흰색 사용량 호(약 70%)
    let center = CGPoint(x: size / 2, y: size / 2 - 10)
    let radius: CGFloat = 250
    ctx.setLineCap(.round)
    ctx.setLineWidth(70)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
    ctx.addArc(center: center, radius: radius, startAngle: .pi * 1.25, endAngle: -.pi * 0.25, clockwise: true)
    ctx.strokePath()
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.addArc(center: center, radius: radius, startAngle: .pi * 1.25, endAngle: .pi * 0.05, clockwise: true)
    ctx.strokePath()

    // 가운데 별(✳︎ 모양): 선 네 개
    ctx.setLineWidth(46)
    let arm: CGFloat = 105
    for i in 0..<4 {
        let a = CGFloat(i) * .pi / 4
        ctx.move(to: CGPoint(x: center.x - cos(a) * arm, y: center.y - sin(a) * arm))
        ctx.addLine(to: CGPoint(x: center.x + cos(a) * arm, y: center.y + sin(a) * arm))
    }
    ctx.strokePath()

    img.unlockFocus()
    return img
}

let img = draw()
let iconset = out + "/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: iconset + "/" + name))
    }
}
print("wrote \(iconset)")
