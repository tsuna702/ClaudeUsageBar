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

struct DashboardCatalogView: View {
    var flat = false   // 스냅샷용: 스크롤 없이 그림

    var body: some View {
        if flat { content } else { ScrollView { content } }
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.grid.2x2").font(.system(size: 15))
                Text(L("대시보드에 보일 항목", "Dashboard Items")).font(.system(size: 15, weight: .semibold))
            }
            Text(L("메뉴 막대를 누르면 뜨는 패널에 무엇을 보일지 골라요. 끈 항목은 자리를 차지하지 않아요.",
                   "Choose what the panel shows when you click the menu bar. Hidden items take no space."))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 18) {
                ForEach(DashItem.groups.indices, id: \.self) { i in
                    let g = DashItem.groups[i]
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Text(g.title).font(.system(size: 13, weight: .semibold))
                            if let note = g.note { Text("(\(note))").font(.system(size: 12)).foregroundStyle(.secondary) }
                        }
                        FlowLayout(spacing: 8) {
                            ForEach(g.items, id: \.self) { DashItemChip($0) }
                        }
                    }
                }
                Divider()
                HStack {
                    Spacer()
                    Button {
                        for item in DashItem.allCases { UserDefaults.standard.removeObject(forKey: item.key) }
                    } label: {
                        Label(L("모두 보이기", "Show All"), systemImage: "arrow.counterclockwise")
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        }
        .padding(24)
    }
}
