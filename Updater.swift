import Foundation

// 업데이트 확인: GitHub Releases의 최신 버전과 현재 버전을 비교 (설치는 사용자가 직접)

struct UpdateInfo {
    let version: String
    let url: URL
}

enum Updater {
    static let repo = "tsuna702/ClaudeUsageBar"

    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    // "v1.2.3" → [1, 2, 3]
    static func parts(_ v: String) -> [Int] {
        v.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // 결과: 새 버전 정보(없으면 nil), 오류 문구
    static func check(_ done: @escaping (UpdateInfo?, String?) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { done(nil, nil); return }   // 아직 릴리스 없음
            guard err == nil, code == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
                done(nil, err?.localizedDescription ?? "HTTP \(code)")
                return
            }
            done(isNewer(tag, than: current) ? UpdateInfo(version: tag, url: page) : nil, nil)
        }.resume()
    }
}
