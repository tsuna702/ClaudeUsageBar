import Foundation

// 서비스 장애 상태: 공식 상태 페이지 확인 (Statuspage 형식 + Google Cloud 장애 목록)

struct ServiceStatus {
    let level: Int          // 0 정상, 1 일부 장애, 2 큰 장애
    let text: String
    let url: URL
}

enum StatusCheck {
    // Statuspage 형식 주소 (status.json)
    static func page(_ p: Provider) -> String? {
        switch p {
        case .claude: return "https://status.claude.com"
        case .codex, .openai: return "https://status.openai.com"
        case .cursor: return "https://status.cursor.com"
        case .cloudflare: return "https://www.cloudflarestatus.com"
        default: return nil
        }
    }

    static func check(_ p: Provider) -> ServiceStatus? {
        if p == .gemini || p == .antigravity { return google() }
        guard let base = page(p), let url = URL(string: base + "/api/v2/status.json") else { return nil }
        var r = URLRequest(url: url)
        r.timeoutInterval = 15
        let (code, data, _) = Net.request(r)
        guard code == 200, let st = Net.json(data)?["status"] as? [String: Any] else { return nil }
        let indicator = (st["indicator"] as? String) ?? "none"
        let level = ["none": 0, "minor": 1, "maintenance": 1, "major": 2, "critical": 2][indicator] ?? 1
        return ServiceStatus(level: level, text: (st["description"] as? String) ?? indicator, url: URL(string: base)!)
    }

    // Google Cloud 장애 목록에서 끝나지 않은 Gemini 관련 장애
    static func google() -> ServiceStatus? {
        var r = URLRequest(url: URL(string: "https://status.cloud.google.com/incidents.json")!)
        r.timeoutInterval = 15
        let (code, data, _) = Net.request(r)
        guard code == 200, let data, let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let page = URL(string: "https://status.cloud.google.com")!
        let active = list.filter { inc in
            guard inc["end"] == nil || inc["end"] is NSNull else { return false }
            let products = (inc["affected_products"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
            return products.contains { $0.localizedCaseInsensitiveContains("Gemini") || $0.localizedCaseInsensitiveContains("Vertex") }
        }
        guard let first = active.first else { return ServiceStatus(level: 0, text: "OK", url: page) }
        let sev = (first["severity"] as? String) ?? "medium"
        return ServiceStatus(level: sev == "high" ? 2 : 1, text: (first["external_desc"] as? String) ?? "Incident", url: page)
    }
}
