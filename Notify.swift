import Foundation
import UserNotifications

// 한도 알림: 사용량이 경고 기준(주황·빨강)을 넘을 때, 한도에 가까웠던 창이 초기화될 때

enum Notify {
    static let enabledKey = "notify_limits"
    static let resetKey = "notify_reset"

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func send(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // 창마다 "초기화 시각 | 마지막으로 알린 단계"를 저장해 같은 알림을 반복하지 않음
    static func check(_ p: Provider, _ q: Quota) {
        let d = UserDefaults.standard
        for (name, label, b) in [("세션", L("세션", "session"), q.session), ("주간", L("주간", "weekly"), q.weekly)] {
            guard let b else { continue }
            let key = "notified.\(p.rawValue).\(name)"
            let reset = Int(b.resetsAt?.timeIntervalSince1970 ?? 0)
            let level = Theme.level(b.percent) + (b.percent >= 100 ? 1 : 0)   // 0 보통, 1 주의, 2 위험, 3 소진
            let saved = (d.string(forKey: key) ?? "").split(separator: "|").compactMap { Int($0) }
            let prevReset = saved.count == 2 ? saved[0] : reset
            let prevLevel = saved.count == 2 ? saved[1] : 0

            // 같은 창이 이어지는 중: 단계가 올라갔을 때만 알림
            // (초기화 시각은 요청마다 몇 초씩 흔들릴 수 있어 1분 이내 차이는 같은 창으로 봄)
            let sameWindow = abs(reset - prevReset) < 60
            if sameWindow {
                if level > prevLevel, level > 0, d.bool(forKey: enabledKey) {
                    let left = max(0, 100 - b.percent)
                    let used = Int(b.percent.rounded())
                    let title = level == 3
                        ? L("\(p.name) \(label) 한도를 다 썼어요", "\(p.name) \(label) limit used up")
                        : L("\(p.name) \(label) 사용량 \(used)%", "\(p.name) \(label) usage at \(used)%")
                    send(title, L("남은 양 \(Int(left.rounded()))% · \(Fmt.until(b.resetsAt))", "\(Int(left.rounded()))% left · resets \(Fmt.until(b.resetsAt))"))
                }
                d.set("\(reset)|\(max(level, prevLevel))", forKey: key)
            } else {
                // 새 창으로 바뀜: 이전 창에서 주의 이상이었으면 초기화 알림
                if prevLevel > 0, d.bool(forKey: resetKey) {
                    let now = Int(max(0, 100 - b.percent).rounded())
                    send(L("\(p.name) \(label) 한도가 초기화됐어요", "\(p.name) \(label) limit has reset"),
                         L("지금 \(now)% 남아 있어요", "\(now)% available now"))
                }
                d.set("\(reset)|\(level)", forKey: key)
            }
        }
    }
}
