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
        .onChange(of: whitelist.blacklistedApps) { _, _ in refreshActivePageData() }
        .onChange(of: whitelist.blacklistedDomains) { _, _ in refreshActivePageData() }
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
        .onChange(of: selectedRange) { _, newRange in
            // 快捷周期始终表示当前自然周期，避免历史翻页留下的参考日期污染“今天/本周”等标题和数据。
            if newRange != .all {
                engine.resetReferenceDate()
            }

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
                        selectRange(range)
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

    private func selectRange(_ range: StatisticsRange) {
        // 1. 状态变化会由 onChange 统一重置参考日期并刷新；这里只处理周期值确实变化的情况。
        guard selectedRange == range else {
            selectedRange = range
            return
        }

        // 2. 重复点击当前快捷周期时不会触发 onChange，因此主动回到当前周期并重新加载数据。
        guard range != .all else { return }
        engine.resetReferenceDate()
        refreshRangeData()
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
    func statisticsPanel(isSecondary: Bool = false) -> some View {
        self.modifier(StatisticsPanelBackground(isSecondary: isSecondary))
    }
}
