import SwiftUI

// 대시보드(메뉴 막대를 누르면 뜨는 패널)에 보일 항목을 켜고 끔

enum DashItem: String, CaseIterable {
    case account, session, weekly, forecast        // 카드 (전체·서비스 탭 공통)
    case outage, update                            // 알림 띠
    case today                                     // 전체 탭
    case extraLimits, trend, costTokens, workTime, hourly, daily, rank, credits, share   // 서비스 탭

    var key: String { "dash_\(rawValue)" }
    var on: Bool { Pref.on(key) }

    var title: String {
        switch self {
        case .account: return L("계정 줄", "Account Row")
        case .session: return L("세션 카드", "Session Card")
        case .weekly: return L("주간 카드", "Weekly Card")
        case .forecast: return L("소진 예측 문구", "Pace Forecast")
        case .outage: return L("서비스 장애", "Service Issues")
        case .update: return L("새 버전 알림", "Update Notice")
        case .today: return L("오늘 사용 요약", "Today Summary")
        case .extraLimits: return L("모델별 한도", "Per-Model Limits")
        case .trend: return L("한도 추이 그래프", "Limit Trend")
        case .costTokens: return L("오늘 비용·토큰", "Cost · Tokens Today")
        case .workTime: return L("오늘 작업 시간", "Working Time Today")
        case .hourly: return L("시간대별 그래프", "Hourly Chart")
        case .daily: return L("30일 그래프", "30-Day Chart")
        case .rank: return L("모델·프로젝트 순위", "Model · Project Ranking")
        case .credits: return L("크레딧·세부 정보", "Credits · Details")
        case .share: return L("주간 사용 비중", "Weekly Share")
        }
    }

    var symbol: String {
        switch self {
        case .account: return "person.crop.circle"
        case .session: return "bolt.fill"
        case .weekly: return "calendar"
        case .forecast: return "flame.fill"
        case .outage: return "exclamationmark.triangle.fill"
        case .update: return "arrow.down.circle.fill"
        case .today: return "number.circle.fill"
        case .extraLimits: return "calendar.badge.clock"
        case .trend: return "chart.xyaxis.line"
        case .costTokens: return "dollarsign.circle.fill"
        case .workTime: return "clock.fill"
        case .hourly: return "chart.bar.fill"
        case .daily: return "chart.bar.xaxis"
        case .rank: return "list.number"
        case .credits: return "creditcard.fill"
        case .share: return "chart.pie.fill"
        }
    }

    static let groups: [(title: String, note: String?, items: [DashItem])] = [
        (L("한도 카드", "Limit Cards"), L("전체·서비스 탭 공통", "All and service tabs"), [.account, .session, .weekly, .forecast]),
        (L("알림 띠", "Banners"), nil, [.outage, .update]),
        (L("전체 탭", "All Tab"), nil, [.today]),
        (L("서비스 탭", "Service Tabs"), nil, [.extraLimits, .trend, .costTokens, .workTime, .hourly, .daily, .rank, .credits, .share]),
    ]

    // MARK: 순서

    // 자리를 옮길 수 있는 항목 (소진 예측 문구는 카드 안의 옵션이라 빠짐)
    static let defaultOrder: [DashItem] = [.outage, .update, .account, .session, .weekly, .today,
                                           .extraLimits, .trend, .costTokens, .workTime, .hourly, .daily, .rank, .credits, .share]
    static let orderKey = "dash_order"

    static var order: [DashItem] {
        get {
            let saved = (UserDefaults.standard.string(forKey: orderKey) ?? "").split(separator: ",").compactMap { DashItem(rawValue: String($0)) }
            var out = saved.filter { defaultOrder.contains($0) }
            // 새로 생긴 항목은 기본 순서에서 앞 항목 바로 뒤에 넣음
            for (i, item) in defaultOrder.enumerated() where !out.contains(item) {
                let prev = defaultOrder[..<i].last { out.contains($0) }
                out.insert(item, at: prev.flatMap { out.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
            }
            return out
        }
        set { UserDefaults.standard.set(newValue.map(\.rawValue).joined(separator: ","), forKey: orderKey) }
    }

    static func index(_ item: DashItem) -> Int { order.firstIndex(of: item) ?? 0 }
    static var accountFirst: Bool { index(.account) < min(index(.session), index(.weekly)) }
    static var sessionFirst: Bool { index(.session) < index(.weekly) }

    // 그릴 순서: 켜진 항목만. 계정 줄·세션·주간은 서비스 묶음 하나(.account 자리)로 합침
    static func layout(forService: Bool) -> [DashItem] {
        var out: [DashItem] = []
        for item in order {
            switch item {
            case .account, .session, .weekly:
                if !out.contains(.account) { out.append(.account) }
            case .today:
                if !forService, item.on { out.append(item) }
            case .outage, .update:
                if item.on { out.append(item) }
            default:
                if forService, item.on { out.append(item) }
            }
        }
        return out
    }

    // 어느 탭에 나오는지
    var whereText: String {
        switch self {
        case .account, .session, .weekly, .outage, .update: return L("모든 탭", "All tabs")
        case .today: return L("전체 탭", "All tab")
        default: return L("서비스 탭", "Service tabs")
        }
    }

    static var defaults: [String: Any] { Dictionary(uniqueKeysWithValues: allCases.map { ($0.key, true as Any) }) }
}

struct DashItemChip: View {
    let item: DashItem
    @AppStorage var on: Bool

    init(_ item: DashItem) {
        self.item = item
        _on = AppStorage(wrappedValue: true, item.key)
    }

    var body: some View {
        CatalogChip(title: item.title, symbol: item.symbol, on: on) { on.toggle() }
    }
}

// 순서 목록의 한 줄: 끌어서 옮기고, 스위치로 켜고 끔
struct DashOrderRow: View {
    let item: DashItem
    @AppStorage var on: Bool

    init(_ item: DashItem) {
        self.item = item
        _on = AppStorage(wrappedValue: true, item.key)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            Image(systemName: item.symbol).foregroundStyle(on ? Color.accentColor : .secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).font(.system(size: 12, weight: .medium))
                Text(item.whereText).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $on).labelsHidden().toggleStyle(.switch).controlSize(.mini)
        }
        .opacity(on ? 1 : 0.55)
        .padding(.vertical, 2)
    }
}

final class DashOrderState: ObservableObject {
    @Published var items = DashItem.order
    func move(_ from: IndexSet, _ to: Int) {
        items.move(fromOffsets: from, toOffset: to)
        DashItem.order = items
    }
    func reset() {
        UserDefaults.standard.removeObject(forKey: DashItem.orderKey)
        for item in DashItem.allCases { UserDefaults.standard.removeObject(forKey: item.key) }
        items = DashItem.order
    }
}

// 설정 > 대시보드: 왼쪽은 순서·켜고 끄기, 오른쪽은 바로 바뀌는 미리보기
struct DashboardCatalogView: View {
    @ObservedObject var store: UsageStore
    var flat = false   // 스냅샷용
    @StateObject var state = DashOrderState()
    @StateObject var preview: DashState = {
        let s = DashState()
        s.height = 900
        return s
    }()
    @AppStorage(DashItem.forecast.key) var forecast = true

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.grid.2x2").font(.system(size: 14))
                    Text(L("대시보드 항목", "Dashboard Items")).font(.system(size: 14, weight: .semibold))
                }
                Text(L("끌어서 순서를 바꾸고, 스위치로 보일지 정해요.", "Drag to reorder; switch to show or hide."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                list
                Toggle(L("한도 카드에 소진 예측 문구", "Pace forecast on limit cards"), isOn: $forecast)
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 12))
                Button { state.reset() } label: {
                    Label(L("기본값으로", "Reset"), systemImage: "arrow.counterclockwise")
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
            }
            .frame(width: 290)

            VStack(alignment: .leading, spacing: 6) {
                Text(L("미리보기", "Preview")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                previewPanel
            }
        }
        .padding(20)
    }

    @ViewBuilder var list: some View {
        if flat {
            VStack(spacing: 4) { ForEach(state.items, id: \.self) { DashOrderRow($0) } }
        } else {
            List {
                ForEach(state.items, id: \.self) { DashOrderRow($0) }
                    .onMove { state.move($0, $1) }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: false))
            .frame(maxHeight: .infinity)
        }
    }

    // 실제 대시보드를 줄여서 보여줌 (탭도 눌러 볼 수 있음)
    var previewPanel: some View {
        let scale: CGFloat = 0.8
        let h: CGFloat = flat ? 900 : 640
        return ScrollView(showsIndicators: false) {
            DashboardView(store: store, ui: preview, onRefresh: {}, onSettings: {}, onQuit: {}, flat: true)
                .frame(width: 400)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: 400 * scale, alignment: .topLeading)
                .allowsHitTesting(true)
        }
        .frame(width: 400 * scale, height: h * scale)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1)))
    }
}
