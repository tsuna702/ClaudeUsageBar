import Foundation

// 한도 사용 기록: 새로고침할 때마다 세션·주간 %를 저장 (최근 8일)
// ~/Library/Application Support/UsageBar/history.json

struct Sample: Codable {
    let t: Double          // 기록 시각 (epoch)
    let p: String          // provider
    let s: Double?         // 세션 사용 %
    let sr: Double?        // 세션 초기화 시각
    let w: Double?         // 주간 사용 %
    let wr: Double?        // 주간 초기화 시각
}

enum LimitKind { case session, weekly }

enum History {
    static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UsageBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    static var samples: [Sample] = {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Sample].self, from: data)) ?? []
    }()

    static func record(_ p: Provider, _ q: Quota) {
        let now = Date().timeIntervalSince1970
        // 같은 서비스는 50초 안에 다시 기록하지 않음
        if let last = samples.last(where: { $0.p == p.rawValue }), now - last.t < 50 { return }
        samples.append(Sample(t: now, p: p.rawValue,
                              s: q.session?.percent, sr: q.session?.resetsAt?.timeIntervalSince1970,
                              w: q.weekly?.percent, wr: q.weekly?.resetsAt?.timeIntervalSince1970))
        samples.removeAll { now - $0.t > 8 * 86400 }
        if let data = try? JSONEncoder().encode(samples) { try? data.write(to: url, options: .atomic) }
    }

    // 현재 창(초기화 시각이 같은 기록)의 (시각, %) 목록
    static func series(_ p: Provider, _ kind: LimitKind, current: Bucket?) -> [(date: Date, percent: Double)] {
        guard let reset = current?.resetsAt?.timeIntervalSince1970 else { return [] }
        return samples.compactMap { s in
            guard s.p == p.rawValue else { return nil }
            let (v, r) = kind == .session ? (s.s, s.sr) : (s.w, s.wr)
            guard let v, let r, abs(r - reset) < 120 else { return nil }
            return (Date(timeIntervalSince1970: s.t), v)
        }
    }

    // 최근 45분 동안의 사용 속도 (%/초). 기록이 10분 미만이면 nil
    static func recentRate(_ p: Provider, _ kind: LimitKind, current: Bucket?) -> Double? {
        let now = Date()
        let pts = series(p, kind, current: current).filter { now.timeIntervalSince($0.date) <= 45 * 60 }
        guard let first = pts.first, let last = pts.last else { return nil }
        let dt = last.date.timeIntervalSince(first.date)
        guard dt >= 10 * 60 else { return nil }
        return max(0, last.percent - first.percent) / dt
    }
}
