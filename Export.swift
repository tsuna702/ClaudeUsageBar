import Cocoa
import UniformTypeIdentifiers

// CSV 내보내기: 일별 · 모델별 · 프로젝트별 집계와 한도 기록을 한 파일로

enum Export {
    static func csv(_ store: UsageStore) -> String {
        var rows = ["type,provider,date,name,tokens,cost_usd,cache_read_tokens,input_tokens,working_seconds,percent"]
        func q(_ s: String) -> String { s.contains(",") || s.contains("\"") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s }
        func n(_ v: Double, _ digits: Int = 0) -> String { String(format: "%.\(digits)f", v) }

        for p in Provider.allCases {
            guard let s = store.local[p] else { continue }
            for k in s.days.keys.sorted() {
                let d = s.days[k]!
                rows.append(["day", p.rawValue, k, "", n(d.tokens), s.hasCost ? n(d.cost, 4) : "",
                             n(d.cacheRead), n(d.inputAll), n(d.seconds), ""].joined(separator: ","))
            }
            for (type, table) in [("model", s.models), ("project", s.projects)] {
                for name in table.keys.sorted() {
                    for k in table[name]!.keys.sorted() {
                        let a = table[name]![k]!
                        rows.append([type, p.rawValue, k, q(name), n(a.tokens), s.hasCost ? n(a.cost, 4) : "", "", "", "", ""].joined(separator: ","))
                    }
                }
            }
        }
        let iso = ISO8601DateFormatter()
        for smp in History.samples {
            let t = iso.string(from: Date(timeIntervalSince1970: smp.t))
            if let v = smp.s { rows.append(["limit_session", smp.p, t, "", "", "", "", "", "", n(v, 1)].joined(separator: ",")) }
            if let v = smp.w { rows.append(["limit_weekly", smp.p, t, "", "", "", "", "", "", n(v, 1)].joined(separator: ",")) }
        }
        return rows.joined(separator: "\n") + "\n"
    }

    static func save(_ store: UsageStore) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "usagebar-\(LocalStats.key(Date())).csv"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try csv(store).write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let a = NSAlert(error: error)
            a.runModal()
        }
    }
}
