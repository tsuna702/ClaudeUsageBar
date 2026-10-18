import SwiftUI

// 서비스별 안내 (공식 API가 아닌 경우 등)
func providerNote(_ p: Provider) -> String? {
    switch p {
    case .gemini:
        return L("Gemini CLI 로그인 정보로 Google 내부 할당량 API를 호출해요. Google은 Gemini CLI 로그인을 다른 프로그램에서 쓰는 것을 정책 위반으로 볼 수 있다고 밝혔으니, 계정 제한 위험을 알고 켜 주세요.",
                 "Uses your Gemini CLI login to call Google's internal quota API. Google has said using Gemini CLI login in other software may violate its policy, so turn this on only if you accept the risk of account restrictions.")
    case .antigravity:
        return L("Antigravity 앱이 실행 중일 때 앱 안의 로컬 서버에서 할당량을 읽어요.", "Reads quotas from Antigravity's local server while the app is running.")
    case .cursor:
        return L("Cursor 앱에 로그인된 정보로 cursor.com 사용량 페이지의 내부 API를 호출해요.", "Uses the Cursor app's login to call the internal API behind cursor.com's usage page.")
    case .grok:
        return L("grok CLI(Grok Build)에 결제 정보를 물어봐요. grok login이 필요해요.", "Asks the grok CLI (Grok Build) for billing. Requires grok login.")
    case .openai:
        return L("조직의 Admin API 키가 필요해요 (일반 API 키로는 비용을 볼 수 없어요). 월 예산을 넣으면 예산 대비 %도 보여줘요.",
                 "Needs an organization Admin API key (regular keys can't read costs). Set a monthly budget to see usage as a %.")
    case .cloudflare:
        return L("Account Analytics 읽기 권한이 있는 API 토큰과 계정 ID가 필요해요. 하루 무료 10,000 neurons 대비 사용량을 보여줘요.",
                 "Needs an API token with Account Analytics read access and your account ID. Shows usage against the free 10,000 neurons per day.")
    default:
        return nil
    }
}

// 입력 중인 키 (@State 대신)
final class KeyDraft: ObservableObject {
    @Published var key = ""
}

// API 키 입력칸 (OpenAI · Cloudflare)
struct APIKeyFields: View {
    let provider: Provider
    @ObservedObject var store: UsageStore
    @ObservedObject var draft = KeyDraft()
    @AppStorage(CloudflareAPI.accountKey) var cfAccount = ""
    @AppStorage(OpenAIAdminAPI.budgetKey) var budget = 0.0

    var body: some View {
        let saved = store.loggedIn[provider] ?? false
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField(provider == .openai ? L("Admin API 키 (sk-admin-…)", "Admin API key (sk-admin-…)")
                                                : L("API 토큰", "API token"), text: $draft.key)
                    .textFieldStyle(.roundedBorder)
                Button(L("저장", "Save")) { save() }.disabled(draft.key.isEmpty)
                if saved {
                    Button(L("지우기", "Remove")) { KeyStore.set(provider.rawValue, ""); refresh() }
                }
            }
            if provider == .cloudflare {
                TextField(L("계정 ID", "Account ID"), text: $cfAccount).textFieldStyle(.roundedBorder)
                    .onSubmit { refresh() }
            }
            if provider == .openai {
                HStack {
                    Text(L("월 예산 ($)", "Monthly budget ($)")).font(.caption)
                    TextField("0", value: $budget, format: .number).textFieldStyle(.roundedBorder).frame(width: 90)
                    Text(L("0이면 금액만 표시", "0 shows spend only")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(saved ? L("키가 키체인에 저장돼 있어요", "Key is stored in the Keychain") : L("키는 이 맥의 키체인에만 저장돼요", "Keys are stored only in this Mac's Keychain"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.leading, 34)
    }

    func save() {
        KeyStore.set(provider.rawValue, draft.key)
        draft.key = ""
        UserDefaults.standard.set(true, forKey: provider.enabledKey)
        refresh()
    }

    func refresh() {
        store.loggedIn[provider] = LoginHelper.isLoggedIn(provider)
        NotificationCenter.default.post(name: .usageLoginChanged, object: nil)
    }
}

// 설정창의 계정 한 줄: 상태 + 로그인/계정 바꾸기 버튼
struct AccountSettingRow: View {
    let provider: Provider
    @ObservedObject var store: UsageStore

    var body: some View {
        let loggedIn = store.loggedIn[provider] ?? false
        let installed = LoginHelper.isInstalled(provider)
        let tool = LoginHelper.toolName(provider)
        VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
            if let logo = provider.logo {
                Image(nsImage: logo).resizable().frame(width: 24, height: 24)
            } else {
                Text(provider.icon).font(.title3).frame(width: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name).font(.system(size: 13, weight: .semibold))
                Text(loggedIn ? (store.quotas[provider]?.email ?? L("연결됨", "Connected"))
                     : installed ? L("연결 필요", "Not connected") : L("\(tool) 설치 필요", "\(tool) not installed"))
                    .font(.caption).foregroundStyle(loggedIn ? Color.secondary : Color.orange)
            }
            Spacer()
            switch provider.loginKind {
            case .apiKey:
                Button(L("키 만드는 곳", "Get a key")) { NSWorkspace.shared.open(LoginHelper.installURL(provider)) }
            case .app:
                if installed {
                    Button(L("앱 열기", "Open app")) { LoginHelper.login(provider) }
                } else {
                    Button(L("설치 안내", "Install")) { NSWorkspace.shared.open(LoginHelper.installURL(provider)) }
                }
            case .cli:
                if !installed {
                    Button(L("설치 안내", "Install")) { NSWorkspace.shared.open(LoginHelper.installURL(provider)) }
                } else {
                    Button(loggedIn ? L("다른 계정으로 로그인", "Sign in to another") : L("로그인", "Sign in")) { LoginHelper.login(provider) }
                }
            }
        }
        if provider.loginKind == .apiKey { APIKeyFields(provider: provider, store: store) }
        if let note = providerNote(provider) {
            Text(note).font(.caption).foregroundStyle(.secondary).padding(.leading, 34)
                .fixedSize(horizontal: false, vertical: true)
        }
        if provider.supportsSavedAccounts { savedList }
        }
        .onAppear {
            // 꺼 둔 서비스도 연결 상태를 확인해서 보여줌
            DispatchQueue.global(qos: .utility).async {
                let v = LoginHelper.isLoggedIn(provider)
                DispatchQueue.main.async { store.loggedIn[provider] = v }
            }
        }
    }

    // 저장된 계정 목록: 고르면 전환
    @ViewBuilder var savedList: some View {
        let current = store.quotas[provider]?.email
        let saved = store.savedAccounts.filter { $0.provider == provider.rawValue }
        if !saved.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(saved, id: \.self) { acc in
                    HStack(spacing: 8) {
                        Image(systemName: acc.email == current ? "checkmark.circle.fill" : "person.circle")
                            .foregroundStyle(acc.email == current ? Color.green : Color.secondary)
                        Text(acc.email).font(.system(size: 12))
                        if acc.email == current {
                            Text(L("사용 중", "Active")).font(.system(size: 10, weight: .bold)).foregroundStyle(.green)
                        }
                        Spacer()
                        if acc.email != current {
                            Button(L("전환", "Switch")) { switchTo(acc, current: current) }.controlSize(.small)
                        }
                        Button { AccountStore.remove(acc); store.savedAccounts = AccountStore.all } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless).controlSize(.small)
                        .help(L("이 앱에 저장된 정보만 지워요", "Removes only what this app saved"))
                    }
                }
            }
            .padding(.leading, 34)
        }
    }

    func switchTo(_ acc: SavedAccount, current: String?) {
        let target = LoginHelper.toolName(provider)
        let alert = NSAlert()
        alert.messageText = L("\(acc.email) 계정으로 전환할까요?", "Switch to \(acc.email)?")
        alert.informativeText = L("\(target)도 이 계정으로 바뀌어요. 실행 중인 \(target)는 다시 시작해야 반영될 수 있어요.",
                                  "\(target) will also use this account. A running \(target) may need a restart.")
        alert.addButton(withTitle: L("전환", "Switch"))
        alert.addButton(withTitle: L("취소", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let err = AccountStore.switchTo(acc, currentEmail: current)
            DispatchQueue.main.async {
                store.savedAccounts = AccountStore.all
                if let err {
                    let a = NSAlert()
                    a.messageText = L("전환하지 못했어요", "Could not switch")
                    a.informativeText = err
                    a.runModal()
                }
            }
        }
    }
}

// 대시보드: 로그인이 안 된 서비스 자리에 보여주는 카드
struct LoginCard: View {
    let provider: Provider

    var body: some View {
        let hasCLI = LoginHelper.isInstalled(provider)
        let tool = LoginHelper.toolName(provider)
        Card {
            HStack(spacing: 12) {
                if let logo = provider.logo {
                    Image(nsImage: logo).resizable().frame(width: 40, height: 40)
                } else {
                    Text(provider.icon).font(.system(size: 26))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("\(provider.name) 연결 필요", "Connect \(provider.name)")).font(.system(size: 14, weight: .semibold))
                    Text(hasCLI ? L("로그인하면 사용량을 불러와요", "Sign in to load your usage") : L("\(tool)를 먼저 설치해 주세요", "Install \(tool) first"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if provider.loginKind == .apiKey {
                        SettingsNav.shared.page = .accounts
                        (NSApp.delegate as? AppDelegate)?.openSettings()
                    } else if hasCLI { LoginHelper.login(provider) } else { NSWorkspace.shared.open(LoginHelper.installURL(provider)) }
                } label: {
                    Text(provider.loginKind == .apiKey ? L("키 입력", "Add key") : hasCLI ? L("로그인", "Sign in") : L("설치 안내", "Install"))
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(Theme.accent))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
