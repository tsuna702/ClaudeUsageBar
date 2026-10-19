import Cocoa

// 메뉴 막대용 원형 게이지: 값(%)만큼 고리를 채우고, 설정에 따라 가운데에 숫자 (색은 경고 단계)
enum Ring {
    static func image(_ percent: Double, level: Int, size: CGFloat, number: Bool = Pref.on(Pref.ringNumber)) -> NSImage {
        let left: Double? = max(0, min(100, percent))
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            // 그릴 때의 화면 모드에 맞춰 기본색을 정함 (labelColor는 그리는 곳에 따라 흐리게 나올 수 있음)
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let base: NSColor = dark ? .white : .black
            let color: NSColor = [base, .systemOrange, .systemRed][level]
            // 숫자가 들어가면 안쪽 공간을 넓히려고 고리를 가늘게
            let line: CGFloat = number ? max(1.6, size * 0.11) : max(2, size * 0.16)
            let r = rect.insetBy(dx: line / 2 + 0.5, dy: line / 2 + 0.5)
            let track = NSBezierPath(ovalIn: r)
            track.lineWidth = line
            base.withAlphaComponent(0.22).setStroke()
            track.stroke()
            if let left, left > 0 {
                // 12시 방향에서 시계 방향으로
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: r.midX, y: r.midY), radius: r.width / 2,
                              startAngle: 90, endAngle: 90 - 360 * left / 100, clockwise: true)
                arc.lineWidth = line
                arc.lineCapStyle = .round
                color.setStroke()
                arc.stroke()
            }
            if number, let left {
                let text = "\(Int(left.rounded()))"
                // 세 자리(100)는 조금 작게
                let font = NSFont.monospacedDigitSystemFont(ofSize: size * (text.count >= 3 ? 0.34 : 0.42), weight: .bold)
                let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
                let ts = s.size()
                s.draw(at: NSPoint(x: rect.midX - ts.width / 2, y: rect.midY - ts.height / 2 + font.descender / 2 + 0.3))
            }
            return true
        }
        return img
    }
}
