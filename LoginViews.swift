import SwiftUI

// 설정창의 계정 한 줄: 상태 + 로그인/계정 바꾸기 버튼
struct AccountSettingRow: View {
    let provider: Provider
    @ObservedObject var store: UsageStore

    var body: some View {
        let loggedIn = store.loggedIn[provider] ?? false
        let hasCLI = LoginHelper.cliPath(provider) != nil
        let cliName = provider == .claude ? "Claude Code" : "Codex"
        VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
            if let logo = provider.logo {
                Image(nsImage: logo).resizable().frame(width: 24, height: 24)
            } else {
                Text(provider.icon).font(.title3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name).font(.system(size: 13, weight: .semibold))
                Text(loggedIn ? (store.quotas[provider]?.email ?? L("로그인됨", "Signed in")) : hasCLI ? L("로그인 필요", "Not signed in") : L("\(cliName) 설치 필요", "\(cliName) not installed"))
                    .font(.caption).foregroundStyle(loggedIn ? Color.secondary : Color.orange)
            }
            Spacer()
            if !hasCLI {
                Button(L("설치 안내", "Install")) { NSWorkspace.shared.open(LoginHelper.installURL(provider)) }
            } else {
                Button(loggedIn ? L("다른 계정으로 로그인", "Sign in to another") : L("로그인", "Sign in")) { LoginHelper.login(provider) }
            }
        }
        savedList
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
        let target = provider == .claude ? "Claude Code" : "Codex"
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
        let hasCLI = LoginHelper.cliPath(provider) != nil
        Card {
            HStack(spacing: 12) {
                if let logo = provider.logo {
                    Image(nsImage: logo).resizable().frame(width: 40, height: 40)
                } else {
                    Text(provider.icon).font(.system(size: 26))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("\(provider.name) 연결 필요", "Connect \(provider.name)")).font(.system(size: 14, weight: .semibold))
                    Text(hasCLI ? L("로그인하면 사용량을 불러와요", "Sign in to load your usage") : L("\(provider == .claude ? "Claude Code" : "Codex")를 먼저 설치해 주세요", "Install \(provider == .claude ? "Claude Code" : "Codex") first"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if hasCLI { LoginHelper.login(provider) } else { NSWorkspace.shared.open(LoginHelper.installURL(provider)) }
                } label: {
                    Text(hasCLI ? L("로그인", "Sign in") : L(L("설치 안내", "Install"), "Install"))
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(Theme.accent))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
