import SwiftUI
import SwiftData
import Charts

// MARK: - Main Statistics View

private enum StatisticsPage: String, CaseIterable, Identifiable {
    case overview
    case usageQuery
    case records

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .usageQuery: return "使用查询"
        case .records: return "记录明细"
        }
    }
}

struct StatisticsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var engine = StatisticsEngine()
    @State private var whitelist = WhitelistManager.shared
    @State private var selectedPage: StatisticsPage = .overview
    @State private var selectedRange: StatisticsRange = .week
    @State private var selectedDimension: RankingDimension = .app
    @State private var searchText: String = ""
    @State private var selectedContentFilter: ContentFilter = .all
    @State private var selectedAppFilter: String?
    @State private var selectedDomainFilter: String?
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var showAnnualReport = false
    @State private var contentVisible = false
    @State private var selectedUsageDimension: UsageQueryDimension = .app
    @State private var selectedUsageRange: UsageQueryRange = .recentTwelveMonths
    @State private var selectedUsageItem: String?
    @State private var selectedUsageMonth: Date?

    private let calendar = Calendar.current

    var body: some View {
        ZStack {
            // 1. 数据中心直接延展主菜单的系统浅灰底色，不再制造独立 Dashboard 渐变。
            AppDesign.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // 2. 顶部先划分三种用户任务，概览、单项查询和记录管理不再堆叠在同一条长页面中。
                headerSection

                // 3. 三个页面共用窗口与统计引擎，但只创建当前页面需要的图表和列表。
                pageContent
                    .opacity(contentVisible ? 1 : 0)
                    .offset(y: reduceMotion || contentVisible ? 0 : 6)
            }
            
            // 4. 年度学习报告采用应用内悬浮卡片机制，避免系统级 Sheet 窗口自带的白色直角边框与阻碍退出问题。
            if showAnnualReport {
                // 黑色半透明背景遮罩阻断下层点击，确保年度报告弹层交互独立。
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        withAnimation(reduceMotion ? nil : AppDesign.animationCurve) {
                            showAnnualReport = false
                        }
                    }
                
                // 年度报告卡片
                AnnualReportView(dismissAction: {
                    withAnimation(reduceMotion ? nil : AppDesign.animationCurve) {
                        showAnnualReport = false
                    }
                })
                .modelContext(modelContext)
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .frame(width: AppConfig.statisticsWidth, height: AppConfig.statisticsHeight)
        .ignoresSafeArea(.all, edges: .top)
        .onAppear {
            // 1. 先启动数据读取。
            refreshRangeData()

            // 2. 页面只做轻微上移淡入；减少动态效果开启时直接显示。
            if reduceMotion {
                contentVisible = true
            } else {
                withAnimation(AppDesign.animationCurve) {
                    contentVisible = true
                }
            }
        }
        // 使用 default mode，用户拖动滚动条或触控板滚动时系统会自然暂停刷新，避免滚动中重算整页。
        .onReceive(Timer.publish(every: 60, tolerance: 8, on: .main, in: .default).autoconnect()) { _ in
            refreshActivePageData()
        }
        .onChange(of: whitelist.whitelistedApps) { _, _ in refreshActivePageData() }
        .onChange(of: whitelist.whitelistedDomains) { _, _ in refreshActivePageData() }
        .onChange(of: selectedPage) { _, newPage in
            if !reduceMotion {
                contentVisible = false
                DispatchQueue.main.async {
                    withAnimation(AppDesign.animationCurve) {
                        contentVisible = true
                    }
                }
            }

            if newPage == .usageQuery {
                refreshUsageQueryData()
            } else {
                refreshRangeData()
            }
        }
        .onChange(of: selectedRange) { _, _ in
            // 切换周期时先轻微淡出旧内容，新统计回写后再淡入。
            if !reduceMotion {
                withAnimation(AppDesign.animationCurve) {
                    contentVisible = false
                }
            }
            refreshRangeData()
        }
        .onChange(of: engine.baseDataGeneration) { _, _ in
            sanitizeFilterSelection()
            refreshFiltersOnly()
        }
        .onChange(of: engine.filterComputationGeneration) { _, _ in
            withAnimation(reduceMotion ? nil : AppDesign.animationCurve) {
                contentVisible = true
            }
        }
        .onChange(of: engine.usageQueryGeneration) { _, _ in
            sanitizeUsageQuerySelection()
            withAnimation(reduceMotion ? nil : AppDesign.animationCurve) {
                contentVisible = true
            }
        }
        .onChange(of: selectedDimension) { _, _ in engine.updateRanking(for: selectedDimension) }
        .onChange(of: selectedUsageDimension) { _, _ in
            selectedUsageItem = nil
            selectedUsageMonth = nil
            sanitizeUsageQuerySelection()
        }
        .onChange(of: selectedUsageRange) { _, _ in
            selectedUsageItem = nil
            selectedUsageMonth = nil
            refreshUsageQueryData()
        }
        .onChange(of: selectedUsageItem) { _, newValue in
            selectedUsageMonth = nil
            engine.updateUsageQuery(for: selectedUsageDimension, queryKey: newValue)
        }
        .onChange(of: searchText) { _, _ in scheduleSearchRefresh() }
        .onChange(of: selectedContentFilter) { _, _ in refreshFiltersOnly() }
        .onChange(of: selectedAppFilter) { _, _ in refreshFiltersOnly() }
        .onChange(of: selectedDomainFilter) { _, _ in refreshFiltersOnly() }
        .onDisappear {
            searchDebounceTask?.cancel()
            engine.cancelPendingWork()
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var headerSection: some View {
        VStack(spacing: 12) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("数据中心")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(AppDesign.primaryText)
                        
                        Button(action: {
                            withAnimation(reduceMotion ? nil : AppDesign.animationCurve) {
                                showAnnualReport = true
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles")
                                Text("年度报告")
                            }
                            .frame(minWidth: 82)
                        }
                        .buttonStyle(AppCapsuleButtonStyle(role: .primary, compact: true))
                    }
                    Text("查看学习与活动统计")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // 使用查询拥有独立的月份范围，其它页面继续沿用原有周期翻页能力。
                if selectedPage != .usageQuery, selectedRange != .all {
                    HStack(spacing: 12) {
                        ReportPagerButton(
                            systemImage: "chevron.left",
                            isDisabled: !engine.canShowPreviousPeriod,
                            action: { shiftReferencePeriod(by: -1) }
                        )

                        Text(formatDateRange(for: selectedRange, referenceDate: engine.referenceDate))
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(minWidth: 100, alignment: .center)

                        ReportPagerButton(
                            systemImage: "chevron.right",
                            isDisabled: !engine.canShowNextPeriod,
                            action: { shiftReferencePeriod(by: 1) }
                        )
                    }
                } else if selectedPage != .usageQuery {
                    Text("全部历史数据")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 8) {
                ForEach(StatisticsPage.allCases) { page in
                    Button(page.title) {
                        selectedPage = page
                    }
                    .buttonStyle(AppCapsuleButtonStyle(
                        role: selectedPage == page ? .primary : .secondary,
                        compact: true
                    ))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if selectedPage != .usageQuery {
            HStack(spacing: 8) {
                ForEach(StatisticsRange.allCases) { range in
                    Button(range.shortTitle) {
                        selectedRange = range
                    }
                    .buttonStyle(AppCapsuleButtonStyle(
                        role: selectedRange == range ? .primary : .secondary,
                        compact: true
                    ))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch selectedPage {
        case .overview:
            overviewPage
        case .usageQuery:
            usageQueryPage
        case .records:
            recordsPage
        }
    }

    @ViewBuilder
    private var overviewPage: some View {
        if engine.baseRangeLogs.isEmpty {
            emptyStateView
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppDesign.sectionSpacing) {
                    overviewCardsGrid

                    LearningLeisureSummaryBar(
                        studyDuration: engine.studyDuration,
                        entertainmentDuration: engine.entertainmentDuration,
                        formatDuration: formatCompactDuration
                    )

                    RangeTrendSection(
                        daySummaries: engine.daySummaries,
                        selectedDay: engine.selectedDay,
                        chartDataGeneration: engine.filterComputationGeneration,
                        onSelectDay: { engine.updateSelectedDay($0) },
                        formatDuration: formatCompactDuration
                    )

                    RankingSection(
                        selectedDimension: $selectedDimension,
                        rankingEntries: engine.rankingEntries,
                        formatDuration: formatCompactDuration
                    )
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
    }

    private var usageQueryPage: some View {
        ScrollView {
            UsageQuerySection(
                selectedDimension: $selectedUsageDimension,
                selectedRange: $selectedUsageRange,
                selectedItem: $selectedUsageItem,
                selectedMonth: $selectedUsageMonth,
                appOptions: engine.usageAppOptions,
                domainOptions: engine.usageDomainOptions,
                pdfOptions: engine.usagePDFOptions,
                monthlySummaries: engine.monthlyUsageSummaries,
                monthlyWeekSummaries: engine.monthlyWeekUsageSummaries,
                totalDuration: engine.usageQueryTotalDuration,
                isLoading: engine.isLoadingUsageQuery,
                formatDuration: formatCompactDuration
            )
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
    }

    @ViewBuilder
    private var recordsPage: some View {
        if engine.baseRangeLogs.isEmpty {
            emptyStateView
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppDesign.sectionSpacing) {
                    FilterSection(
                        searchText: $searchText,
                        selectedContentFilter: $selectedContentFilter,
                        selectedAppFilter: $selectedAppFilter,
                        selectedDomainFilter: $selectedDomainFilter,
                        appOptions: engine.appFilterOptions,
                        domainOptions: engine.domainFilterOptions,
                        formatDuration: formatCompactDuration
                    )

                    if engine.rangeLogs.isEmpty {
                        filteredEmptyStateView
                    } else {
                        DayPickerSection(
                            daySummaries: engine.daySummaries,
                            selectedDay: engine.selectedDay,
                            onSelect: { engine.updateSelectedDay($0) },
                            formatDuration: formatCompactDuration,
                            formatDate: formatShortDate
                        )

                        SelectedDaySection(
                            selectedDay: engine.selectedDay,
                            appSummaries: engine.selectedDayAppSummaries,
                            domainSummaries: engine.selectedDayDomainSummaries,
                            pdfSummaries: engine.selectedDayPdfSummaries,
                            formatDuration: formatCompactDuration,
                            formatDate: formatLongDate,
                            onDelete: { category, summaryName, detailName in
                                deleteLogs(
                                    on: engine.selectedDay,
                                    category: category,
                                    summaryName: summaryName,
                                    detailName: detailName
                                )
                            }
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 32)
            }
        }
    }

    @ViewBuilder
    private var overviewCardsGrid: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                AppSectionHeader(title: "本期学习概览", subtitle: selectedRange.title, compact: true)
                Spacer()
                Label("持续积累中", systemImage: "waveform.path.ecg")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppDesign.primaryBlue)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(AppDesign.primaryBlueMuted))
            }

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("总学习时长")
                        .font(.caption)
                        .foregroundStyle(AppDesign.secondaryText)
                    AppStatValue(value: formatDetailedDuration(engine.studyDuration), tint: AppDesign.primaryBlue)

                    Text("专注时间是这份报告最重要的数字")
                        .font(.system(size: 10))
                        .foregroundStyle(AppDesign.tertiaryText)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: AppDesign.mediumCornerRadius, style: .continuous)
                        .fill(AppDesign.tintedSurface(AppDesign.primaryBlue, opacity: 0.13))
                )

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 8
                ) {
                    OverviewMetric(title: "日均学习", value: formatCompactDuration(engine.averageDailyDuration), icon: "chart.bar.fill", tint: AppDesign.websiteTeal)
                    OverviewMetric(title: "活跃天数", value: "\(engine.activeDays) 天", icon: "calendar.badge.checkmark", tint: AppDesign.successGreen)
                    OverviewMetric(
                        title: "与上期对比",
                        value: formatComparisonValue(engine.comparison),
                        subtitle: formatComparisonSubtitle(engine.comparison, range: selectedRange),
                        icon: "arrow.up.right",
                        tint: AppDesign.leisurePurple
                    )

                    // 起止时间沿用当前周期的学习日志计算结果，和总学习时长保持同一统计口径。
                    OverviewMetric(
                        title: "最早开始",
                        value: engine.earliestStudyStart.map(formatClock) ?? "--:--",
                        subtitle: "本期最早开始学习",
                        icon: "sunrise.fill",
                        tint: AppDesign.successGreen
                    )
                    OverviewMetric(
                        title: "最晚结束",
                        value: engine.latestStudyEnd.map(formatClock) ?? "--:--",
                        subtitle: "本期最晚结束学习",
                        icon: "moon.stars.fill",
                        tint: AppDesign.leisurePurple
                    )
                }
                .frame(width: 390)
            }
        }
        .appPanel(.regular)
    }

    private var emptyStateView: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 42))
                .foregroundColor(.secondary.opacity(0.35))
            Text("当前时间范围没有记录")
                .font(.headline)
            Text("产生新的 App 或网站使用记录后，这里会显示统计数据。")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filteredEmptyStateView: some View {
        VStack(spacing: 14) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.35))
            Text("无匹配记录")
                .font(.headline)
            Text("请调整筛选条件。")
                .font(.caption)
                .foregroundColor(.secondary)
            Button("清空筛选") {
                clearFilters()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    // MARK: - Logic Helpers

    private func refreshRangeData() {
        engine.refreshBaseData(for: selectedRange, modelContext: modelContext, whitelist: whitelist)
    }

    private func refreshUsageQueryData() {
        engine.refreshUsageQueryData(for: selectedUsageRange, whitelist: whitelist)
    }

    private func refreshActivePageData() {
        // 概览和记录明细共享周期数据；使用查询则读取自己独立的自然月范围。
        if selectedPage == .usageQuery {
            refreshUsageQueryData()
        } else {
            refreshRangeData()
        }
    }

    private func refreshFiltersOnly() {
        engine.applyFilters(
            searchText: searchText,
            contentFilter: selectedContentFilter,
            appFilter: selectedAppFilter,
            domainFilter: selectedDomainFilter,
            dimension: selectedDimension,
            range: selectedRange
        )
    }

    private func shiftReferencePeriod(by val: Int) {
        engine.shiftReferenceDate(by: val, range: selectedRange)
        refreshRangeData()
    }

    private func sanitizeFilterSelection() {
        if let selectedAppFilter,
           !engine.appFilterOptions.contains(where: { $0.name == selectedAppFilter }) {
            self.selectedAppFilter = nil
        }

        if let selectedDomainFilter,
           !engine.domainFilterOptions.contains(where: { $0.name == selectedDomainFilter }) {
            self.selectedDomainFilter = nil
        }
    }

    private func sanitizeUsageQuerySelection() {
        // 1. 维度切换或时间范围刷新后，只保留仍存在于新选项集中的查询对象。
        let options: [FilterOption]
        switch selectedUsageDimension {
        case .app:
            options = engine.usageAppOptions
        case .domain:
            options = engine.usageDomainOptions
        case .pdf:
            options = engine.usagePDFOptions
        }
        let resolvedItem = selectedUsageItem.flatMap { current in
            options.contains(where: { $0.queryKey == current }) ? current : nil
        } ?? options.first?.queryKey

        // 2. 选择发生变化时交给 onChange 统一刷新；未变化时主动重算刚加载的新一批月度数据。
        if selectedUsageItem != resolvedItem {
            selectedUsageItem = resolvedItem
        } else {
            engine.updateUsageQuery(for: selectedUsageDimension, queryKey: resolvedItem)
        }
    }

    private func clearFilters() {
        searchDebounceTask?.cancel()
        searchText = ""
        selectedContentFilter = .all
        selectedAppFilter = nil
        selectedDomainFilter = nil
        refreshFiltersOnly()
    }

    private func scheduleSearchRefresh() {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                refreshFiltersOnly()
            }
        }
    }

    private func deleteLogs(on selectedDay: Date?, category: DetailCategory, summaryName: String, detailName: String) {
        // 1. 调用业务引擎的 deleteLogs 方法，从持久化层擦除数据。
        engine.deleteLogs(on: selectedDay, category: category, summaryName: summaryName, detailName: detailName, modelContext: modelContext)

        // 2. 执行保存完后刷新引擎数据。
        refreshRangeData()
    }

    // MARK: - Formatters

    private func formatCompactDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return hours > 0 ? "\(hours)小时\(minutes)分" : "\(minutes)分"
    }

    private func formatDetailedDuration(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let remainingSeconds = Int(seconds) % 60
        return hours > 0
            ? String(format: "%02d时%02d分%02d秒", hours, minutes, remainingSeconds)
            : String(format: "%02d分%02d秒", minutes, remainingSeconds)
    }

    private func formatShortDate(_ date: Date) -> String {
        let comps = calendar.dateComponents([.month, .day], from: date)
        return "\(comps.month ?? 0)/\(comps.day ?? 0)"
    }

    private func formatLongDate(_ date: Date) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(comps.year ?? 0)年\(comps.month ?? 0)月\(comps.day ?? 0)日"
    }

    private func formatDateRange(for range: StatisticsRange, referenceDate: Date) -> String {
        let now = Date()
        guard let interval = engine.interval(for: range, referenceDate: referenceDate, currentDate: now) else {
            return "全部历史数据"
        }
        let endDate = interval.end.addingTimeInterval(-1)

        let startComps = calendar.dateComponents([.year, .month, .day], from: interval.start)
        let endComps = calendar.dateComponents([.year, .month, .day], from: endDate)

        if range == .today {
            return "\(startComps.year ?? 0)年\(startComps.month ?? 0)月\(startComps.day ?? 0)日"
        }

        return "\(startComps.month ?? 0)/\(startComps.day ?? 0) - \(endComps.month ?? 0)/\(endComps.day ?? 0)"
    }

    private func formatClock(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    private func formatComparisonValue(_ comparison: ReportComparison?) -> String {
        guard let comparison else { return "暂无上期" }
        if let rate = comparison.totalDurationChangeRate {
            let pct = Int((rate * 100).rounded())
            if pct > 0 {
                return "+\(pct)%"
            } else if pct < 0 {
                return "\(pct)%"
            } else {
                return "持平"
            }
        }
        return "暂无上期"
    }

    private func formatComparisonSubtitle(_ comparison: ReportComparison?, range: StatisticsRange) -> String {
        guard let comparison else { return "暂无可对比的数据" }
        let delta = comparison.totalDurationDelta
        let direction = delta > 0 ? "多" : "少"
        if delta == 0 {
            return "较\(range.previousTitle)持平"
        }
        return "较\(range.previousTitle)\(direction) \(formatCompactDuration(abs(delta)))"
    }
}

// MARK: - Supporting Subviews & Components

private struct OverviewMetric: View {
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

private struct LearningLeisureSummaryBar: View {
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

private struct UsageQuerySection: View {
    @Binding var selectedDimension: UsageQueryDimension
    @Binding var selectedRange: UsageQueryRange
    @Binding var selectedItem: String?
    @Binding var selectedMonth: Date?
    let appOptions: [FilterOption]
    let domainOptions: [FilterOption]
    let pdfOptions: [FilterOption]
    let monthlySummaries: [MonthlyUsageSummary]
    let monthlyWeekSummaries: [MonthlyWeekUsageSummary]
    let totalDuration: TimeInterval
    let isLoading: Bool
    let formatDuration: (TimeInterval) -> String

    @State private var optionSearchText = ""
    @State private var isShowingOptionPicker = false

    private var options: [FilterOption] {
        switch selectedDimension {
        case .app: return appOptions
        case .domain: return domainOptions
        case .pdf: return pdfOptions
        }
    }

    private var matchingOptions: [FilterOption] {
        let keyword = optionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return options }
        return options.filter { $0.name.localizedStandardContains(keyword) }
    }

    private var selectedOption: FilterOption? {
        guard let selectedItem else { return nil }
        return options.first { $0.queryKey == selectedItem }
    }

    private var displayedMonthlySummaries: [MonthlyUsageSummary] {
        // 1. 裁掉首尾连续的零值月份，避免少量近期数据全部挤在图表右侧。
        guard let firstActiveIndex = monthlySummaries.firstIndex(where: { $0.totalTime > 0 }),
              let lastActiveIndex = monthlySummaries.lastIndex(where: { $0.totalTime > 0 }) else {
            return monthlySummaries
        }

        // 2. 保留首尾活跃月之间的零值月份，它们代表真实中断，不能为了居中而抹掉。
        return Array(monthlySummaries[firstActiveIndex...lastActiveIndex])
    }

    private var selectedSummary: MonthlyUsageSummary? {
        guard let selectedMonth else { return displayedMonthlySummaries.last }
        return displayedMonthlySummaries.first { summary in
            Calendar.current.isDate(summary.monthStart, equalTo: selectedMonth, toGranularity: .month)
        } ?? displayedMonthlySummaries.last
    }

    private var displayedMonthlyWeekSummaries: [MonthlyWeekUsageSummary] {
        guard let firstMonth = displayedMonthlySummaries.first?.monthStart,
              let lastMonth = displayedMonthlySummaries.last?.monthStart else {
            return monthlyWeekSummaries
        }
        return monthlyWeekSummaries.filter {
            $0.monthStart >= firstMonth && $0.monthStart <= lastMonth
        }
    }

    private var maximumHours: Double {
        max(1, (displayedMonthlyWeekSummaries.map(\.totalTime).max() ?? 0) / 3600 * 1.15)
    }

    /// 基于月份数量估算每根柱的理想宽度，用于计算绘图区总宽度；柱体本身使用自动宽度避免重叠。
    private var dynamicBarWidth: CGFloat {
        let monthCount = displayedMonthlySummaries.count
        switch monthCount {
        case ...2:  return 28
        case 3:     return 24
        case 4...5: return 20
        case 6...8: return 16
        default:    return 12
        }
    }

    /// 根据月份数量计算绘图区宽度。每个月份占据固定槽位宽度，少月时图表自动收窄，
    /// 多月时允许占满容器，避免柱组在大片空白中迷失。
    private var chartPlotWidth: CGFloat? {
        let monthCount = displayedMonthlySummaries.count
        // 每个月份 4 根柱 + 间隙，按柱宽的倍率估算合理的槽位宽度。
        let slotWidth = dynamicBarWidth * 6.5
        let computedWidth = CGFloat(monthCount) * slotWidth
        // 月份较多时不设固定宽度，让 Chart 自行铺满可用空间。
        return monthCount <= 7 ? max(computedWidth, 180) : nil
    }

    private var selectedMonthKey: Binding<String?> {
        Binding(
            get: {
                selectedMonth.map { monthChartKey($0) }
            },
            set: { key in
                // 分类横轴返回的是稳定的月份键，这里映射回日期以保留原有的月份点击查询能力。
                selectedMonth = displayedMonthlySummaries.first {
                    monthChartKey($0.monthStart) == key
                }?.monthStart
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.sectionSpacing) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("查询对象")
                            .font(.headline)
                        Text(queryDescription)
                            .font(.caption)
                            .foregroundStyle(AppDesign.secondaryText)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        ForEach(UsageQueryDimension.allCases) { dimension in
                            Button(dimension.title) {
                                selectedDimension = dimension
                            }
                            .buttonStyle(AppCapsuleButtonStyle(
                                role: selectedDimension == dimension ? .primary : .secondary,
                                compact: true
                            ))
                        }
                    }
                }

                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(AppDesign.tertiaryText)

                        TextField("搜索\(selectedDimension.title)名称", text: $optionSearchText)
                            .textFieldStyle(.plain)
                            .onSubmit {
                                // 回车直接选择首个匹配项，键盘查询不必再展开选择框。
                                if let firstMatch = matchingOptions.first {
                                    selectedItem = firstMatch.queryKey
                                    optionSearchText = ""
                                    isShowingOptionPicker = false
                                }
                            }

                        if !optionSearchText.isEmpty {
                            Button {
                                optionSearchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(AppDesign.tertiaryText)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("清空搜索")
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: AppDesign.controlHeight)
                    .background(
                        RoundedRectangle(cornerRadius: AppDesign.controlCornerRadius, style: .continuous)
                            .fill(AppDesign.elevatedPanelBackground)
                    )

                    Button {
                        isShowingOptionPicker.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("选择\(selectedDimension.title)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(AppDesign.secondaryText)
                                Text(selectedOption?.name ?? "请选择查询对象")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(AppDesign.primaryText)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(AppDesign.tertiaryText)
                        }
                        .padding(.horizontal, 12)
                        .frame(width: 250, height: AppDesign.controlHeight)
                        .background(
                            RoundedRectangle(cornerRadius: AppDesign.controlCornerRadius, style: .continuous)
                                .fill(AppDesign.elevatedPanelBackground)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(options.isEmpty)
                    .popover(isPresented: $isShowingOptionPicker, arrowEdge: .top) {
                        optionPickerPopover
                    }
                }

                HStack(spacing: 8) {
                    ForEach(UsageQueryRange.allCases) { range in
                        Button(range.title) {
                            selectedRange = range
                        }
                        .buttonStyle(AppCapsuleButtonStyle(
                            role: selectedRange == range ? .primary : .secondary,
                            compact: true
                        ))
                    }

                    Spacer()

                    if !optionSearchText.isEmpty {
                        Text("匹配 \(matchingOptions.count) 项")
                            .font(.caption)
                            .foregroundStyle(AppDesign.secondaryText)
                    } else if !options.isEmpty {
                        Text("共 \(options.count) 项，可输入名称搜索")
                            .font(.caption)
                            .foregroundStyle(AppDesign.secondaryText)
                    }
                }
            }
            .padding(16)
            .statisticsPanel(isSecondary: true)

            if isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在汇总月度使用时间…")
                        .font(.caption)
                        .foregroundStyle(AppDesign.secondaryText)
                }
                .frame(maxWidth: .infinity, minHeight: 290)
                .statisticsPanel()
            } else if options.isEmpty || selectedItem == nil {
                VStack(spacing: 12) {
                    Image(systemName: emptyStateIcon)
                        .font(.system(size: 34))
                        .foregroundStyle(AppDesign.tertiaryText)
                    Text("这个时间范围没有\(selectedDimension.title)记录")
                        .font(.headline)
                    Text("可以切换查询类型或扩大月份范围。")
                        .font(.caption)
                        .foregroundStyle(AppDesign.secondaryText)
                }
                .frame(maxWidth: .infinity, minHeight: 290)
                .statisticsPanel()
            } else {
                monthlyChart
            }
        }
        .onChange(of: selectedDimension) { _, _ in
            optionSearchText = ""
            isShowingOptionPicker = false
        }
        .onChange(of: selectedRange) { _, _ in
            optionSearchText = ""
            isShowingOptionPicker = false
        }
    }

    private var optionPickerPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("选择\(selectedDimension.title)")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(matchingOptions.count) 项")
                    .font(.caption)
                    .foregroundStyle(AppDesign.secondaryText)
            }

            Divider()

            if matchingOptions.isEmpty {
                Text("没有匹配的\(selectedDimension.title)")
                    .font(.caption)
                    .foregroundStyle(AppDesign.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 固定浮层尺寸并在内部滚动，避免长文件名或大量选项把系统菜单撑满整个窗口。
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(matchingOptions) { option in
                            Button {
                                selectedItem = option.queryKey
                                optionSearchText = ""
                                isShowingOptionPicker = false
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(AppDesign.primaryText)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text(formatDuration(option.totalTime))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(AppDesign.secondaryText)
                                    }

                                    Spacer(minLength: 8)

                                    if selectedItem == option.queryKey {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(AppDesign.primaryBlue)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 42)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(selectedItem == option.queryKey ? AppDesign.primaryBlueMuted : Color.clear)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 380, height: optionPickerHeight)
    }

    private var optionPickerHeight: CGFloat {
        // 最多直接露出 6 行，其余内容通过滚动查看；少量结果时浮层自动收紧。
        let visibleRowCount = min(max(matchingOptions.count, 1), 6)
        return 70 + CGFloat(visibleRowCount * 46)
    }

    private var monthlyChart: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(selectedOption?.name ?? "") 使用趋势")
                        .font(.headline)
                        .lineLimit(1)
                    Text(formatMonthRange())
                        .font(.caption)
                        .foregroundStyle(AppDesign.secondaryText)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("区间总计")
                        .font(.caption)
                        .foregroundStyle(AppDesign.secondaryText)
                    Text(formatDuration(totalDuration))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(AppDesign.primaryBlue)
                }
            }

            Chart(displayedMonthlyWeekSummaries) { summary in
                // 使用比例宽度而非固定像素，让 Charts 在 span 内自动分配每根柱的空间，避免柱间重叠。
                BarMark(
                    x: .value("月份", monthChartKey(summary.monthStart)),
                    y: .value("小时", summary.totalTime / 3600)
                )
                .position(
                    by: .value("周次", summary.weekIndex),
                    // 同月四柱紧凑排列，两侧留白拉开月份间距。
                    span: .ratio(0.62)
                )
                .foregroundStyle(weekColor(summary.weekIndex))
                .cornerRadius(3)

                if summary.totalTime == 0 {
                    // 零值柱本身没有高度，用基线圆点保留周位置，避免误以为该月缺少某一周。
                    PointMark(
                        x: .value("月份", monthChartKey(summary.monthStart)),
                        y: .value("小时", 0)
                    )
                    .position(
                        by: .value("周次", summary.weekIndex),
                        span: .ratio(0.62)
                    )
                    .symbolSize(14)
                    .foregroundStyle(weekColor(summary.weekIndex).opacity(0.7))
                }
            }
            .frame(height: 260)
            .chartYScale(domain: 0...maximumHours)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.06))
                    AxisValueLabel {
                        if let hours = value.as(Double.self) {
                            Text(hours == 0 ? "0h" : "\(Int(hours.rounded()))h")
                                .font(.system(size: 9))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { value in
                    // 月份之间用虚线分隔，帮助辨认柱组归属。
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                        .foregroundStyle(Color.primary.opacity(0.08))
                    AxisTick()
                    AxisValueLabel {
                        if let key = value.as(String.self) {
                            Text(formatAxisMonth(key))
                                .font(.system(size: 9))
                        }
                    }
                }
            }
            // 月份少时收窄绘图区域，让柱组自然聚拢而非铺满整个宽度。
            .chartPlotStyle { plotArea in
                plotArea.frame(width: chartPlotWidth)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .chartXSelection(value: selectedMonthKey)
            .id("\(selectedDimension.rawValue)|\(selectedRange.rawValue)|\(selectedItem ?? "")")

            HStack {
                HStack(spacing: 12) {
                    ForEach(1...4, id: \.self) { weekIndex in
                        HStack(spacing: 4) {
                            Circle()
                                .fill(weekColor(weekIndex))
                                .frame(width: 7, height: 7)
                            Text("第\(weekIndex)周")
                                .font(.caption)
                                .foregroundStyle(AppDesign.secondaryText)
                        }
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    Text("第 4 周包含 22 日至月底")
                        .font(.caption)
                        .foregroundStyle(AppDesign.secondaryText)
                    if let selectedSummary {
                        Text("\(formatMonthYear(selectedSummary.monthStart)) · \(formatDuration(selectedSummary.totalTime))")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }
                }
            }
        }
        .padding(18)
        .statisticsPanel()
    }

    private var emptyStateIcon: String {
        switch selectedDimension {
        case .app: return "app.dashed"
        case .domain: return "network.slash"
        case .pdf: return "doc.text.magnifyingglass"
        }
    }

    private var queryDescription: String {
        switch selectedDimension {
        case .app:
            return "学习 App 优先展示，其余应用合并为娱乐与杂项"
        case .domain:
            return "仅显示白名单和已识别的学习网站"
        case .pdf:
            return "搜索 PDF，再按自然月查看使用时长"
        }
    }

    private func formatMonthRange() -> String {
        guard let first = displayedMonthlySummaries.first?.monthStart,
              let last = displayedMonthlySummaries.last?.monthStart else {
            return selectedRange.title
        }
        return "\(formatMonthYear(first))—\(formatMonthYear(last)) · 仅展示有记录区间"
    }

    private func monthChartKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    private func formatAxisMonth(_ key: String) -> String {
        guard let month = Int(key.suffix(2)) else { return key }
        return "\(month)月"
    }

    private func weekColor(_ weekIndex: Int) -> Color {
        switch weekIndex {
        case 1: return AppDesign.primaryBlue.opacity(0.34)
        case 2: return AppDesign.primaryBlue.opacity(0.52)
        case 3: return AppDesign.primaryBlue.opacity(0.72)
        default: return AppDesign.primaryBlue
        }
    }

    private func formatMonthYear(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month], from: date)
        return "\(components.year ?? 0)年\(components.month ?? 0)月"
    }
}

private struct FilterSection: View {
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

private struct FilterChip: View {
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

private struct RangeTrendSection: View {
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

private struct DayPickerSection: View {
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

private struct RankingSection: View {
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



private struct SelectedDaySection: View {
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

private struct CategorySummaryGroup: View {
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

private struct SummaryEntryRowView: View {
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

private struct LearningVsEntertainmentDonutCard: View {
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

private struct ContentCategoryDonutCard: View {
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

private struct RhythmSection: View {
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
                        Text("你更常在")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary) +
                        Text(" \(primaryTimeSlot.title) ")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(AppDesign.primaryBlue) +
                        Text("时段进入学习状态。")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
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

private struct ReportRhythmHourlyChart: View {
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

private struct ClockCard: View {
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

private struct AppFocusDonutCard: View {
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

private struct ReportRankingPanel: View {
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

private struct ReportLegendStat: View {
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

private struct ReportPagerButton: View {
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

// MARK: - Shared Statistics Panel Styling

struct StatisticsPanelBackground: ViewModifier {
    var isSecondary: Bool = false

    func body(content: Content) -> some View {
        let resolvedRadius = isSecondary ? AppDesign.mediumCornerRadius : AppDesign.largeCornerRadius

        content
            .background(
                // 宽屏面板与主菜单共用填充与圆角，不再使用白色悬浮卡片和描边。
                RoundedRectangle(cornerRadius: resolvedRadius, style: .continuous)
                    .fill(isSecondary ? AppDesign.elevatedPanelBackground : AppDesign.panelBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: resolvedRadius, style: .continuous)
                            .stroke(Color.primary.opacity(0.04), lineWidth: 1)
                    )
            )
    }
}

extension View {
    fileprivate func statisticsPanel(isSecondary: Bool = false) -> some View {
        self.modifier(StatisticsPanelBackground(isSecondary: isSecondary))
    }
}
