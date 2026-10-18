import Foundation

// 로컬 사용 기록(Claude Code·Codex 로그)을 읽어 일별 토큰·비용·작업 시간을 집계

struct DayStat {
    var tokens = 0.0      // 전체 토큰 (입력+캐시+출력)
    var cost = 0.0        // API 요금으로 환산한 비용 (USD)
    var saved = 0.0       // 캐시 덕분에 아낀 비용 (USD)
    var cacheRead = 0.0   // 캐시에서 읽은 입력 토큰
    var inputAll = 0.0    // 캐시 포함 전체 입력 토큰
    var seconds = 0.0     // 작업 시간

    var cacheRatio: Double { inputAll > 0 ? cacheRead / inputAll : 0 }
}

// 모델·프로젝트별 합계
struct Agg {
    var tokens = 0.0
    var cost = 0.0
}

struct LocalStats {
    var days: [String: DayStat] = [:]
    var hours: [String: DayStat] = [:]                 // "yyyy-MM-dd HH"
    var models: [String: [String: Agg]] = [:]          // 모델 → 날짜 → 합계
    var projects: [String: [String: Agg]] = [:]        // 프로젝트 → 날짜 → 합계
    var hasCost = false

    static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH"
        return f
    }()

    // 오늘 0시~23시 시간대별
    var todayHours: [(hour: Int, stat: DayStat)] {
        let day = LocalStats.key(Date())
        return (0..<24).map { h in (h, hours[String(format: "%@ %02d", day, h)] ?? DayStat()) }
    }

    // 최근 n일(오늘 포함) 기준 상위 항목
    static func top(_ table: [String: [String: Agg]], days n: Int, limit: Int = 5) -> [(name: String, agg: Agg)] {
        let keys = Set((0..<n).map { LocalStats.key(Calendar.current.date(byAdding: .day, value: -$0, to: Date())!) })
        let rows = table.map { name, byDay -> (String, Agg) in
            var a = Agg()
            for (k, v) in byDay where keys.contains(k) { a.tokens += v.tokens; a.cost += v.cost }
            return (name, a)
        }
        return rows.filter { $0.1.tokens > 0 }.sorted { $0.1.tokens > $1.1.tokens }.prefix(limit).map { ($0.0, $0.1) }
    }

    static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func key(_ d: Date) -> String { keyFormatter.string(from: d) }

    func day(offset: Int) -> DayStat {
        let d = Calendar.current.date(byAdding: .day, value: -offset, to: Date())!
        return days[LocalStats.key(d)] ?? DayStat()
    }

    // 오래된 날부터 최근 30일
    var last30: [(date: Date, stat: DayStat)] {
        let today = Calendar.current.startOfDay(for: Date())
        return (0..<30).reversed().map { i in
            let d = Calendar.current.date(byAdding: .day, value: -i, to: today)!
            return (d, days[LocalStats.key(d)] ?? DayStat())
        }
    }

    mutating func merge(_ o: LocalStats) {
        for (k, d) in o.days {
            var s = days[k] ?? DayStat()
            s.tokens += d.tokens; s.cost += d.cost; s.saved += d.saved
            s.cacheRead += d.cacheRead; s.inputAll += d.inputAll; s.seconds += d.seconds
            days[k] = s
        }
    }

    mutating func add(_ date: Date, _ f: (inout DayStat) -> Void) {
        let k = LocalStats.key(date)
        var s = days[k] ?? DayStat()
        f(&s)
        days[k] = s
    }
}

// 기록 한 건 (응답 하나의 사용량)
struct UsageEntry {
    let id: String        // 중복 제거용 (비어 있으면 항상 집계)
    let date: Date
    var tokens = 0.0, cost = 0.0, saved = 0.0, cacheRead = 0.0, inputAll = 0.0
    var model = ""
    var project = ""
}

struct FileScan {
    var entries: [UsageEntry] = []
    var times: [Date] = []
}

enum LocalScan {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    // 최근 31일 안에 바뀐 .jsonl 파일
    static func recentFiles(in dirs: [String]) -> [URL] {
        let cutoff = Date().addingTimeInterval(-31 * 86400)
        var out: [URL] = []
        for dir in dirs {
            guard let e = FileManager.default.enumerator(
                at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let url as URL in e where url.pathExtension == "jsonl" {
                let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let m, m >= cutoff { out.append(url) }
            }
        }
        return out
    }

    // 파일별 읽기 결과 캐시: 수정 시각과 크기가 같으면 다시 읽지 않음 (백그라운드 한 곳에서만 호출)
    static var cache: [String: (mtime: Date, size: Int, scan: FileScan)] = [:]

    static func cached(_ url: URL, _ read: (URL) -> FileScan) -> FileScan {
        let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let m = v?.contentModificationDate ?? .distantPast, size = v?.fileSize ?? 0
        if let c = cache[url.path], c.mtime == m, c.size == size { return c.scan }
        let s = read(url)
        cache[url.path] = (m, size, s)
        return s
    }

    static func lines(_ url: URL) -> [Substring] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
    }

    // 여러 파일 결과를 합침: 같은 ID는 한 번만, 작업 시간은 전체 기록 시각을 이어 붙여 계산
    // (세션을 이어 쓰면 이전 기록이 새 파일에 복사되므로 파일 간 중복 제거가 필요)
    static func combine(_ scans: [FileScan], hasCost: Bool) -> LocalStats {
        var stats = LocalStats()
        stats.hasCost = hasCost
        var seen = Set<String>()
        var times = Set<Date>()
        for s in scans {
            for e in s.entries {
                if !e.id.isEmpty { guard seen.insert(e.id).inserted else { continue } }
                stats.add(e.date) {
                    $0.tokens += e.tokens; $0.cost += e.cost; $0.saved += e.saved
                    $0.cacheRead += e.cacheRead; $0.inputAll += e.inputAll
                }
                let hk = LocalStats.hourFormatter.string(from: e.date), dk = LocalStats.key(e.date)
                var h = stats.hours[hk] ?? DayStat()
                h.tokens += e.tokens; h.cost += e.cost
                stats.hours[hk] = h
                if !e.model.isEmpty {
                    var a = stats.models[e.model, default: [:]][dk] ?? Agg()
                    a.tokens += e.tokens; a.cost += e.cost
                    stats.models[e.model, default: [:]][dk] = a
                }
                if !e.project.isEmpty {
                    var a = stats.projects[e.project, default: [:]][dk] ?? Agg()
                    a.tokens += e.tokens; a.cost += e.cost
                    stats.projects[e.project, default: [:]][dk] = a
                }
            }
            times.formUnion(s.times)
        }
        // 5분 이내 간격만 이어서 작업 시간으로 계산 (동시에 돌린 세션은 한 번만 셈)
        let sorted = times.sorted()
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            let gap = b.timeIntervalSince(a)
            if gap > 0, gap <= 300 { stats.add(b) { $0.seconds += gap } }
        }
        return stats
    }

    // MARK: Claude

    // 모델별 1M 토큰당 가격 (입력, 출력, 캐시 읽기). 앞에서부터 먼저 맞는 항목을 씀
    static let claudePrices: [(prefix: String, input: Double, output: Double, read: Double)] = [
        ("claude-fable", 10, 50, 0.25),
        ("claude-mythos", 10, 50, 0.25),
        ("claude-opus-5-5", 4, 20, 0.20),
        ("claude-opus-5", 5, 25, 0.50),
        ("claude-opus-4-8", 5, 25, 0.50),
        ("claude-opus-4-7", 5, 25, 0.50),
        ("claude-opus-4-6", 5, 25, 0.50),
        ("claude-opus-4-5", 5, 25, 0.50),
        ("claude-opus", 15, 75, 1.50),
        ("claude-sonnet-5", 2, 10, 0.20),
        ("claude-sonnet", 3, 15, 0.30),
        ("claude-haiku-5", 0.10, 0.50, 0.01),
        ("claude-haiku-4", 1, 5, 0.10),
        ("claude-3-5-haiku", 0.80, 4, 0.08),
    ]

    static func readClaude(_ url: URL) -> FileScan {
        var scan = FileScan()
        for line in lines(url) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let ts = date(obj["timestamp"]) else { continue }
            scan.times.append(ts)
            guard obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any],
                  let model = msg["model"] as? String, model.hasPrefix("claude") else { continue }
            // 같은 응답이 여러 줄·여러 파일에 기록되므로 메시지 ID로 중복 제거
            let mid = msg["id"] as? String ?? "", rid = obj["requestId"] as? String ?? ""
            let id = mid.isEmpty && rid.isEmpty ? "" : "\(mid)|\(rid)"

            func n(_ k: String) -> Double { (usage[k] as? NSNumber)?.doubleValue ?? 0 }
            let input = n("input_tokens"), output = n("output_tokens")
            let write = n("cache_creation_input_tokens"), read = n("cache_read_input_tokens")
            let cc = usage["cache_creation"] as? [String: Any]
            let write1h = (cc?["ephemeral_1h_input_tokens"] as? NSNumber)?.doubleValue ?? 0
            let write5m = max(0, write - write1h)

            let p = claudePrices.first { model.hasPrefix($0.prefix) } ?? ("", 4, 20, 0.20)
            var e = UsageEntry(id: id, date: ts)
            e.tokens = input + output + write + read
            e.cost = (input * p.input + output * p.output + read * p.read
                      + write5m * p.input * 1.25 + write1h * p.input * 2) / 1_000_000
            e.saved = read * (p.input - p.read) / 1_000_000
            e.cacheRead = read
            e.inputAll = input + write + read
            e.model = model
            e.project = (obj["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            scan.entries.append(e)
        }
        return scan
    }

    static func claude() -> LocalStats {
        let root = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? (NSHomeDirectory() + "/.claude")
        return combine(recentFiles(in: [root + "/projects"]).map { cached($0, readClaude) }, hasCost: true)
    }

    // MARK: Codex

    static func readCodex(_ url: URL) -> FileScan {
        var scan = FileScan()
        var lastTotal = 0.0
        var model = "", project = ""
        for line in lines(url) {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let ts = date(obj["timestamp"]) else { continue }
            scan.times.append(ts)
            // 세션 정보·턴 정보에서 현재 모델과 작업 폴더를 기억
            if let t = obj["type"] as? String, t == "session_meta" || t == "turn_context",
               let pl = obj["payload"] as? [String: Any] {
                if let m = pl["model"] as? String { model = m }
                if let c = pl["cwd"] as? String { project = URL(fileURLWithPath: c).lastPathComponent }
            }
            guard let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any] else { continue }
            // 누적값이 늘었을 때만 새 사용으로 봄 (같은 이벤트가 반복 기록됨)
            let totalTokens = (total["total_tokens"] as? NSNumber)?.doubleValue ?? 0
            guard totalTokens > lastTotal else { continue }
            lastTotal = totalTokens
            func n(_ k: String) -> Double { (last[k] as? NSNumber)?.doubleValue ?? 0 }
            let input = n("input_tokens"), output = n("output_tokens")
            // 이어 쓴 세션이 복사돼도 한 번만 세도록 시각+누적값으로 ID를 만듦
            var e = UsageEntry(id: "\(obj["timestamp"] ?? "")|\(Int(totalTokens))", date: ts)
            e.tokens = input + output
            e.cacheRead = n("cached_input_tokens")
            e.inputAll = input
            e.model = model
            e.project = project
            scan.entries.append(e)
        }
        return scan
    }

    static func codex() -> LocalStats {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? (NSHomeDirectory() + "/.codex")
        return combine(recentFiles(in: [home + "/sessions", home + "/archived_sessions"]).map { cached($0, readCodex) }, hasCost: false)
    }
}
