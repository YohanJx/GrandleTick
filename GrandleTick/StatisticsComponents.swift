import SwiftUI
import Charts

// MARK: - Supporting Subviews & Components

struct OverviewMetric: View {
    let title: String
    let value: String
    var subtitle: String?
    let icon: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 25, height: 25)
                .background(Circle().fill(tint.opacity(0.12)))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundColor(AppDesign.secondaryText)

                AppStatValue(value: value, compact: true, tint: tint)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 8))
                        .foregroundColor(AppDesign.tertiaryText)
                        .lineLimit(1)
                }
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppDesign.controlCornerRadius, style: .continuous)
                .fill(AppDesign.tintedSurface(tint, opacity: 0.08))
        )
    }
}

struct LearningLeisureSummaryBar: View {
    let studyDuration: TimeInterval
    let entertainmentDuration: TimeInterval
    let formatDuration: (TimeInterval) -> String

    private var totalDuration: TimeInterval {
        studyDuration + entertainmentDuration
    }

    private var studyShare: Double {
        totalDuration > 0 ? studyDuration / totalDuration : 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("学习与休闲")
                    .font(.headline)
                Spacer()
                Text("学习占比 \(Int((studyShare * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(AppDesign.secondaryText)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(AppDesign.leisurePurple.opacity(0.72))

                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(AppDesign.primaryBlue)
                        .frame(width: geometry.size.width * studyShare)
                }
            }
            .frame(height: 9)

            HStack(spacing: 20) {
                ReportLegendStat(title: "学习", value: formatDuration(studyDuration), tint: AppDesign.primaryBlue)
                ReportLegendStat(title: "休闲", value: formatDuration(entertainmentDuration), tint: AppDesign.leisurePurple)
                Spacer()
            }
        }
        .padding(18)
        .statisticsPanel()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("学习与休闲使用分布")
        .accessibilityValue("学习 \(formatDuration(studyDuration))，休闲 \(formatDuration(entertainmentDuration))")
    }
}

struct FilterSection: View {
    @Binding var searchText: String
    @Binding var selectedContentFilter: ContentFilter
    @Binding var selectedAppFilter: String?
    @Binding var selectedDomainFilter: String?
    let appOptions: [FilterOption]
    let domainOptions: [FilterOption]
    let formatDuration: (TimeInterval) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("筛选条件")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if hasActiveFilters {
                    Button("清空筛选") {
                        searchText = ""
                        selectedContentFilter = .all
                        selectedAppFilter = nil
                        selectedDomainFilter = nil
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .font(.caption)
                }
            }

            TextField("搜索应用、域名、标题或链接", text: $searchText)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .frame(height: AppDesign.controlHeight)
                .background(
                    RoundedRectangle(cornerRadius: AppDesign.controlCornerRadius, style: .continuous)
                        .fill(AppDesign.elevatedPanelBackground)
                )

            HStack(spacing: 8) {
                ForEach(ContentFilter.allCases) { filter in
                    Button(filter == .all ? "全部" : filter == .website ? "网页" : "PDF") {
                        selectedContentFilter = filter
                    }
                    .buttonStyle(AppCapsuleButtonStyle(
                        role: selectedContentFilter == filter ? .primary : .secondary,
                        compact: true
                    ))
                }
            }

            HStack(spacing: 12) {
                Menu {
                    Button("全部应用") { selectedAppFilter = nil }
                    if !appOptions.isEmpty { Divider() }
                    ForEach(appOptions.prefix(12)) { option in
                        Button { selectedAppFilter = option.name } label: {
                            HStack {
                                Text(option.name)
                                Spacer()
                                Text(formatDuration(option.totalTime))
                            }
                        }
                    }
                } label: {
                    FilterChip(title: "应用", value: selectedAppFilter ?? "全部应用")
                }
                .buttonStyle(.plain)

                Menu {
                    Button("全部域名") { selectedDomainFilter = nil }
                    if !domainOptions.isEmpty { Divider() }
                    ForEach(domainOptions.prefix(12)) { option in
                        Button { selectedDomainFilter = option.name } label: {
                            HStack {
                                Text(option.name)
                                Spacer()
                                Text(formatDuration(option.totalTime))
                            }
                        }
                    }
                } label: {
                    FilterChip(title: "域名", value: selectedDomainFilter ?? "全部域名")
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .statisticsPanel(isSecondary: true)
    }

    private var hasActiveFilters: Bool {
        !searchText.isEmpty || selectedContentFilter != .all || selectedAppFilter != nil || selectedDomainFilter != nil
    }
}

struct FilterChip: View {
    let title: String
    let value: String
    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Spacer()
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundColor(.secondary)
        }
        .padding(.vertical, 8).padding(.horizontal, 10).frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppDesign.controlCornerRadius, style: .continuous)
                .fill(AppDesign.elevatedPanelBackground)
        )
    }
}

struct RangeTrendSection: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let daySummaries: [DaySummary]
    let selectedDay: Date?
    let chartDataGeneration: UInt
    let onSelectDay: (Date) -> Void
    let formatDuration: (TimeInterval) -> String
    @State private var highlightedDay: Date?
    @State private var commitTask: Task<Void, Never>?
    @State private var chartVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("每日学习趋势").font(.headline)
            Chart(daySummaries) { daySummary in
                BarMark(x: .value("日期", daySummary.date, unit: .day), y: .value("时长", daySummary.totalTime / 3600))
                .foregroundStyle(barGradient(for: daySummary.date, colorScheme: colorScheme))
                .cornerRadius(6)
                .annotation(position: .top, alignment: .center) {
                    if isHighlighted(daySummary.date) {
                        Text(formatDuration(daySummary.totalTime))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(colorScheme == .dark ? .white : .secondary)
                    }
                }
            }
            .frame(height: 200)
            .opacity(reduceMotion || chartVisible ? 1 : 0)
            .scaleEffect(y: reduceMotion || chartVisible ? 1 : 0.92, anchor: .bottom)
            .chartYAxis { AxisMarks(position: .leading) }
            .chartXAxis { AxisMarks(values: .automatic) { value in AxisGridLine(); AxisValueLabel { if let date = value.as(Date.self) { Text(formatShortDate(date)) } } } }
            .chartOverlay { proxy in GeometryReader { geometry in Rectangle().fill(.clear).contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { value in updateSelection(at: value.location, proxy: proxy, geometry: geometry) }) } }
            .chartXScale(domain: chartDateDomain)
            // 每批统计结果都重建 Charts 内部布局，避免月视图多日期缩到周视图单日期时复用旧比例尺并产生 NaN。
            .id(chartDataGeneration)

            if let strongestDay = daySummaries.max(by: { $0.totalTime < $1.totalTime }) {
                HStack {
                    Text("单日最高学习").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Text(strongestDay.date.formatted(.dateTime.month(.defaultDigits).day())).font(.caption).foregroundColor(.secondary)
                    Text(formatDuration(strongestDay.totalTime)).font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
            }
        }
        .padding(18)
        .statisticsPanel()
        .onAppear {
            highlightedDay = selectedDay
            withAnimation(reduceMotion ? nil : AppDesign.springAnimation.delay(0.08)) {
                chartVisible = true
            }
        }
        .onChange(of: selectedDay) { _, newValue in commitTask?.cancel(); if !isSameDay(highlightedDay, newValue) { highlightedDay = newValue } }
    }

    private func isHighlighted(_ date: Date) -> Bool { guard let highlightedDay else { return false }; return Calendar.current.isDate(date, inSameDayAs: highlightedDay) }

    private var chartDateDomain: ClosedRange<Date> {
        // 单日统计也显式保留完整一天的横轴宽度，避免自动日期域退化成起止点相同的零长度区间。
        let calendar = Calendar.current
        let firstDate = daySummaries.first?.date ?? Date()
        let lastDate = daySummaries.last?.date ?? firstDate
        let start = calendar.startOfDay(for: firstDate)
        let lastDayStart = calendar.startOfDay(for: lastDate)
        let end = calendar.date(byAdding: .day, value: 1, to: lastDayStart)
            ?? lastDayStart.addingTimeInterval(24 * 60 * 60)
        return start...end
    }

    private func updateSelection(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        // 1. 提取图表的绘图区域，并将触摸点坐标转换为相对于绘图区的坐标。
        guard let plotFrame = proxy.plotFrame.map({ geometry[$0] }) else { return }
        let relativeX = location.x - plotFrame.origin.x
        guard relativeX >= 0, relativeX <= plotFrame.size.width else { return }
        
        // 2. 计算触摸位置在 X 轴上距离最近的每日柱状数据中心点。
        let nearest = daySummaries.compactMap { daySummary -> (summary: DaySummary, distance: CGFloat)? in
            guard let centerDate = Calendar.current.date(byAdding: .hour, value: 12, to: daySummary.date), let positionX = proxy.position(forX: centerDate) else { return nil }
            return (daySummary, abs(positionX - relativeX))
        }.min { $0.distance < $1.distance }
        
        // 3. 找出距离最近的日期，若与当前选中日期不同，则更新高亮状态并延迟提交选择。
        if let nearest, !isHighlighted(nearest.summary.date) { highlightedDay = nearest.summary.date; scheduleCommit(for: nearest.summary.date) }
    }
    private func scheduleCommit(for date: Date) { commitTask?.cancel(); commitTask = Task { try? await Task.sleep(for: .milliseconds(80)); guard !Task.isCancelled else { return }; await MainActor.run { onSelectDay(date) } } }
    private func isSameDay(_ lhs: Date?, _ rhs: Date?) -> Bool { switch (lhs, rhs) { case let (left?, right?): return Calendar.current.isDate(left, inSameDayAs: right); case (nil, nil): return true; default: return false } }
    private func formatShortDate(_ date: Date) -> String {
        let comps = Calendar.current.dateComponents([.month, .day], from: date)
        return "\(comps.month ?? 0)/\(comps.day ?? 0)"
    }
    
    // 2. 为趋势图设计带平滑渐变的柱状样式，增强交互高亮时的对比度。
    private func barGradient(for date: Date, colorScheme: ColorScheme) -> LinearGradient {
        if isHighlighted(date) {
            return LinearGradient(
                colors: [AppDesign.primaryBlue, AppDesign.websiteTeal.opacity(0.72)],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            return LinearGradient(
                colors: [AppDesign.primaryBlue.opacity(colorScheme == .dark ? 0.35 : 0.22), AppDesign.websiteTeal.opacity(colorScheme == .dark ? 0.15 : 0.08)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

struct DayPickerSection: View {
    let daySummaries: [DaySummary]
    let selectedDay: Date?
    let onSelect: (Date) -> Void
    let formatDuration: (TimeInterval) -> String
    let formatDate: (Date) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("按日期查看").font(.system(size: 14, weight: .semibold)).foregroundColor(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(daySummaries.sorted { $0.date > $1.date }) { daySummary in
                        Button(action: { onSelect(daySummary.date) }) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(formatDate(daySummary.date)).font(.system(size: 12, weight: .semibold))
                                Text(formatDuration(daySummary.totalTime)).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                            }
                            .padding(.vertical, 8).padding(.horizontal, 10)
                            .background(
                                RoundedRectangle(cornerRadius: AppDesign.controlCornerRadius, style: .continuous)
                                    .fill(isSelected(daySummary.date) ? AppDesign.primaryBlueMuted : AppDesign.elevatedPanelBackground)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: AppDesign.controlCornerRadius, style: .continuous)
                                    .stroke(isSelected(daySummary.date) ? AppDesign.primaryBlue.opacity(0.28) : Color.clear, lineWidth: 1)
                            )
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
    private func isSelected(_ date: Date) -> Bool { guard let selectedDay else { return false }; return Calendar.current.isDate(date, inSameDayAs: selectedDay) }
}

struct RankingSection: View {
    @Binding var selectedDimension: RankingDimension
    let rankingEntries: [RankingEntry]
    let formatDuration: (TimeInterval) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("学习时长排行").font(.headline)
            HStack(spacing: 8) {
                ForEach(RankingDimension.allCases) { dimension in
                    Button(dimension == .app ? "应用" : dimension == .domain ? "域名" : "窗口") {
                        selectedDimension = dimension
                    }
                    .buttonStyle(AppCapsuleButtonStyle(
                        role: selectedDimension == dimension ? .primary : .secondary,
                        compact: true
                    ))
                }
            }

            if rankingEntries.isEmpty {
                Text("无数据").font(.caption).foregroundColor(.secondary).padding(.top, 4)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(rankingEntries.prefix(8).enumerated()), id: \.element.id) { index, entry in
                        HStack(spacing: 12) {
                            let rankTint = AppDesign.chartPalette[index % AppDesign.chartPalette.count]
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(rankTint)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(rankTint.opacity(0.12)))

                            Text(entry.name)
                                .font(.system(size: 13))
                                .lineLimit(1)

                            Spacer()

                            Text(formatDuration(entry.totalTime))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 6)
                        if index < min(rankingEntries.count, 8) - 1 {
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }
        .padding(18)
        .statisticsPanel()
    }
}

struct SelectedDaySection: View {
    let selectedDay: Date?
    let appSummaries: [GroupedSummary]
    let domainSummaries: [GroupedSummary]
    let pdfSummaries: [GroupedSummary]
    let formatDuration: (TimeInterval) -> String
    let formatDate: (Date) -> String
    let onDelete: (DetailCategory, String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("选中日期活动明细").font(.headline)
                    Text(selectedDay.map(formatDate) ?? "暂无日期").font(.caption).foregroundColor(.secondary)
                }
                Spacer()
            }

            if appSummaries.isEmpty && domainSummaries.isEmpty && pdfSummaries.isEmpty {
                Text("当天没有学习记录").font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 16)
            } else {
                VStack(spacing: 12) {
                    CategorySummaryGroup(title: "按应用", emptyText: "无应用记录", summaries: appSummaries, formatDuration: formatDuration, onDelete: { onDelete(.app, $0, $1) })
                    CategorySummaryGroup(title: "按域名", emptyText: "无域名记录", summaries: domainSummaries, formatDuration: formatDuration, onDelete: { onDelete(.domain, $0, $1) })
                    CategorySummaryGroup(title: "按 PDF", emptyText: "无 PDF 记录", summaries: pdfSummaries, formatDuration: formatDuration, onDelete: { onDelete(.pdf, $0, $1) })
                }
            }
        }
        .padding(18)
        .statisticsPanel()
    }
}

struct CategorySummaryGroup: View {
    let title, emptyText: String
    let summaries: [GroupedSummary]
    let formatDuration: (TimeInterval) -> String
    let onDelete: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .bold)).foregroundColor(.secondary)
            if summaries.isEmpty {
                Text(emptyText).font(.caption).foregroundColor(.secondary).padding(.leading, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(summaries.enumerated()), id: \.element.id) { index, summary in
                        SummaryEntryRowView(summary: summary, formatDuration: formatDuration, onDelete: { onDelete(summary.name, $0) })
                        if index < summaries.count - 1 {
                            Divider()
                                .opacity(0.35)
                                .padding(.leading, 44)
                        }
                    }
                }
            }
        }
    }
}

struct SummaryEntryRowView: View {
    let summary: GroupedSummary
    let formatDuration: (TimeInterval) -> String
    let onDelete: (String) -> Void

    @State private var showsAllDetails = false

    private var visibleDetails: ArraySlice<SummaryDetail> {
        showsAllDetails ? summary.details[...] : summary.details.prefix(4)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.12)).frame(width: 32, height: 32)
                Text(String(summary.name.prefix(1)).uppercased()).font(.system(size: 14, weight: .bold)).foregroundColor(.blue)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(summary.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text(formatDuration(summary.totalTime)).font(.system(size: 12, design: .monospaced)).foregroundColor(.secondary)
                }

                // 默认限制每组的明细节点数量，长时间使用后单日记录再多也不会拖慢整页滚动。
                ForEach(visibleDetails) { detail in
                    HStack(alignment: .top) {
                        Text("•").foregroundColor(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(detail.name).font(.system(size: 11)).foregroundColor(.primary.opacity(0.8)).lineLimit(2)
                            if let subtitle = detail.subtitle {
                                Text(subtitle).font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(formatDuration(detail.totalTime)).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary.opacity(0.8))
                    }
                    .contextMenu {
                        Button(role: .destructive) { onDelete(detail.name) } label: {
                            Label("删除本条记录", systemImage: "trash")
                        }
                    }
                }

                if summary.details.count > 4 {
                    Button(showsAllDetails ? "收起明细" : "展开其余 \(summary.details.count - 4) 项") {
                        withAnimation(AppDesign.animationCurve) {
                            showsAllDetails.toggle()
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppDesign.primaryBlue)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
    }
}

// MARK: - Merged Custom Report Components

struct LearningVsEntertainmentDonutCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let studyDuration: TimeInterval
    let entertainmentDuration: TimeInterval
    let chartDataGeneration: UInt
    let formatDuration: (TimeInterval) -> String

    @State private var animateData = false

    private var total: TimeInterval { studyDuration + entertainmentDuration }
    private var studyShare: Double { total > 0 ? studyDuration / total : 1.0 }

    struct Segment: Identifiable {
        let type: String
        let duration: Double
        let color: Color
        var id: String { type }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("学习与休闲分布")
                .font(.system(size: 14, weight: .semibold))

            HStack(spacing: 16) {
                let data = [
                    Segment(type: "学习时间", duration: studyDuration, color: AppDesign.primaryBlue),
                    Segment(type: "休闲时间", duration: entertainmentDuration, color: AppDesign.leisurePurple)
                ].filter { $0.duration > 0 }

                Chart(data) { segment in
                    SectorMark(
                        angle: .value("时间", segment.duration),
                        innerRadius: .ratio(0.60),
                        angularInset: 2.0
                    )
                    .cornerRadius(6)
                    .foregroundStyle(segment.color)
                }
                .frame(width: 100, height: 100)
                .scaleEffect(reduceMotion || animateData ? 1.0 : 0.96)
                .opacity(animateData ? 1.0 : 0.0)
                .chartBackground { chartProxy in
                    GeometryReader { geo in
                        if let frame = chartProxy.plotFrame {
                            let frameWidth = geo[frame].width
                            let frameHeight = geo[frame].height
                            VStack(spacing: 2) {
                                Text("学习占比")
                                    .font(.system(size: 8))
                                    .foregroundColor(.secondary)
                                Text("\(Int((studyShare * 100).rounded()))%")
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                    .foregroundColor(AppDesign.primaryBlue)
                            }
                            .position(x: frameWidth / 2, y: frameHeight / 2)
                        }
                    }
                }
                // SectorMark 对动态增删扇区较敏感；按完整统计批次重建可避免内部角度缓存跨周期复用。
                .id(chartDataGeneration)

                VStack(alignment: .leading, spacing: 8) {
                    ReportLegendStat(title: "学习时间", value: formatDuration(studyDuration), tint: AppDesign.primaryBlue)
                    ReportLegendStat(title: "休闲时间", value: formatDuration(entertainmentDuration), tint: AppDesign.leisurePurple)
                }

                Spacer()
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .statisticsPanel()
        .onAppear {
            withAnimation(reduceMotion ? nil : AppDesign.animationCurve.delay(0.04)) {
                animateData = true
            }
        }
    }
}

struct ContentCategoryDonutCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let websiteDuration: TimeInterval
    let pdfDuration: TimeInterval
    let totalDuration: TimeInterval
    let chartDataGeneration: UInt
    let formatDuration: (TimeInterval) -> String

    @State private var animateData = false

    struct Category: Identifiable {
        let name: String
        let duration: Double
        let color: Color
        var id: String { name }
    }

    private var categories: [Category] {
        let appDuration = max(0, totalDuration - websiteDuration - pdfDuration)
        return [
            Category(name: "PDF 文档", duration: pdfDuration, color: AppDesign.documentOrange),
            Category(name: "网页浏览", duration: websiteDuration, color: AppDesign.websiteTeal),
            Category(name: "应用", duration: appDuration, color: AppDesign.primaryBlue)
        ].filter { $0.duration > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("学习来源分布")
                .font(.system(size: 14, weight: .semibold))

            HStack(spacing: 16) {
                Chart(categories) { item in
                    SectorMark(
                        angle: .value("时长", item.duration),
                        innerRadius: .ratio(0.60),
                        angularInset: 2.0
                    )
                    .cornerRadius(5)
                    .foregroundStyle(item.color)
                }
                .frame(width: 100, height: 100)
                .scaleEffect(reduceMotion || animateData ? 1.0 : 0.96)
                .opacity(animateData ? 1.0 : 0.0)
                .id(chartDataGeneration)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(categories) { item in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(item.color)
                                .frame(width: 6, height: 6)

                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.name)
                                    .font(.system(size: 9))
                                    .foregroundColor(.primary.opacity(0.85))
                                Text(formatDuration(item.duration))
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                Spacer()
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .statisticsPanel()
        .onAppear {
            withAnimation(reduceMotion ? nil : AppDesign.animationCurve.delay(0.06)) {
                animateData = true
            }
        }
    }
}

struct RhythmSection: View {
    let hourlyDurations: [Double]
    let primaryTimeSlot: ReportTimeSlot?
    let earliestStudyStart: Date?
    let latestStudyEnd: Date?
    let chartDataGeneration: UInt
    let formatDuration: (TimeInterval) -> String
    let formatClock: (Date) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("学习时段分布")
                .font(.headline)

            HStack(alignment: .top, spacing: 16) {
                // Left: Hourly Area/Line Chart
                VStack(alignment: .leading, spacing: 10) {
                    ReportRhythmHourlyChart(
                        hourlyDurations: hourlyDurations,
                        chartDataGeneration: chartDataGeneration
                    )

                    if let primaryTimeSlot {
                        HStack(spacing: 0) {
                            Text("你更常在")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                            Text(" \(primaryTimeSlot.title) ")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(AppDesign.primaryBlue)
                            Text("时段进入学习状态。")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                // Right: Clock indicator cards
                VStack(spacing: 12) {
                    ClockCard(
                        title: "最早开始",
                        time: earliestStudyStart.map(formatClock) ?? "--:--",
                        subtitle: "最早开始学习"
                    )

                    ClockCard(
                        title: "最晚结束",
                        time: latestStudyEnd.map(formatClock) ?? "--:--",
                        subtitle: "最晚结束学习"
                    )
                }
                .frame(width: 160)
            }
        }
        .padding(18)
        .statisticsPanel()
    }
}

struct ReportRhythmHourlyChart: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let hourlyDurations: [Double]
    let chartDataGeneration: UInt

    @State private var animateData = false

    var body: some View {
        let chartData = hourlyDurations.enumerated().map { index, value in
            (hour: index, value: value / 3600.0)
        }

        Chart {
            ForEach(chartData, id: \.hour) { item in
                AreaMark(
                    x: .value("时间", "\(item.hour)点"),
                    y: .value("时长", item.value)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [AppDesign.primaryBlue.opacity(0.24), AppDesign.primaryBlue.opacity(0.01)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }

            ForEach(chartData, id: \.hour) { item in
                LineMark(
                    x: .value("时间", "\(item.hour)点"),
                    y: .value("时长", item.value)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [AppDesign.primaryBlue, AppDesign.websiteTeal],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .lineStyle(StrokeStyle(lineWidth: 2.5))
            }
        }
        .frame(height: 120)
        // 仅对合成层做入场效果，不再逐帧修改 48 个 Chart mark 的数据并触发布局。
        .opacity(reduceMotion || animateData ? 1 : 0)
        .scaleEffect(y: reduceMotion || animateData ? 1 : 0.96, anchor: .bottom)
        .chartXAxis {
            AxisMarks(values: ["0点", "4点", "8点", "12点", "16点", "20点"]) { value in
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        Text(label).font(.system(size: 9))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                AxisValueLabel {
                    if let hours = value.as(Double.self) {
                        Text(hours == 0 ? "0h" : String(format: "%.1fh", hours)).font(.system(size: 9))
                    }
                }
            }
        }
        .id(chartDataGeneration)
        .onAppear {
            withAnimation(reduceMotion ? nil : AppDesign.animationCurve.delay(0.08)) {
                animateData = true
            }
        }
    }
}

struct ClockCard: View {
    let title: String
    let time: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(time)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
            Text(subtitle)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppDesign.mediumCornerRadius, style: .continuous)
                .fill(AppDesign.elevatedPanelBackground)
        )
    }
}

struct AppFocusDonutCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let topApps: [RankingEntry]
    let totalDuration: TimeInterval
    let chartDataGeneration: UInt
    let formatDuration: (TimeInterval) -> String

    @State private var animateData = false

    private let palette: [Color] = [
        AppDesign.primaryBlue,
        AppDesign.websiteTeal,
        AppDesign.documentOrange,
        AppDesign.leisurePurple
    ]

    struct Segment: Identifiable {
        let name: String
        let duration: Double
        let color: Color
        var id: String { name }
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        var sumTop = 0.0

        for (index, item) in topApps.prefix(3).enumerated() {
            let color = palette[index % palette.count]
            result.append(Segment(name: item.name, duration: item.totalTime, color: color))
            sumTop += item.totalTime
        }

        let remaining = max(0, totalDuration - sumTop)
        if remaining > 60 {
            result.append(Segment(name: "其他应用", duration: remaining, color: Color.secondary.opacity(0.25)))
        }

        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("应用学习时长占比")
                .font(.headline)

            HStack(spacing: 20) {
                Chart(segments) { segment in
                    SectorMark(
                        angle: .value("时长", segment.duration),
                        innerRadius: .ratio(0.60),
                        angularInset: 1.5
                    )
                    .cornerRadius(5)
                    .foregroundStyle(segment.color)
                }
                .frame(width: 100, height: 100)
                .scaleEffect(reduceMotion || animateData ? 1.0 : 0.96)
                .opacity(animateData ? 1.0 : 0.0)
                .id(chartDataGeneration)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(segments) { segment in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(segment.color)
                                .frame(width: 6, height: 6)

                            VStack(alignment: .leading, spacing: 0) {
                                Text(segment.name)
                                    .font(.system(size: 11))
                                    .foregroundColor(.primary.opacity(0.85))
                                    .lineLimit(1)
                                Text(formatDuration(segment.duration))
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                Spacer()
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .statisticsPanel()
        .onAppear {
            withAnimation(reduceMotion ? nil : AppDesign.animationCurve.delay(0.10)) {
                animateData = true
            }
        }
    }
}

struct ReportRankingPanel: View {
    let title: String
    let items: [RankingEntry]
    let tint: Color
    let formatDuration: (TimeInterval) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))

            if items.isEmpty {
                Text("暂无数据")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                let total = items.reduce(0) { $0 + $1.totalTime }
                VStack(spacing: 10) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        let share = total > 0 ? item.totalTime / total : 0.0
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(index + 1). \(item.name)")
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)

                                Spacer()

                                Text(formatDuration(item.totalTime))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }

                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.primary.opacity(0.06))
                                        .frame(height: 6)

                                    Capsule()
                                        .fill(
                                            LinearGradient(
                                                colors: [tint, tint.opacity(0.55)],
                                                startPoint: .leading,
                                                endPoint: .trailing
                                            )
                                        )
                                        .frame(width: max(geometry.size.width * CGFloat(share), 6), height: 6)
                                }
                            }
                            .frame(height: 6)

                            Text("占比 \(Int((share * 100).rounded()))%")
                                .font(.system(size: 9))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .statisticsPanel()
    }
}

struct ReportLegendStat: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint.opacity(0.85))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.primary)
            }
        }
    }
}

struct ReportPagerButton: View {
    let systemImage: String
    let isDisabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppDesign.primaryBlue.opacity(isDisabled ? 0.34 : 1))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: AppDesign.controlCornerRadius, style: .continuous)
                        .fill(isHovered ? AppDesign.primaryBlue.opacity(0.13) : AppDesign.primaryBlueMuted)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering in
            if !isDisabled {
                withAnimation(AppDesign.animationCurve) {
                    isHovered = hovering
                }
            }
        }
    }
}
