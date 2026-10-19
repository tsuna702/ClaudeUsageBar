import Cocoa
import SwiftUI
import ServiceManagement

// Claude · Codex 사용량을 메뉴 막대에 표시하는 앱.
// Claude: Claude Code 로그인 토큰(키체인)으로 api.anthropic.com/api/oauth/usage 호출
// Codex:  ~/.codex/auth.json 토큰으로 chatgpt.com/backend-api/wham/usage 호출

// MARK: - 공통 모델

struct Bucket {
    let percent: Double
    let resetsAt: Date?
    var label: String? = nil     // 카드 제목 (없으면 세션/주간)
    var short: String? = nil     // 메뉴 막대 라벨 (없으면 5h/7d)
    var window: Double? = nil    // 창 길이(초), 소진 예상·추이 그래프에 사용
}

struct Quota {
    var session: Bucket?         // 짧은 창 (첫 번째 한도)
    var weekly: Bucket?          // 긴 창 (두 번째 한도)
    var extras: [(String, Bucket)] = []      // 주간 Opus 등 추가 한도
    var breakdown: [(String, Double)] = []   // 주간 사용 비중
    var plan: String?
    var email: String?
    var limitReached = false
    var extras2: [(label: String, value: String)] = []   // 추가 사용량 · 크레딧 등 정보 줄
    var headline: String?        // 한도 %가 없는 서비스의 메뉴 막대 문구 (예: 이번 달 비용)

    static let sample = Quota(session: Bucket(percent: 12, resetsAt: nil), weekly: Bucket(percent: 45, resetsAt: nil))
}

// 로그인 방식
enum LoginKind { case cli, app, apiKey }

enum Provider: String, CaseIterable {
    case claude, codex, gemini, antigravity, cursor, grok, openai, cloudflare

    var name: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .antigravity: return "Antigravity"
        case .cursor: return "Cursor"
        case .grok: return "Grok"
        case .openai: return "OpenAI API"
        case .cloudflare: return "Cloudflare AI"
        }
    }

    // 글자 아이콘 (로고가 없을 때)
    var icon: String {
        switch self {
        case .claude: return "✳︎"
        case .codex: return "◎"
        case .gemini: return "✦"
        case .antigravity: return "◬"
        case .cursor: return "➤"
        case .grok: return "𝕏"
        case .openai: return "⬡"
        case .cloudflare: return "☁︎"
        }
    }

    // 탭 등에 쓰는 SF Symbol
    var symbol: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .gemini: return "sparkles"
        case .antigravity: return "triangle"
        case .cursor: return "cursorarrow"
        case .grok: return "xmark"
        case .openai: return "hexagon"
        case .cloudflare: return "cloud"
        }
    }

    var color: Color {
        switch self {
        case .claude: return .orange
        case .codex: return .teal
        case .gemini: return .blue
        case .antigravity: return .indigo
        case .cursor: return .gray
        case .grok: return .primary
        case .openai: return .green
        case .cloudflare: return .orange
        }
    }

    var webURL: URL {
        let s: String
        switch self {
        case .claude: s = "https://claude.ai/settings/usage"
        case .codex: s = "https://chatgpt.com/codex/settings/usage"
        case .gemini: s = "https://aistudio.google.com/usage"
        case .antigravity: s = "https://antigravity.google"
        case .cursor: s = "https://cursor.com/dashboard?tab=usage"
        case .grok: s = "https://grok.com"
        case .openai: s = "https://platform.openai.com/usage"
        case .cloudflare: s = "https://dash.cloudflare.com/?to=/:account/ai/workers-ai"
        }
        return URL(string: s)!
    }

    var loginKind: LoginKind {
        switch self {
        case .antigravity, .cursor: return .app
        case .openai, .cloudflare: return .apiKey
        default: return .cli
        }
    }

    // 이 맥의 로컬 기록(토큰·비용·작업 시간)을 읽을 수 있는 서비스
    var hasLocalLogs: Bool { self == .claude || self == .codex }
    // 저장된 계정 전환을 지원하는 서비스
    var supportsSavedAccounts: Bool { self == .claude || self == .codex }

    var enabledKey: String { "show_\(rawValue)" }

    // 공식 앱 번들 ID 후보 (로고·설치 확인용)
    var bundleIDs: [String] {
        switch self {
        case .claude: return ["com.anthropic.claudefordesktop"]
        case .codex: return ["com.openai.codex", "com.openai.chat"]
        case .cursor: return ["com.todesktop.230313mzl4w4u92"]
        case .antigravity: return ["com.google.antigravity"]
        case .grok: return ["ai.x.grok"]
        default: return []
        }
    }

    var appURL: URL? {
        if let u = bundleIDs.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first { return u }
        // 번들 ID를 모를 때는 이름으로 찾음
        let names: [String] = self == .antigravity ? ["Antigravity"] : self == .cursor ? ["Cursor"] : []
        for n in names {
            for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
                let path = "\(dir)/\(n).app"
                if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }

    // 설치된 공식 앱의 아이콘을 로고로 사용 (없으면 nil → 글자 아이콘)
    static var logoCache: [Provider: NSImage?] = [:]
    var logo: NSImage? {
        if let c = Provider.logoCache[self] { return c }
        if ProcessInfo.processInfo.environment["USAGE_NOLOGO"] != nil { return nil }
        // 공식 앱 아이콘이 있으면 그것을, 없으면 함께 넣은 로고 타일
        let img = appURL.map { flatIcon(NSWorkspace.shared.icon(forFile: $0.path)) } ?? LogoTile.make(self)
        Provider.logoCache[self] = img
        return img
    }
    var showsLogo: Bool { Pref.on(Pref.showIcon) && Pref.on(Pref.useLogo) && logo != nil }
}

// 시스템 아이콘(여러 해상도가 섞인 이미지)을 일반 비트맵으로 바꿈
// (그대로 SwiftUI에 넣으면 화면 전체가 흐리게 그려지는 문제가 있음)
func flatIcon(_ src: NSImage, px: Int = 128) -> NSImage {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return src }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    src.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    let img = NSImage(size: NSSize(width: px / 2, height: px / 2))
    img.addRepresentation(rep)
    return img
}

// MARK: - Claude

struct ClaudeWindow: Decodable {
    let utilization: Double?
    let resets_at: String?
}

struct ClaudeUsage: Decodable {
    struct Row: Decodable { let display_name: String; let percent: Double }
    struct Breakdown: Decodable { let rows: [Row] }
    let five_hour: ClaudeWindow?
    let seven_day: ClaudeWindow?
    let seven_day_opus: ClaudeWindow?
    let seven_day_sonnet: ClaudeWindow?
    let seven_day_breakdown: Breakdown?
    struct Extra: Decodable {
        let is_enabled: Bool?
        let monthly_limit: Double?
        let used_credits: Double?
        let utilization: Double?
        let currency: String?
        let decimal_places: Int?
    }
    let extra_usage: Extra?
}

func parseISO(_ s: String?) -> Date? {
    guard let s else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
}

enum ClaudeAPI {
    static let service = "Claude Code-credentials"
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let refreshLock = NSLock()

    @discardableResult
    static func security(_ args: [String], stdin: String? = nil) -> (Int32, Data) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        if stdin != nil { p.standardInput = inp }
        do { try p.run() } catch { return (-1, Data()) }
        if let stdin {
            inp.fileHandleForWriting.write(stdin.data(using: .utf8)!)
            inp.fileHandleForWriting.closeFile()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }

    static func readCredentials() -> [String: Any]? {
        let (status, data) = security(["find-generic-password", "-s", service, "-w"])
        guard status == 0 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // 로그인 정보는 메모리에 두고 씀. 키체인은 처음, 토큰 만료가 가까울 때, 거절당했을 때만 읽음
    // (Claude Code가 토큰을 갱신하며 항목을 다시 만들면 '항상 허용'이 풀려 매번 암호를 물을 수 있음)
    static var cache: [String: Any]?
    static var cacheStamp = ""
    static let cacheLock = NSLock()

    // 항목 속성(수정 시각 포함)은 암호 없이 읽을 수 있음. 바뀌었으면(다른 계정으로 로그인 등) 다시 읽음
    static func stamp() -> String {
        let (code, data) = security(["find-generic-password", "-s", service])
        return code == 0 ? String(decoding: data, as: UTF8.self) : ""
    }

    static func credentials(fresh: Bool = false) -> [String: Any]? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        let st = stamp()
        guard !st.isEmpty else { cache = nil; return nil }   // 로그아웃됨
        if !fresh, let c = cache, st == cacheStamp { return c }
        cache = readCredentials()
        cacheStamp = st
        return cache
    }

    static func forget() {
        cacheLock.lock(); cache = nil; cacheLock.unlock()
    }

    static func expiresAt(_ json: [String: Any]?) -> Double {
        ((json?["claudeAiOauth"] as? [String: Any])?["expiresAt"] as? Double ?? 0) / 1000
    }

    // Claude Code가 쓰는 것과 같은 키체인 항목에 덮어씀 (비밀값은 argv 대신 stdin으로 전달)
    static func writeCredentials(_ json: [String: Any]) -> Bool {
        let (_, attrs) = security(["find-generic-password", "-s", service])
        let text = String(decoding: attrs, as: UTF8.self)
        let account = text.range(of: #""acct"<blob>="([^"]*)""#, options: .regularExpression)
            .map { String(text[$0]).replacingOccurrences(of: #""acct"<blob>=""#, with: "").dropLast() }
            .map(String.init) ?? NSUserName()
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return false }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let cmd = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \(hex)\n"
        let ok = security(["-i"], stdin: cmd).0 == 0
        if ok { cacheLock.lock(); cache = json; cacheStamp = stamp(); cacheLock.unlock() }
        return ok
    }

    // 만료(또는 5분 이내 만료 예정)면 refresh token으로 새 토큰을 받아 키체인에 저장
    static func refreshIfNeeded(force: Bool = false) -> String? {
        refreshLock.lock(); defer { refreshLock.unlock() }
        let soon = Date().timeIntervalSince1970 + 300
        var current = credentials()
        // 만료가 가깝거나 거절당했으면, Claude Code가 이미 새 토큰을 받아 뒀을 수 있으니 키체인을 다시 읽음
        if force || expiresAt(current) <= soon {
            let before = (current?["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String
            current = credentials(fresh: true)
            let after = (current?["claudeAiOauth"] as? [String: Any])?["accessToken"] as? String
            if let after, after != before, expiresAt(current) > soon { return after }
        }
        guard var json = current, var oauth = json["claudeAiOauth"] as? [String: Any] else { return nil }
        if !force, expiresAt(json) > soon { return oauth["accessToken"] as? String }
        guard let refreshToken = oauth["refreshToken"] as? String else { return oauth["accessToken"] as? String }

        var req = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": clientID]
        if let scopes = oauth["scopes"] as? [String] { body["scope"] = scopes.joined(separator: " ") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 20

        var result: [String: Any]?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if (resp as? HTTPURLResponse)?.statusCode == 200, let data {
                result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            sem.signal()
        }.resume()
        sem.wait()

        guard let r = result, let access = r["access_token"] as? String else { return nil }
        oauth["accessToken"] = access
        if let rt = r["refresh_token"] as? String { oauth["refreshToken"] = rt }
        if let exp = r["expires_in"] as? Double { oauth["expiresAt"] = (Date().timeIntervalSince1970 + exp) * 1000 }
        json["claudeAiOauth"] = oauth
        _ = writeCredentials(json)
        return access
    }

    // ~/.claude.json 의 로그인 계정 이메일
    static func accountEmail() -> String? {
        guard let data = FileManager.default.contents(atPath: NSHomeDirectory() + "/.claude.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let acct = json["oauthAccount"] as? [String: Any] else { return nil }
        return acct["emailAddress"] as? String
    }

    static func bucket(_ w: ClaudeWindow?) -> Bucket? {
        guard let u = w?.utilization else { return nil }
        return Bucket(percent: u, resetsAt: parseISO(w?.resets_at))
    }

    static func fetch(_ done: @escaping (Quota?, String?) -> Void) {
        fetch(retry: true, done)
    }

    static func fetch(retry: Bool, _ done: @escaping (Quota?, String?) -> Void) {
        guard credentials() != nil else { done(nil, L("Claude Code 로그인 정보를 찾을 수 없어요", "Claude Code login not found")); return }
        guard let token = refreshIfNeeded() else { done(nil, L("토큰 갱신 실패 — 터미널에서 claude를 한 번 실행해 주세요", "Token refresh failed — run claude in Terminal once")); return }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err { done(nil, err.localizedDescription); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            // 만료 시각 전인데 401이면 한 번만 강제 갱신 후 재시도
            if code == 401, retry {
                DispatchQueue.global().async {
                    _ = refreshIfNeeded(force: true)
                    fetch(retry: false, done)
                }
                return
            }
            guard code == 200, let data else {
                done(nil, code == 401 ? L("토큰 만료 — 터미널에서 claude를 한 번 실행해 주세요", "Token expired — run claude in Terminal once") : Net.httpError(code, nil))
                return
            }
            guard let u = try? JSONDecoder().decode(ClaudeUsage.self, from: data) else { done(nil, L("응답 해석 실패", "Could not read response")); return }
            var q = Quota(session: bucket(u.five_hour), weekly: bucket(u.seven_day))
            if let b = bucket(u.seven_day_opus) { q.extras.append((L("주간 Opus", "Weekly Opus"), b)) }
            if let b = bucket(u.seven_day_sonnet) { q.extras.append((L("주간 Sonnet", "Weekly Sonnet"), b)) }
            q.breakdown = (u.seven_day_breakdown?.rows ?? []).map { ($0.display_name, $0.percent) }
            let oauth = credentials()?["claudeAiOauth"] as? [String: Any]
            q.plan = oauth?["subscriptionType"] as? String
            q.email = accountEmail()
            if let x = u.extra_usage {
                if x.is_enabled == true {
                    // 금액은 최소 단위(센트 등)로 오므로 소수 자릿수만큼 나눔
                    let div = pow(10, Double(x.decimal_places ?? 2))
                    let cur = x.currency ?? "USD"
                    let used = (x.used_credits ?? 0) / div
                    let limit = x.monthly_limit.map { $0 / div }
                    var v = String(format: "%.2f %@", used, cur)
                    if let limit { v += String(format: " / %.2f", limit) }
                    if let ut = x.utilization { v += " (\(Int(ut.rounded()))%)" }
                    q.extras2.append((L("추가 사용량 (이번 달)", "Extra usage (this month)"), v))
                } else {
                    q.extras2.append((L("추가 사용량", "Extra usage"), L("꺼짐", "Off")))
                }
            }
            done(q, nil)
        }.resume()
    }
}

// MARK: - Codex

struct CodexWindow: Decodable {
    let used_percent: Double
    let limit_window_seconds: Int?
    let reset_at: Double?
}

struct CodexUsage: Decodable {
    struct RateLimit: Decodable {
        let limit_reached: Bool?
        let primary_window: CodexWindow?
        let secondary_window: CodexWindow?
    }
    let plan_type: String?
    let email: String?
    let rate_limit: RateLimit?
    struct Credits: Decodable { let has_credits: Bool?; let unlimited: Bool?; let balance: String? }
    struct ResetCredits: Decodable { let available_count: Int? }
    let credits: Credits?
    let rate_limit_reset_credits: ResetCredits?
}

enum CodexAPI {
    static func credentials() -> (token: String, account: String?)? {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? (NSHomeDirectory() + "/.codex")
        guard let data = FileManager.default.contents(atPath: home + "/auth.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String else { return nil }
        return (token, tokens["account_id"] as? String)
    }

    static func bucket(_ w: CodexWindow?) -> Bucket? {
        guard let w else { return nil }
        return Bucket(percent: w.used_percent, resetsAt: w.reset_at.map { Date(timeIntervalSince1970: $0) })
    }

    static func fetch(_ done: @escaping (Quota?, String?) -> Void) {
        guard let c = credentials() else { done(nil, L("Codex 로그인 정보를 찾을 수 없어요", "Codex login not found")); return }
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.setValue("Bearer \(c.token)", forHTTPHeaderField: "Authorization")
        if let a = c.account { req.setValue(a, forHTTPHeaderField: "ChatGPT-Account-Id") }
        req.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err { done(nil, err.localizedDescription); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200, let data else {
                done(nil, code == 401 ? L("토큰 만료 — Codex를 한 번 실행해 주세요", "Token expired — open Codex once") : Net.httpError(code, nil))
                return
            }
            guard let u = try? JSONDecoder().decode(CodexUsage.self, from: data) else { done(nil, L("응답 해석 실패", "Could not read response")); return }
            var q = Quota()
            // 창 길이로 세션(짧은 창)과 주간(긴 창)을 구분
            for w in [u.rate_limit?.primary_window, u.rate_limit?.secondary_window].compactMap({ $0 }) {
                if (w.limit_window_seconds ?? 0) >= 86400 { q.weekly = bucket(w) } else { q.session = bucket(w) }
            }
            q.plan = u.plan_type
            q.email = u.email
            if let c = u.credits {
                let v = c.unlimited == true ? L("무제한", "Unlimited") : (c.balance ?? "0")
                q.extras2.append((L("크레딧 잔액", "Credit balance"), v))
            }
            if let n = u.rate_limit_reset_credits?.available_count {
                q.extras2.append((L("한도 리셋 사용 가능", "Limit resets available"), L("\(n)회", "\(n)")))
            }
            q.limitReached = u.rate_limit?.limit_reached ?? false
            done(q, nil)
        }.resume()
    }
}

// MARK: - 설정 키

enum Pref {
    static let refreshMinutes = "refreshMinutes"
    static func intervalKey(_ p: Provider) -> String { "interval_\(p.rawValue)" }
    static let colorWarnings = "colorWarnings"
    static let orangeAt = "orangeAt"
    static let redAt = "redAt"

    // 메뉴 막대에 보일 요소 (각각 켜고 끔)
    static let showIcon = "bar_icon"
    static let useLogo = "bar_logo"
    static let useRing = "bar_ring"
    static let ringNumber = "bar_ring_number"
    static let showName = "bar_name"
    static let showSession = "bar_session"
    static let showSessionLeft = "bar_session_left"
    static let showLeftLabel = "bar_left_label"
    static let showWeekly = "bar_weekly"
    static let showLabels = "bar_labels"
    static let showReset = "bar_reset"
    static let useGauge = "bar_gauge"
    static let spacing = "bar_spacing"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            refreshMinutes: 5, colorWarnings: true, orangeAt: 70, redAt: 90,
            Provider.claude.enabledKey: true, Provider.codex.enabledKey: true,
            Provider.gemini.enabledKey: false, Provider.antigravity.enabledKey: false, Provider.cursor.enabledKey: false,
            Provider.grok.enabledKey: false, Provider.openai.enabledKey: false, Provider.cloudflare.enabledKey: false,
            Notify.enabledKey: true, Notify.resetKey: true,
            Hotkey.key: "optcmdU",
            Notify.quietKey: false, Notify.quietStartKey: 22, Notify.quietEndKey: 8,
            showIcon: true, useLogo: true, useRing: false, showName: false, showSession: true, showSessionLeft: false, showLeftLabel: true, showWeekly: true,
            showLabels: false, showReset: false, useGauge: false, spacing: 10.0, ringNumber: true,
        ])
    }

    static func on(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: key) }

    static func enabled(_ p: Provider) -> Bool { UserDefaults.standard.bool(forKey: p.enabledKey) }
}

// MARK: - 표시 형식

enum Format {
    static func pct(_ b: Bucket?) -> String {
        guard let b else { return "–" }
        return "\(Int(b.percent.rounded()))%"
    }

    static func shortReset(_ b: Bucket?) -> String {
        guard let date = b?.resetsAt else { return "3h20m" }
        let secs = max(0, Int(date.timeIntervalSinceNow))
        if secs < 3600 { return "\(secs / 60)m" }
        return "\(secs / 3600)h\((secs % 3600) / 60)m"
    }

    static func gauge(_ b: Bucket?) -> String {
        let filled = min(5, max(0, Int(((b?.percent ?? 0) / 20).rounded())))
        return String(repeating: "▰", count: filled) + String(repeating: "▱", count: 5 - filled)
    }

    static func remaining(_ b: Bucket?) -> Bucket? {
        b.map { Bucket(percent: max(0, 100 - $0.percent), resetsAt: $0.resetsAt) }
    }

    // 메뉴 막대 한 서비스의 조각: 글자 또는 링 (링은 그 값을 고리와 숫자로 그림)
    enum Part { case text(String), ring(Double) }

    // 켜진 요소만 모아 한 서비스의 조각을 만듦
    // ringDrawn: 링을 그림으로 그릴 수 있는 곳(메뉴 막대)인지. 아니면 링 값도 글자로
    static func parts(_ q: Quota, _ p: Provider, ringDrawn: Bool = true) -> [Part] {
        let labels = Pref.on(Pref.showLabels), ringOn = Pref.on(Pref.useRing)
        let ring = ringDrawn && ringOn
        let gaugeOn = !ringOn && Pref.on(Pref.useGauge)
        func text(_ b: Bucket?) -> String { gaugeOn ? gauge(b) : pct(b) }
        func value(_ b: Bucket?) -> Part {
            if ring, let b { return .ring(b.percent) }
            return .text(text(b))
        }

        var head: [Part] = []
        if Pref.on(Pref.showIcon), !p.showsLogo { head.append(.text(p.icon)) }
        if Pref.on(Pref.showName) { head.append(.text(p.name)) }

        // 한도 %가 없는 서비스(예: OpenAI API 월 비용)는 대표 문구를 보여줌
        if q.session == nil, q.weekly == nil {
            let parts = head + (q.headline.map { [.text($0)] } ?? [])
            return parts.isEmpty ? [.text(p.icon)] : parts
        }
        var values: [[Part]] = []
        let used = Pref.on(Pref.showSession), left = Pref.on(Pref.showSessionLeft)
        if (used || left), let sb = q.session {
            var g: [Part] = labels ? [.text(sb.short ?? "5h")] : []
            if ringOn {
                // 링은 사용량과 남은 사용량 중 하나만 (둘 다 켜져 있으면 남은 쪽)
                g.append(value(left ? remaining(sb) : sb))
            } else {
                var pieces: [String] = []
                if used { pieces.append(text(sb)) }
                let leftLabel = Pref.on(Pref.showLeftLabel)
                if left { pieces.append(leftLabel ? L("남음 \(text(remaining(sb)))", "\(text(remaining(sb))) left") : text(remaining(sb))) }
                // '남음' 글자가 없으면 사용/남은 값을 '/'로 구분
                g.append(.text(pieces.joined(separator: leftLabel ? " " : "/")))
            }
            if Pref.on(Pref.showReset) { g.append(.text("(\(shortReset(sb)))")) }
            values.append(g)
        }
        if Pref.on(Pref.showWeekly), let wb = q.weekly {
            values.append((labels ? [.text(wb.short ?? "7d")] : []) + [value(wb)])
        }
        // 켜 둔 항목이 이 서비스에 없으면 있는 값 하나라도 보여줌
        if values.isEmpty, used || left || Pref.on(Pref.showWeekly), let b = q.session ?? q.weekly {
            let shown = (ringOn && left && !used) ? remaining(b) : b
            values.append((labels ? [.text(b.short ?? "")] : []) + [value(shown)])
        }

        // 글자 사이는 " · ", 링끼리는 띄어쓰기만
        var body: [Part] = []
        for (i, g) in values.enumerated() {
            if i > 0, !ring { body.append(.text("·")) }
            body += g
        }
        let parts = head + body
        if parts.isEmpty { return p.showsLogo ? [] : [.text(p.icon)] }
        return parts
    }

    // 조각을 글자 한 줄로 (상태줄, 디버그 출력)
    static func title(_ q: Quota, _ p: Provider) -> String {
        parts(q, p, ringDrawn: false).compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined(separator: " ")
    }

    // 붙어 있는 글자 조각은 하나로 합침 (그릴 때 링과 글자만 번갈아 나오게)
    static func merged(_ parts: [Part]) -> [Part] {
        var out: [Part] = []
        for p in parts {
            if case .text(let t) = p, case .text(let prev)? = out.last {
                out[out.count - 1] = .text(prev + " " + t)
            } else {
                out.append(p)
            }
        }
        return out
    }

    static func resetText(_ b: Bucket) -> String {
        guard let date = b.resetsAt else { return "" }
        let secs = Int(date.timeIntervalSinceNow)
        let rel: String
        if secs <= 0 { rel = L("곧", "soon") }
        else if secs < 3600 { rel = L("\(secs / 60)분 후", "in \(secs / 60)m") }
        else if secs < 86400 { rel = L("\(secs / 3600)시간 \((secs % 3600) / 60)분 후", "in \(secs / 3600)h \((secs % 3600) / 60)m") }
        else { rel = L("\(secs / 86400)일 \((secs % 86400) / 3600)시간 후", "in \(secs / 86400)d \((secs % 86400) / 3600)h") }
        let df = DateFormatter()
        df.locale = Lang.locale
        df.dateFormat = "M/d (E) HH:mm"
        return L("초기화: \(df.string(from: date)) · \(rel)", "Resets \(df.string(from: date)) · \(rel)")
    }

    // 경고 색 단계: 0 보통, 1 주황, 2 빨강
    static func level(_ q: Quota) -> Int {
        let d = UserDefaults.standard
        guard d.bool(forKey: Pref.colorWarnings) else { return 0 }
        if q.limitReached { return 2 }
        let worst = max(q.session?.percent ?? 0, q.weekly?.percent ?? 0)
        if worst >= d.double(forKey: Pref.redAt) { return 2 }
        if worst >= d.double(forKey: Pref.orangeAt) { return 1 }
        return 0
    }

    // 메뉴 막대 전체 문구 (서비스별로 색을 따로 입힘)
    static func segments(_ quotas: [Provider: Quota], sampleIfMissing: Bool) -> [([Part], Int, Provider)] {
        Provider.allCases.filter(Pref.enabled).compactMap { p in
            guard let q = quotas[p] ?? (sampleIfMissing ? .sample : nil) else { return nil }
            return (merged(parts(q, p)), level(q), p)
        }
    }
}

// 설정창과 공유하는 현재 사용량
final class UsageStore: ObservableObject {
    @Published var quotas: [Provider: Quota] = [:]
    @Published var errors: [Provider: String] = [:]
    @Published var updated: [Provider: Date] = [:]
    @Published var local: [Provider: LocalStats] = [:]
    @Published var loading = false
    @Published var loggedIn: [Provider: Bool] = [:]
    @Published var update: UpdateInfo?
    @Published var statuses: [Provider: ServiceStatus] = [:]
    @Published var savedAccounts: [SavedAccount] = AccountStore.all
    @Published var updateStatus = ""
}

// 로그인 시 자동 실행 상태
final class LoginItem: ObservableObject {
    @Published var enabled = SMAppService.mainApp.status == .enabled
    @Published var error: String?

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = L("설정 실패: ", "Failed: ") + error.localizedDescription
        }
        enabled = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - 설정창 (SwiftUI)

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var login = LoginItem()
    @AppStorage(Pref.showIcon) var showIcon = true
    @AppStorage(Pref.useLogo) var useLogo = true
    @AppStorage(Pref.showName) var showName = false
    @AppStorage(Pref.showSession) var showSession = true
    @AppStorage(Pref.showSessionLeft) var showSessionLeft = false
    @AppStorage(Pref.showLeftLabel) var showLeftLabel = true
    @AppStorage(Pref.showWeekly) var showWeekly = true
    @AppStorage(Pref.showLabels) var showLabels = false
    @AppStorage(Pref.showReset) var showReset = false
    @AppStorage(Pref.useGauge) var useGauge = false
    @AppStorage(Pref.refreshMinutes) var refreshMinutes = 5
    @AppStorage(Notify.enabledKey) var notifyLimits = true
    @AppStorage(Lang.key) var lang = "system"
    @AppStorage(Hotkey.key) var hotkey = "optcmdU"
    @AppStorage(Notify.resetKey) var notifyReset = true
    @AppStorage(Notify.quietKey) var quietOn = false
    @AppStorage(Notify.quietStartKey) var quietStart = 22
    @AppStorage(Notify.quietEndKey) var quietEnd = 8
    @AppStorage(Pref.colorWarnings) var colorWarnings = true
    @AppStorage(Pref.orangeAt) var orangeAt = 70.0
    @AppStorage(Pref.redAt) var redAt = 90.0

    func color(_ level: Int) -> Color { [Color.primary, .orange, .red][level] }

    @ObservedObject var nav = SettingsNav.shared
    @ObservedObject var diag = DiagState()

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .id(lang)
        .frame(width: 720, height: 520)
    }

    // 왼쪽 목록
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPage.allCases, id: \.self) { page in
                let on = nav.page == page
                Button { nav.page = page } label: {
                    HStack(spacing: 9) {
                        Image(systemName: page.symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(page.color.gradient))
                        Text(page.title).font(.system(size: 13, weight: on ? .semibold : .regular))
                        Spacer()
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.accentColor.opacity(0.18) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 200)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }

    // 오른쪽: 고른 항목의 설정만
    @ViewBuilder var detail: some View {
        if nav.page == .menubar {
            MenubarCatalogView(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if nav.page == .diagnostics {
            DiagnosticsView(state: diag)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Form {
                switch nav.page {
                case .general: generalPage
                case .accounts: accountsPage
                case .alerts: alertsPage
                case .menubar, .diagnostics: EmptyView()
                }
            }
            .formStyle(.grouped)
            .toggleStyle(.switch)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    var previewSection: some View {
        Section(L("미리보기", "Preview")) {
            HStack {
                Spacer()
                BarPreview(store: store)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
                Spacer()
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder var generalPage: some View {
        Section(L("일반", "General")) {
            Picker(L("언어", "Language"), selection: $lang) {
                Text(L("시스템 설정 따르기", "Follow system")).tag("system")
                Text("한국어").tag("ko")
                Text("English").tag("en")
            }
            Picker(L("대시보드 단축키", "Dashboard shortcut"), selection: $hotkey) {
                ForEach(Hotkey.presets, id: \.id) { p in
                    Text(p.id == "off" ? L("사용 안 함", "Off") : p.label).tag(p.id)
                }
            }
            Picker(L("새로고침 간격", "Refresh every"), selection: $refreshMinutes) {
                Text(L("1분", "1 min")).tag(1)
                Text(L("2분", "2 min")).tag(2)
                Text(L("5분", "5 min")).tag(5)
                Text(L("10분", "10 min")).tag(10)
                Text(L("30분", "30 min")).tag(30)
            }
            Toggle(L("로그인 시 자동 실행", "Launch at login"), isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
            if let loginError = login.error {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
        }
        StatusLineSection()
        Section(L("업데이트", "Updates")) {
            LabeledContent(L("현재 버전", "Current version"), value: Updater.current)
            HStack {
                Text(store.updateStatus).font(.caption).foregroundStyle(store.update == nil ? Color.secondary : Color.accentColor)
                Spacer()
                if let u = store.update {
                    Button(L("다운로드 페이지 열기", "Open download page")) { NSWorkspace.shared.open(u.url) }
                }
                Button(L("지금 확인", "Check now")) { (NSApp.delegate as? AppDelegate)?.checkUpdate() }
            }
        }
        Section(L("데이터", "Data")) {
            LabeledContent(L("사용 기록 내보내기", "Export usage")) {
                Button(L("CSV로 내보내기…", "Export CSV…")) { Export.save(store) }
            }
            Text(L("최근 30일 일별 · 모델별 · 프로젝트별 집계와 한도 사용 기록(최근 8일)을 담아요.",
                   "Includes daily, per-model and per-project totals for the last 30 days, plus limit history (last 8 days)."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder var accountsPage: some View {
        Section(L("계정 연결", "Accounts")) {
            ForEach(Provider.allCases, id: \.self) { p in
                AccountSettingRow(provider: p, store: store)
            }
            Text(L("각 서비스의 공식 로그인 창이 터미널에서 열려요. 로그인이 끝나면 자동으로 사용량을 불러와요.", "Each service's official login opens in Terminal. Your usage loads automatically when you finish."))
                .font(.caption).foregroundStyle(.secondary)
        }
        Section(L("표시할 서비스", "Services")) {
            ForEach(Provider.allCases, id: \.self) { p in ServiceToggle(provider: p) }
        }
    }

    @ViewBuilder var alertsPage: some View {
        previewSection
        Section(L("경고 색상", "Warning colors")) {
            Toggle(L("사용량이 높으면 색으로 알려주기", "Color the menu bar when usage is high"), isOn: $colorWarnings)
            if colorWarnings {
                LabeledContent(L("주황색 기준", "Orange at")) {
                    Stepper("\(Int(orangeAt))%", value: $orangeAt, in: 10...100, step: 5)
                }
                LabeledContent(L("빨간색 기준", "Red at")) {
                    Stepper("\(Int(redAt))%", value: $redAt, in: 10...100, step: 5)
                }
            }
        }
        Section(L("알림", "Notifications")) {
            Toggle(L("사용량이 경고 기준을 넘으면 알리기", "Notify when usage crosses a warning level"), isOn: $notifyLimits)
            Toggle(L("한도에 가까웠던 창이 초기화되면 알리기", "Notify when a nearly used-up limit resets"), isOn: $notifyReset)
            Text(L("기준은 위 '경고 색상'의 주황색·빨간색 값을 따르고, 한도를 다 쓰면 한 번 더 알려요.", "Uses the orange and red levels from Warning colors, and notifies once more when a limit runs out."))
                .font(.caption).foregroundStyle(.secondary)
        }
        Section(L("방해 금지 시간", "Quiet Hours")) {
            Toggle(L("이 시간에는 알리지 않기", "Don't notify during these hours"), isOn: $quietOn)
            if quietOn {
                Picker(L("시작", "From"), selection: $quietStart) {
                    ForEach(0..<24, id: \.self) { h in Text(String(format: "%02d:00", h)).tag(h) }
                }
                Picker(L("끝", "To"), selection: $quietEnd) {
                    ForEach(0..<24, id: \.self) { h in Text(String(format: "%02d:00", h)).tag(h) }
                }
                Text(L("이 시간에 생긴 알림은 보내지 않고 넘어가요. 메뉴 막대 색은 그대로 바뀌어요.",
                       "Notifications during these hours are skipped. Menu bar colors still change."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// 설정창 왼쪽 목록 항목
enum SettingsPage: CaseIterable {
    case general, accounts, menubar, alerts, diagnostics

    var title: String {
        switch self {
        case .general: return L("일반", "General")
        case .accounts: return L("계정", "Accounts")
        case .menubar: return L("메뉴 막대", "Menu Bar")
        case .alerts: return L("경고와 알림", "Alerts")
        case .diagnostics: return L("진단", "Diagnostics")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .accounts: return "person.crop.circle.fill"
        case .menubar: return "menubar.rectangle"
        case .alerts: return "bell.badge.fill"
        case .diagnostics: return "stethoscope"
        }
    }

    var color: Color {
        switch self {
        case .general: return .gray
        case .accounts: return .blue
        case .menubar: return .purple
        case .alerts: return .red
        case .diagnostics: return .green
        }
    }
}

// 설정창에서 고른 항목 (@State 대신)
final class SettingsNav: ObservableObject {
    static let shared = SettingsNav()
    @Published var page: SettingsPage = .general
}

// MARK: - 앱

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let store = UsageStore()
    var timer: Timer?
    var lastUpdated: Date?
    var settingsWindow: NSWindow?
    let popover = NSPopover()
    let ui = DashState()
    var rightMenu = NSMenu()
    var inFlight = Set<Provider>()
    var scanning = false
    var lastFetch: [Provider: Date] = [:]
    var enabledSet = Set<Provider>()
    var lastRefreshStart = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        Pref.registerDefaults()
        // 개발용: 모든 서비스를 진단해서 보고서를 출력하고 종료
        if ProcessInfo.processInfo.environment["USAGE_DIAG"] != nil {
            DispatchQueue.global().async {
                var r: [Provider: [DiagStep]] = [:]
                for p in Provider.allCases { r[p] = Diagnostics.run(p) }
                print(Diagnostics.report(r)); fflush(stdout)
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
            return
        }
        Notify.requestPermission()
        Hotkey.action = { [weak self] in
            guard let self, let b = self.statusItem.button else { return }
            self.statusClicked(b)
        }
        Hotkey.apply()
        autoEnableDetected()
        statusItem.button?.title = "✳︎ …"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover.behavior = .transient
        popover.animates = true
        let host = NSHostingController(rootView: DashboardView(
            store: store, ui: ui,
            onRefresh: { [weak self] in self?.refresh() },
            onSettings: { [weak self] in self?.popover.performClose(nil); self?.openSettings() },
            onQuit: { NSApp.terminate(nil) }))
        // 크기는 직접 정함 (SwiftUI가 열린 뒤 크기를 바꾸면 팝오버 위치가 틀어짐)
        host.sizingOptions = []
        popover.contentViewController = host
        rebuildMenu()
        refresh()
        scheduleTimer()
        // 업데이트 확인: 실행할 때 + 하루에 한 번
        checkUpdate()
        Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in self?.checkUpdate() }
        // 개발용: 실행하자마자 대시보드를 열어 위치 확인
        if ProcessInfo.processInfo.environment["USAGE_OPEN"] != nil, let b = statusItem.button {
            // 값이 숫자면 그만큼(초) 기다렸다가 엶
            let delay = Double(ProcessInfo.processInfo.environment["USAGE_OPEN"] ?? "") ?? 1
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self.statusClicked(b)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let pw = self.popover.contentViewController?.view.window
                    print("button", b.window?.frame ?? .zero, "popover", pw?.frame ?? .zero,
                          "screen", b.window?.screen?.visibleFrame ?? .zero, "shown", self.popover.isShown)
                    fflush(stdout)
                }
            }
        }
        // 설정창에서 값이 바뀌면 바로 반영
        // 로그인/계정 전환이 끝나면 바로 새로고침
        NotificationCenter.default.addObserver(forName: .usageLoginChanged, object: nil, queue: .main) { [weak self] _ in
            ClaudeAPI.forget()
            self?.refresh()
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleRedraw()
            self?.settingsWindow?.title = L("사용량 설정", "UsageBar Settings")
            Hotkey.apply()
            // 새로 켠 서비스가 있으면 바로 불러옴
            if let self {
                let newly = Set(Provider.allCases.filter(Pref.enabled)).subtracting(self.enabledSet)
                if !newly.isEmpty { self.refresh(only: Array(newly)) }
            }
        }
    }

    // 여러 변경이 한꺼번에 와도 메뉴 막대와 메뉴는 한 번만 다시 그림
    var redrawPending = false
    func scheduleRedraw() {
        guard !redrawPending else { return }
        redrawPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.redrawPending = false
            self.updateTitle()
            self.rebuildMenu()
        }
    }

    // 1분마다 확인해서 서비스마다 정한 간격이 지났으면 새로고침
    func scheduleTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
    }

    // 새로 추가된 서비스 중 이미 로그인돼 있는 것은 처음 한 번만 자동으로 켬
    func autoEnableDetected() {
        DispatchQueue.global(qos: .utility).async {
            let d = UserDefaults.standard
            // Gemini는 계정 제한 위험이 있어 사용자가 직접 켜야 함
            for p in Provider.allCases where !p.hasLocalLogs && p != .gemini {
                let flag = "autoenabled_\(p.rawValue)"
                guard !d.bool(forKey: flag) else { continue }
                // Antigravity는 앱이 실행 중일 때만 (설치만으로는 켜지 않음)
                let found = p == .antigravity ? AntigravityAPI.discover() != nil : LoginHelper.isLoggedIn(p)
                if found {
                    d.set(true, forKey: flag)
                    DispatchQueue.main.async { d.set(true, forKey: p.enabledKey) }
                }
            }
        }
    }

    // 왼쪽 클릭: 대시보드, 오른쪽 클릭: 간단 메뉴
    @objc func statusClicked(_ sender: NSStatusBarButton) {
        // 아이콘을 누를 때마다 새로고침 (10초 안에 다시 누르면 건너뜀)
        // 마지막으로 불러온 지 1분이 지난 서비스만 (요청이 몰리지 않게)
        if Date().timeIntervalSince(lastRefreshStart) > 10, !popover.isShown {
            let now = Date()
            refresh(only: Provider.allCases.filter { now.timeIntervalSince(lastFetch[$0] ?? .distantPast) > 60 })
        }
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = rightMenu
            sender.performClick(nil)
            statusItem.menu = nil
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // 메뉴 막대 아래 남은 공간에 맞춰 높이를 먼저 정한 뒤 띄움
            let visible = sender.window?.screen?.visibleFrame.height ?? 900
            let h = min(760, visible - 70)
            ui.height = h
            popover.contentSize = NSSize(width: 400, height: h)
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // 서비스별 새로고침 간격(분). 0이면 전체 설정을 따름
    func interval(_ p: Provider) -> Double {
        let own = UserDefaults.standard.integer(forKey: Pref.intervalKey(p))
        return Double(own > 0 ? own : max(1, UserDefaults.standard.integer(forKey: Pref.refreshMinutes))) * 60
    }

    // 1분마다: 간격이 지난 서비스만 새로고침
    func tick() {
        let now = Date()
        let due = Provider.allCases.filter { Pref.enabled($0) && now.timeIntervalSince(lastFetch[$0] ?? .distantPast) >= interval($0) - 5 }
        if !due.isEmpty { refresh(only: due) }
    }

    func updateLoading() {
        let busy = !inFlight.isEmpty || scanning
        if store.loading && !busy, let dir = ProcessInfo.processInfo.environment["USAGE_SNAPSHOT"] {
            store.loading = false
            MainActor.assumeIsolated { snapshot(to: dir) }
        }
        store.loading = busy
    }

    @objc func refresh() { refresh(only: nil) }

    // 상태 페이지는 서비스마다 5분에 한 번만 확인
    var lastStatus: [Provider: Date] = [:]
    func checkStatuses(_ ps: [Provider]) {
        let now = Date()
        for p in ps where now.timeIntervalSince(lastStatus[p] ?? .distantPast) > 300 {
            lastStatus[p] = now
            DispatchQueue.global(qos: .utility).async {
                let st = StatusCheck.check(p)
                DispatchQueue.main.async { self.store.statuses[p] = st }
            }
        }
    }

    func refresh(only: [Provider]?) {
        lastRefreshStart = Date()
        enabledSet = Set(Provider.allCases.filter(Pref.enabled))
        let targets = (only ?? Provider.allCases).filter { Pref.enabled($0) && !inFlight.contains($0) }
        guard !targets.isEmpty else { return }
        for p in targets { inFlight.insert(p); lastFetch[p] = Date() }
        checkStatuses(targets)
        // 로컬 기록 집계 (토큰·비용·작업 시간): Claude·Codex를 새로고침할 때만
        if !scanning, targets.contains(where: \.hasLocalLogs) {
            scanning = true
            DispatchQueue.global(qos: .utility).async {
            let t0 = Date()
            let (c, x) = LocalScan.scanAll()
            if ProcessInfo.processInfo.environment["USAGE_DEBUG"] != nil {
                print("scan", String(format: "%.1fs", -t0.timeIntervalSinceNow))
            }
            DispatchQueue.main.async {
                self.store.local[.claude] = c
                self.store.local[.codex] = x
                if ProcessInfo.processInfo.environment["USAGE_DEBUG"] != nil {
                    for (p, s) in [(Provider.claude, c), (.codex, x)] {
                        let d = s.day(offset: 0), y = s.day(offset: 1)
                        print(p.name, "today tokens", Fmt.tokens(d.tokens), "cost", Fmt.money(d.cost), "saved", Fmt.money(d.saved),
                              "cache", Int(d.cacheRatio * 100), "% time", Fmt.duration(d.seconds),
                              "| yday tokens", Fmt.tokens(y.tokens), "cost", Fmt.money(y.cost),
                              "| 30d", Fmt.money(s.last30.map(\.stat.cost).reduce(0, +)), Fmt.tokens(s.last30.map(\.stat.tokens).reduce(0, +)))
                    }
                    fflush(stdout)
                }
                self.scanning = false
                self.updateLoading()
            }
            }
        }
        updateLoading()
        for p in targets {
            DispatchQueue.global().async {
                ProviderFetch.fetch(p) { q, err, stats in
                    let loggedIn = LoginHelper.isLoggedIn(p)
                    DispatchQueue.main.async {
                        if let stats { self.store.local[p] = stats }
                        if let q {
                            self.store.quotas[p] = q; self.store.updated[p] = Date(); self.lastUpdated = Date()
                            if Pref.enabled(p) { Notify.check(p, q) }
                            History.record(p, q)
                            // 로그인된 계정을 자동으로 저장해 두어 나중에 전환할 수 있게 함
                            if p.supportsSavedAccounts, let email = q.email {
                                DispatchQueue.global(qos: .utility).async {
                                    AccountStore.saveIfNeeded(p, email: email)
                                    DispatchQueue.main.async { self.store.savedAccounts = AccountStore.all }
                                }
                            }
                        }
                        self.store.loggedIn[p] = loggedIn
                        if !loggedIn {   // 로그아웃하면 이전 값을 지움
                            self.store.quotas[p] = nil
                            if p == .claude { ClaudeAPI.forget() }
                        }
                        self.store.errors[p] = err
                        // 429면 5분 동안 이 서비스는 다시 요청하지 않음
                        if err == Net.rateLimitMessage { self.lastFetch[p] = Date().addingTimeInterval(300 - self.interval(p)) }
                        if ProcessInfo.processInfo.environment["USAGE_DEBUG"] != nil {
                            print(p.name, q.map { "session \(Format.pct($0.session)) weekly \(Format.pct($0.weekly)) bar=[\(Format.title($0, p))]" } ?? "-", err ?? ""); fflush(stdout)
                        }
                        self.scheduleRedraw()
                        self.inFlight.remove(p)
                        self.updateLoading()
                    }
                }
            }
        }
    }

    @objc func checkUpdate() {
        store.updateStatus = L("확인 중…", "Checking…")
        Updater.check { info, err in
            DispatchQueue.main.async {
                self.store.update = info
                if let err { self.store.updateStatus = L("확인 실패: ", "Check failed: ") + err }
                else if let info { self.store.updateStatus = L("새 버전 \(info.version)이 있어요", "\(info.version) is available") }
                else { self.store.updateStatus = L("최신 버전이에요", "You're up to date") }
            }
        }
    }


    // 개발용: 대시보드 탭별 화면을 PNG로 저장
    @MainActor func snapshot(to dir: String) {
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            appearance.performAsCurrentDrawingAppearance {
                for t in DashTab.visible {
                    let state = DashState()
                    state.tab = t
                    let view = DashboardView(store: store, ui: state, onRefresh: {}, onSettings: {}, onQuit: {}, flat: true)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let r = ImageRenderer(content: view)
                    r.scale = 2
                    if let img = r.nsImage, let tiff = img.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: dir + "/dash-\(t.id)\(dark ? "-dark" : "").png"))
                    }
                }
            }
        }
        let cat = ImageRenderer(content: MenubarCatalogView(store: store, flat: true).frame(width: 520)
            .background(Color(nsColor: .windowBackgroundColor)))
        cat.scale = 2
        if let img = cat.nsImage, let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir + "/catalog.png"))
        }
        print("snapshot saved"); fflush(stdout)
    }

    // MARK: 화면

    func updateTitle() {
        StatusLine.write(store.quotas)
        let segs = Format.segments(store.quotas, sampleIfMissing: false)
        guard !segs.isEmpty else {
            statusItem.button?.title = store.errors.isEmpty ? "✳︎ …" : "✳︎ ⚠︎"
            return
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let title = NSMutableAttributedString()
        let space = NSAttributedString(string: " ", attributes: [.font: font])
        for (i, seg) in segs.enumerated() {
            if i > 0 {
                // 서비스 사이 간격 (설정 값, pt)
                let gap = UserDefaults.standard.double(forKey: Pref.spacing)
                title.append(NSAttributedString(string: " ", attributes: [.font: font, .kern: max(0, gap - 4)]))
            }
            var first = true
            if seg.2.showsLogo, let img = seg.2.logo {
                let a = NSTextAttachment()
                a.image = img
                a.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
                title.append(NSAttributedString(attachment: a))
                first = false
            }
            for part in seg.0 {
                if !first { title.append(space) }
                first = false
                switch part {
                case .ring(let v):
                    let a = NSTextAttachment()
                    a.image = Ring.image(v, level: seg.1, size: 18)
                    a.bounds = NSRect(x: 0, y: -4, width: 18, height: 18)
                    title.append(NSAttributedString(attachment: a))
                case .text(let t):
                    title.append(NSAttributedString(string: t, attributes: [
                        .foregroundColor: [NSColor.labelColor, .systemOrange, .systemRed][seg.1],
                        .font: font,
                    ]))
                }
            }
        }
        statusItem.button?.attributedTitle = title
    }

    func info(_ text: String, bold: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if bold {
            item.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        }
        return item
    }

    func addBucket(_ menu: NSMenu, _ name: String, _ b: Bucket?) {
        guard let b else { return }
        menu.addItem(info(L("   \(name): \(Format.pct(b)) 사용 · \(Format.pct(Format.remaining(b))) 남음", "   \(name): \(Format.pct(b)) used · \(Format.pct(Format.remaining(b))) left")))
        let r = Format.resetText(b)
        if !r.isEmpty { menu.addItem(info("      \(r)")) }
    }

    func rebuildMenu() {
        let menu = NSMenu()
        for p in Provider.allCases where Pref.enabled(p) {
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            let q = store.quotas[p]
            var header = "\(p.icon) \(p.name)"
            if let plan = q?.plan { header += " (\(plan.capitalized))" }
            if q?.limitReached == true { header += L(" — 한도 도달", " — limit reached") }
            menu.addItem(info(header, bold: true))
            if let q {
                addBucket(menu, q.session?.label ?? L("현재 세션 (5시간)", "Current session (5h)"), q.session)
                addBucket(menu, q.weekly?.label ?? L("주간", "Weekly"), q.weekly)
                if q.session == nil, q.weekly == nil, let h = q.headline { menu.addItem(info("   " + h)) }
                for x in q.extras2 { menu.addItem(info("   \(x.label): \(x.value)")) }
                for (name, b) in q.extras { addBucket(menu, name, b) }
                let rows = q.breakdown.filter { $0.1 > 0 }
                if !rows.isEmpty {
                    menu.addItem(info(L("   주간 사용 비중: ", "   Weekly share: ") + rows.map { "\($0.0) \(Int($0.1))%" }.joined(separator: ", ")))
                }
            }
            if let e = store.errors[p] { menu.addItem(info("   ⚠︎ \(e)")) }
            let web = NSMenuItem(title: L("   \(p.name) 사용량 페이지 열기", "   Open \(p.name) usage page"), action: #selector(openWeb(_:)), keyEquivalent: "")
            web.target = self
            web.representedObject = p.rawValue
            menu.addItem(web)
        }
        menu.addItem(.separator())
        if let t = lastUpdated {
            let df = DateFormatter()
            df.dateFormat = "HH:mm:ss"
            menu.addItem(info(L("마지막 업데이트 \(df.string(from: t))", "Last updated \(df.string(from: t))")))
        }
        let refreshItem = NSMenuItem(title: L("지금 새로고침", "Refresh now"), action: #selector(refresh as () -> Void), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let settings = NSMenuItem(title: L("설정…", "Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("종료", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        rightMenu = menu
    }

    // 실행 중에 앱을 다시 열면(Finder·Launchpad 등) 설정창을 띄움
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    @objc func openWeb(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let p = Provider(rawValue: raw) else { return }
        NSWorkspace.shared.open(p.webURL)
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(store: store)))
            w.title = L("사용량 설정", "UsageBar Settings")
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
