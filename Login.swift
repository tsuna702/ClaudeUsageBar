import Cocoa

// 로그인 연동: 각 서비스의 공식 CLI 로그인을 터미널에서 실행하고, 로그인 정보가 생기면 새로고침

extension Notification.Name {
    static let usageLoginChanged = Notification.Name("usageLoginChanged")
}

enum LoginHelper {
    static var home: String { NSHomeDirectory() }

    // 공식 CLI 위치 후보 (앞에서부터 먼저 있는 것을 씀)
    static func cliPath(_ p: Provider) -> String? {
        func common(_ n: String) -> [String] {
            [home + "/.local/bin/\(n)", "/opt/homebrew/bin/\(n)", "/usr/local/bin/\(n)",
             home + "/.npm-global/bin/\(n)", home + "/.bun/bin/\(n)"]
        }
        let names: [String]
        switch p {
        case .claude:
            names = [home + "/.local/bin/claude", home + "/.claude/local/claude",
                     "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        case .codex:
            var list = common("codex")
            // ChatGPT(Codex) 앱에 함께 들어 있는 CLI
            for id in ["com.openai.codex", "com.openai.chat"] {
                if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    list.append(app.path + "/Contents/Resources/codex-cli/bin/codex")
                }
            }
            names = list
        case .gemini: names = common("gemini")
        case .grok:
            // USAGE_GROK_CLI: 개발·테스트용 경로
            names = [ProcessInfo.processInfo.environment["USAGE_GROK_CLI"], GrokAPI.home + "/bin/grok"].compactMap { $0 } + common("grok")
        case .antigravity, .cursor, .openai, .cloudflare: names = []
        }
        return names.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // 로그인에 필요한 것이 설치돼 있는지 (CLI · 앱). API 키 방식은 항상 true
    static func isInstalled(_ p: Provider) -> Bool {
        switch p.loginKind {
        case .cli: return cliPath(p) != nil
        case .app: return p.appURL != nil
        case .apiKey: return true
        }
    }

    // 설치 안내 문구에 쓰는 이름
    static func toolName(_ p: Provider) -> String {
        switch p {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .grok: return "grok CLI"
        default: return p.name
        }
    }

    static func loginArgs(_ p: Provider) -> String {
        switch p {
        case .claude: return "auth login"
        case .gemini: return ""          // 처음 실행하면 로그인 방법을 물어봄
        default: return "login"
        }
    }

    static func installURL(_ p: Provider) -> URL {
        let s: String
        switch p {
        case .claude: s = "https://code.claude.com/docs/en/setup"
        case .codex: s = "https://chatgpt.com/codex"
        case .gemini: s = "https://github.com/google-gemini/gemini-cli"
        case .antigravity: s = "https://antigravity.google/download"
        case .cursor: s = "https://cursor.com/download"
        case .grok: s = "https://x.ai/cli"
        case .openai: s = "https://platform.openai.com/settings/organization/admin-keys"
        case .cloudflare: s = "https://dash.cloudflare.com/profile/api-tokens"
        }
        return URL(string: s)!
    }

    static func fileDate(_ path: String) -> String {
        let m = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        return m.map { "\($0.timeIntervalSince1970)" } ?? "none"
    }

    // 로그인 정보가 있는지 (토큰 값은 읽지 않고 존재만 확인)
    static func isLoggedIn(_ p: Provider) -> Bool {
        switch p {
        case .claude: return ClaudeAPI.hasLogin()
        case .codex: return CodexAPI.credentials() != nil
        case .gemini: return FileManager.default.fileExists(atPath: GeminiAPI.credsPath)
        case .antigravity: return p.appURL != nil      // 로그인 여부는 앱이 실행 중일 때 확인
        case .cursor: return CursorAPI.value("cursorAuth/accessToken") != nil
        case .grok: return FileManager.default.fileExists(atPath: GrokAPI.authPath)
        case .openai: return KeyStore.get(p.rawValue) != nil
        case .cloudflare: return KeyStore.get(p.rawValue) != nil && !(UserDefaults.standard.string(forKey: CloudflareAPI.accountKey) ?? "").isEmpty
        }
    }

    // 로그인 정보의 변경 표식 (바뀌면 로그인/계정 전환이 끝난 것으로 봄)
    static func fingerprint(_ p: Provider) -> String {
        switch p {
        case .claude:
            let (code, data) = ClaudeAPI.security(["find-generic-password", "-s", ClaudeAPI.service])
            return code == 0 ? String(decoding: data, as: UTF8.self) : "none"
        case .codex: return fileDate((ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home + "/.codex") + "/auth.json")
        case .gemini: return fileDate(GeminiAPI.credsPath)
        case .cursor: return fileDate(CursorAPI.dbPath)
        case .grok: return fileDate(GrokAPI.authPath)
        case .antigravity, .openai, .cloudflare: return "\(isLoggedIn(p))"
        }
    }

    static var watchers: [Provider: Timer] = [:]

    // 터미널에서 공식 로그인 명령 실행 → 끝나면 자동 새로고침
    static func login(_ p: Provider) {
        switch p.loginKind {
        case .apiKey:
            // 키는 설정창에서 입력
            NSWorkspace.shared.open(installURL(p))
            return
        case .app:
            // 앱에서 로그인하면 감지
            if let app = p.appURL { NSWorkspace.shared.open(app); watch(p) } else { NSWorkspace.shared.open(installURL(p)) }
            return
        case .cli:
            break
        }
        guard let cli = cliPath(p) else {
            NSWorkspace.shared.open(installURL(p))
            return
        }
        let start = L("\(p.name) 로그인을 시작해요. 브라우저에서 로그인을 마치면 이 창은 닫아도 돼요.",
                      "Starting \(p.name) login. Finish signing in in your browser; you can close this window afterwards.")
        let done = L("완료! UsageBar가 자동으로 사용량을 불러와요. 이 창은 닫아도 돼요.",
                     "Done! UsageBar will load your usage automatically. You can close this window.")
        let script = """
        #!/bin/zsh
        clear
        echo "\(start)"
        echo
        "\(cli)" \(loginArgs(p))
        echo
        echo "\(done)"
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("usagebar-login-\(p.rawValue).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch { return }
        NSWorkspace.shared.open(url)
        watch(p)
    }

    // 5분 동안 3초마다 로그인 정보 변화를 확인
    static func watch(_ p: Provider) {
        watchers[p]?.invalidate()
        let before = fingerprint(p)
        let start = Date()
        watchers[p] = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { t in
            if fingerprint(p) != before {
                t.invalidate()
                NotificationCenter.default.post(name: .usageLoginChanged, object: nil)
            } else if Date().timeIntervalSince(start) > 300 {
                t.invalidate()
            }
        }
    }
}
