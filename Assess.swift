import Foundation

// 한도 하나의 위험도: 모든 서비스·모든 화면(카드 배지, 예측 문구, 대시보드 머리 배지, 메뉴 막대 색)이 같은 판단을 씀
// - 쓴 양: 설정의 주황/빨강 기준(기본 70%/90%)
// - 속도: 지금 속도로 초기화 전에 바닥나는지
// 둘 중 더 나쁜 쪽을 따름

struct Assessment {
    let level: Int          // 0 여유, 1 주의, 2 위험, 3 소진
    let text: String?       // 예측 문구 (판단할 근거가 없으면 nil)
    let paceOK: Bool        // 지금 속도로 초기화까지 버티는지 (문구 색)
}

enum Assess {
    static func evaluate(used: Double, resetsAt: Date?, window: Double, recentRate: Double?, limitReached: Bool) -> Assessment {
        if used >= 100 || (limitReached && used >= 99.5) {
            return Assessment(level: 3, text: L("한도 소진 — 초기화 대기", "Limit reached — waiting for reset"), paceOK: false)
        }
        let byUsed = Theme.level(used)
        guard let reset = resetsAt, reset.timeIntervalSinceNow > 0, window > 0 else {
            return Assessment(level: byUsed, text: nil, paceOK: true)
        }
        let left = reset.timeIntervalSinceNow
        let elapsed = max(0, window - left)

        // 평균 속도: 창이 시작된 뒤 쓴 양 ÷ 지난 시간. 막 시작했을 때는 값이 크게 튀므로
        // 창 길이의 5%(세션 15분, 주간 8시간) 이상 지나야 씀
        let average: Double? = used > 0 && elapsed >= max(900, window * 0.05) ? used / elapsed : nil
        // 최근 45분 속도: 짧은 창(세션)에서만. 주간은 밤·쉬는 날이 섞여 있어 잠깐의 몰아쓰기를 일주일로 늘리면 과장됨
        let recent: Double? = window < 86400 ? recentRate : nil
        let rate = max(recent ?? 0, average ?? 0)

        guard rate > 0 else {
            let text = recent == 0 ? L("최근 사용 없음", "No recent use") : nil
            return Assessment(level: byUsed, text: text, paceOK: true)
        }
        let toEmpty = (100 - used) / rate
        if toEmpty >= left {
            let text = recent == 0 ? L("최근 사용 없음 · 초기화까지 유지", "No recent use · lasts until reset")
                                   : L("이 속도면 초기화까지 유지", "At this pace, lasts until reset")
            return Assessment(level: byUsed, text: text, paceOK: true)
        }
        // 초기화 전에 바닥남: 남은 시간의 절반도 못 버티면 위험, 아니면 주의
        let byPace = toEmpty < left * 0.5 ? 2 : 1
        let usual = (recent ?? 0) < (average ?? 0)
        let text = usual ? L("평소 속도면 \(Fmt.span(toEmpty)) 후 소진", "At your usual pace, empty in \(Fmt.span(toEmpty))")
                         : L("이 속도면 \(Fmt.span(toEmpty)) 후 소진", "At this pace, empty in \(Fmt.span(toEmpty))")
        return Assessment(level: max(byUsed, byPace), text: text, paceOK: false)
    }

    // 서비스의 세션·주간 한도 (기록이 있으면 최근 속도도 반영)
    static func bucket(_ p: Provider, _ kind: LimitKind, _ q: Quota) -> Assessment? {
        guard let b = kind == .session ? q.session : q.weekly else { return nil }
        return evaluate(used: b.percent, resetsAt: b.resetsAt,
                        window: b.window ?? (kind == .session ? 5 * 3600 : 7 * 86400),
                        recentRate: History.recentRate(p, kind, current: b), limitReached: q.limitReached)
    }

    // 서비스 전체에서 가장 나쁜 단계 (한도 %가 없고 '한도 도달'만 알려주는 서비스 포함)
    static func worst(_ p: Provider, _ q: Quota) -> Int {
        let levels = [bucket(p, .session, q), bucket(p, .weekly, q)].compactMap { $0?.level }
        if levels.isEmpty, q.limitReached { return 3 }
        return levels.max() ?? 0
    }
}
