import Foundation
import SwiftData

// MARK: - StatisticsEngine Implementation

@MainActor
@Observable
final class StatisticsEngine {
    // 基础数据与主界面日志
    var baseRangeLogs: [PreparedLog] = []
    var rangeLogs: [PreparedLog] = []
    var previousRangeLogs: [PreparedLog] = []

    var daySummaries: [DaySummary] = []
    var rankingEntries: [RankingEntry] = []
    var rangeTotalDuration: TimeInterval = 0
    var todayDuration: TimeInterval = 0

    var selectedDay: Date?
    var selectedDayAppSummaries: [GroupedSummary] = []
    var selectedDayDomainSummaries: [GroupedSummary] = []
    var selectedDayPdfSummaries: [GroupedSummary] = []
    var topAppSummary: AppDurationSummary?

    var appFilterOptions: [FilterOption] = []
    var domainFilterOptions: [FilterOption] = []

    // 统一周期与对比状态
    var referenceDate: Date = Date()
    var canShowPreviousPeriod = false
    var canShowNextPeriod = false

    // 常用项目排行缓存
    var topWebsites: [RankingEntry] = []
    var topPDFs: [RankingEntry] = []
    var topStudyApps: [RankingEntry] = []

    // 合并后的报告扩展统计量
    var studyDuration: TimeInterval = 0
    var entertainmentDuration: TimeInterval = 0
    var activeDays: Int = 0
    var averageDailyDuration: TimeInterval = 0
    var strongestDay: DaySummary?
    var shortestActiveDay: DaySummary?
    var longestStreak: Int = 0

    var websiteDuration: TimeInterval = 0
    var pdfDuration: TimeInterval = 0
    var primaryTimeSlot: ReportTimeSlot?
    var earliestStudyStart: Date?
    var latestStudyEnd: Date?
    var comparison: ReportComparison?
    var hourlyDurations: [Double] = Array(repeating: 0.0, count: 24)
    var baseDataGeneration: UInt = 0
    var filterComputationGeneration: UInt = 0
    var isLoadingBaseData = false

    // 单项使用查询独立于概览周期，避免切换查询对象时重算整张统计页。
    var usageQueryLogs: [PreparedLog] = []
    var usageAppOptions: [FilterOption] = []
    var usageDomainOptions: [FilterOption] = []
    var usagePDFOptions: [FilterOption] = []
    var monthlyUsageSummaries: [MonthlyUsageSummary] = []
    var monthlyWeekUsageSummaries: [MonthlyWeekUsageSummary] = []
    var usageQueryTotalDuration: TimeInterval = 0
    var usageQueryGeneration: UInt = 0
    var isLoadingUsageQuery = false

    private var baseDataLoadingTask: Task<Void, Never>?
    private var baseDataLoadingToken: UInt = 0
    private var filterComputationTask: Task<Void, Never>?
    private var filterComputationToken: UInt = 0
    private var usageQueryLoadingTask: Task<Void, Never>?
    private var usageQueryLoadingToken: UInt = 0
    private var usageQueryInterval: DateInterval?
    private let calendar = Calendar.current

    // MARK: - Data Refreshing

    func cancelPendingWork() {
        // 关闭统计窗口后立即让后台读取和聚合失效，避免用户已经离开页面时仍继续占用 CPU 与磁盘。
        baseDataLoadingTask?.cancel()
        filterComputationTask?.cancel()
        usageQueryLoadingTask?.cancel()
        baseDataLoadingToken &+= 1
        filterComputationToken &+= 1
        usageQueryLoadingToken &+= 1
        baseDataLoadingTask = nil
        filterComputationTask = nil
        usageQueryLoadingTask = nil
        isLoadingBaseData = false
        isLoadingUsageQuery = false
    }

    /// 刷新选定周期下的底量数据，执行数据库抓取并清洗
    func refreshBaseData(for range: StatisticsRange, modelContext: ModelContext, whitelist: WhitelistManager) {
        baseDataLoadingTask?.cancel()
        filterComputationTask?.cancel()
        usageQueryLoadingTask?.cancel()
        baseDataLoadingToken &+= 1
        usageQueryLoadingToken &+= 1
        usageQueryLoadingTask = nil
        isLoadingUsageQuery = false

        let token = baseDataLoadingToken
        let databaseURL = ActivityLogSnapshotStore.databaseURL()
        let referenceDate = referenceDate
        let calendar = calendar
        isLoadingBaseData = true

        // 1. 根据当前参考日期和时间周期计算出要抓取的数据时间跨度。
        let whitelistSnapshot = WhitelistSnapshot(whitelist: whitelist)
        let fetchInterval = fetchInterval(for: range, referenceDate: referenceDate, currentDate: Date())

        baseDataLoadingTask = Task.detached(priority: .userInitiated) {
            // 2. 优先读取已结束整天的聚合缓存；缓存缺失或源数据变更时在后台按天重建。
            let newRangeLogs = ActivityAggregateCacheStore.fetchPreparedLogs(
                databaseURL: databaseURL,
                interval: fetchInterval,
                whitelist: whitelistSnapshot,
                calendar: calendar
            )
            let newAppFilterOptions = Self.buildFilterOptions(from: newRangeLogs, dimension: .app)
            let newDomainFilterOptions = Self.buildFilterOptions(from: newRangeLogs, dimension: .domain)

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard token == self.baseDataLoadingToken else { return }

                // 3. 将全局状态缓存并生成筛选器的快捷选项。generation 只在整批数据落地后递增，
                // 让视图层能在正确时机重新套用搜索和筛选条件。
                self.baseRangeLogs = newRangeLogs
                self.appFilterOptions = newAppFilterOptions
                self.domainFilterOptions = newDomainFilterOptions
                self.baseDataGeneration &+= 1
                self.isLoadingBaseData = false
            }
        }
    }

    /// 读取单项使用查询所需的底量数据；App 和域名选项共用同一批日志，切换维度无需重复访问磁盘。
    func refreshUsageQueryData(for range: UsageQueryRange, whitelist: WhitelistManager) {
        baseDataLoadingTask?.cancel()
        filterComputationTask?.cancel()
        usageQueryLoadingTask?.cancel()
        baseDataLoadingToken &+= 1
        filterComputationToken &+= 1
        usageQueryLoadingToken &+= 1
        baseDataLoadingTask = nil
        filterComputationTask = nil
        isLoadingBaseData = false

        let token = usageQueryLoadingToken
        let now = Date()
        let calendar = calendar
        guard let interval = range.interval(containing: now, calendar: calendar) else {
            usageQueryLogs = []
            usageAppOptions = []
            usageDomainOptions = []
            usagePDFOptions = []
            monthlyUsageSummaries = []
            monthlyWeekUsageSummaries = []
            usageQueryTotalDuration = 0
            isLoadingUsageQuery = false
            return
        }

        let databaseURL = ActivityLogSnapshotStore.databaseURL()
        let whitelistSnapshot = WhitelistSnapshot(whitelist: whitelist)
        isLoadingUsageQuery = true

        usageQueryLoadingTask = Task.detached(priority: .userInitiated) {
            // 1. 使用现有按日聚合缓存读取目标月份，避免查询一年数据时重新构建全部 SwiftData 对象。
            let logs = ActivityAggregateCacheStore.fetchPreparedLogs(
                databaseURL: databaseURL,
                interval: interval,
                whitelist: whitelistSnapshot,
                calendar: calendar
            )

            guard !Task.isCancelled else { return }

            // 2. App 只单列学习相关应用，其余普通应用合并；域名和 PDF 则各自按原始标识汇总。
            let appOptions = Self.buildUsageAppOptions(from: logs)
            let domainOptions = Self.buildUsageDomainOptions(from: logs)
            let pdfOptions = Self.buildUsagePDFOptions(from: logs)

            await MainActor.run {
                guard token == self.usageQueryLoadingToken else { return }

                // 3. 整批落地后再递增版本，让视图先校验当前选择，再生成对应月度柱状数据。
                self.usageQueryInterval = interval
                self.usageQueryLogs = logs
                self.usageAppOptions = appOptions
                self.usageDomainOptions = domainOptions
                self.usagePDFOptions = pdfOptions
                self.usageQueryGeneration &+= 1
                self.isLoadingUsageQuery = false
            }
        }
    }

    /// 根据用户选中的 App、域名或 PDF，在内存中快速生成按月趋势。
    func updateUsageQuery(for dimension: UsageQueryDimension, queryKey: String?) {
        guard let interval = usageQueryInterval else {
            monthlyUsageSummaries = []
            monthlyWeekUsageSummaries = []
            usageQueryTotalDuration = 0
            return
        }

        // 1. 按分类键筛选日志。PDF 使用稳定指纹，App 的“其他”项使用专用键，避免与真实名称冲突。
        let normalizedKey = queryKey?.lowercased()
        let learningAppNames = Self.learningAppNames(in: usageQueryLogs)
        let matchingLogs = usageQueryLogs.filter { log in
            guard let normalizedKey else { return false }

            switch dimension {
            case .app:
                guard !log.isWebsite, !log.isPDF else { return false }
                if normalizedKey == Self.otherAppsQueryKey {
                    return !learningAppNames.contains(log.appName.lowercased())
                }
                return log.appName.lowercased() == normalizedKey
            case .domain:
                // 域名趋势只统计既有规则判定为学习的网页记录；B 站仍需知识区标识才能计入。
                return log.isWebsite
                    && log.isStudy
                    && log.resolvedDomain?.lowercased() == normalizedKey
            case .pdf:
                guard log.isPDF else { return false }
                return (log.pdfIdentifier ?? log.windowTitle).lowercased() == normalizedKey
            }
        }

        // 2. 补齐范围内所有自然月，即使当月为零也保留柱位，让时间轴连续且可比较。
        let summaries = Self.monthlyUsageSummaries(
            for: matchingLogs,
            interval: interval,
            calendar: calendar
        )

        let weekSummaries = Self.monthlyWeekUsageSummaries(
            for: matchingLogs,
            interval: interval,
            calendar: calendar
        )

        // 3. 同步回写图表和总计，切换对象时无需重新读取数据库。
        monthlyUsageSummaries = summaries
        monthlyWeekUsageSummaries = weekSummaries
        usageQueryTotalDuration = summaries.reduce(0) { $0 + $1.totalTime }
    }

    /// 应用过滤条件（如搜索字词、内容分类、应用白名单等），在独立线程中执行大量聚合和报告生成计算
    func applyFilters(
        searchText: String,
        contentFilter: ContentFilter,
        appFilter: String?,
        domainFilter: String?,
        dimension: RankingDimension,
        range: StatisticsRange
    ) {
        filterComputationTask?.cancel()
        filterComputationToken &+= 1

        let token = filterComputationToken
        let sourceLogs = baseRangeLogs
        let filters = FilterCriteria(
            normalizedSearchText: searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            selectedContentFilter: contentFilter,
            selectedAppFilter: appFilter,
            selectedDomainFilter: domainFilter
        )
        let currentSelectedDay = selectedDay
        let calendar = calendar
        let now = Date()
        let refDate = referenceDate

        // 1. 获取当前周期以及对比上期的 DateInterval 边界。
        let currentInterval = interval(for: range, referenceDate: refDate, currentDate: now)
        let previousInterval = currentInterval.flatMap { self.previousInterval(for: range, currentInterval: $0) }

        filterComputationTask = Task.detached(priority: .userInitiated) {
            // 2. 区分当前时间段与上期对比时间段的日志数据。
            let currentLogs = sourceLogs.filter { log in
                if let current = currentInterval {
                    return log.startTime >= current.start && log.startTime < current.end
                }
                return true
            }
            let prevLogs = sourceLogs.filter { log in
                if let prev = previousInterval {
                    return log.startTime >= prev.start && log.startTime < prev.end
                }
                return false
            }

            // 3. 将搜索、单应用、单域名等筛选规则应用在这两组日志上。
            let newFilteredLogs = Self.applyCriteria(to: currentLogs, using: filters)
            let prevFilteredLogs = Self.applyCriteria(to: prevLogs, using: filters)

            // 4. 将日志区分为学习与娱乐类别，用于后续指标计算。
            let currentStudyLogs = newFilteredLogs.filter { !Self.isEntertainmentLog($0) }
            let previousStudyLogs = prevFilteredLogs.filter { !Self.isEntertainmentLog($0) }
            let currentEntertainmentLogs = newFilteredLogs.filter { Self.isEntertainmentLog($0) }

            // 5. 计算每日的概览图表趋势点和当前选中的天数。
            // 传入 newFilteredLogs（全部日志，用于获取所有活跃天数以保证可在图表上点选）和 currentStudyLogs（仅学习日志，用于累计学习时长）。
            let newDaySummaries = Self.dailySummaries(for: newFilteredLogs, studyLogs: currentStudyLogs)
            let resolvedDay = Self.resolvedSelectedDay(
                currentSelection: currentSelectedDay,
                from: newDaySummaries,
                calendar: calendar
            )
            let todayLogs = Self.logs(for: now, in: newFilteredLogs, calendar: calendar)
            let selectedLogs = Self.logs(for: resolvedDay, in: newFilteredLogs, calendar: calendar)

            // 6. 执行概览卡片数值计算（学习时长、娱乐时长等）。
            let studyDuration = currentStudyLogs.reduce(0) { $0 + $1.duration }
            let entertainmentDuration = currentEntertainmentLogs.reduce(0) { $0 + $1.duration }
            let activeDays = newDaySummaries.filter { $0.totalTime > 0 }.count
            let averageDailyDuration = activeDays > 0 ? studyDuration / Double(activeDays) : 0

            // 7. 计算高峰日（学习时间最多的一天）与低谷日（已完成天数内学习时间最少的一天）。
            let todayStart = calendar.startOfDay(for: now)
            let completedDays = newDaySummaries.filter { $0.date < todayStart }
            let strongestDay = completedDays.max(by: { $0.totalTime < $1.totalTime })
            let shortestActiveDay = completedDays.min(by: { $0.totalTime < $1.totalTime })

            // 8. 计算连续学习天数、常用 PDF/网页等数据。
            let longestStreak = Self.longestStreak(in: newDaySummaries, calendar: calendar)
            let websiteDuration = currentStudyLogs.filter(\.isWebsite).reduce(0) { $0 + $1.duration }
            let pdfDuration = currentStudyLogs.filter(\.isPDF).reduce(0) { $0 + $1.duration }

            // 9. 计算时段分布，包括最常学习时段、最早开始和最晚结束时间。
            let primaryTimeSlot = Self.strongestTimeSlot(in: currentStudyLogs, calendar: calendar)
            let earliestStudyStart = Self.earliestStudyStart(in: currentStudyLogs, calendar: calendar)
            let latestStudyEnd = Self.latestStudyEnd(in: currentStudyLogs, calendar: calendar)

            // 10. 全天 24 小时活跃度曲线的柱状映射（将秒数累计至 24 个小时桶中）。
            var hourlyDurations = Array(repeating: 0.0, count: 24)
            for log in currentStudyLogs {
                let hour = calendar.component(.hour, from: log.startTime)
                hourlyDurations[hour] += log.duration
            }

            // 11. 与上一周期进行同比数据比较。
            let comparison = Self.buildComparison(currentLogs: currentStudyLogs, previousLogs: previousStudyLogs)

            // 12. 排行榜必须从学习日志中单独计算，避免娱乐应用被展示在“学习来源”中。
            let topWebsites = Self.rankingEntries(for: currentStudyLogs.filter(\.isWebsite), dimension: .domain).prefix(3).map { $0 }
            let topPDFs = Self.rankingEntries(for: currentStudyLogs.filter(\.isPDF), dimension: .item).prefix(3).map { $0 }
            let topStudyApps = Self.rankingEntries(for: currentStudyLogs, dimension: .app).prefix(3).map { $0 }

            let result = FilterComputationResult(
                filteredLogs: newFilteredLogs,
                previousFilteredLogs: prevFilteredLogs,
                daySummaries: newDaySummaries,
                rangeTotalDuration: newFilteredLogs.reduce(0) { $0 + $1.duration },
                topAppSummary: Self.topAppSummary(in: sourceLogs),
                rankingEntries: Self.rankingEntries(for: currentStudyLogs, dimension: dimension),
                resolvedSelectedDay: resolvedDay,
                todayDuration: todayLogs.filter { !Self.isEntertainmentLog($0) }.reduce(0) { $0 + $1.duration },
                selectedDayAppSummaries: Self.groupedSummaries(for: selectedLogs, dimension: .app),
                selectedDayDomainSummaries: Self.groupedSummaries(for: selectedLogs, dimension: .domain),
                selectedDayPdfSummaries: Self.pdfSummaries(for: selectedLogs),
                topWebsites: topWebsites,
                topPDFs: topPDFs,
                topStudyApps: topStudyApps,
                studyDuration: studyDuration,
                entertainmentDuration: entertainmentDuration,
                activeDays: activeDays,
                averageDailyDuration: averageDailyDuration,
                strongestDay: strongestDay,
                shortestActiveDay: shortestActiveDay,
                longestStreak: longestStreak,
                websiteDuration: websiteDuration,
                pdfDuration: pdfDuration,
                primaryTimeSlot: primaryTimeSlot,
                earliestStudyStart: earliestStudyStart,
                latestStudyEnd: latestStudyEnd,
                comparison: comparison,
                hourlyDurations: hourlyDurations
            )

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard token == self.filterComputationToken else { return }
                self.rangeLogs = result.filteredLogs
                self.previousRangeLogs = result.previousFilteredLogs
                self.daySummaries = result.daySummaries
                self.rangeTotalDuration = result.rangeTotalDuration
                self.topAppSummary = result.topAppSummary
                self.rankingEntries = result.rankingEntries
                self.selectedDay = result.resolvedSelectedDay
                self.todayDuration = result.todayDuration
                self.selectedDayAppSummaries = result.selectedDayAppSummaries
                self.selectedDayDomainSummaries = result.selectedDayDomainSummaries
                self.selectedDayPdfSummaries = result.selectedDayPdfSummaries
                self.topWebsites = result.topWebsites
                self.topPDFs = result.topPDFs
                self.topStudyApps = result.topStudyApps

                // 更新合并生成的报告分析指标
                self.studyDuration = result.studyDuration
                self.entertainmentDuration = result.entertainmentDuration
                self.activeDays = result.activeDays
                self.averageDailyDuration = result.averageDailyDuration
                self.strongestDay = result.strongestDay
                self.shortestActiveDay = result.shortestActiveDay
                self.longestStreak = result.longestStreak
                self.websiteDuration = result.websiteDuration
                self.pdfDuration = result.pdfDuration
                self.primaryTimeSlot = result.primaryTimeSlot
                self.earliestStudyStart = result.earliestStudyStart
                self.latestStudyEnd = result.latestStudyEnd
                self.comparison = result.comparison
                self.hourlyDurations = result.hourlyDurations

                // 所有统计字段落地后再递增版本，让年度报告不会在半成品状态下结束加载。
                self.filterComputationGeneration &+= 1

                // 根据是否有上周期数据更新翻页按钮的可用状态
                self.updatePaginationState(range: range, now: now)
            }
        }
    }

    /// 切换排行榜排序维度（应用 / 域名 / 网页标题）时的极速响应函数
    func updateRanking(for dimension: RankingDimension) {
        // rangeLogs 还承担全天活动明细的数据源，不能直接改成只保存学习日志；
        // 排行切换时必须再次过滤，否则娱乐应用会在切换维度后重新混入学习榜。
        let studyLogs = rangeLogs.filter { !Self.isEntertainmentLog($0) }
        rankingEntries = Self.rankingEntries(for: studyLogs, dimension: dimension)
    }

    /// 用户在每日趋势图中点击选择不同日期时，快速更新详情卡片数据
    func updateSelectedDay(_ day: Date) {
        if selectedDay != day {
            selectedDay = day
        }
        let selectedLogs = Self.logs(for: day, in: rangeLogs, calendar: calendar)
        selectedDayAppSummaries = Self.groupedSummaries(for: selectedLogs, dimension: .app)
        selectedDayDomainSummaries = Self.groupedSummaries(for: selectedLogs, dimension: .domain)
        selectedDayPdfSummaries = Self.pdfSummaries(for: selectedLogs)
    }

    /// 从数据库中删除特定日期和分类下的日志，并持久化保存
    func deleteLogs(on selectedDay: Date?, category: DetailCategory, summaryName: String, detailName: String, modelContext: ModelContext) {
        guard let selectedDay else { return }

        // 1. 聚合缓存下 rangeLogs 可能是“多条原始日志合并后的统计行”，不能再用统计行的 duration 反查原始记录。
        // 因此删除时重新抓取当天原始日志，并用同一套 PreparedLog 规则判断哪些原始行应被清理。
        let dayStart = calendar.startOfDay(for: selectedDay)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return }
        let descriptor = FetchDescriptor<ActivityLog>(predicate: #Predicate { log in
            log.startTime >= dayStart && log.startTime < dayEnd
        })
        let whitelistSnapshot = WhitelistSnapshot(whitelist: WhitelistManager.shared)
        let sourceLogs = (try? modelContext.fetch(descriptor)) ?? []
        let logsToDelete = sourceLogs.filter { log in
            guard let prepared = PreparedLog(log: log, whitelist: whitelistSnapshot, calendar: calendar) else {
                return false
            }

            // 2. 按当前详情卡片的分类语义匹配原始记录，而不是匹配聚合缓存行。
            switch category {
            case .app:
                return prepared.appName == summaryName && prepared.windowTitle == detailName
            case .domain:
                return prepared.resolvedDomain == summaryName
            case .pdf:
                return prepared.isPDF && prepared.windowTitle == summaryName && prepared.windowTitle == detailName
            }
        }

        guard !logsToDelete.isEmpty else { return }

        // 3. 删除匹配到的原始 SwiftData 日志，并清除当天缓存，确保下一次刷新会从事实源重建统计。
        for log in logsToDelete {
                modelContext.delete(log)
        }

        try? modelContext.save()
        ActivityAggregateCacheStore.invalidateDay(
            databaseURL: ActivityLogSnapshotStore.databaseURL(),
            dayStart: dayStart
        )
    }

    /// 前后翻页逻辑，基于当前时间跨度周期平移参考时间
    func shiftReferenceDate(by value: Int, range: StatisticsRange) {
        let component: Calendar.Component
        switch range {
        case .today: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        case .year: component = .year
        case .all: return
        }

        if let newDate = calendar.date(byAdding: component, value: value, to: referenceDate) {
            referenceDate = newDate
        }
    }

    /// 将快捷周期的参考日期恢复为当前时间，避免历史翻页状态泄漏到当前周期。
    func resetReferenceDate() {
        referenceDate = Date()
    }

    // MARK: - Private Helpers

    private func updatePaginationState(range: StatisticsRange, now: Date) {
        // 1. 判断是否能够向前翻页。如果我们在最前没有数据的阶段，或者使用“全部”范围，则禁用。
        if range == .all {
            canShowPreviousPeriod = false
            canShowNextPeriod = false
            return
        }

        // 2. 检查是否有上一周期日志。这里可以通过 previousRangeLogs 是否有数据或之前是否有基础数据来确定。
        // 为了获得良好的体验，如果上一周期有数据记录，或者存在更早的历史数据，设为可向前翻页。
        canShowPreviousPeriod = !previousRangeLogs.isEmpty || baseRangeLogs.contains { $0.startTime < (interval(for: range, referenceDate: referenceDate, currentDate: now)?.start ?? Date()) }

        // 3. 判断是否能够向后翻页（不能越过当前周期的截止点）。
        guard let current = interval(for: range, referenceDate: referenceDate, currentDate: now),
              let latest = interval(for: range, referenceDate: now, currentDate: now) else {
            canShowNextPeriod = false
            return
        }
        canShowNextPeriod = current.start < latest.start
    }

    private func fetchLogs(for range: StatisticsRange, referenceDate: Date, modelContext: ModelContext) -> [ActivityLog] {
        let now = Date()
        guard let current = interval(for: range, referenceDate: referenceDate, currentDate: now) else {
            // 抓取全部日志数据
            let sortBy = [SortDescriptor(\ActivityLog.startTime, order: .reverse)]
            do {
                return try modelContext.fetch(FetchDescriptor<ActivityLog>(sortBy: sortBy))
            } catch {
                print("[StatisticsEngine] 抓取全部日志失败: \(error.localizedDescription)")
                return []
            }
        }

        // 为了进行同比对比计算，我们需要抓取当前周期和前一周期两个区间的连续日志。
        let start: Date
        if let prev = previousInterval(for: range, currentInterval: current) {
            start = prev.start
        } else {
            start = current.start
        }
        let end = current.end

        let descriptor = FetchDescriptor<ActivityLog>(
            predicate: #Predicate { log in
                log.startTime >= start && log.startTime < end
            },
            sortBy: [SortDescriptor(\ActivityLog.startTime, order: .reverse)]
        )

        do {
            return try modelContext.fetch(descriptor)
        } catch {
            print("[StatisticsEngine] 抓取日志失败: \(error.localizedDescription)")
            return []
        }
    }

    private func fetchInterval(for range: StatisticsRange, referenceDate: Date, currentDate: Date) -> DateInterval? {
        guard let current = interval(for: range, referenceDate: referenceDate, currentDate: currentDate) else {
            return nil
        }

        // 为了进行同比对比计算，后台读取当前周期和前一周期两个区间的连续日志。
        let start = previousInterval(for: range, currentInterval: current)?.start ?? current.start
        return DateInterval(start: start, end: current.end)
    }

    nonisolated private static func buildFilterOptions(from logs: [PreparedLog], dimension: RankingDimension) -> [FilterOption] {
        Self.rankingEntries(for: logs, dimension: dimension).map {
            FilterOption(name: $0.name, totalTime: $0.totalTime)
        }
    }

    nonisolated private static let otherAppsQueryKey = "__grandletick_other_apps__"

    nonisolated private static func learningAppNames(in logs: [PreparedLog]) -> Set<String> {
        // 网页和 PDF 已有独立查询分类，这里只识别白名单规则命中的普通学习应用。
        Set(
            logs.lazy
                .filter { $0.isStudy && !$0.isWebsite && !$0.isPDF }
                .map { $0.appName.lowercased() }
        )
    }

    nonisolated private static func buildUsageAppOptions(from logs: [PreparedLog]) -> [FilterOption] {
        // 1. 仅将学习相关普通 App 单独分组，避免娱乐应用把主要查询对象淹没。
        let learningNames = learningAppNames(in: logs)
        let appLogs = logs.filter { !$0.isWebsite && !$0.isPDF }
        let groupedLearningLogs = Dictionary(grouping: appLogs.filter {
            learningNames.contains($0.appName.lowercased())
        }) { $0.appName.lowercased() }

        var options = groupedLearningLogs.map { queryKey, groupedLogs in
            let displayName = groupedLogs.max(by: { $0.startTime < $1.startTime })?.appName ?? queryKey
            return FilterOption(
                name: displayName,
                totalTime: groupedLogs.reduce(0) { $0 + $1.duration },
                queryKey: queryKey
            )
        }
        .sorted { $0.totalTime > $1.totalTime }

        // 2. 其余非网页、非 PDF 应用统一归入杂项，保留总量但不再逐项制造选择噪音。
        let otherDuration = appLogs.reduce(0) { partialResult, log in
            learningNames.contains(log.appName.lowercased())
                ? partialResult
                : partialResult + log.duration
        }
        if otherDuration > 0 {
            options.append(
                FilterOption(
                    name: "其他娱乐与杂项",
                    totalTime: otherDuration,
                    queryKey: otherAppsQueryKey
                )
            )
        }
        return options
    }

    nonisolated private static func buildUsageDomainOptions(from logs: [PreparedLog]) -> [FilterOption] {
        // 1. 复用统一学习分类，只保留白名单网站和已识别的学习网页记录。
        // 这样娱乐网站、局域网地址与浏览器内部页不会进入查询候选项。
        let domainLogs = logs.filter {
            $0.isWebsite && $0.isStudy && $0.resolvedDomain != nil
        }

        // 2. 域名大小写不应生成重复选项；选择键统一小写，显示名保留最近记录中的写法。
        let grouped = Dictionary(grouping: domainLogs) { $0.resolvedDomain?.lowercased() ?? "" }
        return grouped.compactMap { queryKey, groupedLogs in
            guard !queryKey.isEmpty else { return nil }
            let displayName = groupedLogs.max(by: { $0.startTime < $1.startTime })?.resolvedDomain ?? queryKey
            return FilterOption(
                name: displayName,
                totalTime: groupedLogs.reduce(0) { $0 + $1.duration },
                queryKey: queryKey
            )
        }
        .sorted { $0.totalTime > $1.totalTime }
    }

    nonisolated private static func buildUsagePDFOptions(from logs: [PreparedLog]) -> [FilterOption] {
        // 1. 继续沿用历史 PDF 指纹作为合并键，让同一文件改名后仍是一条连续趋势。
        let grouped = Dictionary(grouping: logs.filter(\.isPDF)) { log in
            log.pdfIdentifier ?? log.windowTitle
        }

        // 2. 界面显示最近一次文件名，查询时仍传递稳定指纹。
        return grouped.map { queryKey, groupedLogs in
            let displayName = groupedLogs.max(by: { $0.startTime < $1.startTime })?.windowTitle ?? queryKey
            return FilterOption(
                name: displayName,
                totalTime: groupedLogs.reduce(0) { $0 + $1.duration },
                queryKey: queryKey
            )
        }
        .sorted { $0.totalTime > $1.totalTime }
    }

    nonisolated private static func monthlyUsageSummaries(
        for logs: [PreparedLog],
        interval: DateInterval,
        calendar: Calendar
    ) -> [MonthlyUsageSummary] {
        // 1. 按自然月建立连续的零值桶，当前月也只覆盖查询区间内已经发生的部分。
        guard let firstMonth = calendar.dateInterval(of: .month, for: interval.start)?.start else {
            return []
        }

        var monthStarts: [Date] = []
        var cursor = firstMonth
        while cursor < interval.end {
            monthStarts.append(cursor)
            guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = nextMonth
        }

        var durationByMonth = Dictionary(uniqueKeysWithValues: monthStarts.map { ($0, 0.0) })

        // 2. 聚合缓存以自然日为最小边界，因此按日志所属自然月累加可保持与现有日/月统计语义一致。
        for log in logs {
            guard log.startTime >= interval.start,
                  log.startTime < interval.end,
                  let monthStart = calendar.dateInterval(of: .month, for: log.startTime)?.start,
                  durationByMonth[monthStart] != nil else {
                continue
            }
            durationByMonth[monthStart, default: 0] += log.duration
        }

        // 3. 依时间顺序输出，Swift Charts 可以稳定复用同一组月份坐标。
        return monthStarts.map { monthStart in
            MonthlyUsageSummary(
                monthStart: monthStart,
                totalTime: durationByMonth[monthStart, default: 0]
            )
        }
    }

    nonisolated private static func monthlyWeekUsageSummaries(
        for logs: [PreparedLog],
        interval: DateInterval,
        calendar: Calendar
    ) -> [MonthlyWeekUsageSummary] {
        // 1. 建立查询区间内每个自然月的四个固定周段，保证所有月份拥有相同的比较结构。
        guard let firstMonth = calendar.dateInterval(of: .month, for: interval.start)?.start else {
            return []
        }

        var monthStarts: [Date] = []
        var cursor = firstMonth
        while cursor < interval.end {
            monthStarts.append(cursor)
            guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = nextMonth
        }

        var durationsByMonth = Dictionary(
            uniqueKeysWithValues: monthStarts.map { ($0, Array(repeating: 0.0, count: 4)) }
        )

        // 2. 以 1–7、8–14、15–21、22–月底划分四段；最后一段吸收多出的日期，避免月底数据丢失。
        for log in logs {
            guard log.startTime >= interval.start,
                  log.startTime < interval.end,
                  let monthStart = calendar.dateInterval(of: .month, for: log.startTime)?.start,
                  var weekDurations = durationsByMonth[monthStart] else {
                continue
            }

            let dayOfMonth = max(1, calendar.component(.day, from: log.startTime))
            let weekIndex = min((dayOfMonth - 1) / 7, 3)
            weekDurations[weekIndex] += log.duration
            durationsByMonth[monthStart] = weekDurations
        }

        // 3. 按月份和周次稳定输出，视图层可以直接生成每月四柱的分组图。
        return monthStarts.flatMap { monthStart in
            let weekDurations = durationsByMonth[monthStart] ?? Array(repeating: 0, count: 4)
            return weekDurations.enumerated().map { index, duration in
                MonthlyWeekUsageSummary(
                    monthStart: monthStart,
                    weekIndex: index + 1,
                    totalTime: duration
                )
            }
        }
    }

    // MARK: - Date Intervals Calculations

    func interval(for range: StatisticsRange, referenceDate: Date, currentDate: Date) -> DateInterval? {
        let startOfRef = calendar.startOfDay(for: referenceDate)

        switch range {
        case .today:
            let start = startOfRef
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? currentDate
            let isCurrent = calendar.isDate(referenceDate, inSameDayAs: currentDate)
            let cappedEnd = isCurrent ? min(end, currentDate) : end
            return DateInterval(start: start, end: max(start, cappedEnd))

        case .week:
            guard let naturalInterval = calendar.dateInterval(of: .weekOfYear, for: referenceDate) else { return nil }
            let isCurrent = naturalInterval.contains(currentDate) || naturalInterval.start >= currentDate
            let cappedEnd = isCurrent ? min(naturalInterval.end, currentDate) : naturalInterval.end
            return DateInterval(start: naturalInterval.start, end: max(naturalInterval.start, cappedEnd))

        case .month:
            guard let naturalInterval = calendar.dateInterval(of: .month, for: referenceDate) else { return nil }
            let isCurrent = naturalInterval.contains(currentDate) || naturalInterval.start >= currentDate
            let cappedEnd = isCurrent ? min(naturalInterval.end, currentDate) : naturalInterval.end
            return DateInterval(start: naturalInterval.start, end: max(naturalInterval.start, cappedEnd))

        case .year:
            guard let naturalInterval = calendar.dateInterval(of: .year, for: referenceDate) else { return nil }
            let isCurrent = naturalInterval.contains(currentDate) || naturalInterval.start >= currentDate
            let cappedEnd = isCurrent ? min(naturalInterval.end, currentDate) : naturalInterval.end
            return DateInterval(start: naturalInterval.start, end: max(naturalInterval.start, cappedEnd))

        case .all:
            return nil
        }
    }

    func previousInterval(for range: StatisticsRange, currentInterval: DateInterval) -> DateInterval? {
        switch range {
        case .today:
            guard let prevStart = calendar.date(byAdding: .day, value: -1, to: currentInterval.start),
                  let prevEnd = calendar.date(byAdding: .day, value: -1, to: currentInterval.end) else { return nil }
            return DateInterval(start: prevStart, end: prevEnd)

        case .week:
            guard let prevStart = calendar.date(byAdding: .weekOfYear, value: -1, to: currentInterval.start),
                  let prevEnd = calendar.date(byAdding: .weekOfYear, value: -1, to: currentInterval.end) else { return nil }
            return DateInterval(start: prevStart, end: prevEnd)

        case .month:
            guard let prevStart = calendar.date(byAdding: .month, value: -1, to: currentInterval.start),
                  let prevEnd = calendar.date(byAdding: .month, value: -1, to: currentInterval.end) else { return nil }
            return DateInterval(start: prevStart, end: prevEnd)

        case .year:
            guard let prevStart = calendar.date(byAdding: .year, value: -1, to: currentInterval.start),
                  let prevEnd = calendar.date(byAdding: .year, value: -1, to: currentInterval.end) else { return nil }
            return DateInterval(start: prevStart, end: prevEnd)

        case .all:
            return nil
        }
    }

    // MARK: - Thread-Safe Static Logic (Background Processing)

    nonisolated private static func applyCriteria(to logs: [PreparedLog], using filters: FilterCriteria) -> [PreparedLog] {
        return logs.filter { log in
            if let selectedAppFilter = filters.selectedAppFilter, log.appName != selectedAppFilter {
                return false
            }
            if let selectedDomainFilter = filters.selectedDomainFilter, log.resolvedDomain != selectedDomainFilter {
                return false
            }
            switch filters.selectedContentFilter {
            case .all: break
            case .website: if !log.isWebsite { return false }
            case .pdf: if !log.isPDF { return false }
            }
            if filters.normalizedSearchText.isEmpty { return true }
            return log.searchableText.contains(filters.normalizedSearchText)
        }
    }

    nonisolated private static func dailySummaries(for logs: [PreparedLog], studyLogs: [PreparedLog]) -> [DaySummary] {
        let allDays = Set(logs.map { $0.dayStart })
        let studyGrouped = Dictionary(grouping: studyLogs) { $0.dayStart }
        return allDays.map { date in
            let dayStudyLogs = studyGrouped[date] ?? []
            let studyDuration = dayStudyLogs.reduce(0) { $0 + $1.duration }
            return DaySummary(date: date, totalTime: studyDuration)
        }
        .sorted { $0.date < $1.date }
    }

    nonisolated private static func rankingEntries(for logs: [PreparedLog], dimension: RankingDimension) -> [RankingEntry] {
        let grouped = Dictionary(grouping: logs) { log in
            rankingKey(for: log, dimension: dimension)
        }
        return grouped.compactMap { key, groupedLogs in
            guard let key else { return nil }
            let displayName: String
            if dimension == .item, groupedLogs.first?.isPDF == true {
                // 如果是 PDF 且按单项展示，将唯一标识符映射回最近一次的文件名
                displayName = groupedLogs.max(by: { $0.startTime < $1.startTime })?.windowTitle ?? key
            } else {
                displayName = key
            }
            return RankingEntry(name: displayName, totalTime: groupedLogs.reduce(0) { $0 + $1.duration })
        }
        .sorted { $0.totalTime > $1.totalTime }
    }

    nonisolated private static func groupedSummaries(for logs: [PreparedLog], dimension: RankingDimension) -> [GroupedSummary] {
        let grouped = Dictionary(grouping: logs) { log in
            rankingKey(for: log, dimension: dimension)
        }
        return grouped.compactMap { key, groupedLogs in
            guard let key else { return nil }
            if dimension == .domain {
                return GroupedSummary(
                    name: key,
                    totalTime: groupedLogs.reduce(0) { $0 + $1.duration },
                    details: [SummaryDetail(name: key, subtitle: groupedLogs.first?.appName, totalTime: groupedLogs.reduce(0) { $0 + $1.duration })]
                )
            }
            let detailGroups = Dictionary(grouping: groupedLogs) { detailKey(for: $0, dimension: dimension) }
            let details = detailGroups.map { detailKey, detailLogs in
                let displayName: String
                if dimension == .app, detailLogs.first?.isPDF == true {
                    // 如果是在“预览”应用下展示其打开过的 PDF 文件列表，将指纹键映射回最新的文件名
                    displayName = detailLogs.max(by: { $0.startTime < $1.startTime })?.windowTitle ?? detailKey
                } else {
                    displayName = detailKey
                }
                return SummaryDetail(name: displayName, subtitle: detailSubtitle(for: detailLogs, dimension: dimension), totalTime: detailLogs.reduce(0) { $0 + $1.duration })
            }
            .sorted { $0.totalTime > $1.totalTime }
            
            let displayGroupName: String
            if dimension == .item, groupedLogs.first?.isPDF == true {
                // 单项维度（Item）排行下的 PDF 显示最新文件名
                displayGroupName = groupedLogs.max(by: { $0.startTime < $1.startTime })?.windowTitle ?? key
            } else {
                displayGroupName = key
            }
            return GroupedSummary(name: displayGroupName, totalTime: groupedLogs.reduce(0) { $0 + $1.duration }, details: details)
        }
        .sorted { $0.totalTime > $1.totalTime }
    }

    nonisolated private static func pdfSummaries(for logs: [PreparedLog]) -> [GroupedSummary] {
        let pdfLogs = logs.filter(\.isPDF)
        // 使用 pdfIdentifier 作为唯一合并键，不存在特征码的传统数据退回到 windowTitle
        let grouped = Dictionary(grouping: pdfLogs) { $0.pdfIdentifier ?? $0.windowTitle }
        return grouped.map { key, titleLogs in
            let latestTitle = titleLogs.max(by: { $0.startTime < $1.startTime })?.windowTitle ?? key
            return GroupedSummary(
                name: latestTitle,
                totalTime: titleLogs.reduce(0) { $0 + $1.duration },
                details: [SummaryDetail(name: latestTitle, subtitle: titleLogs.first?.appName, totalTime: titleLogs.reduce(0) { $0 + $1.duration })]
            )
        }
        .sorted { $0.totalTime > $1.totalTime }
    }

    nonisolated private static func topAppSummary(in logs: [PreparedLog]) -> AppDurationSummary? {
        let filteredLogs = logs.filter { !isEntertainmentLog($0) }
        return rankingEntries(for: filteredLogs, dimension: .app).first.map {
            AppDurationSummary(displayName: $0.name, totalTime: $0.totalTime)
        }
    }

    nonisolated private static func resolvedSelectedDay(currentSelection: Date?, from daySummaries: [DaySummary], calendar: Calendar) -> Date? {
        guard !daySummaries.isEmpty else { return nil }
        if let currentSelection, daySummaries.contains(where: { calendar.isDate($0.date, inSameDayAs: currentSelection) }) {
            return currentSelection
        }
        return daySummaries.last?.date
    }

    nonisolated private static func logs(for day: Date?, in logs: [PreparedLog], calendar: Calendar) -> [PreparedLog] {
        guard let day else { return [] }
        return logs.filter { calendar.isDate($0.startTime, inSameDayAs: day) }
    }

    nonisolated private static func isEntertainmentLog(_ log: PreparedLog) -> Bool {
        !log.isStudy
    }

    nonisolated private static func rankingKey(for log: PreparedLog, dimension: RankingDimension) -> String? {
        switch dimension {
        case .app: return log.appName
        case .domain: return log.resolvedDomain
        case .item:
            // 如果是 PDF，我们使用唯一指纹作为排行的汇总键，合并同文件重命名产生的多项记录
            if log.isPDF {
                return log.pdfIdentifier ?? log.windowTitle
            }
            return log.windowTitle
        }
    }

    nonisolated private static func detailKey(for log: PreparedLog, dimension: RankingDimension) -> String {
        switch dimension {
        case .app:
            // 预览 App 下展示 PDF 文档明细时，同样以唯一指纹作为合并键
            if log.isPDF {
                return log.pdfIdentifier ?? log.windowTitle
            }
            return log.windowTitle
        case .domain: return log.resolvedDomain ?? log.appName
        case .item: return log.resolvedDomain ?? log.appName
        }
    }

    nonisolated private static func detailSubtitle(for logs: [PreparedLog], dimension: RankingDimension) -> String? {
        guard dimension == .item else { return nil }
        let sources = Set(logs.map { $0.resolvedDomain ?? $0.appName }).sorted()
        return sources.isEmpty ? nil : sources.joined(separator: " · ")
    }

    nonisolated private static func longestStreak(in daySummaries: [DaySummary], calendar: Calendar) -> Int {
        guard !daySummaries.isEmpty else { return 0 }
        
        // 1. 提取所有活跃日期并进行升序排序。
        let sortedDays = daySummaries.map(\.date).sorted()
        var longest = 1
        var current = 1
        
        // 2. 遍历日期数组，判断相邻日期是否连续（相差一天）。
        for index in 1..<sortedDays.count {
            guard let previous = calendar.date(byAdding: .day, value: 1, to: sortedDays[index - 1]) else { continue }
            
            // 3. 若连续则递增当前计数并更新最大连续天数；若中断则重置当前计数。
            if calendar.isDate(previous, inSameDayAs: sortedDays[index]) {
                current += 1
                longest = max(longest, current)
            } else {
                current = 1
            }
        }
        return longest
    }

    nonisolated private static func strongestTimeSlot(in logs: [PreparedLog], calendar: Calendar) -> ReportTimeSlot? {
        guard !logs.isEmpty else { return nil }
        
        // 1. 将日志按开始时间分配到对应的时段桶（上午/下午/晚上/深夜）。
        var buckets: [ReportTimeSlot: TimeInterval] = [:]
        for log in logs {
            let hour = calendar.component(.hour, from: log.startTime)
            let slot: ReportTimeSlot
            switch hour {
            case 6..<12: slot = .morning
            case 12..<18: slot = .afternoon
            case 18..<24: slot = .evening
            default: slot = .lateNight
            }
            buckets[slot, default: 0] += log.duration
        }
        
        // 2. 找出累计时长最高的时段并返回。
        return buckets.max(by: { $0.value < $1.value })?.key
    }

    nonisolated private static func earliestStudyStart(in logs: [PreparedLog], calendar: Calendar) -> Date? {
        logs.min { lhs, rhs in
            minutesSinceStartOfDay(for: lhs.startTime, calendar: calendar) < minutesSinceStartOfDay(for: rhs.startTime, calendar: calendar)
        }?.startTime
    }

    nonisolated private static func latestStudyEnd(in logs: [PreparedLog], calendar: Calendar) -> Date? {
        logs.max { lhs, rhs in
            minutesSinceStartOfDay(for: lhs.endTime, calendar: calendar) < minutesSinceStartOfDay(for: rhs.endTime, calendar: calendar)
        }?.endTime
    }

    nonisolated private static func minutesSinceStartOfDay(for date: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    nonisolated private static func buildComparison(currentLogs: [PreparedLog], previousLogs: [PreparedLog]) -> ReportComparison? {
        guard !previousLogs.isEmpty else { return nil }
        let currentTotal = currentLogs.reduce(0) { $0 + $1.duration }
        let previousTotal = previousLogs.reduce(0) { $0 + $1.duration }
        let currentActiveDays = Set(currentLogs.map(\.dayStart)).count
        let previousActiveDays = Set(previousLogs.map(\.dayStart)).count
        let rate: Double? = previousTotal > 0 ? (currentTotal - previousTotal) / previousTotal : nil
        return ReportComparison(
            totalDurationDelta: currentTotal - previousTotal,
            totalDurationChangeRate: rate,
            activeDaysDelta: currentActiveDays - previousActiveDays
        )
    }
}
