import SwiftUI

// 설정 값이 바뀌면 알려줌 (키가 많은 화면을 다시 그릴 때 사용)
final class PrefsWatcher: ObservableObject {
    static let shared = PrefsWatcher()
    @Published var tick = 0
    private var token: NSObjectProtocol?

    init() {
        token = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.tick += 1
        }
    }
}

struct ServiceToggle: View {
    let provider: Provider
    @AppStorage var on: Bool
    @ObservedObject var watcher = PrefsWatcher.shared

    init(provider: Provider) {
        self.provider = provider
        _on = AppStorage(wrappedValue: false, provider.enabledKey)
    }

    var body: some View {
        let onlyOne = on && Provider.allCases.filter(Pref.enabled).count <= 1
        Toggle(isOn: $on) {
            HStack(spacing: 8) {
                if let logo = provider.logo {
                    Image(nsImage: logo).resizable().frame(width: 18, height: 18)
                } else {
                    Text(provider.icon).frame(width: 18)
                }
                Text(provider.name)
                if provider.loginKind == .apiKey {
                    Text(L("API 키", "API key")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .disabled(onlyOne)
    }
}

// 서비스 칩 (메뉴 막대 카탈로그용)
struct ServiceChip: View {
    let provider: Provider
    @AppStorage var on: Bool
    @ObservedObject var watcher = PrefsWatcher.shared

    init(provider: Provider) {
        self.provider = provider
        _on = AppStorage(wrappedValue: false, provider.enabledKey)
    }

    var body: some View {
        let onlyOne = on && Provider.allCases.filter(Pref.enabled).count <= 1
        CatalogChip(title: provider.name, symbol: provider.symbol, image: provider.logo, on: on, disabled: onlyOne) { on.toggle() }
    }
}
