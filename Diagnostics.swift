import SwiftUI

// 연결 진단: 서비스마다 단계별로 확인 (토큰 등 비밀값은 보여주지 않음)

struct DiagStep: Hashable {
    let name: String
    let ok: Bool?        // nil = 참고 정보
    let detail: String
}

enum Diagnostics {
    static func short(_ path: String) -> String { path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    static func run(_ p: Provider) -> [DiagStep] {
        var steps: [DiagStep] = []
        func add(_ name: String, _ ok: Bool?, _ detail: String = "") { steps.append(DiagStep(name: name, ok: ok, detail: detail)) }

        add(L("켜짐", "Enabled"), Pref.enabled(p), Pref.enabled(p) ? "" : L("설정 → 계정에서 켜야 메뉴 막대에 보여요", "Turn on in Settings → Accounts"))
        switch p.loginKind {
        case .cli:
            let path = LoginHelper.cliPath(p)
            add(L("\(LoginHelper.toolName(p)) 설치", "\(LoginHelper.toolName(p)) installed"), path != nil, path.map(short) ?? L("찾지 못함", "Not found"))
        case .app:
            add(L("\(p.name) 앱", "\(p.name) app"), p.appURL != nil, p.appURL.map { short($0.path) } ?? L("찾지 못함", "Not found"))
        case .apiKey:
            break
        }
        add(L("로그인 정보", "Login"), LoginHelper.isLoggedIn(p))

        // 서비스별 추가 확인
        switch p {
        case .claude:
            if let o = ClaudeAPI.readCredentials()?["claudeAiOauth"] as? [String: Any], let exp = Net.number(o["expiresAt"]) {
                let mins = Int((exp / 1000 - Date().timeIntervalSince1970) / 60)
                add(L("토큰 만료까지", "Token expires in"), nil, mins > 0 ? L("\(mins)분", "\(mins) min") : L("만료됨 (자동 갱신 대상)", "Expired (will refresh)"))
            }
        case .gemini:
            add(L("토큰 갱신용 OAuth 정보", "OAuth client for refresh"), GeminiAPI.cliOAuthClient() != nil,
                L("Gemini CLI 안의 oauth2.js에서 찾아요", "Read from Gemini CLI's oauth2.js"))
        case .antigravity:
            let ep = AntigravityAPI.discover()
            add(L("language_server 실행 중", "language_server running"), ep != nil,
                ep.map { L("포트 \($0.ports.map(String.init).joined(separator: ", "))", "ports \($0.ports.map(String.init).joined(separator: ", "))") }
                    ?? L("Antigravity를 실행해 주세요", "Open Antigravity"))
        case .cursor:
            add(L("로그인 DB", "Login database"), FileManager.default.fileExists(atPath: CursorAPI.dbPath), short(CursorAPI.dbPath))
        case .grok:
            add("auth.json", FileManager.default.fileExists(atPath: GrokAPI.authPath), short(GrokAPI.authPath))
        case .cloudflare:
            let acct = UserDefaults.standard.string(forKey: CloudflareAPI.accountKey) ?? ""
            add(L("계정 ID", "Account ID"), !acct.isEmpty, acct.isEmpty ? L("비어 있음", "Empty") : String(acct.prefix(6)) + "…")
        default:
            break
        }

        if let st = StatusCheck.check(p) {
            add(L("서비스 상태", "Service status"), st.level == 0, st.text)
        }

        // 실제 사용량 요청
        let start = Date()
        var result: (Quota?, String?, LocalStats?) = (nil, nil, nil)
        let sem = DispatchSemaphore(value: 0)
        ProviderFetch.fetch(p) { q, e, s in result = (q, e, s); sem.signal() }
        if sem.wait(timeout: .now() + 40) == .timedOut { result.1 = L("40초 안에 응답이 없어요", "No response in 40 seconds") }
        let ms = Int(-start.timeIntervalSinceNow * 1000)
        if let q = result.0 {
            var parts: [String] = []
            if let b = q.session { parts.append("\(b.label ?? L("세션", "session")) \(Format.pct(b))") }
            if let b = q.weekly { parts.append("\(b.label ?? L("주간", "weekly")) \(Format.pct(b))") }
            if let h = q.headline { parts.append(h) }
            if let pl = q.plan { parts.append(pl) }
            add(L("사용량 요청", "Usage request"), true, parts.joined(separator: " · ") + " (\(ms)ms)")
        } else {
            add(L("사용량 요청", "Usage request"), false, (result.1 ?? "?") + " (\(ms)ms)")
        }
        return steps
    }

    static func report(_ results: [Provider: [DiagStep]]) -> String {
        var lines = ["UsageBar \(Updater.current) — \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        for p in Provider.allCases {
            guard let steps = results[p] else { continue }
            lines.append("")
            lines.append("[\(p.name)]")
            for s in steps {
                let mark = s.ok == nil ? "•" : (s.ok! ? "✓" : "✗")
                lines.append("\(mark) \(s.name)\(s.detail.isEmpty ? "" : ": " + s.detail)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

final class DiagState: ObservableObject {
    @Published var results: [Provider: [DiagStep]] = [:]
    @Published var running = Set<Provider>()

    func run(_ ps: [Provider]) {
        for p in ps where !running.contains(p) {
            running.insert(p)
            DispatchQueue.global(qos: .userInitiated).async {
                let steps = Diagnostics.run(p)
                DispatchQueue.main.async {
                    self.results[p] = steps
                    self.running.remove(p)
                }
            }
        }
    }
}

struct DiagnosticsView: View {
    @ObservedObject var state: DiagState

    var body: some View {
        Form {
            Section {
                HStack {
                    Button(L("모두 진단", "Run all")) { state.run(Provider.allCases) }
                    Button(L("켜 둔 서비스만", "Enabled only")) { state.run(Provider.allCases.filter(Pref.enabled)) }
                    Spacer()
                    Button(L("결과 복사", "Copy report")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Diagnostics.report(state.results), forType: .string)
                    }
                    .disabled(state.results.isEmpty)
                }
                Text(L("문제가 생기면 결과를 복사해서 GitHub 이슈에 붙여 주세요. 토큰이나 키는 들어가지 않아요.",
                       "If something fails, copy the report into a GitHub issue. Tokens and keys are never included."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Provider.allCases, id: \.self) { p in
                Section {
                    if let steps = state.results[p] {
                        ForEach(steps, id: \.self) { s in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: s.ok == nil ? "info.circle" : (s.ok! ? "checkmark.circle.fill" : "xmark.circle.fill"))
                                    .foregroundStyle(s.ok == nil ? Color.secondary : (s.ok! ? Color.green : Color.red))
                                Text(s.name).font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text(s.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.trailing).textSelection(.enabled)
                            }
                        }
                    } else {
                        Text(L("아직 진단하지 않았어요", "Not checked yet")).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text(p.name)
                        Spacer()
                        if state.running.contains(p) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button(L("진단", "Check")) { state.run([p]) }.controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
