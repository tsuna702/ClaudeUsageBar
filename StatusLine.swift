import Cocoa
import SwiftUI

// Claude Code 상태줄 연동: 사용량 한 줄을 파일로 남기고, Claude Code 설정에 그 파일을 보여주는 statusLine을 등록

enum StatusLine {
    static var fileURL: URL { History.url.deletingLastPathComponent().appendingPathComponent("statusline.txt") }
    static var command: String { "cat '\(fileURL.path)' 2>/dev/null" }
    static var settingsPath: String {
        (ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude") + "/settings.json"
    }

    // 메뉴 막대와 같은 형식으로, 그림 대신 글자 아이콘을 써서 한 줄로
    static func line(_ quotas: [Provider: Quota]) -> String {
        Provider.allCases.filter(Pref.enabled).compactMap { p -> String? in
            guard let q = quotas[p] else { return nil }
            // 상태줄에는 그림이 없으므로 링 값도 글자로 씀
            var t = Format.title(q, p)
            if Pref.on(Pref.showIcon), p.showsLogo { t = p.icon + " " + t }
            return t
        }.joined(separator: "  ")
    }

    static var lastWritten = ""

    // 내용이 바뀔 때만 파일에 씀
    static func write(_ quotas: [Provider: Quota]) {
        let text = line(quotas)
        guard !text.isEmpty, text != lastWritten else { return }
        if (try? (text + "\n").write(to: fileURL, atomically: true, encoding: .utf8)) != nil { lastWritten = text }
    }

    static func readSettings() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    static func saveSettings(_ json: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return false }
        try? FileManager.default.createDirectory(atPath: (settingsPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        return (try? data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)) != nil
    }

    // 지금 설정된 statusLine 명령
    static var currentCommand: String? {
        (readSettings()["statusLine"] as? [String: Any])?["command"] as? String
    }

    static var isConnected: Bool { currentCommand == command }

    // 다른 상태줄이 이미 있으면 바꿀지 먼저 물어봄
    static func connect() -> Bool {
        var json = readSettings()
        if let existing = currentCommand, existing != command {
            let a = NSAlert()
            a.messageText = L("이미 다른 상태줄이 설정돼 있어요", "Another status line is already set")
            a.informativeText = L("지금 설정: \(existing)\n\nUsageBar 상태줄로 바꿀까요?", "Current: \(existing)\n\nReplace it with UsageBar's status line?")
            a.addButton(withTitle: L("바꾸기", "Replace"))
            a.addButton(withTitle: L("취소", "Cancel"))
            guard a.runModal() == .alertFirstButtonReturn else { return false }
        }
        json["statusLine"] = ["type": "command", "command": command, "padding": 0]
        return saveSettings(json)
    }

    // 우리가 넣은 상태줄일 때만 지움
    static func disconnect() -> Bool {
        var json = readSettings()
        guard isConnected else { return false }
        json.removeValue(forKey: "statusLine")
        return saveSettings(json)
    }
}

// 설정창 섹션

final class StatusLineState: ObservableObject {
    @Published var connected = StatusLine.isConnected
    func reload() { connected = StatusLine.isConnected }
}

struct StatusLineSection: View {
    @ObservedObject var state = StatusLineState()

    var body: some View {
        Section(L("Claude Code 상태줄", "Claude Code Status Line")) {
            LabeledContent(L("상태줄에 사용량 표시", "Show usage in status line")) {
                if state.connected {
                    Button(L("연결 해제", "Disconnect")) { _ = StatusLine.disconnect(); state.reload() }
                } else {
                    Button(L("연결", "Connect")) { _ = StatusLine.connect(); state.reload() }
                }
            }
            Text(L("Claude Code 설정(~/.claude/settings.json)의 statusLine에 아래 명령을 넣어요. 메뉴 막대와 같은 형식으로 보여요.",
                   "Adds this command as statusLine in Claude Code's settings (~/.claude/settings.json). It uses the same format as the menu bar."))
                .font(.caption).foregroundStyle(.secondary)
            Text(StatusLine.command).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
        }
        .onAppear { state.reload() }
    }
}
