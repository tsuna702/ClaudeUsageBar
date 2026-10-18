import Cocoa

// 메뉴 막대용 원형 게이지: 남은 양을 고리로 그림 (색은 경고 단계)
enum Ring {
    static func image(_ q: Quota, size: CGFloat) -> NSImage {
        let b = q.session ?? q.weekly
        let left = b.map { max(0, min(100, 100 - $0.percent)) / 100 }
        let level = Format.level(q)
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // 그릴 때의 화면 모드에 맞춰 기본색을 정함 (labelColor는 그리는 곳에 따라 흐리게 나올 수 있음)
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let base: NSColor = dark ? .white : .black
            let color: NSColor = [base, .systemOrange, .systemRed][level]
            let line: CGFloat = max(2, size * 0.16)
            let r = rect.insetBy(dx: line / 2 + 0.5, dy: line / 2 + 0.5)
            let track = NSBezierPath(ovalIn: r)
            track.lineWidth = line
            base.withAlphaComponent(0.22).setStroke()
            track.stroke()
            if let left, left > 0 {
                // 12시 방향에서 시계 방향으로
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: r.midX, y: r.midY), radius: r.width / 2,
                              startAngle: 90, endAngle: 90 - 360 * left, clockwise: true)
                arc.lineWidth = line
                arc.lineCapStyle = .round
                color.setStroke()
                arc.stroke()
            }
            return true
        }
        return img
    }
}
