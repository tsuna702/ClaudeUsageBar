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
}

struct Quota {
    var session: Bucket?
    var weekly: Bucket?
    var extras: [(String, Bucket)] = []      // 주간 Opus 등 추가 한도
    var breakdown: [(String, Double)] = []   // 주간 사용 비중
    var plan: String?
    var email: String?
    var limitReached = false

    static let sample = Quota(session: Bucket(percent: 12, resetsAt: nil), weekly: Bucket(percent: 45, resetsAt: nil))
}

enum Provider: String, CaseIterable {
    case claude, codex

    var name: String { self == .claude ? "Claude" : "Codex" }
    var icon: String { self == .claude ? "✳︎" : "◎" }
    var webURL: URL {
        URL(string: self == .claude ? "https://claude.ai/settings/usage" : "https://chatgpt.com/codex/settings/usage")!
    }
    var enabledKey: String { "show_\(rawValue)" }

    // 설치된 공식 앱의 아이콘을 로고로 사용 (없으면 nil → 글자 아이콘)
    static var logoCache: [Provider: NSImage?] = [:]
    var logo: NSImage? {
        if let c = Provider.logoCache[self] { return c }
        if ProcessInfo.processInfo.environment["USAGE_NOLOGO"] != nil { return nil }
        let ids = self == .claude ? ["com.anthropic.claudefordesktop"] : ["com.openai.codex", "com.openai.chat"]
        let img = ids.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            .first.map { flatIcon(NSWorkspace.shared.icon(forFile: $0.path)) }
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
        return security(["-i"], stdin: cmd).0 == 0
    }

    // 만료(또는 5분 이내 만료 예정)면 refresh token으로 새 토큰을 받아 키체인에 저장
    static func refreshIfNeeded(force: Bool = false) -> String? {
        refreshLock.lock(); defer { refreshLock.unlock() }
        guard var json = readCredentials(), var oauth = json["claudeAiOauth"] as? [String: Any] else { return nil }
        let expiresAt = (oauth["expiresAt"] as? Double ?? 0) / 1000
        if !force, expiresAt > Date().timeIntervalSince1970 + 300 { return oauth["accessToken"] as? String }
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
        guard readCredentials() != nil else { done(nil, L("Claude Code 로그인 정보를 찾을 수 없어요", "Claude Code login not found")); return }
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
                done(nil, code == 401 ? L("토큰 만료 — 터미널에서 claude를 한 번 실행해 주세요", "Token expired — run claude in Terminal once") : "HTTP \(code)")
                return
            }
            guard let u = try? JSONDecoder().decode(ClaudeUsage.self, from: data) else { done(nil, L("응답 해석 실패", "Could not read response")); return }
            var q = Quota(session: bucket(u.five_hour), weekly: bucket(u.seven_day))
            if let b = bucket(u.seven_day_opus) { q.extras.append((L("주간 Opus", "Weekly Opus"), b)) }
            if let b = bucket(u.seven_day_sonnet) { q.extras.append((L("주간 Sonnet", "Weekly Sonnet"), b)) }
            q.breakdown = (u.seven_day_breakdown?.rows ?? []).map { ($0.display_name, $0.percent) }
            let oauth = readCredentials()?["claudeAiOauth"] as? [String: Any]
            q.plan = oauth?["subscriptionType"] as? String
            q.email = accountEmail()
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
                done(nil, code == 401 ? L("토큰 만료 — Codex를 한 번 실행해 주세요", "Token expired — open Codex once") : "HTTP \(code)")
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
            q.limitReached = u.rate_limit?.limit_reached ?? false
            done(q, nil)
        }.resume()
    }
}

// MARK: - 설정 키

enum Pref {
    static let refreshMinutes = "refreshMinutes"
    static let colorWarnings = "colorWarnings"
    static let orangeAt = "orangeAt"
    static let redAt = "redAt"

    // 메뉴 막대에 보일 요소 (각각 켜고 끔)
    static let showIcon = "bar_icon"
    static let useLogo = "bar_logo"
    static let showName = "bar_name"
    static let showSession = "bar_session"
    static let showSessionLeft = "bar_session_left"
    static let showLeftLabel = "bar_left_label"
    static let showWeekly = "bar_weekly"
    static let showLabels = "bar_labels"
    static let showReset = "bar_reset"
    static let useGauge = "bar_gauge"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            refreshMinutes: 5, colorWarnings: true, orangeAt: 70, redAt: 90,
            Provider.claude.enabledKey: true, Provider.codex.enabledKey: true,
            Notify.enabledKey: true, Notify.resetKey: true,
            showIcon: true, useLogo: true, showName: false, showSession: true, showSessionLeft: false, showLeftLabel: true, showWeekly: true,
            showLabels: false, showReset: false, useGauge: false,
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

    // 켜진 요소만 모아 한 서비스의 문구를 만듦
    static func title(_ q: Quota, _ p: Provider) -> String {
        let labels = Pref.on(Pref.showLabels), gaugeOn = Pref.on(Pref.useGauge)
        func value(_ b: Bucket?) -> String { gaugeOn ? gauge(b) : pct(b) }

        var head: [String] = []
        if Pref.on(Pref.showIcon), !p.showsLogo { head.append(p.icon) }
        if Pref.on(Pref.showName) { head.append(p.name) }

        var values: [String] = []
        let used = Pref.on(Pref.showSession), left = Pref.on(Pref.showSessionLeft)
        if used || left {
            var pieces: [String] = []
            if used { pieces.append(value(q.session)) }
            let leftLabel = Pref.on(Pref.showLeftLabel)
            if left { pieces.append(leftLabel ? L("남음 \(value(remaining(q.session)))", "\(value(remaining(q.session))) left") : value(remaining(q.session))) }
            // '남음' 글자가 없으면 사용/남은 값을 '/'로 구분
            var s = (labels ? "5h " : "") + pieces.joined(separator: leftLabel ? " " : "/")
            if Pref.on(Pref.showReset) { s += " (\(shortReset(q.session)))" }
            values.append(s)
        }
        if Pref.on(Pref.showWeekly) { values.append((labels ? "7d " : "") + value(q.weekly)) }

        let parts = head + (values.isEmpty ? [] : [values.joined(separator: " · ")])
        return parts.isEmpty ? p.icon : parts.joined(separator: " ")
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
    static func segments(_ quotas: [Provider: Quota], sampleIfMissing: Bool) -> [(String, Int, Provider)] {
        Provider.allCases.filter(Pref.enabled).compactMap { p in
            guard let q = quotas[p] ?? (sampleIfMissing ? .sample : nil) else { return nil }
            return (title(q, p), level(q), p)
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
    @AppStorage(Notify.resetKey) var notifyReset = true
    @AppStorage(Pref.colorWarnings) var colorWarnings = true
    @AppStorage(Pref.orangeAt) var orangeAt = 70.0
    @AppStorage(Pref.redAt) var redAt = 90.0
    @AppStorage(Provider.claude.enabledKey) var showClaude = true
    @AppStorage(Provider.codex.enabledKey) var showCodex = true

    func color(_ level: Int) -> Color { [Color.primary, .orange, .red][level] }

    func preview() -> some View {
        // 토글 값이 바뀔 때마다 다시 그려지도록 읽어둠
        _ = (showIcon, useLogo, showName, showSession, showSessionLeft, showLeftLabel, showWeekly, showLabels, showReset, useGauge, showClaude, showCodex)
        let segs = Format.segments(store.quotas, sampleIfMissing: true)
        return HStack(spacing: 10) {
            ForEach(segs.indices, id: \.self) { i in
                HStack(spacing: 4) {
                    if segs[i].2.showsLogo, let img = segs[i].2.logo {
                        Image(nsImage: img).resizable().frame(width: 16, height: 16)
                    }
                    if !segs[i].0.isEmpty { Text(segs[i].0).foregroundStyle(color(segs[i].1)) }
                }
            }
        }
        .font(.system(size: 13, weight: .medium).monospacedDigit())
    }

    var body: some View {
        Form {
            Section(L("미리보기", "Preview")) {
                HStack {
                    Spacer()
                    preview()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary))
                    Spacer()
                }
                .padding(.vertical, 6)
            }

            Section(L("계정 연결", "Accounts")) {
                ForEach(Provider.allCases, id: \.self) { p in
                    AccountSettingRow(provider: p, store: store)
                }
                Text(L("각 서비스의 공식 로그인 창이 터미널에서 열려요. 로그인이 끝나면 자동으로 사용량을 불러와요.", "Each service's official login opens in Terminal. Your usage loads automatically when you finish."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("표시할 서비스", "Services")) {
                Toggle("✳︎ Claude", isOn: $showClaude).disabled(showClaude && !showCodex)
                Toggle("◎ Codex", isOn: $showCodex).disabled(showCodex && !showClaude)
            }

            Section(L("메뉴 막대 표시 형식", "Menu bar display")) {
                Toggle(L("아이콘", "Icon"), isOn: $showIcon)
                Toggle(L("아이콘을 앱 로고로 표시", "Use app logos as icons"), isOn: $useLogo).disabled(!showIcon)
                Toggle(L("서비스 이름 (Claude, Codex)", "Service name (Claude, Codex)"), isOn: $showName)
                Toggle(L("세션 사용량 (5시간)", "Session usage (5h)"), isOn: $showSession)
                Toggle(L("세션 남은 사용량", "Session remaining"), isOn: $showSessionLeft)
                Toggle(L("“남음” 글자 표시", "Show “left” label"), isOn: $showLeftLabel).disabled(!showSessionLeft)
                Toggle(L("주간 사용량", "Weekly usage"), isOn: $showWeekly)
                Toggle(L("5h · 7d 라벨", "5h · 7d labels"), isOn: $showLabels).disabled(!showSession && !showSessionLeft && !showWeekly)
                Toggle(L("세션 초기화까지 남은 시간", "Time until session reset"), isOn: $showReset).disabled(!showSession && !showSessionLeft)
                Toggle(L("숫자 대신 막대 게이지 (▰▱)", "Gauge instead of numbers (▰▱)"), isOn: $useGauge).disabled(!showSession && !showSessionLeft && !showWeekly)
            }
            .toggleStyle(.switch)

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

            Section(L("일반", "General")) {
                Picker(L("언어", "Language"), selection: $lang) {
                    Text(L("시스템 설정 따르기", "Follow system")).tag("system")
                    Text("한국어").tag("ko")
                    Text("English").tag("en")
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
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .id(lang)
        .frame(width: 460, height: 640)
    }
}

// MARK: - 앱

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let store = UsageStore()
    var timer: Timer?
    var timerMinutes = 0
    var lastUpdated: Date?
    var settingsWindow: NSWindow?
    let popover = NSPopover()
    let ui = DashState()
    var rightMenu = NSMenu()
    var pending = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        Pref.registerDefaults()
        Notify.requestPermission()
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
        // 개발용: 실행하자마자 대시보드를 열어 위치 확인
        if ProcessInfo.processInfo.environment["USAGE_OPEN"] != nil, let b = statusItem.button {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
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
            self?.refresh()
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.updateTitle()
            self?.rebuildMenu()
            self?.scheduleTimer()
            self?.settingsWindow?.title = L("사용량 설정", "UsageBar Settings")
        }
    }

    func scheduleTimer() {
        let minutes = max(1, UserDefaults.standard.integer(forKey: Pref.refreshMinutes))
        guard minutes != timerMinutes else { return }
        timerMinutes = minutes
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: true) { [weak self] _ in self?.refresh() }
    }

    // 왼쪽 클릭: 대시보드, 오른쪽 클릭: 간단 메뉴
    @objc func statusClicked(_ sender: NSStatusBarButton) {
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

    @objc func refresh() {
        guard pending == 0 else { return }
        pending = Provider.allCases.count + 1
        store.loading = true
        // 로컬 기록 집계 (토큰·비용·작업 시간)
        DispatchQueue.global(qos: .utility).async {
            let t0 = Date()
            let c = LocalScan.claude(), x = LocalScan.codex()
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
                self.finishOne()
            }
        }
        // 꺼둔 서비스도 받아둬서 설정에서 켜면 바로 보이게 함
        for p in Provider.allCases {
            let fetch = p == .claude ? ClaudeAPI.fetch : CodexAPI.fetch
            DispatchQueue.global().async {
                fetch { q, err in
                    DispatchQueue.main.async {
                        if let q {
                            self.store.quotas[p] = q; self.store.updated[p] = Date(); self.lastUpdated = Date()
                            if Pref.enabled(p) { Notify.check(p, q) }
                        }
                        let loggedIn = LoginHelper.isLoggedIn(p)
                        self.store.loggedIn[p] = loggedIn
                        if !loggedIn { self.store.quotas[p] = nil }   // 로그아웃하면 이전 값을 지움
                        self.store.errors[p] = err
                        if ProcessInfo.processInfo.environment["USAGE_DEBUG"] != nil {
                            print(p.name, q.map { "session \(Format.pct($0.session)) weekly \(Format.pct($0.weekly)) bar=[\(Format.title($0, p))]" } ?? "-", err ?? ""); fflush(stdout)
                        }
                        self.updateTitle()
                        self.rebuildMenu()
                        self.finishOne()
                    }
                }
            }
        }
    }

    func finishOne() {
        pending = max(0, pending - 1)
        if pending == 0 {
            store.loading = false
            if let dir = ProcessInfo.processInfo.environment["USAGE_SNAPSHOT"] { MainActor.assumeIsolated { snapshot(to: dir) } }
        }
    }

    // 개발용: 대시보드 탭별 화면을 PNG로 저장
    @MainActor func snapshot(to dir: String) {
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            appearance.performAsCurrentDrawingAppearance {
                for t in DashTab.allCases {
                    let state = DashState()
                    state.tab = t
                    let view = DashboardView(store: store, ui: state, onRefresh: {}, onSettings: {}, onQuit: {}, flat: true)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let r = ImageRenderer(content: view)
                    r.scale = 2
                    if let img = r.nsImage, let tiff = img.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: dir + "/dash-\(t.rawValue)\(dark ? "-dark" : "").png"))
                    }
                }
            }
        }
        print("snapshot saved"); fflush(stdout)
    }

    // MARK: 화면

    func updateTitle() {
        let segs = Format.segments(store.quotas, sampleIfMissing: false)
        guard !segs.isEmpty else {
            statusItem.button?.title = store.errors.isEmpty ? "✳︎ …" : "✳︎ ⚠︎"
            return
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let title = NSMutableAttributedString()
        for (i, seg) in segs.enumerated() {
            if i > 0 { title.append(NSAttributedString(string: "   ", attributes: [.font: font])) }
            if seg.2.showsLogo, let img = seg.2.logo {
                let a = NSTextAttachment()
                a.image = img
                a.bounds = NSRect(x: 0, y: -3, width: 16, height: 16)
                title.append(NSAttributedString(attachment: a))
                if !seg.0.isEmpty { title.append(NSAttributedString(string: " ", attributes: [.font: font])) }
            }
            title.append(NSAttributedString(string: seg.0, attributes: [
                .foregroundColor: [NSColor.labelColor, .systemOrange, .systemRed][seg.1],
                .font: font,
            ]))
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
                addBucket(menu, L("현재 세션 (5시간)", "Current session (5h)"), q.session)
                addBucket(menu, L("주간", "Weekly"), q.weekly)
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
        let refreshItem = NSMenuItem(title: L("지금 새로고침", "Refresh now"), action: #selector(refresh), keyEquivalent: "r")
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
