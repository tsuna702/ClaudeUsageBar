import SwiftUI
import Charts

// 메뉴 막대 아이콘을 클릭하면 뜨는 대시보드 팝오버

enum DashTab: String, CaseIterable {
    case all, claude, codex
    var title: String { self == .all ? L("전체", "All") : self == .claude ? "Claude" : "Codex" }
    var symbol: String { self == .all ? "square.grid.2x2.fill" : self == .claude ? "sparkle" : "chevron.left.forwardslash.chevron.right" }
    var provider: Provider? { self == .claude ? .claude : self == .codex ? .codex : nil }
}

// 팝오버 화면 상태 (@State 대신 사용: swiftc 단독 빌드에서는 매크로를 못 씀)
final class DashState: ObservableObject {
    @Published var tab: DashTab = .all
    @Published var chartCost = true
    @Published var showEmail = false
    @Published var height: CGFloat = 760
    @Published var byProject = false        // 사용 순위: 모델 / 프로젝트
    @Published var rankDays = 7             // 사용 순위 기간: 1 / 7 / 30일   // 팝오버 전체 높이 (열 때 화면에 맞춰 정함)
}

// MARK: - 색과 포맷

enum Theme {
    static let appIcon = flatIcon(NSApp.applicationIconImage)
    static let accent = Color(red: 0.91, green: 0.42, blue: 0.40)
    static let bar = LinearGradient(colors: [Color(red: 0.42, green: 0.36, blue: 0.85), Color(red: 0.30, green: 0.75, blue: 0.55)],
                                    startPoint: .leading, endPoint: .trailing)
    static func level(_ used: Double) -> Int {
        let d = UserDefaults.standard
        if used >= d.double(forKey: Pref.redAt) { return 2 }
        if used >= d.double(forKey: Pref.orangeAt) { return 1 }
        return 0
    }
    static func levelColor(_ l: Int) -> Color { [Color.green, .orange, .red][l] }
    static func levelText(_ l: Int, full: Bool = false) -> String {
        full ? L("소진", "Empty") : [L("여유", "OK"), L("주의", "Watch"), L("위험", "High")][l]
    }
}

enum Fmt {
    static func tokens(_ v: Double) -> String {
        if v >= 1_000_000_000 { return String(format: "%.1fB", v / 1_000_000_000) }
        if v >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000) }
        if v >= 1_000 { return String(format: "%.1fK", v / 1_000) }
        return "\(Int(v))"
    }

    static func money(_ v: Double) -> String { String(format: "$%.2f", v) }

    static func duration(_ s: Double) -> String {
        let t = Int(s)
        if t >= 3600 { return L("\(t / 3600)시간 \((t % 3600) / 60)분", "\(t / 3600)h \((t % 3600) / 60)m") }
        if t >= 60 { return L("\(t / 60)분 \(t % 60)초", "\(t / 60)m \(t % 60)s") }
        return L("\(t)초", "\(t)s")
    }

    static func until(_ d: Date?) -> String {
        guard let d else { return L("초기화 시각 모름", "Reset time unknown") }
        let s = Int(d.timeIntervalSinceNow)
        if s <= 0 { return L("곧 초기화", "Resets soon") }
        if s < 3600 { return L("\(s / 60)분 후", "in \(s / 60)m") }
        if s < 86400 { return L("\(s / 3600)시간 \((s % 3600) / 60)분 후", "in \(s / 3600)h \((s % 3600) / 60)m") }
        return L("\(s / 86400)일 \((s % 86400) / 3600)시간 후", "in \(s / 86400)d \((s % 86400) / 3600)h")
    }

    static func span(_ s: Double) -> String {
        let t = Int(s)
        if t >= 86400 { return L("\(t / 86400)일 \((t % 86400) / 3600)시간", "\(t / 86400)d \((t % 86400) / 3600)h") }
        if t >= 3600 { return L("\(t / 3600)시간 \((t % 3600) / 60)분", "\(t / 3600)h \((t % 3600) / 60)m") }
        return L("\(max(1, t / 60))분", "\(max(1, t / 60))m")
    }

    // 모델 ID를 읽기 쉽게: claude-opus-5-5 → Opus 5.5
    static func model(_ id: String) -> String {
        guard id.hasPrefix("claude-") else { return id }
        let parts = id.dropFirst(7).split(separator: "-")
        guard let name = parts.first else { return id }
        let ver = parts.dropFirst().filter { $0.allSatisfy(\.isNumber) && $0.count <= 2 }.joined(separator: ".")
        return name.capitalized + (ver.isEmpty ? "" : " " + ver)
    }

    static func ago(_ d: Date?) -> String {
        guard let d else { return L("아직 못 불러옴", "Not loaded yet") }
        let s = Int(-d.timeIntervalSinceNow)
        if s < 60 { return L("방금 업데이트", "Updated just now") }
        if s < 3600 { return L("\(s / 60)분 전 업데이트", "Updated \(s / 60)m ago") }
        return L("\(s / 3600)시간 전 업데이트", "Updated \(s / 3600)h ago")
    }

    static func maskEmail(_ e: String) -> String {
        let parts = e.split(separator: "@")
        guard parts.count == 2 else { return e }
        let domain = parts[1].split(separator: ".")
        let tld = domain.count > 1 ? "." + domain.dropFirst().joined(separator: ".") : ""
        return "\(parts[0].prefix(1))•••@\(domain.first?.prefix(1) ?? "")•••\(tld)"
    }

    static let yesterday: String = {
        let f = DateFormatter()
        f.locale = Lang.locale
        f.dateFormat = "M/d"
        return f.string(from: Calendar.current.date(byAdding: .day, value: -1, to: Date())!)
    }()
}

// MARK: - 공통 카드

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(nsColor: .textBackgroundColor).opacity(0.75)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

struct CardTitle: View {
    let symbol: String
    let color: Color
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color).font(.system(size: 11, weight: .bold))
            Text(text).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
        }
    }
}

struct Chip: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.85)))
    }
}

// 진행 막대 + 시간 경과 표시(▲)
struct ProgressBar: View {
    let fraction: Double          // 0...1 채움
    var marker: Double? = nil     // 0...1 위치
    var fill: AnyShapeStyle = AnyShapeStyle(Theme.bar)

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(fill).frame(width: max(0, min(1, fraction)) * g.size.width)
                if let m = marker {
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.orange)
                        .offset(x: max(0, min(1, m)) * g.size.width - 4, y: 9)
                }
            }
        }
        .frame(height: 7)
        .padding(.bottom, marker == nil ? 0 : 6)
    }
}

// MARK: - 한도 카드

struct LimitCard: View {
    let title: String
    let symbol: String
    let bucket: Bucket?
    let window: Double          // 창 길이(초)
    let limitReached: Bool

    // 소진 예상: 이 창이 시작된 뒤 평균 속도로 계속 쓰면 언제 100%가 되는지
    func forecast(used: Double) -> (text: String, ok: Bool)? {
        guard let reset = bucket?.resetsAt else { return nil }
        let left = reset.timeIntervalSinceNow
        let elapsed = window - left
        if used >= 100 { return (L("한도 소진 — 초기화 대기", "Limit reached — waiting for reset"), false) }
        guard used > 0, elapsed > 300, left > 0 else { return nil }
        let toEmpty = (100 - used) / (used / elapsed)
        return toEmpty < left ? (L("이 속도면 \(Fmt.span(toEmpty)) 후 소진", "At this pace, empty in \(Fmt.span(toEmpty))"), false) : (L("이 속도면 초기화 전까지 여유", "At this pace, lasts until reset"), true)
    }

    var body: some View {
        let used = bucket?.percent ?? 0
        let left = max(0, 100 - used)
        let lvl = limitReached && used >= 100 ? 2 : Theme.level(used)
        // 남은 시간 비율: 막대보다 ▲가 오른쪽이면 지금 속도로는 초기화 전에 소진
        let timeLeft = bucket?.resetsAt.map { max(0, min(1, $0.timeIntervalSinceNow / window)) }
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardTitle(symbol: symbol, color: .accentColor, text: title)
                    Spacer()
                    Chip(text: Theme.levelText(lvl, full: left <= 0), color: Theme.levelColor(lvl))
                }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(bucket == nil ? "–" : "\(Int(left.rounded()))")
                        .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    Text("%").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text(L("남음", "left")).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                }
                ProgressBar(fraction: left / 100, marker: timeLeft)
                if let eta = forecast(used: used) {
                    HStack(spacing: 4) {
                        Image(systemName: eta.ok ? "checkmark.circle.fill" : "flame.fill").font(.system(size: 9))
                        Text(eta.text).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(eta.ok ? Color.green : Color.orange)
                }
                HStack(spacing: 4) {
                    Image(systemName: "clock.fill").font(.system(size: 9))
                    Text(Fmt.until(bucket?.resetsAt)).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer()
                    Text(L("\(Int(used.rounded()))% 사용", "\(Int(used.rounded()))% used"))
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 통계 카드 (비용·토큰·작업 시간)

struct StatCard: View {
    let title: String
    let symbol: String
    let color: Color
    let value: String
    let unit: String
    let sub: String?
    let fraction: Double?
    let delta: (text: String, lower: Bool)?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle(symbol: symbol, color: color, text: title)
                HStack(alignment: .firstTextBaseline) {
                    Text(value).font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Spacer()
                    Text(unit).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
                if let sub { Text(sub).font(.system(size: 11)).foregroundStyle(.secondary) }
                if let fraction { ProgressBar(fraction: fraction, fill: AnyShapeStyle(color.gradient)) }
                if let delta {
                    HStack(spacing: 4) {
                        Image(systemName: delta.lower ? "arrow.down.right" : "arrow.up.right")
                        Text(delta.text).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(delta.lower ? Color.green : Color.orange)
                }
            }
        }
    }
}

// 캐시로 아낀 비용 문구
func savedText(_ d: DayStat) -> String {
    let pct = Int((d.saved / max(0.0001, d.cost + d.saved)) * 100)
    return L("캐시로 \(Fmt.money(d.saved)) 절약 (\(pct)%)", "Cache saved \(Fmt.money(d.saved)) (\(pct)%)")
}

// 어제 대비 증감 문구
func compare(_ today: Double, _ yesterday: Double, _ format: (Double) -> String) -> (text: String, lower: Bool)? {
    guard yesterday > 0 else { return nil }
    let diff = today - yesterday
    let pct = abs(diff) / yesterday * 100
    let sign = diff < 0 ? "-" : "+"
    let body = "\(sign)\(format(abs(diff))) (\(String(format: "%.0f", pct))%)"
    return (L("\(Fmt.yesterday) 대비 \(body)", "vs \(Fmt.yesterday) \(body)"), diff < 0)
}

// MARK: - 계정 줄

struct AccountRow: View {
    let provider: Provider
    @ObservedObject var store: UsageStore
    @ObservedObject var ui: DashState

    var body: some View {
        let q = store.quotas[provider]
        let email = q?.email ?? provider.name
        Card {
            HStack(spacing: 12) {
                if let logo = provider.logo {
                    Image(nsImage: logo).resizable().interpolation(.high).frame(width: 44, height: 44)
                } else {
                ZStack {
                    Circle().fill(LinearGradient(colors: provider == .claude
                                                 ? [Color(red: 0.95, green: 0.55, blue: 0.40), Color(red: 0.85, green: 0.35, blue: 0.55)]
                                                 : [Color(red: 0.25, green: 0.65, blue: 0.75), Color(red: 0.35, green: 0.40, blue: 0.85)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text(provider.icon).font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: 40, height: 40)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(ui.showEmail ? email : Fmt.maskEmail(email))
                            .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        if let plan = q?.plan {
                            Text(plan.uppercased())
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Theme.accent))
                        }
                        Button { ui.showEmail.toggle() } label: {
                            Image(systemName: ui.showEmail ? "eye" : "eye.slash").font(.system(size: 10))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    Text(Fmt.ago(store.updated[provider]) + " · API")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if let err = store.errors[provider] {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(err)
                }
            }
        }
    }
}

// MARK: - 일별 차트

struct DailyChart: View {
    let provider: Provider
    let stats: LocalStats
    @ObservedObject var ui: DashState

    var body: some View {
        let cost = stats.hasCost && ui.chartCost
        let data = stats.last30
        let values = data.map { cost ? $0.stat.cost : $0.stat.tokens }
        let total = values.reduce(0, +)
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    CardTitle(symbol: "chart.bar.fill", color: .yellow, text: L("일별 사용량 — 최근 30일", "Daily usage — last 30 days"))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(cost ? Fmt.money(total) : Fmt.tokens(total)).font(.system(size: 17, weight: .bold, design: .rounded))
                        Text(cost ? L("30일 합계 (API 환산)", "30-day total (API rates)") : L("30일 토큰", "30-day tokens")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                if stats.hasCost {
                    HStack(spacing: 6) {
                        pill(L("비용", "Cost"), on: ui.chartCost) { ui.chartCost = true }
                        pill(L("토큰", "Tokens"), on: !ui.chartCost) { ui.chartCost = false }
                    }
                }
                Chart {
                    ForEach(Array(data.enumerated()), id: \.offset) { i, d in
                        BarMark(x: .value("date", d.date, unit: .day), y: .value("value", values[i]))
                            .foregroundStyle(provider == .claude ? Color.orange.gradient : Color.teal.gradient)
                            .cornerRadius(2)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing) { v in
                        AxisGridLine()
                        AxisValueLabel {
                            if let d = v.as(Double.self) { Text(cost ? "$\(Int(d))" : Fmt.tokens(d)).font(.system(size: 9)) }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisValueLabel(format: .dateTime.month(.defaultDigits).day(), centered: false).font(.system(size: 9))
                    }
                }
                .frame(height: 120)
            }
        }
    }
}

// MARK: - 오늘 시간대별

struct HourlyChart: View {
    let provider: Provider
    let stats: LocalStats
    @ObservedObject var ui: DashState

    var body: some View {
        let cost = stats.hasCost && ui.chartCost
        let rows = stats.todayHours
        let now = Calendar.current.component(.hour, from: Date())
        let peak = rows.max { (cost ? $0.stat.cost : $0.stat.tokens) < (cost ? $1.stat.cost : $1.stat.tokens) }
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardTitle(symbol: "waveform.path.ecg", color: .blue, text: L("오늘 시간대별", "Today by hour"))
                    Spacer()
                    if let peak, (cost ? peak.stat.cost : peak.stat.tokens) > 0 {
                        Text(L("가장 많이 쓴 시간 \(peak.hour)시", "Peak \(peak.hour):00")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Chart {
                    ForEach(rows, id: \.hour) { r in
                        BarMark(x: .value("hour", r.hour), y: .value("value", cost ? r.stat.cost : r.stat.tokens))
                            .foregroundStyle(r.hour == now ? AnyShapeStyle(Theme.accent.gradient) : AnyShapeStyle(Color.blue.opacity(0.55).gradient))
                            .cornerRadius(2)
                    }
                }
                .chartXScale(domain: -0.5...23.5)
                .chartXAxis {
                    AxisMarks(values: [0, 6, 12, 18, 23]) { v in
                        AxisValueLabel { if let h = v.as(Int.self) { Text(L("\(h)시", "\(h):00")).font(.system(size: 9)) } }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing) { v in
                        AxisGridLine()
                        AxisValueLabel {
                            if let d = v.as(Double.self) { Text(cost ? String(format: "$%.1f", d) : Fmt.tokens(d)).font(.system(size: 9)) }
                        }
                    }
                }
                .frame(height: 80)
            }
        }
    }
}

// MARK: - 모델·프로젝트별 순위

struct RankCard: View {
    let provider: Provider
    let stats: LocalStats
    @ObservedObject var ui: DashState

    var body: some View {
        let rows = LocalStats.top(ui.byProject ? stats.projects : stats.models, days: ui.rankDays)
        let maxTokens = rows.first?.agg.tokens ?? 1
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(symbol: "list.number", color: .indigo, text: ui.byProject ? L("프로젝트별 사용", "Usage by project") : L("모델별 사용", "Usage by model"))
                HStack(spacing: 6) {
                    pill(L("모델", "Model"), on: !ui.byProject) { ui.byProject = false }
                    pill(L("프로젝트", "Project"), on: ui.byProject) { ui.byProject = true }
                    Spacer()
                    ForEach([1, 7, 30], id: \.self) { d in
                        pill(d == 1 ? L("오늘", "Today") : L("\(d)일", "\(d)d"), on: ui.rankDays == d) { ui.rankDays = d }
                    }
                }
                if rows.isEmpty {
                    Text(L("이 기간에는 기록이 없어요", "No activity in this period")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(rows, id: \.name) { r in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(ui.byProject ? r.name : Fmt.model(r.name))
                                .font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(Fmt.tokens(r.agg.tokens)).font(.system(size: 12)).monospacedDigit()
                            if stats.hasCost {
                                Text(Fmt.money(r.agg.cost)).font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                                    .frame(width: 58, alignment: .trailing)
                            }
                        }
                        ProgressBar(fraction: r.agg.tokens / maxTokens, fill: AnyShapeStyle(Color.indigo.gradient))
                    }
                }
            }
        }
    }
}

func pill(_ text: String, on: Bool, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(text)
            .font(.system(size: 11, weight: on ? .bold : .medium))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(on ? Color.primary.opacity(0.1) : .clear))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
    }
    .buttonStyle(.plain)
}

// MARK: - 메인 화면

struct DashboardView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var ui: DashState
    let onRefresh: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void
    var flat = false   // 스냅샷용: 스크롤 없이 전체를 그림
    @AppStorage(Lang.key) var lang = "system"   // 바뀌면 전체를 다시 그림

    var providers: [Provider] { Provider.allCases.filter(Pref.enabled) }

    // 전체 상태: 활성 서비스 중 가장 나쁜 단계
    var overall: Int {
        providers.compactMap { store.quotas[$0] }.map { q in
            q.limitReached ? 2 : Theme.level(max(q.session?.percent ?? 0, q.weekly?.percent ?? 0))
        }.max() ?? 0
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            tabs
            if flat {
                VStack(spacing: 10) { content }
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 10) { content }.padding(.bottom, 4)
                }
                .frame(maxHeight: .infinity)
            }
            footer
        }
        .padding(16)
        .id(lang)
        .frame(width: 400, height: flat ? nil : ui.height)
        .background(
            LinearGradient(colors: [Theme.accent.opacity(0.10), Color.purple.opacity(0.06), .clear],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }

    var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: Theme.appIcon).resizable().interpolation(.high).frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 1) {
                Text("UsageBar").font(.system(size: 18, weight: .bold))
                Text(L("AI 사용량 모니터", "AI usage monitor")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(Theme.levelColor(overall)).frame(width: 9, height: 9)
                    .overlay(Circle().stroke(Theme.levelColor(overall).opacity(0.3), lineWidth: 4))
                Text([L("정상", "Healthy"), L("주의", "Watch"), L("한도 임박", "Near limit")][overall]).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Color(nsColor: .textBackgroundColor).opacity(0.8)))
            .overlay(Capsule().strokeBorder(Theme.levelColor(overall).opacity(0.35)))
        }
    }

    var tabs: some View {
        HStack(spacing: 6) {
            ForEach(DashTab.allCases.filter { $0.provider == nil || Pref.enabled($0.provider!) }, id: \.self) { t in
                let on = ui.tab == t
                Button { ui.tab = t } label: {
                    HStack(spacing: 5) {
                        if let logo = t.provider?.logo {
                            Image(nsImage: logo).resizable().interpolation(.high).frame(width: 18, height: 18)
                        } else {
                            Image(systemName: t.symbol).font(.system(size: 11, weight: .semibold))
                        }
                        Text(t.title).font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(on ? Color.white : Color.primary)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(on ? AnyShapeStyle(LinearGradient(colors: [Theme.accent, Color(red: 0.85, green: 0.35, blue: 0.55)], startPoint: .leading, endPoint: .trailing))
                                                  : AnyShapeStyle(Color(nsColor: .textBackgroundColor).opacity(0.7))))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(on ? 0 : 0.08)))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    @ViewBuilder var content: some View {
        if let p = ui.tab.provider, Pref.enabled(p) {
            detail(p)
        } else {
            ForEach(providers, id: \.self) { p in
                if store.loggedIn[p] == false {
                    LoginCard(provider: p)
                } else {
                    AccountRow(provider: p, store: store, ui: ui)
                    limits(p)
                }
            }
            summary
        }
    }

    func limits(_ p: Provider) -> some View {
        let q = store.quotas[p]
        return HStack(spacing: 10) {
            LimitCard(title: L("세션", "Session"), symbol: "bolt.fill", bucket: q?.session, window: 5 * 3600, limitReached: q?.limitReached ?? false)
            LimitCard(title: L("주간", "Weekly"), symbol: "calendar", bucket: q?.weekly, window: 7 * 86400, limitReached: q?.limitReached ?? false)
        }
    }

    // 전체 탭: 오늘 토큰을 서비스별로 한 줄씩
    @ViewBuilder var summary: some View {
        let rows = providers.compactMap { p in store.local[p].map { (p, $0.day(offset: 0)) } }
        if !rows.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    CardTitle(symbol: "number.circle.fill", color: .green, text: L("오늘 사용", "Today"))
                    ForEach(rows, id: \.0) { p, d in
                        HStack {
                            HStack(spacing: 5) {
                                if let logo = p.logo { Image(nsImage: logo).resizable().frame(width: 18, height: 18) }
                                Text(p.logo == nil ? "\(p.icon) \(p.name)" : p.name).font(.system(size: 13, weight: .semibold))
                            }
                            Spacer()
                            Text(L("\(Fmt.tokens(d.tokens)) 토큰", "\(Fmt.tokens(d.tokens)) tokens")).monospacedDigit()
                            if p == .claude { Text("· \(Fmt.money(d.cost))").foregroundStyle(.secondary).monospacedDigit() }
                            Text("· \(Fmt.duration(d.seconds))").foregroundStyle(.secondary)
                        }
                        .font(.system(size: 12))
                    }
                }
            }
        }
    }

    @ViewBuilder func detail(_ p: Provider) -> some View {
        if store.loggedIn[p] == false {
            LoginCard(provider: p)
        } else {
            detailBody(p)
        }
    }

    @ViewBuilder func detailBody(_ p: Provider) -> some View {
        AccountRow(provider: p, store: store, ui: ui)
        limits(p)
        if let q = store.quotas[p], !q.extras.isEmpty {
            HStack(spacing: 10) {
                ForEach(q.extras.indices, id: \.self) { i in
                    LimitCard(title: q.extras[i].0, symbol: "calendar.badge.clock", bucket: q.extras[i].1, window: 7 * 86400, limitReached: false)
                }
            }
        }
        if let s = store.local[p] {
            let today = s.day(offset: 0), yday = s.day(offset: 1)
            HStack(spacing: 10) {
                if s.hasCost {
                    StatCard(title: L("오늘 비용", "Cost today"), symbol: "dollarsign.circle.fill", color: .yellow,
                             value: Fmt.money(today.cost), unit: L("API 환산", "API rates"),
                             sub: today.saved > 0 ? savedText(today) : nil,
                             fraction: today.cost / max(0.0001, today.cost + today.saved),
                             delta: compare(today.cost, yday.cost, Fmt.money))
                }
                StatCard(title: L("오늘 토큰", "Tokens today"), symbol: "number.circle.fill", color: .green,
                         value: Fmt.tokens(today.tokens), unit: L("토큰", "Tokens"),
                         sub: L("\(Int((today.cacheRatio * 100).rounded()))% 캐시 사용", "\(Int((today.cacheRatio * 100).rounded()))% from cache"),
                         fraction: today.cacheRatio,
                         delta: compare(today.tokens, yday.tokens, Fmt.tokens))
            }
            StatCard(title: L("오늘 작업 시간", "Working time today"), symbol: "clock.fill", color: .purple,
                     value: Fmt.duration(today.seconds), unit: L("작업 시간", "Duration"), sub: nil,
                     fraction: min(1, today.seconds / (8 * 3600)),
                     delta: compare(today.seconds, yday.seconds, Fmt.duration))
            HourlyChart(provider: p, stats: s, ui: ui)
            DailyChart(provider: p, stats: s, ui: ui)
            RankCard(provider: p, stats: s, ui: ui)
        }
        if let q = store.quotas[p] {
            let rows = q.breakdown.filter { $0.1 > 0 }
            if !rows.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        CardTitle(symbol: "chart.pie.fill", color: .pink, text: L("주간 사용 비중", "Weekly usage share"))
                        ForEach(rows.indices, id: \.self) { i in
                            HStack {
                                Text(rows[i].0).font(.system(size: 12))
                                    .frame(width: 90, alignment: .leading)
                                ProgressBar(fraction: rows[i].1 / 100, fill: AnyShapeStyle(Color.pink.gradient))
                                Text("\(Int(rows[i].1))%").font(.system(size: 12)).monospacedDigit()
                                    .frame(width: 36, alignment: .trailing)
                            }
                        }
                    }
                }
            }
        }
    }

    var footer: some View {
        HStack(spacing: 8) {
            footerButton(L("대시보드", "Dashboard"), "safari") {
                NSWorkspace.shared.open((ui.tab.provider ?? providers.first ?? .claude).webURL)
            }
            footerButton(store.loading ? L("불러오는 중", "Loading") : L("새로고침", "Refresh"), "arrow.clockwise", action: onRefresh)
            Spacer()
            circleButton("gearshape.fill", help: L("설정", "Settings"), action: onSettings)
            circleButton("power", help: L("종료", "Quit"), action: onQuit)
        }
    }

    func footerButton(_ text: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                Text(text).font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Capsule().fill(Color(nsColor: .textBackgroundColor).opacity(0.8)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    func circleButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(Circle().fill(Color(nsColor: .textBackgroundColor).opacity(0.8)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
