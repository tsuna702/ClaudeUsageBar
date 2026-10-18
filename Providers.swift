import Foundation
import Security

// Claude·Codex 외 서비스의 사용량 가져오기
// 대부분 공식 문서가 없는 내부 API라 서비스가 바뀌면 동작하지 않을 수 있음

typealias FetchDone = (Quota?, String?, LocalStats?) -> Void

enum ProviderFetch {
    static func fetch(_ p: Provider, _ done: @escaping FetchDone) {
        switch p {
        case .claude: ClaudeAPI.fetch { q, e in done(q, e, nil) }
        case .codex: CodexAPI.fetch { q, e in done(q, e, nil) }
        case .gemini: GeminiAPI.fetch(done)
        case .antigravity: AntigravityAPI.fetch(done)
        case .cursor: CursorAPI.fetch(done)
        case .grok: GrokAPI.fetch(done)
        case .openai: OpenAIAdminAPI.fetch(done)
        case .cloudflare: CloudflareAPI.fetch(done)
        }
    }
}

// MARK: - 공통 도우미

enum Net {
    // 동기 요청 (백그라운드에서만 호출)
    static func request(_ req: URLRequest, session: URLSession = .shared) -> (Int, Data?, String?) {
        var out: (Int, Data?, String?) = (0, nil, nil)
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { data, resp, err in
            out = ((resp as? HTTPURLResponse)?.statusCode ?? 0, data, err?.localizedDescription)
            sem.signal()
        }.resume()
        sem.wait()
        return out
    }

    static func json(_ data: Data?) -> [String: Any]? {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static func post(_ url: String, token: String, body: [String: Any]) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        r.timeoutInterval = 20
        return r
    }

    static func httpError(_ code: Int, _ err: String?) -> String {
        if let err { return err }
        if code == 401 || code == 403 { return L("인증 실패 — 다시 로그인해 주세요", "Auth failed — sign in again") }
        return "HTTP \(code)"
    }

    // JWT 본문(payload) 읽기
    static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        return Data(base64Encoded: b64).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    static func run(_ exe: String, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) }
}

// MARK: - API 키 보관 (앱 전용 키체인 항목)

enum KeyStore {
    static let service = "UsageBar API key"

    static func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: name]
    }

    static func get(_ name: String) -> String? {
        var q = query(name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        let s = String(decoding: d, as: UTF8.self)
        return s.isEmpty ? nil : s
    }

    static func set(_ name: String, _ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { SecItemDelete(query(name) as CFDictionary); return }
        let data = Data(trimmed.utf8)
        if SecItemUpdate(query(name) as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var add = query(name)
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}

// MARK: - Gemini (Gemini CLI 로그인 → Code Assist 할당량 API)

enum GeminiAPI {
    static var home: String { NSHomeDirectory() + "/.gemini" }
    static var credsPath: String { home + "/oauth_creds.json" }
    static let base = "https://cloudcode-pa.googleapis.com/v1internal"

    static func readCreds() -> [String: Any]? {
        FileManager.default.contents(atPath: credsPath).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    // Gemini CLI에 들어 있는 OAuth 클라이언트 값 (토큰 갱신에 필요)
    static func cliOAuthClient() -> (id: String, secret: String)? {
        guard let bin = LoginHelper.cliPath(.gemini) else { return nil }
        var dir = URL(fileURLWithPath: bin).resolvingSymlinksInPath().deletingLastPathComponent()
        let rel = "node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js"
        for _ in 0..<8 {
            for cand in [dir.appendingPathComponent(rel), dir.appendingPathComponent("../gemini-cli-core/dist/src/code_assist/oauth2.js")] {
                if let js = try? String(contentsOf: cand, encoding: .utf8),
                   let id = match(js, "OAUTH_CLIENT_ID\\s*=\\s*['\"]([^'\"]+)['\"]"),
                   let secret = match(js, "OAUTH_CLIENT_SECRET\\s*=\\s*['\"]([^'\"]+)['\"]") {
                    return (id, secret)
                }
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    static func match(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    // 만료됐으면 갱신해서 파일에 다시 저장 (Gemini CLI가 하는 것과 같은 방식)
    static func accessToken() -> String? {
        guard var creds = readCreds(), let token = creds["access_token"] as? String else { return nil }
        let expiry = (Net.number(creds["expiry_date"]) ?? 0) / 1000
        if expiry > Date().timeIntervalSince1970 + 60 { return token }
        guard let refresh = creds["refresh_token"] as? String, let client = cliOAuthClient() else { return token }
        var r = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        r.httpBody = "client_id=\(enc(client.id))&client_secret=\(enc(client.secret))&refresh_token=\(enc(refresh))&grant_type=refresh_token".data(using: .utf8)
        let (code, data, _) = Net.request(r)
        guard code == 200, let j = Net.json(data), let fresh = j["access_token"] as? String else { return token }
        creds["access_token"] = fresh
        if let exp = Net.number(j["expires_in"]) { creds["expiry_date"] = (Date().timeIntervalSince1970 + exp) * 1000 }
        if let id = j["id_token"] as? String { creds["id_token"] = id }
        if let out = try? JSONSerialization.data(withJSONObject: creds, options: [.prettyPrinted]) {
            try? out.write(to: URL(fileURLWithPath: credsPath), options: .atomic)
        }
        return fresh
    }

    static func fetch(_ done: @escaping FetchDone) {
        guard readCreds() != nil else { done(nil, L("Gemini CLI 로그인 정보를 찾을 수 없어요", "Gemini CLI login not found"), nil); return }
        guard let token = accessToken() else { done(nil, L("Gemini 토큰이 없어요", "No Gemini token"), nil); return }

        // 프로젝트와 요금제 확인
        let (c1, d1, e1) = Net.request(Net.post(base + ":loadCodeAssist", token: token,
                                                body: ["metadata": ["ideType": "GEMINI_CLI", "pluginType": "GEMINI"]]))
        guard c1 == 200, let load = Net.json(d1) else { done(nil, Net.httpError(c1, e1), nil); return }
        let project = (load["cloudaicompanionProject"] as? String)
            ?? ((load["cloudaicompanionProject"] as? [String: Any])?["id"] as? String)
        let tier = ((load["currentTier"] as? [String: Any])?["id"] as? String) ?? ""

        let (c2, d2, e2) = Net.request(Net.post(base + ":retrieveUserQuota", token: token,
                                                body: project.map { ["project": $0] } ?? [:]))
        guard c2 == 200, let quota = Net.json(d2) else { done(nil, Net.httpError(c2, e2), nil); return }

        // 모델별 남은 비율 중 가장 적은 값을 Pro / Flash로 묶음
        var pro: (Double, Date?)?, flash: (Double, Date?)?
        var q = Quota()
        for b in (quota["buckets"] as? [[String: Any]]) ?? [] {
            guard let frac = Net.number(b["remainingFraction"]) else { continue }
            let model = (b["modelId"] as? String) ?? ""
            let reset = parseISO(b["resetTime"] as? String)
            let used = max(0, min(100, (1 - frac) * 100))
            if model.contains("flash") {
                if flash == nil || used > flash!.0 { flash = (used, reset) }
            } else if pro == nil || used > pro!.0 { pro = (used, reset) }
            q.extras2.append((model, String(format: L("%.0f%% 남음", "%.0f%% left"), frac * 100)))
        }
        if let pro { q.session = Bucket(percent: pro.0, resetsAt: pro.1, label: "Pro", short: "Pro", window: 86400) }
        if let flash { q.weekly = Bucket(percent: flash.0, resetsAt: flash.1, label: "Flash", short: "Flash", window: 86400) }
        q.plan = tier.replacingOccurrences(of: "-tier", with: "")
        q.email = (readCreds()?["id_token"] as? String).flatMap(Net.jwtPayload)?["email"] as? String
        done(q, nil, nil)
    }
}

// MARK: - Antigravity (앱 안의 로컬 language server에 질의)

final class LocalTLSDelegate: NSObject, URLSessionDelegate {
    // 127.0.0.1의 자체 서명 인증서만 허용
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.host == "127.0.0.1", let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

enum AntigravityAPI {
    static let session = URLSession(configuration: .ephemeral, delegate: LocalTLSDelegate(), delegateQueue: nil)

    // 실행 중인 language_server의 PID·CSRF 토큰·포트
    static func discover() -> (csrf: String, ports: [Int])? {
        let (_, ps) = Net.run("/bin/ps", ["-axo", "pid=,command="])
        for line in ps.split(separator: "\n") where line.contains("language_server") && line.contains("--csrf_token") && !line.contains("multicall") {
            let t = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let pid = t.first, let i = t.firstIndex(of: "--csrf_token"), i + 1 < t.count else { continue }
            let (_, lsof) = Net.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", pid])
            var ports = Set<Int>()
            for l in lsof.split(separator: "\n") {
                if let r = l.range(of: #":(\d+) \(LISTEN\)"#, options: .regularExpression),
                   let n = Int(l[r].dropFirst().split(separator: " ").first ?? "") { ports.insert(n) }
            }
            if !ports.isEmpty { return (t[i + 1], ports.sorted(by: >)) }
        }
        return nil
    }

    static func call(_ ep: (csrf: String, ports: [Int]), _ method: String, _ body: [String: Any]) -> [String: Any]? {
        for port in ep.ports {
            for scheme in ["http", "https"] {
                var r = URLRequest(url: URL(string: "\(scheme)://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/\(method)")!)
                r.httpMethod = "POST"
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                r.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
                r.setValue(ep.csrf, forHTTPHeaderField: "x-codeium-csrf-token")
                r.httpBody = try? JSONSerialization.data(withJSONObject: body)
                r.timeoutInterval = 5
                let (code, data, _) = Net.request(r, session: session)
                if (200..<300).contains(code), let j = Net.json(data) { return j }
            }
        }
        return nil
    }

    static func fetch(_ done: @escaping FetchDone) {
        guard let ep = discover() else {
            done(nil, L("Antigravity를 실행해 주세요", "Open Antigravity first"), nil)
            return
        }
        var q = Quota()
        if let root = call(ep, "RetrieveUserQuotaSummary", ["forceRefresh": true]) {
            let resp = (root["response"] as? [String: Any]) ?? root
            var short: Bucket?, long: Bucket?
            for g in (resp["groups"] as? [[String: Any]]) ?? [] {
                let name = (g["displayName"] as? String) ?? "?"
                for b in (g["buckets"] as? [[String: Any]]) ?? [] {
                    // 0이면 필드가 빠지므로, 비율이 없는 버킷은 건너뜀
                    guard let frac = Net.number(b["remainingFraction"]) else { continue }
                    let w = (b["window"] as? String) ?? ""
                    let id = (b["bucketId"] as? String) ?? ""
                    let weekly = w == "weekly" || id.hasSuffix("-weekly")
                    let bucket = Bucket(percent: max(0, min(100, (1 - frac) * 100)), resetsAt: parseISO(b["resetTime"] as? String),
                                        label: "\(name) · \(weekly ? L("주간", "weekly") : "5h")",
                                        short: weekly ? "7d" : "5h", window: weekly ? 7 * 86400 : 5 * 3600)
                    q.extras.append((bucket.label!, bucket))
                    if weekly { if long == nil || bucket.percent > long!.percent { long = bucket } }
                    else if short == nil || bucket.percent > short!.percent { short = bucket }
                }
            }
            q.session = short.map { Bucket(percent: $0.percent, resetsAt: $0.resetsAt, window: 5 * 3600) }
            q.weekly = long.map { Bucket(percent: $0.percent, resetsAt: $0.resetsAt, window: 7 * 86400) }
        }
        // 예전 버전: 모델별 할당량
        if q.session == nil, let root = call(ep, "GetCascadeModelConfigData", [:]) {
            let container = ((root["userStatus"] as? [String: Any])?["cascadeModelConfigData"] as? [String: Any]) ?? root
            for m in (container["clientModelConfigs"] as? [[String: Any]]) ?? [] {
                guard let label = m["label"] as? String, let qi = m["quotaInfo"] as? [String: Any],
                      let frac = Net.number(qi["remainingFraction"]) else { continue }
                let b = Bucket(percent: max(0, min(100, (1 - frac) * 100)), resetsAt: parseISO(qi["resetTime"] as? String), label: label)
                q.extras.append((label, b))
                if q.session == nil || b.percent > q.session!.percent { q.session = b }
            }
        }
        guard q.session != nil || q.weekly != nil else {
            done(nil, L("할당량 정보를 받지 못했어요", "No quota data received"), nil)
            return
        }
        done(q, nil, nil)
    }
}

// MARK: - Cursor (Cursor 앱 로그인 토큰 → cursor.com 사용량 API)

enum CursorAPI {
    static var dbPath: String { NSHomeDirectory() + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb" }

    static func value(_ key: String) -> String? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        let uri = "file:" + (dbPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? dbPath) + "?immutable=1"
        let (code, out) = Net.run("/usr/bin/sqlite3", ["-readonly", uri, "select value from ItemTable where key='\(key)'"])
        let v = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return code == 0 && !v.isEmpty ? v : nil
    }

    static func get(_ path: String, cookie: String) -> (Int, [String: Any]?, String?) {
        var r = URLRequest(url: URL(string: "https://cursor.com" + path)!)
        r.setValue(cookie, forHTTPHeaderField: "Cookie")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.timeoutInterval = 20
        let (code, data, err) = Net.request(r)
        return (code, Net.json(data), err)
    }

    static func fetch(_ done: @escaping FetchDone) {
        guard let token = value("cursorAuth/accessToken") else {
            done(nil, L("Cursor 앱에 로그인해 주세요", "Sign in to the Cursor app"), nil)
            return
        }
        let sub = (Net.jwtPayload(token)?["sub"] as? String) ?? ""
        let userID = sub.split(separator: "|").last.map(String.init) ?? sub
        let cookie = "WorkosCursorSessionToken=\(userID)%3A%3A\(token)"
        let (code, s, err) = get("/api/usage-summary", cookie: cookie)
        guard code == 200, let s else { done(nil, Net.httpError(code, err), nil); return }

        var q = Quota()
        let start = parseISO(s["billingCycleStart"] as? String), end = parseISO(s["billingCycleEnd"] as? String)
        let window = (start != nil && end != nil) ? end!.timeIntervalSince(start!) : 30 * 86400
        let ind = s["individualUsage"] as? [String: Any]
        let plan = ind?["plan"] as? [String: Any]
        let overall = ind?["overall"] as? [String: Any]
        // 금액은 센트 단위
        let usedC = Net.number(plan?["used"]) ?? Net.number(overall?["used"]) ?? 0
        let limitC = Net.number(plan?["limit"]) ?? Net.number(overall?["limit"]) ?? 0
        let pct = Net.number(plan?["totalPercentUsed"]) ?? (limitC > 0 ? usedC / limitC * 100 : nil)
        if let pct {
            q.session = Bucket(percent: min(100, pct), resetsAt: end, label: L("요금제 사용량", "Plan usage"),
                               short: L("월", "mo"), window: window)
        }
        if let od = ind?["onDemand"] as? [String: Any], let lim = Net.number(od["limit"]), lim > 0 {
            let used = Net.number(od["used"]) ?? 0
            q.weekly = Bucket(percent: min(100, used / lim * 100), resetsAt: end, label: L("추가 사용 (On-demand)", "On-demand"),
                              short: "OD", window: window)
            q.extras2.append((L("추가 사용 금액", "On-demand spend"), String(format: "$%.2f / $%.2f", used / 100, lim / 100)))
        }
        if limitC > 0 { q.extras2.append((L("요금제 포함 금액", "Included in plan"), String(format: "$%.2f / $%.2f", usedC / 100, limitC / 100))) }
        if let a = Net.number(plan?["autoPercentUsed"]) { q.extras2.append(("Auto", String(format: "%.0f%%", a))) }
        if let a = Net.number(plan?["apiPercentUsed"]) { q.extras2.append(("API", String(format: "%.0f%%", a))) }
        q.plan = s["membershipType"] as? String
        if q.session == nil { q.headline = String(format: "$%.2f", usedC / 100) }
        q.email = value("cursorAuth/cachedEmail") ?? (get("/api/auth/me", cookie: cookie).1?["email"] as? String)
        done(q, nil, nil)
    }
}

// MARK: - Grok (grok CLI의 ACP 서버에 결제 정보 질의)

enum GrokAPI {
    static var home: String { ProcessInfo.processInfo.environment["GROK_HOME"] ?? NSHomeDirectory() + "/.grok" }
    static var authPath: String { home + "/auth.json" }

    // auth.json에서 이메일 (OIDC 항목 우선)
    static func email() -> String? {
        guard let data = FileManager.default.contents(atPath: authPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let entries = root.sorted { a, _ in a.key.hasPrefix("https://auth.x.ai") }.compactMap { $0.value as? [String: Any] }
        return entries.lazy.compactMap { $0["email"] as? String }.first
    }

    // `grok agent stdio`를 잠깐 띄워 JSON-RPC로 initialize → x.ai/billing
    static func billing(_ cli: String) -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = ["agent", "stdio"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        defer { p.terminate() }

        var buffer = Data()
        var responses: [Int: [String: Any]] = [:]
        let lock = NSLock()
        let got = DispatchSemaphore(value: 0)
        output.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            if chunk.isEmpty { return }
            lock.lock(); buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if let j = try? JSONSerialization.jsonObject(with: line) as? [String: Any], let id = j["id"] as? Int {
                    responses[id] = j
                    got.signal()
                }
            }
            lock.unlock()
        }
        defer { output.fileHandleForReading.readabilityHandler = nil }

        func send(_ id: Int, _ method: String, _ params: [String: Any]) {
            let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
            guard let raw = try? JSONSerialization.data(withJSONObject: payload) else { return }
            // "/"가 "\/"로 바뀌면 메서드 이름이 달라져서 원래대로 되돌림
            var d = Data(String(decoding: raw, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/").utf8)
            d.append(0x0A)
            input.fileHandleForWriting.write(d)
        }
        func wait(_ id: Int, _ seconds: Double) -> [String: Any]? {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                lock.lock(); let r = responses[id]; lock.unlock()
                if let r { return r }
                _ = got.wait(timeout: .now() + 0.2)
            }
            return nil
        }
        send(1, "initialize", ["protocolVersion": "1",
                               "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false]])
        guard wait(1, 6) != nil else { return nil }
        send(2, "x.ai/billing", [:])
        return wait(2, 6)?["result"] as? [String: Any]
    }

    static func fetch(_ done: @escaping FetchDone) {
        guard let cli = LoginHelper.cliPath(.grok) else { done(nil, L("grok CLI를 설치해 주세요", "Install the grok CLI"), nil); return }
        guard FileManager.default.fileExists(atPath: authPath) else { done(nil, L("grok login으로 로그인해 주세요", "Run grok login"), nil); return }
        guard let b = billing(cli) else { done(nil, L("Grok 결제 정보를 받지 못했어요", "Could not read Grok billing"), nil); return }
        func cents(_ v: Any?) -> Double? { Net.number((v as? [String: Any])?["val"]) }
        let usage = b["usage"] as? [String: Any]
        let cycle = b["billingCycle"] as? [String: Any]
        let start = parseISO(cycle?["billingPeriodStart"] as? String), end = parseISO(cycle?["billingPeriodEnd"] as? String)
        var q = Quota()
        let used = cents(usage?["totalUsed"]) ?? 0
        if let limit = cents(b["monthlyLimit"]), limit > 0 {
            q.session = Bucket(percent: min(100, used / limit * 100), resetsAt: end, label: L("이번 달 사용량", "This month"),
                               short: L("월", "mo"), window: (start != nil && end != nil) ? end!.timeIntervalSince(start!) : 30 * 86400)
            q.extras2.append((L("사용 / 한도", "Used / limit"), String(format: "$%.2f / $%.2f", used / 100, limit / 100)))
        } else {
            q.headline = String(format: "$%.2f", used / 100)
        }
        if let v = cents(usage?["includedUsed"]) { q.extras2.append((L("포함 사용량", "Included used"), String(format: "$%.2f", v / 100))) }
        if let v = cents(usage?["onDemandUsed"]) { q.extras2.append((L("추가 사용량", "On-demand used"), String(format: "$%.2f", v / 100))) }
        q.email = email()
        done(q, nil, nil)
    }
}

// MARK: - OpenAI API (공식 Admin API: 비용·사용량)

enum OpenAIAdminAPI {
    static let budgetKey = "openai_budget"

    static func get(_ path: String, key: String) -> (Int, [String: Any]?, String?) {
        var r = URLRequest(url: URL(string: "https://api.openai.com/v1" + path)!)
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 30
        let (code, data, err) = Net.request(r)
        return (code, Net.json(data), err)
    }

    static func fetch(_ done: @escaping FetchDone) {
        guard let key = KeyStore.get(Provider.openai.rawValue) else {
            done(nil, L("설정에서 Admin API 키를 넣어 주세요", "Add an Admin API key in Settings"), nil)
            return
        }
        let today = Calendar.current.startOfDay(for: Date())
        let start = Int(Calendar.current.date(byAdding: .day, value: -29, to: today)!.timeIntervalSince1970)
        var stats = LocalStats()
        stats.hasCost = true

        // 일별 비용
        let (c1, costs, e1) = get("/organization/costs?start_time=\(start)&bucket_width=1d&limit=31", key: key)
        guard c1 == 200, let costs else { done(nil, Net.httpError(c1, e1), nil); return }
        for b in (costs["data"] as? [[String: Any]]) ?? [] {
            guard let t = Net.number(b["start_time"]) else { continue }
            let total = ((b["results"] as? [[String: Any]]) ?? []).reduce(0.0) {
                $0 + (Net.number(($1["amount"] as? [String: Any])?["value"]) ?? 0)
            }
            stats.add(Date(timeIntervalSince1970: t)) { $0.cost += total }
        }
        // 일별 · 모델별 토큰
        let (c2, usage, _) = get("/organization/usage/completions?start_time=\(start)&bucket_width=1d&limit=31&group_by=model", key: key)
        if c2 == 200, let usage {
            for b in (usage["data"] as? [[String: Any]]) ?? [] {
                guard let t = Net.number(b["start_time"]) else { continue }
                let date = Date(timeIntervalSince1970: t), dk = LocalStats.key(date)
                for r in (b["results"] as? [[String: Any]]) ?? [] {
                    let input = Net.number(r["input_tokens"]) ?? 0, output = Net.number(r["output_tokens"]) ?? 0
                    let cached = Net.number(r["input_cached_tokens"]) ?? 0
                    stats.add(date) { $0.tokens += input + output; $0.cacheRead += cached; $0.inputAll += input }
                    if let m = r["model"] as? String {
                        var a = stats.models[m, default: [:]][dk] ?? Agg()
                        a.tokens += input + output
                        stats.models[m, default: [:]][dk] = a
                    }
                }
            }
        }

        // 이번 달 비용과 (설정한 경우) 월 예산 대비 %
        let monthStart = Calendar.current.dateInterval(of: .month, for: Date())!
        let month = stats.days.filter { (LocalStats.keyFormatter.date(from: $0.key) ?? .distantPast) >= monthStart.start }
            .reduce(0.0) { $0 + $1.value.cost }
        var q = Quota()
        q.headline = String(format: "$%.2f", month)
        let budget = UserDefaults.standard.double(forKey: budgetKey)
        if budget > 0 {
            q.session = Bucket(percent: min(100, month / budget * 100), resetsAt: monthStart.end,
                               label: L("월 예산", "Monthly budget"), short: L("월", "mo"), window: monthStart.duration)
        }
        q.extras2 = [(L("이번 달 비용", "This month"), String(format: "$%.2f", month)),
                     (L("오늘 비용", "Today"), String(format: "$%.2f", stats.day(offset: 0).cost)),
                     (L("최근 30일", "Last 30 days"), String(format: "$%.2f", stats.days.values.reduce(0) { $0 + $1.cost }))]
        if budget > 0 { q.extras2.append((L("월 예산", "Monthly budget"), String(format: "$%.2f", budget))) }
        done(q, nil, stats)
    }
}

// MARK: - Cloudflare Workers AI (공식 GraphQL Analytics API)

enum CloudflareAPI {
    static let accountKey = "cloudflare_account"
    static let freeNeurons = 10_000.0      // 하루 무료 할당량
    static let pricePer1k = 0.011          // 무료량을 넘긴 1,000 neurons당 (Workers Paid)

    static func fetch(_ done: @escaping FetchDone) {
        guard let token = KeyStore.get(Provider.cloudflare.rawValue),
              let account = UserDefaults.standard.string(forKey: accountKey), !account.isEmpty else {
            done(nil, L("설정에서 API 토큰과 계정 ID를 넣어 주세요", "Add an API token and account ID in Settings"), nil)
            return
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let todayUTC = utc.startOfDay(for: Date())
        let start = utc.date(byAdding: .day, value: -29, to: todayUTC)!
        let iso = ISO8601DateFormatter()
        let query = """
        query($account: string!, $start: Time!, $end: Time!) {
          viewer { accounts(filter: {accountTag: $account}) {
            aiInferenceAdaptiveGroups(limit: 10000, filter: {datetime_geq: $start, datetime_leq: $end}) {
              sum { totalNeurons totalInputTokens totalOutputTokens }
              dimensions { date modelId }
            }
          } }
        }
        """
        let body: [String: Any] = ["query": query,
                                   "variables": ["account": account, "start": iso.string(from: start), "end": iso.string(from: Date())]]
        let (code, data, err) = Net.request(Net.post("https://api.cloudflare.com/client/v4/graphql", token: token, body: body))
        guard code == 200, let root = Net.json(data) else { done(nil, Net.httpError(code, err), nil); return }
        if let errs = root["errors"] as? [[String: Any]], let msg = errs.first?["message"] as? String {
            done(nil, msg, nil)
            return
        }
        let accounts = ((root["data"] as? [String: Any])?["viewer"] as? [String: Any])?["accounts"] as? [[String: Any]]
        let rows = (accounts?.first?["aiInferenceAdaptiveGroups"] as? [[String: Any]]) ?? []

        var stats = LocalStats()
        stats.hasCost = true
        var neuronsByDay: [String: Double] = [:]
        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "yyyy-MM-dd"
        dayFmt.timeZone = TimeZone(identifier: "UTC")
        for r in rows {
            let sum = r["sum"] as? [String: Any], dim = r["dimensions"] as? [String: Any]
            guard let day = dim?["date"] as? String, let date = dayFmt.date(from: day) else { continue }
            let neurons = Net.number(sum?["totalNeurons"]) ?? 0
            let tokens = (Net.number(sum?["totalInputTokens"]) ?? 0) + (Net.number(sum?["totalOutputTokens"]) ?? 0)
            neuronsByDay[day, default: 0] += neurons
            // 정오로 맞춰 로컬 날짜가 하루 밀리지 않게 함
            let noon = date.addingTimeInterval(12 * 3600)
            stats.add(noon) { $0.tokens += tokens; $0.inputAll += Net.number(sum?["totalInputTokens"]) ?? 0 }
            if let m = dim?["modelId"] as? String {
                var a = stats.models[m, default: [:]][LocalStats.key(noon)] ?? Agg()
                a.tokens += tokens
                stats.models[m, default: [:]][LocalStats.key(noon)] = a
            }
        }
        // 비용: 하루 무료량을 넘긴 만큼만 (Workers Paid 기준 추정)
        for (day, n) in neuronsByDay {
            guard let d = dayFmt.date(from: day) else { continue }
            stats.add(d.addingTimeInterval(12 * 3600)) { $0.cost += max(0, n - freeNeurons) / 1000 * pricePer1k }
        }
        let today = neuronsByDay[dayFmt.string(from: Date())] ?? 0
        var q = Quota()
        q.session = Bucket(percent: min(100, today / freeNeurons * 100), resetsAt: utc.date(byAdding: .day, value: 1, to: todayUTC),
                           label: L("오늘 무료 할당량", "Free daily neurons"), short: L("일", "day"), window: 86400)
        q.extras2 = [(L("오늘 사용 neurons", "Neurons today"), String(format: "%.0f / %.0f", today, freeNeurons)),
                     (L("최근 30일 neurons", "Neurons, last 30 days"), String(format: "%.0f", neuronsByDay.values.reduce(0, +)))]
        done(q, nil, stats)
    }
}
