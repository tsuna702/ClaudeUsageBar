import Cocoa

// 로그인 연동: 각 서비스의 공식 CLI 로그인을 터미널에서 실행하고, 로그인 정보가 생기면 새로고침

extension Notification.Name {
    static let usageLoginChanged = Notification.Name("usageLoginChanged")
}

enum LoginHelper {
    static var home: String { NSHomeDirectory() }

    // 공식 CLI 위치 후보 (앞에서부터 먼저 있는 것을 씀)
    static func cliPath(_ p: Provider) -> String? {
        let names: [String]
        switch p {
        case .claude:
            names = [home + "/.local/bin/claude", home + "/.claude/local/claude",
                     "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        case .codex:
            var list = [home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
            // ChatGPT(Codex) 앱에 함께 들어 있는 CLI
            for id in ["com.openai.codex", "com.openai.chat"] {
                if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    list.append(app.path + "/Contents/Resources/codex-cli/bin/codex")
                }
            }
            names = list
        }
        return names.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func loginArgs(_ p: Provider) -> String { p == .claude ? "auth login" : "login" }

    static func installURL(_ p: Provider) -> URL {
        URL(string: p == .claude ? "https://code.claude.com/docs/en/setup" : "https://chatgpt.com/codex")!
    }

    // 로그인 정보가 있는지 (토큰 값은 읽지 않고 존재만 확인)
    static func isLoggedIn(_ p: Provider) -> Bool {
        switch p {
        case .claude:
            return ClaudeAPI.security(["find-generic-password", "-s", ClaudeAPI.service]).0 == 0
        case .codex:
            return CodexAPI.credentials() != nil
        }
    }

    // 로그인 정보의 변경 표식 (바뀌면 로그인/계정 전환이 끝난 것으로 봄)
    static func fingerprint(_ p: Provider) -> String {
        switch p {
        case .claude:
            let (code, data) = ClaudeAPI.security(["find-generic-password", "-s", ClaudeAPI.service])
            return code == 0 ? String(decoding: data, as: UTF8.self) : "none"
        case .codex:
            let path = (ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home + "/.codex") + "/auth.json"
            let m = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            return m.map { "\($0.timeIntervalSince1970)" } ?? "none"
        }
    }

    static var watchers: [Provider: Timer] = [:]

    // 터미널에서 공식 로그인 명령 실행 → 끝나면 자동 새로고침
    static func login(_ p: Provider) {
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
