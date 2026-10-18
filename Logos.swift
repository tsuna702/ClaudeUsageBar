import Cocoa

// 앱이 설치돼 있지 않을 때 쓰는 로고: 서비스 색 둥근 사각형 위에 흰색 로고
// 로고 SVG는 Resources/Logos (출처는 그 폴더의 README 참고)

enum LogoTile {
    static func file(_ p: Provider) -> String? {
        switch p {
        case .claude: return "claude"
        case .codex, .openai: return "codex"
        case .gemini: return "gemini"
        case .antigravity: return "antigravity"
        case .cursor: return "cursor"
        case .grok: return "grok"
        case .cloudflare: return "cloudflare"
        }
    }

    static func colors(_ p: Provider) -> [NSColor] {
        func c(_ hex: Int) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        switch p {
        case .claude: return [c(0xD97757), c(0xC2613F)]
        case .codex, .openai, .cursor, .grok: return [c(0x2B2B2B), c(0x0D0D0D)]
        case .gemini: return [c(0x4796E3), c(0x9168C0)]
        case .antigravity: return [c(0x4C8DF6), c(0x3A63D8)]
        case .cloudflare: return [c(0xF6A33C), c(0xF38020)]
        }
    }

    static func glyph(_ p: Provider) -> NSImage? {
        guard let name = file(p) else { return nil }
        let url = Bundle.main.url(forResource: name, withExtension: "svg", subdirectory: "Logos")
            ?? URL(fileURLWithPath: "Resources/Logos/\(name).svg")   // 개발 중 실행할 때
        return NSImage(contentsOf: url)
    }

    static func make(_ p: Provider, px: Int = 128) -> NSImage? {
        guard let g = glyph(p),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        let s = CGFloat(px)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high

        // 배경 (macOS 앱 아이콘과 비슷한 여백과 모서리)
        let tile = NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88)
        let path = NSBezierPath(roundedRect: tile, xRadius: s * 0.2, yRadius: s * 0.2)
        let cs = colors(p)
        NSGradient(starting: cs[0], ending: cs[1])?.draw(in: path, angle: -90)

        // 로고를 흰색으로 칠해서 가운데에
        let inset = s * 0.24
        let box = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
        let white = NSImage(size: box.size, flipped: false) { r in
            g.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        white.draw(in: box)

        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: px / 2, height: px / 2))
        img.addRepresentation(rep)
        return img
    }
}
