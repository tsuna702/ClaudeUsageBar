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

    // 서비스별 기록 (시각 순서). 화면을 그릴 때마다 찾으므로 서비스별로 나눠 둠
    static var samples: [String: [Sample]] = {
        guard let data = try? Data(contentsOf: url),
              let all = try? JSONDecoder().decode([Sample].self, from: data) else { return [:] }
        return Dictionary(grouping: all, by: \.p)
    }()

    static func record(_ p: Provider, _ q: Quota) {
        let now = Date().timeIntervalSince1970
        // 같은 서비스는 50초 안에 다시 기록하지 않음
        if let last = samples[p.rawValue]?.last, now - last.t < 50 { return }
        samples[p.rawValue, default: []].append(Sample(t: now, p: p.rawValue,
                              s: q.session?.percent, sr: q.session?.resetsAt?.timeIntervalSince1970,
                              w: q.weekly?.percent, wr: q.weekly?.resetsAt?.timeIntervalSince1970))
        for k in Array(samples.keys) { samples[k]?.removeAll { now - $0.t > 8 * 86400 } }
        save()
    }

    // 여러 서비스가 한꺼번에 기록되면 한 번만 씀. 화면이 멈추지 않게 백그라운드에서
    static let writer = DispatchQueue(label: "history", qos: .utility)
    static var savePending = false

    static func save() {
        guard !savePending else { return }
        savePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { flush() }
    }

    // 미뤄 둔 기록을 씀. 앱을 끌 때는 다 쓸 때까지 기다림
    static func flush(wait: Bool = false) {
        if savePending {
            savePending = false
            let all = Array(samples.values.joined())
            writer.async { try? encode(all.sorted { $0.t < $1.t }).write(to: url, options: .atomic) }
        }
        if wait { writer.sync {} }
    }

    // JSONEncoder와 같은 형식을 직접 만듦 (기록이 수천 개라 JSONEncoder는 매번 수십 ms가 걸림)
    static func encode(_ list: [Sample]) -> Data {
        var out = "["
        out.reserveCapacity(list.count * 96)
        func num(_ key: String, _ v: Double?) {
            guard let v else { return }
            // 정수는 소수점 없이 (JSONEncoder와 같게)
            out += ",\"\(key)\":" + (!v.isFinite ? "null" : v == v.rounded(.towardZero) && abs(v) < 1e15 ? String(Int(v)) : "\(v)")
        }
        for (i, s) in list.enumerated() {
            out += i == 0 ? "{\"t\":\(s.t),\"p\":\"\(s.p)\"" : ",{\"t\":\(s.t),\"p\":\"\(s.p)\""
            num("s", s.s); num("sr", s.sr); num("w", s.w); num("wr", s.wr)
            out += "}"
        }
        out += "]"
        return Data(out.utf8)
    }

    // 현재 창(초기화 시각이 같은 기록)의 (시각, %) 목록
    static func series(_ p: Provider, _ kind: LimitKind, current: Bucket?) -> [(date: Date, percent: Double)] {
        guard let reset = current?.resetsAt?.timeIntervalSince1970 else { return [] }
        return (samples[p.rawValue] ?? []).compactMap { s in
            let (v, r) = kind == .session ? (s.s, s.sr) : (s.w, s.wr)
            guard let v, let r, abs(r - reset) < 120 else { return nil }
            return (Date(timeIntervalSince1970: s.t), v)
        }
    }

    // 최근 45분 동안의 사용 속도 (%/초). 기록이 10분 미만이면 nil
    // (메뉴 막대·카드마다 불리므로 최근 기록부터 45분 전까지만 봄)
    static func recentRate(_ p: Provider, _ kind: LimitKind, current: Bucket?) -> Double? {
        guard let reset = current?.resetsAt?.timeIntervalSince1970, let list = samples[p.rawValue] else { return nil }
        let now = Date().timeIntervalSince1970
        var first: (t: Double, v: Double)?, last: (t: Double, v: Double)?
        for s in list.reversed() {
            if now - s.t > 45 * 60 { break }
            let (v, r) = kind == .session ? (s.s, s.sr) : (s.w, s.wr)
            guard let v, let r, abs(r - reset) < 120 else { continue }
            if last == nil { last = (s.t, v) }
            first = (s.t, v)
        }
        guard let first, let last else { return nil }
        let dt = last.t - first.t
        guard dt >= 10 * 60 else { return nil }
        return max(0, last.v - first.v) / dt
    }
}
