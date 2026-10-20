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

    // 날짜 키는 양력 숫자로 고정 (기록을 읽을 때 만드는 키와 화면에서 찾는 키가 같아야 함)
    static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = format
        return f
    }

    // 기록마다 부르므로 DateFormatter 대신 직접 만듦 (현지 시각)
    static func hourKey(_ d: Date) -> String {
        var t = time_t(d.timeIntervalSince1970.rounded(.down))
        var tm = tm()
        localtime_r(&t, &tm)
        return String(format: "%04d-%02d-%02d %02d", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour)
    }

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

    static let keyFormatter = formatter("yyyy-MM-dd")

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
    // 날짜 키는 읽을 때 한 번만 만듦 (합칠 때마다 날짜를 글자로 바꾸면 느림)
    let hourKey: String   // "yyyy-MM-dd HH"
    var dayKey: String { String(hourKey.prefix(10)) }
    init(id: String, date: Date) {
        self.id = id; self.date = date
        hourKey = LocalStats.hourKey(date)
    }
    var tokens = 0.0, cost = 0.0, saved = 0.0, cacheRead = 0.0, inputAll = 0.0
    var model = ""
    var project = ""
}

struct FileScan {
    var entries: [UsageEntry] = []
    var times: [Date] = []
    var offset = 0          // 여기까지(마지막 줄바꿈 다음) 읽었음. 파일이 늘어나면 이어서 읽음
    // Codex는 앞 줄의 상태를 이어 받아야 함
    var lastTotal = 0.0
    var model = "", project = ""
}

enum LocalScan {
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let isoPlain = ISO8601DateFormatter()

    // JSON에서 꺼낸 글자는 원래 줄 전체를 붙잡고 있을 수 있어서, 따로 복사해 둠
    // (같은 이름이 수만 번 나오므로 한 벌만 보관)
    static var owned: [String: String] = [:]
    static func own(_ s: String) -> String {
        if let o = owned[s] { return o }
        let copy = String(decoding: Array(s.utf8), as: UTF8.self)
        owned[copy] = copy
        return copy
    }

    static func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        return fastISO(s) ?? iso.date(from: s) ?? isoPlain.date(from: s)
    }

    // 로그 시각 형식(2026-10-11T07:08:54.324Z)은 직접 계산 (날짜 변환기는 기록 수만 건에 느림)
    static func fastISO(_ s: String) -> Date? {
        var u = Array(s.utf8)
        guard u.count >= 20, u[4] == 45, u[7] == 45, u[10] == 84, u[13] == 58, u[16] == 58, u.last == 90 else { return nil }
        u.removeLast()
        func num(_ a: Int, _ n: Int) -> Int? {
            var v = 0
            for i in a..<(a + n) { let c = Int(u[i]) - 48; guard (0...9).contains(c) else { return nil }; v = v * 10 + c }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2),
              let h = num(11, 2), let mi = num(14, 2), let sec = num(17, 2), (1...12).contains(mo) else { return nil }
        var frac = 0.0
        if u.count > 19 {
            guard u[19] == 46, u.count > 20 else { return nil }
            var scale = 0.1
            for c in u[20...] { let v = Int(c) - 48; guard (0...9).contains(v) else { return nil }; frac += Double(v) * scale; scale /= 10 }
        }
        // 그레고리력 날짜 → 1970-01-01부터 며칠
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        return Date(timeIntervalSince1970: Double(days * 86400 + h * 3600 + mi * 60 + sec) + frac)
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

    // 파일별 읽기 결과 캐시 (백그라운드 한 곳에서만 호출)
    // - 수정 시각과 크기가 같으면 다시 읽지 않음
    // - 로그는 끝에 덧붙여지기만 하므로, 커졌으면 새로 붙은 부분만 읽음 (진행 중인 세션 파일은 수십 MB)
    static var cache: [String: (mtime: Date, size: Int, scan: FileScan)] = [:]
    static var touched = Set<String>()
    static var changed = false   // 이번 집계에서 새로 읽은 내용이 있는지

    // 새로 읽은 내용도, 빠진 파일도 없으면 지난 결과를 그대로 씀 (합치는 데 드는 계산을 건너뜀)
    static var last: [String: (paths: [String], stats: LocalStats)] = [:]

    static func combineIfChanged(_ name: String, _ urls: [URL], _ read: (FileScan, [Line]) -> FileScan, hasCost: Bool) -> LocalStats {
        changed = false
        let scans = urls.map { cached($0, read) }
        let paths = urls.map(\.path).sorted()
        if !changed, let l = last[name], l.paths == paths { return l.stats }
        let stats = combine(scans, hasCost: hasCost)
        last[name] = (paths, stats)
        return stats
    }

    // 두 서비스를 한 번에 집계하고, 더 이상 대상이 아닌 파일(31일 지남·삭제)은 캐시에서 뺌
    static func scanAll() -> (claude: LocalStats, codex: LocalStats) {
        touched = []
        let c = claude(), x = codex()
        cache = cache.filter { touched.contains($0.key) }
        return (c, x)
    }

    static func cached(_ url: URL, _ read: (FileScan, [Line]) -> FileScan) -> FileScan {
        let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let m = v?.contentModificationDate ?? .distantPast, size = v?.fileSize ?? 0
        touched.insert(url.path)
        let old = cache[url.path]
        if let c = old, c.mtime == m, c.size == size { return c.scan }
        // 줄어들었으면(다시 쓰인 파일) 처음부터
        changed = true
        let base = old.flatMap { $0.size <= size ? $0.scan : nil } ?? FileScan()
        guard let h = try? FileHandle(forReadingFrom: url) else { return base }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: UInt64(base.offset))) != nil else { return base }
        // 큰 파일을 한 번에 올리면 메모리가 크게 늘어 4MB씩 나눠 읽음
        // (줄 중간에서 끊긴 부분은 다음 조각에 붙여 읽고, 쓰는 중인 마지막 줄은 다음 새로고침에 읽음)
        var s = base
        var carry = Data()
        // 조각마다 임시 객체를 바로 풀어 줌 (안 그러면 집계가 끝날 때까지 쌓임)
        while autoreleasepool(invoking: { () -> Bool in
            guard let chunk = try? h.read(upToCount: 4 << 20), !chunk.isEmpty else { return false }
            var buf = carry
            buf.append(chunk)
            let (lines, used) = split(buf)
            s = read(s, lines)
            s.offset += used
            carry = used < buf.count ? buf.subdata(in: used..<buf.count) : Data()
            return true
        }) {}
        cache[url.path] = (m, size, s)
        return s
    }

    // 마지막 줄바꿈까지의 줄들과, 그만큼의 바이트 수
    static func split(_ data: Data) -> ([Line], Int) {
        var lines: [Line] = []
        var used = 0
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            var start = 0
            while start < buf.count, let nl = memchr(base + start, 0x0A, buf.count - start) {
                let end = base.distance(to: UnsafeRawPointer(nl))
                if end > start { lines.append(Line(data: data, range: start..<end)) }
                start = end + 1
                used = start
            }
        }
        return (lines, used)
    }

    // 로그 한 줄 (파일 내용을 복사하지 않고 위치만 가리킴)
    // 줄 대부분은 도구 출력 같은 큰 내용이라, 필요한 줄만 JSON으로 풀고 나머지는 기록 시각만 찾아 읽음
    struct Line {
        let data: Data
        let range: Range<Int>

        func bytes<T>(_ f: (UnsafeRawBufferPointer) -> T) -> T {
            data.withUnsafeBytes { f(UnsafeRawBufferPointer(rebasing: $0[range])) }
        }

        // 글자 위치 (last: 마지막 것, within: 앞쪽 몇 바이트에서만 찾기)
        func find(_ needle: StaticString, last: Bool = false, within: Int = .max) -> Int? {
            bytes { b -> Int? in
                guard let base = b.baseAddress else { return nil }
                let count = min(b.count, within)
                var from = 0, found: Int? = nil
                while from < count, let hit = memmem(base + from, count - from, needle.utf8Start, needle.utf8CodeUnitCount) {
                    let at = base.distance(to: UnsafeRawPointer(hit))
                    if !last { return at }
                    found = at
                    from = at + 1
                }
                return found
            }
        }

        func has(_ needle: StaticString, within: Int = .max) -> Bool { find(needle, within: within) != nil }

        // "timestamp":"…" 값을 JSON을 풀지 않고 읽음 (문자열 안의 따옴표는 \" 로 적혀 있어 걸리지 않음)
        func timestamp(last: Bool) -> Date? {
            let key: StaticString = "\"timestamp\":\""
            guard let at = find(key, last: last) else { return nil }
            return bytes { b -> Date? in
                let start = at + key.utf8CodeUnitCount
                guard start < b.count, let base = b.baseAddress,
                      let q = memchr(base + start, 0x22, min(40, b.count - start)) else { return nil }
                let end = base.distance(to: UnsafeRawPointer(q))
                return LocalScan.date(String(decoding: UnsafeRawBufferPointer(rebasing: b[start..<end]), as: UTF8.self))
            }
        }

        var json: [String: Any]? {
            try? JSONSerialization.jsonObject(with: data.subdata(in: range)) as? [String: Any]
        }
    }

    // 여러 파일 결과를 합침: 같은 ID는 한 번만, 작업 시간은 전체 기록 시각을 이어 붙여 계산
    // (세션을 이어 쓰면 이전 기록이 새 파일에 복사되므로 파일 간 중복 제거가 필요)
    static func combine(_ scans: [FileScan], hasCost: Bool) -> LocalStats {
        var stats = LocalStats()
        stats.hasCost = hasCost
        var seen = Set<String>()
        var times: [Double] = []
        for s in scans {
            for e in s.entries {
                if !e.id.isEmpty { guard seen.insert(e.id).inserted else { continue } }
                let hk = e.hourKey, dk = e.dayKey
                var d = stats.days[dk] ?? DayStat()
                d.tokens += e.tokens; d.cost += e.cost; d.saved += e.saved
                d.cacheRead += e.cacheRead; d.inputAll += e.inputAll
                stats.days[dk] = d
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
            times.append(contentsOf: s.times.map(\.timeIntervalSince1970))
        }
        // 5분 이내 간격만 이어서 작업 시간으로 계산 (동시에 돌린 세션은 한 번만 셈, 같은 시각은 간격 0이라 건너뜀)
        times.sort()
        for (a, b) in zip(times, times.dropFirst()) {
            let gap = b - a
            if gap > 0, gap <= 300 { stats.add(Date(timeIntervalSince1970: b)) { $0.seconds += gap } }
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

    static func readClaude(_ base: FileScan, _ lines: [Line]) -> FileScan {
        var scan = base
        for line in lines {
            // 사용량이 적힌 응답 줄이 아니면 시각만 (최상위 timestamp는 줄 끝 쪽에 있음)
            guard line.has("\"usage\""), line.has("\"assistant\"") else {
                if let ts = line.timestamp(last: true) { scan.times.append(ts) }
                continue
            }
            guard let obj = line.json, let ts = date(obj["timestamp"]) else { continue }
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
            e.model = own(model)
            e.project = own((obj["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "")
            scan.entries.append(e)
        }
        return scan
    }

    static func claude() -> LocalStats {
        let root = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? (NSHomeDirectory() + "/.claude")
        return combineIfChanged("claude", recentFiles(in: [root + "/projects"]), readClaude, hasCost: true)
    }

    // MARK: Codex

    static func readCodex(_ base: FileScan, _ lines: [Line]) -> FileScan {
        var scan = base
        var lastTotal = base.lastTotal
        var model = base.model, project = base.project
        for line in lines {
            // 사용량·세션 정보·턴 정보 줄이 아니면 시각만 (Codex는 timestamp가 줄 맨 앞)
            // 종류는 줄 앞부분에 적혀 있으므로 앞 200바이트만 봄 (뒤쪽은 큰 출력이 대부분)
            guard line.has("\"token_count\"", within: 200) || line.has("\"session_meta\"", within: 200)
                    || line.has("\"turn_context\"", within: 200) else {
                if let ts = line.timestamp(last: false) { scan.times.append(ts) }
                continue
            }
            guard let obj = line.json, let ts = date(obj["timestamp"]) else { continue }
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
            e.model = own(model)
            e.project = own(project)
            scan.entries.append(e)
        }
        // 다음에 이어 읽을 때 쓸 상태
        scan.lastTotal = lastTotal; scan.model = model; scan.project = project
        return scan
    }

    static func codex() -> LocalStats {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? (NSHomeDirectory() + "/.codex")
        return combineIfChanged("codex", recentFiles(in: [home + "/sessions", home + "/archived_sessions"]), readCodex, hasCost: false)
    }
}
