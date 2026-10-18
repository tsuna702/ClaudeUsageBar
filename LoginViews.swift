import SwiftUI

// 설정창의 계정 한 줄: 상태 + 로그인/계정 바꾸기 버튼
struct AccountSettingRow: View {
    let provider: Provider
    @ObservedObject var store: UsageStore

    var body: some View {
        let loggedIn = store.loggedIn[provider] ?? false
        let hasCLI = LoginHelper.cliPath(provider) != nil
        let cliName = provider == .claude ? "Claude Code" : "Codex"
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
                Button(loggedIn ? L("계정 바꾸기", "Switch account") : L("로그인", "Sign in")) { LoginHelper.login(provider) }
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
