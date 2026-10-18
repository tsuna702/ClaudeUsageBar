import Foundation
import Security

// 저장된 계정: 로그인 정보를 키체인에 따로 보관해 두고, 고르면 공식 위치에 되돌려 써서 전환
// - Claude: 키체인 "Claude Code-credentials" + ~/.claude.json 의 oauthAccount
// - Codex:  ~/.codex/auth.json
// 전환하면 Claude Code / Codex 자체도 그 계정을 쓰게 됨

struct SavedAccount: Codable, Hashable {
    let provider: String
    let email: String
    var savedAt: Double
}

enum AccountStore {
    static let service = "UsageBar saved account"
    static let listKey = "saved_accounts"
    // 저장·전환·삭제가 동시에 돌면 목록을 서로 덮어쓰므로 한 번에 하나씩
    static let lock = NSRecursiveLock()

    static var all: [SavedAccount] {
        guard let data = UserDefaults.standard.data(forKey: listKey) else { return [] }
        return (try? JSONDecoder().decode([SavedAccount].self, from: data)) ?? []
    }

    static func list(_ p: Provider) -> [SavedAccount] { all.filter { $0.provider == p.rawValue } }

    static func setAll(_ v: [SavedAccount]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(v), forKey: listKey)
    }

    static func keychainAccount(_ p: Provider, _ email: String) -> String { "\(p.rawValue):\(email)" }

    static var codexAuthPath: String {
        (ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex") + "/auth.json"
    }
    static var claudeConfigPath: String { NSHomeDirectory() + "/.claude.json" }

    // 지금 로그인된 계정의 로그인 정보 묶음
    static func currentBlob(_ p: Provider) -> Data? {
        switch p {
        case .claude:
            guard let cred = ClaudeAPI.readCredentials() else { return nil }
            var blob: [String: Any] = ["credentials": cred]
            if let data = FileManager.default.contents(atPath: claudeConfigPath),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let acct = json["oauthAccount"] {
                blob["oauthAccount"] = acct
            }
            return try? JSONSerialization.data(withJSONObject: blob, options: [.sortedKeys])
        case .codex:
            return FileManager.default.contents(atPath: codexAuthPath)
        default:
            return nil   // 다른 서비스는 계정 전환을 지원하지 않음
        }
    }

    // 이 앱이 만든 키체인 항목은 Security API로 직접 읽고 씀 (크기 제한 없음, 바이트 그대로)
    static func query(_ p: Provider, _ email: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: keychainAccount(p, email)]
    }

    static func readSaved(_ p: Provider, _ email: String) -> Data? {
        var q = query(p, email)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func writeSaved(_ p: Provider, _ email: String, _ blob: Data) -> Bool {
        let q = query(p, email)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: blob] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var add = q
        add[kSecValueData as String] = blob
        add[kSecAttrLabel as String] = "\(service) (\(p.name))"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func deleteSaved(_ p: Provider, _ email: String) {
        SecItemDelete(query(p, email) as CFDictionary)
    }

    // 현재 계정을 저장 (내용이 바뀌었을 때만 키체인에 씀)
    @discardableResult
    static func saveCurrent(_ p: Provider, email: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let debug = ProcessInfo.processInfo.environment["USAGE_DEBUG"] != nil
        guard !email.isEmpty, let blob = currentBlob(p) else {
            if debug { print("saveCurrent", p.rawValue, "no blob / email"); fflush(stdout) }
            return false
        }
        if debug { print("saveCurrent", p.rawValue, "blob", blob.count, "same", readSaved(p, email) == blob); fflush(stdout) }
        if readSaved(p, email) != blob {
            guard writeSaved(p, email, blob) else { return false }
        }
        var list = all.filter { !($0.provider == p.rawValue && $0.email == email) }
        list.append(SavedAccount(provider: p.rawValue, email: email, savedAt: Date().timeIntervalSince1970))
        setAll(list.sorted { $0.email < $1.email })
        return true
    }

    // 저장된 계정으로 전환. 실패하면 오류 문구
    static func switchTo(_ acc: SavedAccount, currentEmail: String?) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let p = Provider(rawValue: acc.provider) else { return "?" }
        // 지금 계정의 최신 로그인 정보부터 저장해 둬야 나중에 다시 돌아올 수 있음
        if let cur = currentEmail { saveCurrent(p, email: cur) }
        guard let blob = readSaved(p, acc.email) else { return L("저장된 로그인 정보를 찾을 수 없어요", "Saved login not found") }

        switch p {
        case .claude:
            guard let json = try? JSONSerialization.jsonObject(with: blob) as? [String: Any],
                  let cred = json["credentials"] as? [String: Any] else { return L("저장된 정보가 손상됐어요", "Saved login is damaged") }
            guard ClaudeAPI.writeCredentials(cred) else { return L("키체인에 쓰지 못했어요", "Could not write to Keychain") }
            // 계정 표시 정보(oauthAccount)도 맞춰 둠. 나머지 설정은 그대로
            if let acct = json["oauthAccount"],
               let data = FileManager.default.contents(atPath: claudeConfigPath),
               var config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                config["oauthAccount"] = acct
                if let out = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted]) {
                    try? out.write(to: URL(fileURLWithPath: claudeConfigPath), options: .atomic)
                }
            }
        case .codex:
            do {
                try blob.write(to: URL(fileURLWithPath: codexAuthPath), options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: codexAuthPath)
            } catch {
                return error.localizedDescription
            }
        default:
            return L("이 서비스는 계정 전환을 지원하지 않아요", "This service doesn't support switching")
        }
        NotificationCenter.default.post(name: .usageLoginChanged, object: nil)
        return nil
    }

    static func remove(_ acc: SavedAccount) {
        lock.lock(); defer { lock.unlock() }
        guard let p = Provider(rawValue: acc.provider) else { return }
        deleteSaved(p, acc.email)
        setAll(all.filter { $0 != acc })
    }
}
