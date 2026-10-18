import SwiftUI

// 설정 > 메뉴 막대: 미리보기 + 항목 카탈로그(칩) + 간격

// 줄이 넘치면 다음 줄로 넘기는 배치
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}

// 켜고 끄는 칩
struct CatalogChip: View {
    let title: String
    let symbol: String?
    var image: NSImage? = nil
    let on: Bool
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let image {
                    Image(nsImage: image).resizable().frame(width: 16, height: 16)
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                }
                Text(title).font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(on ? Color.white : Color.primary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(on ? Color.accentColor : Color.clear))
            .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: on ? 0 : 1.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }
}

// 메뉴 막대 미리보기 (설정 값이 바뀌면 다시 그려짐)
struct BarPreview: View {
    @ObservedObject var store: UsageStore
    var size: CGFloat = 13
    @AppStorage(Pref.showIcon) var showIcon = true
    @AppStorage(Pref.useLogo) var useLogo = true
    @AppStorage(Pref.useRing) var useRing = false
    @AppStorage(Pref.showName) var showName = false
    @AppStorage(Pref.showSession) var showSession = true
    @AppStorage(Pref.showSessionLeft) var showSessionLeft = false
    @AppStorage(Pref.showLeftLabel) var showLeftLabel = true
    @AppStorage(Pref.showWeekly) var showWeekly = true
    @AppStorage(Pref.showLabels) var showLabels = false
    @AppStorage(Pref.showReset) var showReset = false
    @AppStorage(Pref.useGauge) var useGauge = false
    @AppStorage(Pref.spacing) var spacing = 10.0
    @AppStorage(Pref.colorWarnings) var colorWarnings = true
    @ObservedObject var watcher = PrefsWatcher.shared   // 서비스 켜고 끄기 등 나머지 설정

    var body: some View {
        // 위 값들이 바뀔 때마다 다시 그려지도록 읽어둠
        _ = (showIcon, useLogo, useRing, showName, showSession, showSessionLeft, showLeftLabel, showWeekly,
             showLabels, showReset, useGauge, colorWarnings, watcher.tick)
        let segs = Format.segments(store.quotas, sampleIfMissing: true)
        return HStack(spacing: spacing) {
            ForEach(segs.indices, id: \.self) { i in
                HStack(spacing: 4) {
                    if segs[i].2.showsRing {
                        Image(nsImage: Ring.image(store.quotas[segs[i].2] ?? .sample, size: size + 2))
                    } else if segs[i].2.showsLogo, let img = segs[i].2.logo {
                        Image(nsImage: img).resizable().frame(width: size + 3, height: size + 3)
                    }
                    if !segs[i].0.isEmpty {
                        Text(segs[i].0).foregroundStyle([Color.primary, .orange, .red][segs[i].1])
                    }
                }
            }
        }
        .font(.system(size: size, weight: .medium).monospacedDigit())
    }
}

struct MenubarCatalogView: View {
    @ObservedObject var store: UsageStore
    var flat = false   // 스냅샷용: 스크롤 없이 그림
    @AppStorage(Pref.showIcon) var showIcon = true
    @AppStorage(Pref.useLogo) var useLogo = true
    @AppStorage(Pref.useRing) var useRing = false
    @AppStorage(Pref.showName) var showName = false
    @AppStorage(Pref.showSession) var showSession = true
    @AppStorage(Pref.showSessionLeft) var showSessionLeft = false
    @AppStorage(Pref.showLeftLabel) var showLeftLabel = true
    @AppStorage(Pref.showWeekly) var showWeekly = true
    @AppStorage(Pref.showLabels) var showLabels = false
    @AppStorage(Pref.showReset) var showReset = false
    @AppStorage(Pref.useGauge) var useGauge = false
    @AppStorage(Pref.spacing) var spacing = 10.0

    var anyValue: Bool { showSession || showSessionLeft || showWeekly }

    var body: some View {
        if flat { content } else { ScrollView { content } }
    }

    var content: some View {
            VStack(alignment: .leading, spacing: 18) {
                header(L("현재 메뉴 막대", "Selected Menu Bar Items"), "menubar.rectangle")
                panel {
                    HStack {
                        BarPreview(store: store, size: 15)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
                        Spacer()
                    }
                }

                header(L("항목 카탈로그", "Menu Bar Items Catalog"), "book")
                panel {
                    VStack(alignment: .leading, spacing: 18) {
                        group(L("아이콘 스타일", "Icon Style"), note: L("하나만 선택", "Choose one")) {
                            CatalogChip(title: L("숨기기", "Don't Show"), symbol: "eye.slash", on: !showIcon) {
                                showIcon = false
                            }
                            CatalogChip(title: L("기호 (✳︎ ◎)", "Symbols (✳︎ ◎)"), symbol: "asterisk", on: showIcon && !useLogo && !useRing) {
                                showIcon = true; useLogo = false; useRing = false
                            }
                            CatalogChip(title: L("앱 로고", "App Logos"), symbol: nil, image: Provider.claude.logo, on: showIcon && useLogo && !useRing) {
                                showIcon = true; useLogo = true; useRing = false
                            }
                            CatalogChip(title: L("링 게이지", "Ring Gauge"), symbol: "circle.dashed", on: showIcon && useRing) {
                                showIcon = true; useRing = true
                            }
                        }
                        group(L("서비스", "Services"), note: L("하나 이상", "At least one")) {
                            ForEach(Provider.allCases, id: \.self) { p in ServiceChip(provider: p) }
                        }
                        group(L("세션 (5시간)", "Session (5h)"), note: nil) {
                            CatalogChip(title: L("사용량", "Used"), symbol: "bolt.fill", on: showSession) { showSession.toggle() }
                            CatalogChip(title: L("남은 사용량", "Remaining"), symbol: "battery.75percent", on: showSessionLeft) { showSessionLeft.toggle() }
                            CatalogChip(title: L("“남음” 글자", "“left” Label"), symbol: "textformat", on: showLeftLabel,
                                        disabled: !showSessionLeft) { showLeftLabel.toggle() }
                            CatalogChip(title: L("초기화까지 남은 시간", "Time to Reset"), symbol: "clock", on: showReset,
                                        disabled: !showSession && !showSessionLeft) { showReset.toggle() }
                        }
                        group(L("주간", "Weekly"), note: nil) {
                            CatalogChip(title: L("사용량", "Used"), symbol: "calendar", on: showWeekly) { showWeekly.toggle() }
                        }
                        group(L("표시 옵션", "Display Options"), note: nil) {
                            CatalogChip(title: L("서비스 이름", "Service Name"), symbol: "character.textbox", on: showName) { showName.toggle() }
                            CatalogChip(title: L("5h · 7d 라벨", "5h · 7d Labels"), symbol: "tag", on: showLabels,
                                        disabled: !anyValue) { showLabels.toggle() }
                            CatalogChip(title: L("막대 게이지 (▰▱)", "Gauge (▰▱)"), symbol: "chart.bar.fill", on: useGauge,
                                        disabled: !anyValue) { useGauge.toggle() }
                        }
                        Divider()
                        HStack {
                            Spacer()
                            Button { resetDefaults() } label: {
                                Label(L("기본값", "Reset"), systemImage: "arrow.counterclockwise")
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                            Button { clearAll() } label: {
                                Label(L("모두 끄기", "Clear All"), systemImage: "trash")
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 14).padding(.vertical, 7)
                                    .background(Capsule().fill(Color.red.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
                        }
                        .font(.system(size: 13, weight: .medium))
                    }
                }

                HStack(spacing: 10) {
                    header(L("서비스 간 간격", "Spacing Between Services"), "arrow.left.and.right")
                    Spacer()
                    Text("0").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $spacing, in: 0...30, step: 2).frame(width: 200)
                    Text("30").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24)
    }

    func header(_ text: String, _ symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 15))
            Text(text).font(.system(size: 15, weight: .semibold))
        }
    }

    func panel<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }

    func group<C: View>(_ title: String, note: String?, @ViewBuilder _ chips: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let note { Text("(\(note))").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            FlowLayout(spacing: 8) { chips() }
        }
    }

    func resetDefaults() {
        let d = UserDefaults.standard
        for k in [Pref.showIcon, Pref.useLogo, Pref.useRing, Pref.showName, Pref.showSession, Pref.showSessionLeft, Pref.showLeftLabel,
                  Pref.showWeekly, Pref.showLabels, Pref.showReset, Pref.useGauge, Pref.spacing]
                  + Provider.allCases.map(\.enabledKey) {
            d.removeObject(forKey: k)
        }
    }

    // 값 표시는 모두 끄고 아이콘만 남김
    func clearAll() {
        showName = false; showSession = false; showSessionLeft = false; showWeekly = false
        showLabels = false; showReset = false; useGauge = false
        showIcon = true
    }
}
