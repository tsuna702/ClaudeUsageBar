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

    // 오늘 0시~23시 시간대별
    var todayHours: [(hour: Int, stat: DayStat)] {
        let day = LocalTime.day(Date().timeIntervalSince1970)
        return (0..<24).map { h in (h, hours[LocalTime.key(hour: day * 100 + h)] ?? DayStat()) }
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

    // 날짜 키를 다시 날짜로 읽을 때 씀
    static let keyFormatter = formatter("yyyy-MM-dd")

    // 기록을 집계할 때와 같은 방식(현지 시각)으로 만듦
    static func key(_ d: Date) -> String { LocalTime.key(day: LocalTime.day(d.timeIntervalSince1970)) }

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

// 현지 날짜·시각을 숫자로 (20261028 = 2026-10-28, 2026102807 = 그날 7시)
// 집계는 숫자로 하고 글자 키는 마지막에 한 번만 만듦 (날짜 변환기는 기록 수만 건에 느림)
enum LocalTime {
    static func hour(_ t: Double) -> Int {
        var tt = time_t(t.rounded(.down)), tm = tm()
        localtime_r(&tt, &tm)
        return day(tm) * 100 + Int(tm.tm_hour)
    }

    static func day(_ t: Double) -> Int { hour(t) / 100 }

    static func day(_ tm: tm) -> Int { (Int(tm.tm_year) + 1900) * 10000 + Int(tm.tm_mon + 1) * 100 + Int(tm.tm_mday) }

    // 20261028 → "2026-10-28"
    static func key(day: Int) -> String {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 10) { b in
            put(b, day)
            return String(decoding: b, as: UTF8.self)
        }
    }

    // 2026102807 → "2026-10-28 07"
    static func key(hour: Int) -> String {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 13) { b in
            put(b, hour / 100)
            b[10] = 0x20
            digits(b, 11, hour % 100, 2)
            return String(decoding: b, as: UTF8.self)
        }
    }

    private static func put(_ b: UnsafeMutableBufferPointer<UInt8>, _ day: Int) {
        digits(b, 0, day / 10000, 4); b[4] = 0x2D
        digits(b, 5, day / 100 % 100, 2); b[7] = 0x2D
        digits(b, 8, day % 100, 2)
    }

    private static func digits(_ b: UnsafeMutableBufferPointer<UInt8>, _ at: Int, _ v: Int, _ width: Int) {
        var v = v
        for k in (at..<at + width).reversed() { b[k] = UInt8(48 + v % 10); v /= 10 }
    }
}

// 시각이 속한 현지 날짜. 같은 날 안이면 다시 계산하지 않음
struct DayFinder {
    private var start = 0.0, end = 0.0, code = 0

    mutating func day(_ t: Double) -> Int {
        if t >= start, t < end { return code }
        var tt = time_t(t.rounded(.down)), tm = tm()
        localtime_r(&tt, &tm)
        code = LocalTime.day(tm)
        // 그날 0시부터 하루. 시차가 바뀌는 날(일광 절약 시간)은 범위를 기억하지 않고 매번 계산
        let s = Int(tt) - (Int(tm.tm_hour) * 3600 + Int(tm.tm_min) * 60 + Int(tm.tm_sec))
        var t1 = time_t(s), t2 = time_t(s + 86399), a = Darwin.tm(), b = Darwin.tm()
        localtime_r(&t1, &a); localtime_r(&t2, &b)
        if a.tm_gmtoff == tm.tm_gmtoff, b.tm_gmtoff == tm.tm_gmtoff, LocalTime.day(a) == code, LocalTime.day(b) == code {
            start = Double(s); end = Double(s + 86400)
        } else {
            start = 0; end = 0
        }
        return code
    }
}

// 기록 한 건 (응답 하나의 사용량)
struct UsageEntry {
    let id: UInt64        // 중복 제거용 (0이면 항상 집계)
    let hour: Int         // 현지 시각 yyyymmddhh
    var tokens = 0.0, cost = 0.0, saved = 0.0, cacheRead = 0.0, inputAll = 0.0
    var model = ""
    var project = ""
}

struct FileScan {
    var entries: [UsageEntry] = []
    var times: [Double] = []   // 기록 시각 (작업 시간 계산용, epoch 초)
    var offset = 0          // 여기까지(마지막 줄바꿈 다음) 읽었음. 파일이 늘어나면 이어서 읽음
    // Codex는 앞 줄의 상태를 이어 받아야 함
    var lastTotal = 0.0
    var model = "", project = ""
    private var days = DayFinder()

    // 작업 시간은 5분 이내 간격을 이어 더하므로, 앞뒤 시각이 5분 안·같은 날이면 그 사이 시각은
    // 있어도 없어도 합계와 날짜별 배분이 같음 → 버려서 메모리와 정렬 비용을 줄임 (수십 배)
    mutating func addTime(_ t: Double) {
        let n = times.count
        if n >= 2 {
            let a = times[n - 2], b = times[n - 1]
            if a <= b, b <= t, t - a <= 300, days.day(a) == days.day(t) {
                times[n - 1] = t
                return
            }
        }
        times.append(t)
    }
}

// 파일을 읽어 둘 버퍼. malloc 대신 mmap으로 잡아 집계가 끝나면 바로 운영체제에 돌려줌
// (몇 MB짜리 버퍼를 malloc으로 만들었다 풀면 그 메모리가 앱에 계속 남아 있었음)
final class ReadBuffer {
    private(set) var base: UnsafeMutablePointer<UInt8>
    private(set) var size: Int

    init?(size: Int = 4 << 20) {
        guard let m = ReadBuffer.map(size) else { return nil }
        base = m
        self.size = size
    }

    deinit { munmap(base, size) }

    // 버퍼보다 긴 줄을 만나면 두 배로
    func grow(keeping used: Int) -> Bool {
        guard let bigger = ReadBuffer.map(size * 2) else { return false }
        memcpy(bigger, base, used)
        munmap(base, size)
        base = bigger
        size *= 2
        return true
    }

    private static func map(_ size: Int) -> UnsafeMutablePointer<UInt8>? {
        guard let m = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), m != MAP_FAILED else { return nil }
        return m.assumingMemoryBound(to: UInt8.self)
    }
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

    // 작업 폴더 경로 → 폴더 이름 (같은 경로가 이어서 나오므로 마지막 결과를 기억)
    static var lastProject = ("", "")
    static func projectName(_ cwd: String) -> String {
        if cwd == lastProject.0 { return lastProject.1 }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        lastProject = (cwd, name)
        return name
    }

    // 중복 제거용 ID: 글자 대신 64비트 해시로 보관 (메모리와 비교 비용을 줄임)
    static func idHash(_ a: String, _ b: String) -> UInt64 {
        guard !(a.isEmpty && b.isEmpty) else { return 0 }
        var h = Hasher(), a = a, b = b
        a.withUTF8 { h.combine(bytes: UnsafeRawBufferPointer($0)) }
        h.combine(UInt8(0xFF))
        b.withUTF8 { h.combine(bytes: UnsafeRawBufferPointer($0)) }
        let v = UInt64(UInt(bitPattern: h.finalize()))
        return v == 0 ? 1 : v
    }

    // 기록 시각 글자 → epoch 초
    static func time(_ b: UnsafeRawBufferPointer) -> Double? {
        if let t = fastISO(b) { return t }
        let s = String(decoding: b, as: UTF8.self)
        return (iso.date(from: s) ?? isoPlain.date(from: s))?.timeIntervalSince1970
    }

    static func time(_ v: Any?) -> Double? {
        guard var s = v as? String else { return nil }
        return s.withUTF8 { time(UnsafeRawBufferPointer($0)) }
    }

    // 로그 시각 형식(2026-10-11T07:08:54.324Z)은 직접 계산 (날짜 변환기는 기록 수만 건에 느림)
    static func fastISO(_ u: UnsafeRawBufferPointer) -> Double? {
        let n = u.count
        guard n >= 20, u[4] == 45, u[7] == 45, u[10] == 84, u[13] == 58, u[16] == 58, u[n - 1] == 90 else { return nil }
        let m = n - 1   // Z 앞까지
        func num(_ a: Int, _ k: Int) -> Int? {
            var v = 0
            for i in a..<(a + k) { let c = Int(u[i]) - 48; guard (0...9).contains(c) else { return nil }; v = v * 10 + c }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2),
              let h = num(11, 2), let mi = num(14, 2), let sec = num(17, 2), (1...12).contains(mo) else { return nil }
        var frac = 0.0
        if m > 19 {
            guard u[19] == 46, m > 20 else { return nil }
            var scale = 0.1
            for i in 20..<m { let v = Int(u[i]) - 48; guard (0...9).contains(v) else { return nil }; frac += Double(v) * scale; scale /= 10 }
        }
        // 그레고리력 날짜 → 1970-01-01부터 며칠
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        return Double(days * 86400 + h * 3600 + mi * 60 + sec) + frac
    }

    // 최근 31일 안에 바뀐 .jsonl 파일
    static func recentFiles(in dirs: [String]) -> [URL] {
        let cutoff = Date().addingTimeInterval(-31 * 86400)
        var out: [URL] = []
        for dir in dirs {
            // 크기도 함께 받아 둠 (파일마다 다시 묻지 않게)
            guard let e = FileManager.default.enumerator(
                at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
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
    static var combined = false  // 이번 집계에서 결과를 새로 만들었는지 (아니면 화면에 알릴 필요 없음)
    static var buffer: ReadBuffer?   // 집계 한 번 동안 같이 씀

    // 새로 읽은 내용도, 빠진 파일도 없으면 지난 결과를 그대로 씀 (합치는 데 드는 계산을 건너뜀)
    static var last: [String: (paths: [String], stats: LocalStats)] = [:]

    static func combineIfChanged(_ name: String, _ urls: [URL], _ read: (inout FileScan, Line) -> Void, hasCost: Bool) -> LocalStats {
        changed = false
        let scans = urls.map { cached($0, read) }
        let paths = urls.map(\.path).sorted()
        if !changed, let l = last[name], l.paths == paths { return l.stats }
        combined = true
        let stats = combine(scans, hasCost: hasCost)
        last[name] = (paths, stats)
        return stats
    }

    // 두 서비스를 한 번에 집계하고, 더 이상 대상이 아닌 파일(31일 지남·삭제)은 캐시에서 뺌
    static func scanAll() -> (claude: LocalStats, codex: LocalStats, changed: Bool) {
        touched = []
        combined = false
        let c = claude(), x = codex()
        cache = cache.filter { touched.contains($0.key) }
        buffer = nil
        return (c, x, combined)
    }

    static func cached(_ url: URL, _ read: (inout FileScan, Line) -> Void) -> FileScan {
        let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let m = v?.contentModificationDate ?? .distantPast, size = v?.fileSize ?? 0
        touched.insert(url.path)
        let old = cache[url.path]
        if let c = old, c.mtime == m, c.size == size { return c.scan }
        // 줄어들었으면(다시 쓰인 파일) 처음부터
        changed = true
        var s = old.flatMap { $0.size <= size ? $0.scan : nil } ?? FileScan()
        guard let buf = buffer ?? ReadBuffer() else { return s }
        buffer = buf
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return s }
        defer { close(fd) }
        // 버퍼에 이어 읽으면서 완성된 줄만 처리 (쓰는 중인 마지막 줄은 다음 새로고침에 읽음)
        var filled = 0
        while true {
            if filled == buf.size, !buf.grow(keeping: filled) { break }
            let got = pread(fd, buf.base + filled, buf.size - filled, off_t(s.offset + filled))
            guard got > 0 else { break }
            filled += got
            // 조각마다 임시 객체를 바로 풀어 줌
            let used = autoreleasepool { lines(buf.base, filled) { read(&s, $0) } }
            s.offset += used
            if used > 0 {
                memmove(buf.base, buf.base + used, filled - used)
                filled -= used
            }
        }
        cache[url.path] = (m, size, s)
        return s
    }

    // 버퍼 안의 완성된 줄마다 f를 부르고, 마지막 줄바꿈 다음 위치를 돌려줌
    static func lines(_ base: UnsafeMutablePointer<UInt8>, _ count: Int, _ f: (Line) -> Void) -> Int {
        var start = 0
        while start < count, let nl = memchr(base + start, 0x0A, count - start) {
            let end = nl.assumingMemoryBound(to: UInt8.self) - base
            if end > start { f(Line(p: base + start, n: end - start)) }
            start = end + 1
        }
        return start
    }

    // 로그 한 줄 (읽기 버퍼 안의 위치만 가리킴)
    struct Line {
        let p: UnsafePointer<UInt8>
        let n: Int

        // 글자 위치 (last: 마지막 것, within: 앞쪽 몇 바이트에서만 찾기)
        func find(_ needle: StaticString, last: Bool = false, within: Int = .max) -> Int? {
            let count = min(n, within)
            var from = 0, found: Int? = nil
            while from < count, let hit = memmem(p + from, count - from, needle.utf8Start, needle.utf8CodeUnitCount) {
                let at = UnsafeRawPointer(p).distance(to: hit)
                if !last { return at }
                found = at
                from = at + 1
            }
            return found
        }

        func has(_ needle: StaticString, within: Int = .max) -> Bool { find(needle, within: within) != nil }

        // "timestamp":"…" 값을 JSON을 풀지 않고 읽음 (문자열 안의 따옴표는 \" 로 적혀 있어 걸리지 않음)
        func timestamp(last: Bool) -> Double? {
            let key: StaticString = "\"timestamp\":\""
            guard let at = find(key, last: last) else { return nil }
            let start = at + key.utf8CodeUnitCount
            guard start < n, let q = memchr(p + start, 0x22, min(40, n - start)) else { return nil }
            let end = UnsafeRawPointer(p).distance(to: q)
            return LocalScan.time(UnsafeRawBufferPointer(start: p + start, count: end - start))
        }

        var json: [String: Any]? {
            try? JSONSerialization.jsonObject(with: Data(bytes: p, count: n)) as? [String: Any]
        }
    }

    // JSON 한 줄에서 필요한 값만 꺼내고 나머지(응답 내용·도구 출력 등)는 건너뜀
    // (JSONSerialization은 줄 전체를 객체로 만들어 느리고 메모리를 많이 씀)
    struct Cursor {
        struct Str { let start: Int, end: Int }   // 문자열 값 위치 (따옴표 안쪽)

        let p: UnsafePointer<UInt8>
        let n: Int
        var i = 0
        var ok = true            // 형식이 틀리면 false → 그 줄은 JSONSerialization으로 다시 읽음
        private var first = false

        init(_ line: Line) { p = line.p; n = line.n }

        mutating func ws() {
            while i < n, p[i] == 0x20 || p[i] == 0x0A || p[i] == 0x0D || p[i] == 0x09 { i += 1 }
        }

        // 객체에 들어감. 객체가 아니면 그 값을 건너뛰고 false
        mutating func object() -> Bool {
            guard ok else { return false }
            ws()
            guard i < n, p[i] == 0x7B else { skip(); return false }
            i += 1
            first = true
            return true
        }

        // 다음 키. 객체가 끝나면 nil (값은 바로 읽거나 skip()으로 건너뛰어야 함)
        mutating func key() -> Str? {
            guard ok else { return nil }
            ws()
            guard i < n else { ok = false; return nil }
            if first {
                first = false
                if p[i] == 0x7D { i += 1; return nil }
            } else if p[i] == 0x2C {
                i += 1
                ws()
            } else {
                if p[i] == 0x7D { i += 1 } else { ok = false }
                return nil
            }
            guard i < n, p[i] == 0x22, let k = scanString() else { ok = false; return nil }
            ws()
            guard i < n, p[i] == 0x3A else { ok = false; return nil }
            i += 1
            return k
        }

        private mutating func scanString() -> Str? {
            let start = i + 1
            guard let end = stringEnd(start) else { return nil }
            i = end + 1
            return Str(start: start, end: end)
        }

        // 닫는 따옴표 위치 (앞의 \ 개수가 홀수면 글자 안의 따옴표)
        private func stringEnd(_ start: Int) -> Int? {
            var j = start
            while j < n, let q = memchr(p + j, 0x22, n - j) {
                let at = UnsafeRawPointer(p).distance(to: q)
                var k = at - 1
                while k >= start, p[k] == 0x5C { k -= 1 }
                if (at - 1 - k) % 2 == 0 { return at }
                j = at + 1
            }
            return nil
        }

        // 값 하나를 건너뜀
        mutating func skip() {
            ws()
            guard ok, i < n else { ok = false; return }
            let c = p[i]
            if c == 0x22 {
                guard let e = stringEnd(i + 1) else { ok = false; return }
                i = e + 1
            } else if c == 0x7B || c == 0x5B {
                var depth = 0
                while i < n {
                    let c = p[i]
                    if c == 0x22 {
                        guard let e = stringEnd(i + 1) else { ok = false; return }
                        i = e + 1
                        continue
                    }
                    if c == 0x7B || c == 0x5B {
                        depth += 1
                    } else if c == 0x7D || c == 0x5D {
                        depth -= 1
                        if depth == 0 { i += 1; return }
                    }
                    i += 1
                }
                ok = false
            } else {
                // 숫자·true·false·null
                let s = i
                while i < n, p[i] != 0x2C, p[i] != 0x7D, p[i] != 0x5D, p[i] != 0x20, p[i] != 0x0A, p[i] != 0x0D, p[i] != 0x09 { i += 1 }
                if i == s { ok = false }
            }
        }

        // 문자열 값 (문자열이 아니면 건너뛰고 nil)
        mutating func text() -> Str? {
            ws()
            if i < n, p[i] == 0x22 {
                if let s = scanString() { return s }
                ok = false
                return nil
            }
            skip()
            return nil
        }

        // 숫자 값 (NSNumber처럼 true는 1, 숫자가 아닌 값은 0)
        mutating func number() -> Double {
            ws()
            guard ok, i < n else { ok = false; return 0 }
            let c = p[i]
            guard c == 0x2D || (c >= 0x30 && c <= 0x39) else {
                skip()
                return c == 0x74 ? 1 : 0
            }
            let s = i
            var v = 0.0, plain = true
            while i < n {
                let d = p[i]
                if d >= 0x30 && d <= 0x39 {
                    v = v * 10 + Double(d - 0x30)
                } else if d == 0x2D || d == 0x2B || d == 0x2E || d == 0x65 || d == 0x45 {
                    plain = false
                } else {
                    break
                }
                i += 1
            }
            if plain, i - s <= 15 { return v }   // 정수는 그대로 (15자리까지는 정확함)
            let len = i - s
            return withUnsafeTemporaryAllocation(of: CChar.self, capacity: len + 1) { b in
                for k in 0..<len { b[k] = CChar(bitPattern: p[s + k]) }
                b[len] = 0
                return strtod(b.baseAddress!, nil)
            }
        }

        func eq(_ s: Str, _ k: StaticString) -> Bool {
            s.end - s.start == k.utf8CodeUnitCount && memcmp(p + s.start, k.utf8Start, k.utf8CodeUnitCount) == 0
        }

        // 글자로 (이스케이프가 있으면 JSONSerialization으로 풀어 예전과 같은 값을 냄)
        func string(_ s: Str) -> String {
            let len = s.end - s.start
            if memchr(p + s.start, 0x5C, len) == nil {
                return String(decoding: UnsafeRawBufferPointer(start: p + s.start, count: len), as: UTF8.self)
            }
            let raw = Data(bytes: p + s.start - 1, count: len + 2)
            return (try? JSONSerialization.jsonObject(with: raw, options: .fragmentsAllowed)) as? String ?? ""
        }

        func time(_ s: Str) -> Double? {
            let len = s.end - s.start
            if memchr(p + s.start, 0x5C, len) != nil { return LocalScan.time(string(s)) }
            return LocalScan.time(UnsafeRawBufferPointer(start: p + s.start, count: len))
        }
    }

    // 여러 파일 결과를 합침: 같은 ID는 한 번만, 작업 시간은 전체 기록 시각을 이어 붙여 계산
    // (세션을 이어 쓰면 이전 기록이 새 파일에 복사되므로 파일 간 중복 제거가 필요)
    static func combine(_ scans: [FileScan], hasCost: Bool) -> LocalStats {
        var days: [Int: DayStat] = [:], hours: [Int: DayStat] = [:]
        var models: [String: [Int: Agg]] = [:], projects: [String: [Int: Agg]] = [:]
        var seen = Set<UInt64>()
        var times: [Double] = []
        times.reserveCapacity(scans.reduce(0) { $0 + $1.times.count })
        for s in scans {
            for e in s.entries {
                if e.id != 0 { guard seen.insert(e.id).inserted else { continue } }
                let day = e.hour / 100
                func addDay(_ d: inout DayStat) {
                    d.tokens += e.tokens; d.cost += e.cost; d.saved += e.saved
                    d.cacheRead += e.cacheRead; d.inputAll += e.inputAll
                }
                func addHour(_ h: inout DayStat) { h.tokens += e.tokens; h.cost += e.cost }
                func addAgg(_ a: inout Agg) { a.tokens += e.tokens; a.cost += e.cost }
                addDay(&days[day, default: DayStat()])
                addHour(&hours[e.hour, default: DayStat()])
                if !e.model.isEmpty { addAgg(&models[e.model, default: [:]][day, default: Agg()]) }
                if !e.project.isEmpty { addAgg(&projects[e.project, default: [:]][day, default: Agg()]) }
            }
            times.append(contentsOf: s.times)
        }
        // 5분 이내 간격만 이어서 작업 시간으로 계산 (동시에 돌린 세션은 한 번만 셈, 같은 시각은 간격 0이라 건너뜀)
        times.sort()
        var finder = DayFinder()
        for (a, b) in zip(times, times.dropFirst()) {
            let gap = b - a
            if gap > 0, gap <= 300 { days[finder.day(b), default: DayStat()].seconds += gap }
        }
        var stats = LocalStats()
        stats.hasCost = hasCost
        for (k, v) in days { stats.days[LocalTime.key(day: k)] = v }
        for (k, v) in hours { stats.hours[LocalTime.key(hour: k)] = v }
        for (name, t) in models { stats.models[name] = Dictionary(uniqueKeysWithValues: t.map { (LocalTime.key(day: $0.key), $0.value) }) }
        for (name, t) in projects { stats.projects[name] = Dictionary(uniqueKeysWithValues: t.map { (LocalTime.key(day: $0.key), $0.value) }) }
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

    static func readClaude(_ scan: inout FileScan, _ line: Line) {
        var c = Cursor(line)
        var ts: Cursor.Str?, type: Cursor.Str?, rid: Cursor.Str?, cwd: Cursor.Str?, mid: Cursor.Str?, model: Cursor.Str?
        var message = false, usage = false
        var input = 0.0, output = 0.0, write = 0.0, read = 0.0, write1h = 0.0
        if c.object() {
            while let k = c.key() {
                if c.eq(k, "timestamp") { ts = c.text() }
                else if c.eq(k, "type") { type = c.text() }
                else if c.eq(k, "requestId") { rid = c.text() }
                else if c.eq(k, "cwd") { cwd = c.text() }
                else if c.eq(k, "message") {
                    guard c.object() else { continue }
                    message = true
                    while let k = c.key() {
                        if c.eq(k, "id") { mid = c.text() }
                        else if c.eq(k, "model") { model = c.text() }
                        else if c.eq(k, "usage") {
                            guard c.object() else { continue }
                            usage = true
                            while let k = c.key() {
                                if c.eq(k, "input_tokens") { input = c.number() }
                                else if c.eq(k, "output_tokens") { output = c.number() }
                                else if c.eq(k, "cache_creation_input_tokens") { write = c.number() }
                                else if c.eq(k, "cache_read_input_tokens") { read = c.number() }
                                else if c.eq(k, "cache_creation") {
                                    guard c.object() else { continue }
                                    while let k = c.key() {
                                        if c.eq(k, "ephemeral_1h_input_tokens") { write1h = c.number() } else { c.skip() }
                                    }
                                } else { c.skip() }
                            }
                        } else { c.skip() }
                    }
                } else { c.skip() }
            }
        } else {
            c.ok = false
        }
        // 형식을 못 읽은 줄(깨진 줄 등)은 예전 방식 그대로
        guard c.ok else { readClaudeSlow(&scan, line); return }
        guard let ts else {
            // 맨 위에 시각이 없는 줄(파일 기록 스냅숏 등)은 안쪽 시각을 씀 (예전과 같게)
            if !(line.has("\"usage\"") && line.has("\"assistant\"")), let t = line.timestamp(last: true) { scan.addTime(t) }
            return
        }
        guard let t = c.time(ts) else { return }
        scan.addTime(t)
        guard let type, c.eq(type, "assistant"), message, usage, let model else { return }
        let name = c.string(model)
        guard name.hasPrefix("claude") else { return }
        scan.entries.append(claudeEntry(name, id: idHash(mid.map { c.string($0) } ?? "", rid.map { c.string($0) } ?? ""),
                                        cwd: cwd.map { c.string($0) }, time: t,
                                        input: input, output: output, write: write, read: read, write1h: write1h))
    }

    // JSONSerialization으로 읽는 예전 방식 (빠른 읽기가 실패한 줄만)
    static func readClaudeSlow(_ scan: inout FileScan, _ line: Line) {
        // 사용량이 적힌 응답 줄이 아니면 시각만 (최상위 timestamp는 줄 끝 쪽에 있음)
        guard line.has("\"usage\""), line.has("\"assistant\"") else {
            if let t = line.timestamp(last: true) { scan.addTime(t) }
            return
        }
        guard let obj = line.json, let t = time(obj["timestamp"]) else { return }
        scan.addTime(t)
        guard obj["type"] as? String == "assistant",
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any],
              let model = msg["model"] as? String, model.hasPrefix("claude") else { return }
        func n(_ k: String) -> Double { (usage[k] as? NSNumber)?.doubleValue ?? 0 }
        let cc = usage["cache_creation"] as? [String: Any]
        scan.entries.append(claudeEntry(model, id: idHash(msg["id"] as? String ?? "", obj["requestId"] as? String ?? ""),
                                        cwd: obj["cwd"] as? String, time: t,
                                        input: n("input_tokens"), output: n("output_tokens"),
                                        write: n("cache_creation_input_tokens"), read: n("cache_read_input_tokens"),
                                        write1h: (cc?["ephemeral_1h_input_tokens"] as? NSNumber)?.doubleValue ?? 0))
    }

    // 같은 응답이 여러 줄·여러 파일에 기록되므로 메시지 ID로 중복 제거
    static func claudeEntry(_ model: String, id: UInt64, cwd: String?, time t: Double,
                            input: Double, output: Double, write: Double, read: Double, write1h: Double) -> UsageEntry {
        let write5m = max(0, write - write1h)
        let p = claudePrices.first { model.hasPrefix($0.prefix) } ?? ("", 4, 20, 0.20)
        var e = UsageEntry(id: id, hour: LocalTime.hour(t))
        e.tokens = input + output + write + read
        e.cost = (input * p.input + output * p.output + read * p.read
                  + write5m * p.input * 1.25 + write1h * p.input * 2) / 1_000_000
        e.saved = read * (p.input - p.read) / 1_000_000
        e.cacheRead = read
        e.inputAll = input + write + read
        e.model = own(model)
        e.project = own(cwd.map(projectName) ?? "")
        return e
    }

    static func claude() -> LocalStats {
        let root = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? (NSHomeDirectory() + "/.claude")
        return combineIfChanged("claude", recentFiles(in: [root + "/projects"]), readClaude, hasCost: true)
    }

    // MARK: Codex

    static func readCodex(_ scan: inout FileScan, _ line: Line) {
        // 사용량·세션 정보·턴 정보 줄이 아니면 시각만 (Codex는 timestamp가 줄 맨 앞)
        // 종류는 줄 앞부분에 적혀 있으므로 앞 200바이트만 봄 (뒤쪽은 큰 출력이 대부분)
        guard line.has("\"token_count\"", within: 200) || line.has("\"session_meta\"", within: 200)
                || line.has("\"turn_context\"", within: 200) else {
            if let t = line.timestamp(last: false) { scan.addTime(t) }
            return
        }
        var c = Cursor(line)
        var ts: Cursor.Str?, type: Cursor.Str?, ptype: Cursor.Str?, model: Cursor.Str?, cwd: Cursor.Str?
        var payload = false, info = false, total = false, last = false
        var totalTokens = 0.0, input = 0.0, output = 0.0, cached = 0.0
        if c.object() {
            while let k = c.key() {
                if c.eq(k, "timestamp") { ts = c.text() }
                else if c.eq(k, "type") { type = c.text() }
                else if c.eq(k, "payload") {
                    guard c.object() else { continue }
                    payload = true
                    while let k = c.key() {
                        if c.eq(k, "type") { ptype = c.text() }
                        else if c.eq(k, "model") { model = c.text() }
                        else if c.eq(k, "cwd") { cwd = c.text() }
                        else if c.eq(k, "info") {
                            guard c.object() else { continue }
                            info = true
                            while let k = c.key() {
                                if c.eq(k, "total_token_usage") {
                                    guard c.object() else { continue }
                                    total = true
                                    while let k = c.key() {
                                        if c.eq(k, "total_tokens") { totalTokens = c.number() } else { c.skip() }
                                    }
                                } else if c.eq(k, "last_token_usage") {
                                    guard c.object() else { continue }
                                    last = true
                                    while let k = c.key() {
                                        if c.eq(k, "input_tokens") { input = c.number() }
                                        else if c.eq(k, "output_tokens") { output = c.number() }
                                        else if c.eq(k, "cached_input_tokens") { cached = c.number() }
                                        else { c.skip() }
                                    }
                                } else { c.skip() }
                            }
                        } else { c.skip() }
                    }
                } else { c.skip() }
            }
        } else {
            c.ok = false
        }
        guard c.ok else { readCodexSlow(&scan, line); return }
        guard let ts, let t = c.time(ts) else { return }
        scan.addTime(t)
        // 세션 정보·턴 정보에서 현재 모델과 작업 폴더를 기억
        if payload, let type, c.eq(type, "session_meta") || c.eq(type, "turn_context") {
            if let model { scan.model = c.string(model) }
            if let cwd { scan.project = projectName(c.string(cwd)) }
        }
        guard payload, let ptype, c.eq(ptype, "token_count"), info, total, last else { return }
        addCodex(&scan, ts: c.string(ts), total: totalTokens, input: input, output: output, cached: cached, time: t)
    }

    // JSONSerialization으로 읽는 예전 방식 (빠른 읽기가 실패한 줄만)
    static func readCodexSlow(_ scan: inout FileScan, _ line: Line) {
        guard let obj = line.json, let t = time(obj["timestamp"]) else { return }
        scan.addTime(t)
        if let type = obj["type"] as? String, type == "session_meta" || type == "turn_context",
           let pl = obj["payload"] as? [String: Any] {
            if let m = pl["model"] as? String { scan.model = m }
            if let c = pl["cwd"] as? String { scan.project = projectName(c) }
        }
        guard let payload = obj["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let total = info["total_token_usage"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any] else { return }
        func n(_ k: String) -> Double { (last[k] as? NSNumber)?.doubleValue ?? 0 }
        addCodex(&scan, ts: obj["timestamp"] as? String ?? "", total: (total["total_tokens"] as? NSNumber)?.doubleValue ?? 0,
                 input: n("input_tokens"), output: n("output_tokens"), cached: n("cached_input_tokens"), time: t)
    }

    static func addCodex(_ scan: inout FileScan, ts: String, total: Double, input: Double, output: Double, cached: Double, time t: Double) {
        // 누적값이 늘었을 때만 새 사용으로 봄 (같은 이벤트가 반복 기록됨)
        guard total > scan.lastTotal else { return }
        scan.lastTotal = total
        // 이어 쓴 세션이 복사돼도 한 번만 세도록 시각+누적값으로 ID를 만듦
        var e = UsageEntry(id: idHash(ts, String(Int(total))), hour: LocalTime.hour(t))
        e.tokens = input + output
        e.cacheRead = cached
        e.inputAll = input
        e.model = own(scan.model)
        e.project = own(scan.project)
        scan.entries.append(e)
    }

    static func codex() -> LocalStats {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? (NSHomeDirectory() + "/.codex")
        return combineIfChanged("codex", recentFiles(in: [home + "/sessions", home + "/archived_sessions"]), readCodex, hasCost: false)
    }
}
